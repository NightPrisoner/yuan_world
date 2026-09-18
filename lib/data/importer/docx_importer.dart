/// DOCX 解析器。
///
/// 目标是把「B站专栏导出」的 .docx 转成应用内部统一的 Markdown 表示。
///
/// 这类文档有很规整的头部元信息，实测格式为：
/// ```
/// 我喜欢B站，的同时也讨厌B站          ← 标题
/// 作者：梦之夜囚
/// 发布时间：编辑于 2023年09月10日 05:13
/// 文集：杂碎记
/// 来源：https://www.bilibili.com/read/cv26421497
/// ```
/// 下面 [_extractMeta] 会把这几行抽出来，并从正文中剔除。
///
/// 图片从 `word/media/` 解出，正文里替换成 `images/<序号>.<ext>` 占位，
/// 由调用方落盘后再改写为最终相对路径。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// 从 docx 里解出的一张图片。
class ParsedImage {
  ParsedImage({required this.placeholder, required this.fileName, required this.bytes});

  /// 正文中使用的占位路径，如 `images/1.png`
  final String placeholder;

  /// 原始文件名，如 `image1.png`
  final String fileName;

  final Uint8List bytes;
}

/// 解析结果。
class ParsedDocument {
  ParsedDocument({
    required this.title,
    required this.markdown,
    required this.images,
    this.author = '',
    this.collection = '',
    this.sourceUrl = '',
    this.publishedAt,
    this.tableCount = 0,
  });

  final String title;
  final String markdown;
  final List<ParsedImage> images;
  final String author;
  final String collection;
  final String sourceUrl;
  final DateTime? publishedAt;

  /// 文档里有几个表格。
  ///
  /// 表格没有对应的 Markdown 表示，导入时会整块跳过 ——
  /// 但我们**必须告诉用户**，否则他会以为内容好好地导进来了。
  final int tableCount;
}

class DocxImporter {
  /// 解析 docx 字节流。
  ///
  /// [fallbackTitle] 就是**文件名** —— 现在标题一律用它，不再从文档里猜。
  static ParsedDocument parse(Uint8List bytes, {String? fallbackTitle}) {
    final archive = ZipDecoder().decodeBytes(bytes);

    // 1) 读取关系表，建立 rId -> media 路径的映射
    final relMap = <String, String>{};
    final relsFile = _find(archive, 'word/_rels/document.xml.rels');
    if (relsFile != null) {
      final relDoc = XmlDocument.parse(utf8.decode(_bytesOf(relsFile), allowMalformed: true));
      for (final rel in relDoc.findAllElements('Relationship')) {
        final id = rel.getAttribute('Id');
        final target = rel.getAttribute('Target');
        if (id != null && target != null && target.contains('media/')) {
          relMap[id] = target.startsWith('/') ? target.substring(1) : target;
        }
      }
    }

    // 2) 正文
    final docFile = _find(archive, 'word/document.xml');
    if (docFile == null) {
      throw const FormatException('不是有效的 .docx：缺少 word/document.xml');
    }
    final doc = XmlDocument.parse(utf8.decode(_bytesOf(docFile), allowMalformed: true));

    final body = doc.findAllElements('w:body').firstOrNull ?? doc.rootElement;

    // 3) 逐段转换
    final images = <ParsedImage>[];
    final imageIndexByRel = <String, int>{};
    final lines = <String>[];

    // 列表层级和「有序/无序」都写在 numbering.xml 里，
    // 光看 document.xml 只知道「这段是列表」，分不出是 1. 还是 •
    final numbering = _numberingMap(archive);
    final tableCount = body.findElements('w:tbl').length;

    // 按 body 的**直接子节点**顺序走，而不是 findElements('w:p')。
    //
    // findElements 是递归的，会把表格单元格里的段落也当成正文段落抽出来 ——
    // 结果表格的几行文字散落在正文里，顺序还对不上。必须在这里就分岔。
    for (final child in body.childElements) {
      switch (child.name.local) {
        case 'p':
          lines.add(
            _paragraph(child, relMap, archive, images, imageIndexByRel, numbering),
          );
        case 'tbl':
          final table = _table(
            child,
            relMap,
            archive,
            images,
            imageIndexByRel,
            numbering,
          );
          if (table.isNotEmpty) lines.add(table);
      }
    }

    // 4) 标题取**文件名**，正文就是全文 —— 不再从文档头里抽任何东西。
    //
    // 之前会去正文开头找「作者 / 发布时间 / 文集 / 来源」这几行，
    // 抽出来当元信息、并把这几行从正文里剔掉。问题是：
    //   - 不是每个文档都有这几行，"有头的"和"没头的"导入结果长得不一样
    //   - 靠"第一行有文字"猜标题，遇到以图片、表格、副标题开头的文档就猜错
    // 现在一律用文件名当标题、全文当正文，行为统一且可预期。
    final title = (fallbackTitle ?? '').trim();
    final bodyText = _tidy(lines.join('\n'));

    return ParsedDocument(
      title: title.isEmpty ? '未命名' : title,
      markdown: bodyText,
      images: images,
      tableCount: tableCount,
    );
  }

