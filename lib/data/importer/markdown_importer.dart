/// Markdown（.md / .markdown）导入。
///
/// 元世界本身就用 Markdown 存正文，所以这一路的重点是**不破坏已有内容**：
/// 不做"清洗"，不做"重新格式化"，只认三件事：
///   1. 可选的 YAML front matter（`title / author / date / source / collection`）
///   2. 文件开头的一个 `# 标题` —— 当作笔记标题，并且不重复写进正文
///      （否则读起来就是"标题下面又一次同样的标题"）
///   3. 正文原样保留，图片/视频的相对路径交给 ImportService 的
///      resolveLocalMedia 一起搬进媒体目录
///
/// 和 txt 一样按扩展名分派，复用同一套落盘、去重、回滚逻辑。
library;

import 'dart:typed_data';

import 'docx_importer.dart';
import 'txt_importer.dart';

class MarkdownImporter {
  const MarkdownImporter._();

  /// Markdown 的管道表格分隔行：`| --- | :---: |`。
  /// 元世界的阅读页没有表格渲染，导入后会被当成普通段落 ——
  /// 和 docx 里的表格一样，得告诉用户"有几个表格没按表格进来"。
  static final RegExp _pipeTableRule = RegExp(
    r'^\s*\|(\s*:?-{2,}:?\s*\|)+\s*$',
    multiLine: true,
  );

  static final RegExp _htmlTable = RegExp('<table', caseSensitive: false);

  static ParsedDocument parse(Uint8List bytes, {String? fallbackTitle}) {
    // 编码复用 txt 的嗅探：BOM → 严格 UTF-8 → GBK。
    // Markdown 在国内也常被 GBK 存过，按 UTF-8 硬解就是一屏乱码。
    final raw = TxtImporter.decodeText(bytes);
    final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final lines = text.split('\n');

    final meta = <String, String>{};
    var start = 0;

    // ── YAML front matter ──────────────────────────────────────────────
    // 只在**第一行就是** `---` 时才认。正文中间的分隔线不能当元信息。
    if (lines.isNotEmpty && lines.first.trim() == '---') {
      var end = -1;
      for (var i = 1; i < lines.length; i++) {
        final t = lines[i].trim();
        if (t == '---' || t == '...') {
          end = i;
          break;
        }
      }
      if (end > 0) {
        for (var i = 1; i < end; i++) {
          final line = lines[i];
          final colon = line.indexOf(':');
          if (colon <= 0) continue;
          final key = line.substring(0, colon).trim().toLowerCase();
          var value = line.substring(colon + 1).trim();
          if (value.length >= 2 &&
              ((value.startsWith('"') && value.endsWith('"')) ||
                  (value.startsWith("'") && value.endsWith("'")))) {
            value = value.substring(1, value.length - 1);
          }
          if (key.isNotEmpty && value.isNotEmpty) meta[key] = value;
        }
        start = end + 1;
      }
    }

    final body = lines.sublist(start);
    while (body.isNotEmpty && body.first.trim().isEmpty) {
      body.removeAt(0);
    }

    // ── 标题 ──────────────────────────────────────────────────────────
    var title = _first(meta, <String>['title', 'name']) ?? '';
    final h1 = RegExp(r'^#\s+(.+?)\s*#*\s*$');
    if (body.isNotEmpty) {
      final m = h1.firstMatch(body.first.trim());
      if (m != null) {
        final headingText = m.group(1)!.trim();
        // 文件开头的一级标题有两种身份：
        //   - 没给 title：它就是标题
        //   - title 和它一样：导出的文件就是「# 标题 + 正文」这个形态，
        //     留着正文里再来一行就是重复
        if (title.isEmpty || title == headingText) {
          title = headingText;
          body.removeAt(0);
          while (body.isNotEmpty && body.first.trim().isEmpty) {
            body.removeAt(0);
          }
        }
      }
    }
    if (title.isEmpty) title = fallbackTitle?.trim() ?? '';
    if (title.isEmpty) title = '未命名';
    if (title.runes.length > 120) {
      title = String.fromCharCodes(title.runes.take(120));
    }

    final markdown = body.join('\n').trim();

    return ParsedDocument(
      title: title,
      markdown: markdown,
      images: const <ParsedImage>[],
      author: _first(meta, <String>['author', 'authors']) ?? '',
      collection: _first(meta, <String>['collection', 'category']) ?? '',
      sourceUrl: _first(meta, <String>['source', 'url', 'link']) ?? '',
      publishedAt: _parseDate(
        _first(meta, <String>['date', 'published', 'created', 'updated']),
      ),
      // 两种"表格"都要数：Markdown 管道表格和直接嵌进来的 HTML 表格。
      // 元世界的正文渲染里没有表格，不报的话用户会以为表格原样进来了。
      tableCount:
          _pipeTableRule.allMatches(markdown).length +
          _htmlTable.allMatches(markdown).length,
    );
  }

  static String? _first(Map<String, String> meta, List<String> keys) {
    for (final k in keys) {
      final v = meta[k];
      if (v != null && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  /// 只认最常见的几种日期写法：`2024-01-02`、`2024/01/02`、带时间的 ISO。
  /// 解析不出来就返回 null —— 退回文件时间，总比瞎猜一个日期强。
  static DateTime? _parseDate(String? raw) {
    if (raw == null) return null;
    final s = raw.trim();
    if (s.isEmpty) return null;
    final iso = DateTime.tryParse(s);
    if (iso != null) return iso;
    final m = RegExp(r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})').firstMatch(s);
    if (m == null) return null;
    final y = int.tryParse(m.group(1)!);
    final mo = int.tryParse(m.group(2)!);
    final d = int.tryParse(m.group(3)!);
    if (y == null || mo == null || d == null) return null;
    if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
    return DateTime(y, mo, d);
  }
}
