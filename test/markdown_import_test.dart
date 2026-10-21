/// Markdown 导入：解析规则 + 端到端落库。
///
/// 导出侧早就支持 `.md`（`ExportFormat.markdown` 保留原始标记），
/// 但导入只收 docx/txt —— 导致「导出的 .md 想再导回来」这条路是断的。
/// 这个文件钉住三件事：
///   1. front matter / 开头一级标题的解析（标题不能被写进正文两遍）
///   2. 正文一个字符都不改（**不能**顺手"清洗" Markdown）
///   3. 走完整导入链路后，图片/视频的相对路径照样被搬进媒体目录
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/docx_importer.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/importer/markdown_importer.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';

void main() {
  group('Markdown 解析', () {
    ParsedDocument parse(String text) =>
        MarkdownImporter.parse(Uint8List.fromList(utf8.encode(text)));

    test('开头的 # 标题就是标题，正文里不会重复出现', () {
      final d = parse('# 我的标题\n\n正文第一段\n\n## 小标题\n正文');
      expect(d.title, '我的标题');
      expect(d.markdown, '正文第一段\n\n## 小标题\n正文');
      expect(d.markdown, isNot(contains('# 我的标题')));
    });

    test('没有标题行时退回文件名', () {
      final d = MarkdownImporter.parse(
        Uint8List.fromList(utf8.encode('就是一段正文\n\n第二段')),
        fallbackTitle: '文件名',
      );
      expect(d.title, '文件名');
      expect(d.markdown, '就是一段正文\n\n第二段');
    });

    test('front matter 里的信息被采纳，且不进正文', () {
      final d = parse(
        '---\n'
        'title: 从元信息来的标题\n'
        'author: 某人\n'
        'date: 2023-05-06\n'
        'source: https://example.com/a\n'
        'collection: 我的文集\n'
        '---\n'
        '\n正文内容',
      );
      expect(d.title, '从元信息来的标题');
      expect(d.author, '某人');
      expect(d.publishedAt, DateTime(2023, 5, 6));
      expect(d.sourceUrl, 'https://example.com/a');
      expect(d.collection, '我的文集');
      expect(d.markdown, '正文内容');
      expect(d.markdown, isNot(contains('title:')));
    });

    test('front matter 的 title 和开头一级标题重复时，标题行也去掉', () {
      final d = parse('---\ntitle: 一样的\n---\n# 一样的\n\n正文');
      expect(d.title, '一样的');
      expect(d.markdown, '正文');
    });

    test('front matter 的 title 和开头一级标题不同时，两个都保留', () {
      final d = parse('---\ntitle: 元信息标题\n---\n# 正文里的大标题\n\n正文');
      expect(d.title, '元信息标题');
      // 标题行本身是正文的一部分，不能因为"看起来像标题"就吞掉
      expect(d.markdown, startsWith('# 正文里的大标题'));
    });

    test('正文中间的分隔线不会被当成 front matter', () {
      final d = parse('第一段\n\n---\n\n第二段');
      expect(d.markdown, '第一段\n\n---\n\n第二段');
    });

    test('Markdown 标记原样保留，不做任何清洗', () {
      const body = '**加粗** 和 `代码`\n\n- 列表项\n- [ ] 待办\n\n> 引用\n\n```\ncode\n```';
      final d = parse('# 标题\n\n$body');
      expect(d.markdown, body);
    });

    test('GBK 编码的 .md 也能读', () {
      final bytes = Uint8List.fromList(gbk.encode('# 郭敬明\n\n正文'));
      final raw = MarkdownImporter.parse(bytes, fallbackTitle: 'x');
      expect(raw.title, '郭敬明');
      expect(raw.markdown, '正文');
    });

    test('管道表格和 HTML 表格都计入"没能按表格导入"的数', () {
      final d = parse(
        '# 表格\n\n'
        '| 甲 | 乙 |\n| --- | --- |\n| 1 | 2 |\n\n'
        '<table><tr><td>x</td></tr></table>',
      );
      expect(d.tableCount, 2);
    });
  });

  group('Markdown 导入端到端', () {
    late AppDatabase db;
    late NoteRepository repo;
    late ImportService importer;
    late Directory work;

    setUp(() {
      db = AppDatabase.openAt(
        Directory.systemTemp.createTempSync('yw_md_e2e_').path,
      );
      repo = NoteRepository(db);
      importer = ImportService(db, repo);
      work = Directory.systemTemp.createTempSync('yw_md_src_');
    });
    tearDown(() {
      db.close();
      for (final d in [db.rootDir, work]) {
        if (d.existsSync()) d.deleteSync(recursive: true);
      }
    });

    File write(String name, String text) {
      final f = File(p.join(work.path, name));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(text, encoding: utf8);
      return f;
    }

    test('.md 能整篇导进来，标题不重复', () async {
      final f = write('a.md', '# 第一篇\n\n正文内容\n\n## 小节\n更多');
      final summary = await importer.importDocx(<File>[f]);
      expect(summary.imported, 1, reason: summary.errors.join('; '));
      final listed = repo.listNotes(const NoteFilter()).single;
      expect(listed.title, '第一篇');
      // listNotes 是轻量查询（不含正文），正文要单独取
      final note = repo.getNote(listed.id)!;
      expect(note.content, '正文内容\n\n## 小节\n更多');
    });

    test('正文里引用的本地图片跟着搬进媒体目录', () async {
      File(p.join(work.path, 'pic.png')).writeAsBytesSync(<int>[1, 2, 3, 4]);
      final f = write('b.md', '# 带图\n\n![图](pic.png)\n\n正文');
      final summary = await importer.importDocx(<File>[f]);
      expect(summary.imported, 1, reason: summary.errors.join('; '));
      final note = repo.getNote(repo.listNotes(const NoteFilter()).single.id)!;
      final rel = RegExp(r'!\[图\]\(([^)]+)\)').firstMatch(note.content)!.group(1)!;
      expect(rel, startsWith('${note.id}/'));
      final media = File(p.join(db.imageRoot.path, rel));
      expect(media.existsSync(), isTrue);
      expect(media.readAsBytesSync(), <int>[1, 2, 3, 4]);
      expect(summary.images, 1);
    });

    test('文件夹导入时按相对路径还原文集层级', () async {
      write('文集/子/一.md', '# 一\n\n甲');
      write('文集/二.md', '# 二\n\n乙');
      final files = ImportService.collectDocx(p.join(work.path, '文集'));
      expect(files.length, 2);
      final summary = await importer.importDocx(
        files,
        collectionName: '文集',
        rootDir: p.join(work.path, '文集'),
      );
      expect(summary.imported, 2, reason: summary.errors.join('; '));
      final names = repo.allCollections().map((c) => c.name).toSet();
      expect(names, containsAll(<String>{'文集', '子'}));
      final sub = repo.allCollections().firstWhere((c) => c.name == '子');
      final note = repo.listNotes(const NoteFilter()).firstWhere((n) => n.title == '一');
      expect(note.collectionId, sub.id);
    });

    test('重复导入同一篇 .md 会跳过，不会产生副本', () async {
      final f = write('dup.md', '# 重复\n\n正文');
      await importer.importDocx(<File>[f]);
      final again = await importer.importDocx(<File>[f]);
      expect(again.imported, 0);
      expect(again.skipped, 1);
      expect(repo.listNotes(const NoteFilter()).length, 1);
    });

    test('collectDocx 也收 .md 和 .markdown，其它扩展名不要', () {
      write('a.md', '# a');
      write('b.markdown', '# b');
      write('c.txt', 'c');
      write('d.docx', 'fake');
      write('e.pdf', 'x');
      final found = ImportService.collectDocx(work.path)
          .map((f) => p.basename(f.path))
          .toSet();
      expect(found, containsAll(<String>{'a.md', 'b.markdown', 'c.txt', 'd.docx'}));
      expect(found.contains('e.pdf'), isFalse);
      expect(ImportService.isImportablePath('/x/y/笔记.MD'), isTrue);
      expect(ImportService.isImportablePath('/x/y/笔记.rtf'), isFalse);
    });
  });
}