  /// 把一个 `<w:tbl>` 转成 Markdown 表格。
  ///
  /// 之前整块跳过 —— 用户导入一篇带表格的文章，表格内容直接凭空消失，
  /// 而且没有任何提示。这是往返一致性里损失最大的一处。
  static String _table(
    XmlElement tbl,
    Map<String, String> relMap,
    Archive archive,
    List<ParsedImage> images,
    Map<String, int> imageIndexByRel,
    Map<int, Map<int, bool>> numbering,
  ) {
    final rows = <List<String>>[];

    for (final tr in tbl.findElements('w:tr')) {
      final cells = <String>[];
      for (final tc in tr.findElements('w:tc')) {
        final parts = <String>[];
        for (final p in tc.findElements('w:p')) {
          final text = _paragraph(
            p,
            relMap,
            archive,
            images,
            imageIndexByRel,
            numbering,
          ).trim();
          if (text.isNotEmpty) parts.add(text);
        }
        // 单元格里的换行和竖线都会破坏 Markdown 表格语法
        cells.add(parts.join('<br>').replaceAll('|', r'\|'));
      }
      if (cells.isNotEmpty) rows.add(cells);
    }

    if (rows.isEmpty) return '';

    // 每行列数补齐：Markdown 表格要求每行列数一致，否则渲染器会错位
    final width = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    final b = StringBuffer();
    for (var i = 0; i < rows.length; i++) {
      final row = <String>[
        ...rows[i],
        ...List<String>.filled(width - rows[i].length, ''),
      ];
      b.writeln('| ${row.join(' | ')} |');
      // 表头分隔行：没有它就不是表格，只是一堆竖线
      if (i == 0) {
        b.writeln('| ${List<String>.filled(width, '---').join(' | ')} |');
      }
    }
    return b.toString().trimRight();
  }

  /// 解析 `word/numbering.xml`：`numId → ilvl → 是不是有序列表`。
  ///
  /// Word 的两层间接：段落引用 `numId`，`numId` 指向一个 `abstractNumId`，
  /// 具体格式（bullet / decimal / chineseCounting…）写在 abstractNum 的每一级上。
  static Map<int, Map<int, bool>> _numberingMap(Archive archive) {
    final out = <int, Map<int, bool>>{};
    final f = _find(archive, 'word/numbering.xml');
    if (f == null) return out;

    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(utf8.decode(_bytesOf(f), allowMalformed: true));
    } catch (_) {
      // numbering.xml 坏掉不该让整个导入失败，退化成全部按无序处理
      return out;
    }

