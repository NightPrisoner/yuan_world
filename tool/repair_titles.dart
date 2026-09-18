// 修复历史数据里的「坏标题」。
//
// 背景：早期版本的导入器用「第一条非空行」当标题，
// 而有些 Word 文档开篇就是一张图，于是标题变成了 `![](45/1.png)`，
// 同时那张图被从正文里删掉了（标题行会被剔除）。
//
// 这个工具做两件事：
//   1. 把被误当作标题的图片放回正文开头
//   2. 重新推导标题：优先显式标题行 → 短的首行 → 【源文件名】→ 截断的首行
//
// 为什么优先用源文件名：这类文档（开篇是图、没有标题行）通常是
// 「图片 + 一大段正文」的结构，第一行文字是一整段话，拿来当标题很难看；
// 而文件本身就是用户自己命名的，反而是最贴切的标题。
//
// 用法：
//   dart run tool/repair_titles.dart --source "E:\deepseek work\B站专栏文集"
//   dart run tool/repair_titles.dart --source "..." --apply
//
// 不加 --apply 只预览，不会写库。
// 注意：请先关闭正在运行的「元世界」。
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yuan_world/core/utils/text_stats.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/docx_importer.dart';
import 'package:yuan_world/data/importer/import_service.dart';

final _imageOnly = RegExp(r'^!\[[^\]]*\]\([^)]*\)$');

Future<void> main(List<String> args) async {
  final apply = args.contains('--apply');
  final sourceDir = _argValue(args, '--source');

  final root = _defaultDbRoot();
  final db = AppDatabase.openAt(root);
  print('数据库：$root');
  print(apply ? '模式：实际写入' : '模式：预览（加 --apply 才会写入）');

  // 建立 source_url → 源文件名 的映射，供标题兜底使用
  final nameByUrl = <String, String>{};
  final nameByTitle = <String, String>{};
  if (sourceDir != null) {
    final dir = Directory(sourceDir);
    if (!dir.existsSync()) {
      print('源目录不存在：$sourceDir');
    } else {
      final files = ImportService.collectDocx(sourceDir);
      print('扫描源文件：${files.length} 个（用于反查文件名）');
      for (final f in files) {
        final base = p.basenameWithoutExtension(f.path);
        // 去掉开头的序号，如 "18 AI绘画（2）" → "AI绘画（2）"
        nameByTitle[base] = base;
        try {
          final doc = DocxImporter.parse(await f.readAsBytes());
          if (doc.sourceUrl.isNotEmpty) nameByUrl[doc.sourceUrl] = base;
        } catch (_) {
          // 解析失败的文件跳过，不影响整体修复
        }
      }
      print('已建立 ${nameByUrl.length} 条来源链接映射');
    }
  } else {
    print('提示：加 --source <文集目录> 可以用源文件名兜底，标题会更贴切');
  }
  print('');

  final rows = db.db.select(
    'SELECT id, title, content, source_url FROM notes ORDER BY id ASC',
  );

  var fixed = 0;
  for (final r in rows) {
    final id = r['id'] as int;
    final title = (r['title'] as String?) ?? '';
    if (!isBadTitle(title)) continue;

    final content = (r['content'] as String?) ?? '';
    final url = (r['source_url'] as String?) ?? '';
    final t = title.trim();

    // 被误当成标题的图片放回正文
    final restored =
        _imageOnly.hasMatch(t) && !content.startsWith(t) ? '$t\n\n$content' : content;

    final derived = deriveTitleFromMarkdown(restored, fallback: '');
    final fromFile = _matchSourceName(url, restored, nameByUrl, nameByTitle);

    // 首行太长（像一整段话）时，源文件名更合适
    final derivedIsTooLong = derived.length > 30 || derived.endsWith('…');
    final newTitle = (fromFile != null && (derived.isEmpty || derivedIsTooLong))
        ? fromFile
        : (derived.isEmpty ? '未命名笔记' : derived);

    fixed++;
    print('#$id');
    print('  旧标题: ${t.isEmpty ? '(空)' : t}');
    print('  新标题: $newTitle${fromFile != null ? '   ← 源文件名' : ''}');
    print('  正文开头: ${_head(restored)}');

    if (apply) {
      db.db.execute(
        'UPDATE notes SET title = ?, content = ?, excerpt = ?, '
        'char_count = ?, word_count = ? WHERE id = ?',
        <Object?>[
          newTitle,
          restored,
          makeExcerpt(restored),
          countChars(restored),
          countWords(restored),
          id,
        ],
      );
    }
  }

  print('');
  print(fixed == 0
      ? '没有发现需要修复的标题。'
      : (apply ? '已修复 $fixed 篇。' : '共 $fixed 篇待修复，确认无误后加 --apply 执行。'));
  db.close();
}

/// 通过来源链接反查源文件名；查不到就返回 null。
String? _matchSourceName(
  String sourceUrl,
  String content,
  Map<String, String> byUrl,
  Map<String, String> byTitle,
) {
  if (sourceUrl.isNotEmpty) {
    final hit = byUrl[sourceUrl];
    if (hit != null) return hit;
  }
  // 退一步：正文里若出现过源文件名，也算命中
  for (final e in byTitle.entries) {
    if (content.contains(e.key)) return e.value;
  }
  return null;
}

String _head(String s) {
  final line =
      s.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '');
  return line.length > 44 ? '${line.substring(0, 44)}…' : line;
}

String? _argValue(List<String> args, String flag) {
  final i = args.indexOf(flag);
  if (i < 0 || i + 1 >= args.length) return null;
  return args[i + 1];
}

String _defaultDbRoot() {
  final appData = Platform.environment['APPDATA'];
  if (appData == null || appData.isEmpty) return Directory.current.path;
  return '$appData${Platform.pathSeparator}com.yuanworld'
      '${Platform.pathSeparator}yuan_world';
}