    final abstracts = <int, Map<int, bool>>{};
    for (final a in doc.findAllElements('w:abstractNum')) {
      final id = int.tryParse(a.getAttribute('w:abstractNumId') ?? '');
      if (id == null) continue;
      final levels = <int, bool>{};
      for (final lvl in a.findElements('w:lvl')) {
        final ilvl = int.tryParse(lvl.getAttribute('w:ilvl') ?? '') ?? 0;
        final fmt = lvl
                .findAllElements('w:numFmt')
                .map((e) => e.getAttribute('w:val') ?? '')
                .firstOrNull ??
            '';
        // bullet / none 之外都当有序（decimal / chineseCounting / lowerLetter…）
        levels[ilvl] = fmt.isNotEmpty && fmt != 'bullet' && fmt != 'none';
      }
      abstracts[id] = levels;
    }

    for (final n in doc.findAllElements('w:num')) {
      final numId = int.tryParse(n.getAttribute('w:numId') ?? '');
      if (numId == null) continue;
      final absId = int.tryParse(
            n
                    .findAllElements('w:abstractNumId')
                    .map((e) => e.getAttribute('w:val') ?? '')
                    .firstOrNull ??
                '',
          ) ??
          -1;
      out[numId] = abstracts[absId] ?? const <int, bool>{};
    }
    return out;
  }

  // ── 段落转换 ─────────────────────────────────────────────────────────────

  static String _paragraph(
    XmlElement p,
    Map<String, String> relMap,
    Archive archive,
    List<ParsedImage> images,
    Map<String, int> imageIndexByRel,
    Map<int, Map<int, bool>> numbering,
  ) {
    // 图片优先：一个段落若含 drawing，直接产出图片行
    final blips = p.findAllElements('a:blip').toList();
    if (blips.isNotEmpty) {
      final parts = <String>[];
      for (final blip in blips) {
        final rid = blip.getAttribute('r:embed') ?? blip.getAttribute('r:link');
        if (rid == null) continue;
        final target = relMap[rid];
        if (target == null) continue;
        final entry = _find(archive, 'word/$target') ?? _find(archive, target);
        if (entry == null) continue;

        final ext = _extOf(target);
        final idx = imageIndexByRel.putIfAbsent(rid, () {
          final n = images.length + 1;
          images.add(ParsedImage(
            placeholder: 'images/$n.$ext',
            fileName: target.split('/').last,
            bytes: _bytesOf(entry),
          ));
          return n;
        });
        parts.add('![](images/$idx.$ext)');
      }
      if (parts.isNotEmpty) return parts.join('\n');
    }

    // 样式：判断标题级别
    final pStyle = p
        .findAllElements('w:pStyle')
        .map((e) => e.getAttribute('w:val') ?? '')
        .firstOrNull ??
        '';
    final headingLevel = _headingLevel(pStyle);

    // 列表：numPr 里带着「第几级」和「用哪套编号」
    final numPr = p.findAllElements('w:numPr').firstOrNull;
    var listLevel = 0;
    var listOrdered = false;
    if (numPr != null) {
      listLevel = int.tryParse(
            numPr
                    .findAllElements('w:ilvl')
                    .map((e) => e.getAttribute('w:val') ?? '')
                    .firstOrNull ??
                '',
          ) ??
          0;
      final numId = int.tryParse(
        numPr
                .findAllElements('w:numId')
                .map((e) => e.getAttribute('w:val') ?? '')
                .firstOrNull ??
            '',
      );
      listOrdered = numId != null && (numbering[numId]?[listLevel] ?? false);
    }

    // 首行缩进：Word 用 twips（1/20 磅），中文段落一般是「首行缩进 2 字符」。
    // firstLineChars 是百分之一字符，200 就是 2 个字符，比 twips 准，优先用它。
    var indentChars = 0;
    final ind = p.findAllElements('w:ind').firstOrNull;
    if (ind != null) {
      final byChars =
          int.tryParse(ind.getAttribute('w:firstLineChars') ?? '') ?? 0;
      if (byChars > 0) {
        indentChars = (byChars / 100).round();
      } else {
        final twips = int.tryParse(ind.getAttribute('w:firstLine') ?? '') ?? 0;
        // 一个中文字约 210 twips（五号字）
        if (twips > 0) indentChars = (twips / 210).round();
      }
    }

    // 拼接 runs，保留粗体/斜体
    final buf = StringBuffer();
    for (final r in p.findElements('w:r')) {
      final text = r
          .findAllElements('w:t')
          .map((t) => t.innerText)
          .join();
      if (text.isEmpty) {
        // 处理 <w:br/> 换行
        if (r.findElements('w:br').isNotEmpty) buf.write('\n');
        continue;
      }
      final bold = r.findAllElements('w:b').isNotEmpty;
      final italic = r.findAllElements('w:i').isNotEmpty;
      var s = text;
      if (bold && s.trim().isNotEmpty) s = '**$s**';
      if (italic && s.trim().isNotEmpty) s = '*$s*';
      buf.write(s);
    }

    var line = buf.toString().trimRight();
    if (line.trim().isEmpty) return '';

    if (headingLevel > 0) {
      line = '${'#' * headingLevel} ${line.trim()}';
    } else if (numPr != null) {
      // 缩进两个空格表示下一级，Markdown 靠这个还原嵌套结构
      final pad = '  ' * listLevel.clamp(0, 5);
      line = '$pad${listOrdered ? '1.' : '-'} ${line.trim()}';
    } else if (indentChars > 0) {
      // 用全角空格，渲染出来才是中文段落那种「空两格」
      line = '${'　' * indentChars.clamp(0, 4)}${line.trim()}';
    }
    return line;
  }

  static int _headingLevel(String style) {
    if (style.isEmpty) return 0;
    final s = style.toLowerCase();
    final m = RegExp(r'heading\s*([1-6])').firstMatch(s) ??
        RegExp(r'^([1-6])$').firstMatch(s);
    if (m != null) return int.parse(m.group(1)!);
    // 中文样式名，如「标题 1」
    final c = RegExp(r'标题\s*([1-6])').firstMatch(style);
    if (c != null) return int.parse(c.group(1)!);
    return 0;
  }

  /// 从路径猜图片扩展名。
  static String _extOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return 'png';
    final e = path.substring(dot + 1).toLowerCase();
    return e.isEmpty ? 'png' : e;
  }

  // ── 归档读取工具 ────────────────────────────────────────────────────────

  /// 在 zip 里找某个文件。大小写和路径分隔符都可能不一致，所以放宽匹配。
  static ArchiveFile? _find(Archive archive, String name) {
    final want = name.toLowerCase().replaceAll('\\', '/');
    for (final f in archive.files) {
      if (f.name.toLowerCase().replaceAll('\\', '/') == want) return f;
    }
    return null;
  }

  /// 取归档里某个文件的字节。content 本来就是 Uint8List，
  /// 拿不到时给一个空数组，调用方不用再判空。
  static Uint8List _bytesOf(ArchiveFile? file) {
    final content = file?.content;
    return content is Uint8List ? content : Uint8List(0);
  }

  /// 收拾空行：连续多个空行压成一个，并去掉首尾空行。
  ///
  /// ⚠️ **不能整体 `.trim()`**：Dart 的 trim() 按 Unicode 空白裁剪，
  /// 会把中文段首的**全角空格 U+3000** 一起吃掉，首行缩进就没了。
  /// 所以只处理"整行是否为空"，不碰行内空白。
  static String _tidy(String text) {
    final lines = text.split('\n');
    final out = <String>[];
    var blank = 0;
    for (final line in lines) {
      if (line.trim().isEmpty) {
        blank++;
        // 最多保留一个空行
        if (blank > 1) continue;
        out.add('');
      } else {
        blank = 0;
        out.add(line);
      }
    }
    while (out.isNotEmpty && out.first.isEmpty) {
      out.removeAt(0);
    }
    while (out.isNotEmpty && out.last.isEmpty) {
      out.removeLast();
    }
    return out.join('\n');
  }
}
