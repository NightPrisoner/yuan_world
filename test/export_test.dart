/// 导出格式的测试。
///
/// 导出是**数据出口**：渲染错了用户拿走的就是错的，
/// 而且他多半不会当场发现。所以三种格式都逐条钉。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/exporter/note_exporter.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';

void main() {
  late AppDatabase db;
  late NoteRepository repo;

  setUp(() {
    db = AppDatabase.inMemory();
    repo = NoteRepository(db);
  });

  tearDown(() => db.close());

  int add(String title, String content, {int chars = 100}) => repo.insertNote(
    title: title,
    content: content,
    excerpt: '',
    charCount: chars,
  );

  group('Markdown', () {
    test('标题成为一级标题，正文原样保留', () {
      final id = add('我的标题', '正文第一段\n\n**加粗**内容');
      final out = NoteExporter.render(
        repo.getNote(id)!,
        ExportFormat.markdown,
      );

      expect(out, startsWith('# 我的标题\n'));
      expect(out, contains('正文第一段'));
      expect(out, contains('**加粗**内容'), reason: 'Markdown 导出不该改动标记');
    });

    test('无标题时不写空标题行', () {
      final id = add('', '就一段正文');
      final out = NoteExporter.render(
        repo.getNote(id)!,
        ExportFormat.markdown,
      );
      expect(out.trimLeft(), startsWith('就一段正文'));
      expect(out.contains('#'), isFalse);
    });
  });

  group('纯文本', () {
    test('Markdown 标记被清掉', () {
      final id = add('标题', '这是 **加粗** 和 `代码`');
      final out = NoteExporter.render(repo.getNote(id)!, ExportFormat.text);

      expect(out, contains('这是 加粗 和 代码'));
      expect(out, isNot(contains('**')), reason: 'txt 里留着星号只会碍事');
      expect(out, isNot(contains('`')));
    });

    test('图片变成一行说明，不再是语法', () {
      final id = add('t', '正文\n\n![](45/1.png)');
      final out = NoteExporter.render(repo.getNote(id)!, ExportFormat.text);

      expect(out, contains('[图片] 45/1.png'));
      expect(out, isNot(contains('![')));
    });

    test('标题带下划线分隔', () {
      final id = add('标题', '# 小标题\n\n正文');
      final out = NoteExporter.render(repo.getNote(id)!, ExportFormat.text);
      expect(out, contains('小标题'));
      expect(out, contains('-' * 3));
    });
  });

  group('导出不带正文目录', () {
    // 用户的原话：「笔记导出后目录不需要出现在正文上面」。
    // 导出的文档要和笔记本身长得一样 —— 第一行就是正文。
    // 导航能力不受影响：docx 靠 Word 内置 Heading 样式走导航窗格。
    const longDoc = '# 一号标题\n\n正文甲\n\n## 二号标题\n\n正文乙\n\n'
        '### 三号标题\n\n正文丙\n\n## 四号标题\n\n正文丁';

    test('Markdown 直接从正文开始', () {
      final id = add('t', longDoc);
      final md = NoteExporter.render(repo.getNote(id)!, ExportFormat.markdown);

      expect(md.contains('## 目录'), isFalse);
      // 标题本身当然还在，只是不再有一份清单排在前面
      expect(md.indexOf('一号标题'), lessThan(md.indexOf('正文甲')));
      expect(md.indexOf('正文甲'), lessThan(md.indexOf('二号标题')));
    });

    test('纯文本直接从正文开始', () {
      final id = add('t', longDoc);
      final txt = NoteExporter.render(repo.getNote(id)!, ExportFormat.text);
      expect(txt.startsWith('t\n'), isTrue, reason: '第一行是标题，第二行就该进正文');
      expect(txt.indexOf('正文甲'), lessThan(txt.indexOf('二号标题')));
    });

    test('docx 正文里没有目录段落，标题仍是大纲级别', () {
      final id = add('t', longDoc);
      final bytes = NoteExporter.renderDocxBytes(repo.getNote(id)!);
      final xml = utf8.decode(
        ZipDecoder().decodeBytes(bytes).files
            .firstWhere((f) => f.name == 'word/document.xml')
            .content as List<int>,
      );

      expect(xml.contains('<w:hyperlink'), isFalse, reason: '目录项才是超链接');
      expect(xml.indexOf('正文甲'), lessThan(xml.indexOf('二号标题')));
      // 导航窗格靠的是样式，不是正文里的目录
      expect(xml, contains('<w:pStyle w:val="Heading2"/>'));
    });

    test('标题里的行内标记会被清掉（不能露出 ** ）', () {
      final id = add('t', '# **加粗**的标题\n\n正文甲');
      final txt = NoteExporter.render(repo.getNote(id)!, ExportFormat.text);
      expect(txt, contains('加粗的标题'));
      expect(txt.contains('**'), isFalse);
    });
  });

  group('落盘', () {
    test('每篇一个文件，数量对得上', () {
      final dir = Directory.systemTemp.createTempSync('yw_export_');
      add('第一篇', 'a');
      add('第二篇', 'b');
      add('第三篇', 'c');

      final n = NoteExporter.exportToDirectory(
        notes: repo.listNotes(const NoteFilter()),
        format: ExportFormat.markdown,
        dir: dir.path,
      );

      expect(n, 3);
      expect(dir.listSync().whereType<File>().length, 3);
      dir.deleteSync(recursive: true);
    });

    test('同名笔记不会互相覆盖', () {
      final dir = Directory.systemTemp.createTempSync('yw_export_');
      add('重名', 'a');
      add('重名', 'b');

      NoteExporter.exportToDirectory(
        notes: repo.listNotes(const NoteFilter()),
        format: ExportFormat.text,
        dir: dir.path,
      );

      final files = dir.listSync().whereType<File>().toList();
      expect(files.length, 2, reason: '两篇同名笔记必须是两个文件');
      dir.deleteSync(recursive: true);
    });

    test('文件名里的非法字符被替换', () {
      final dir = Directory.systemTemp.createTempSync('yw_export_');
      add('a/b:c*d?e"f<g>h|i', 'x');

      NoteExporter.exportToDirectory(
        notes: repo.listNotes(const NoteFilter()),
        format: ExportFormat.text,
        dir: dir.path,
      );

      // 只看文件名本身：完整路径里本来就有 `:` 和 `\`
      final name = p.basename(dir.listSync().whereType<File>().first.path);
      for (final ch in <String>['/', ':', '*', '?', '"', '<', '>', '|']) {
        expect(name.contains(ch), isFalse, reason: '文件名不该含 $ch');
      }
      dir.deleteSync(recursive: true);
    });

    test('无标题笔记有兜底文件名', () {
      final dir = Directory.systemTemp.createTempSync('yw_export_');
      add('', '正文');
      NoteExporter.exportToDirectory(
        notes: repo.listNotes(const NoteFilter()),
        format: ExportFormat.text,
        dir: dir.path,
      );
      expect(
        dir.listSync().whereType<File>().first.path,
        contains('无标题笔记'),
      );
      dir.deleteSync(recursive: true);
    });

    test('目录不存在会自动创建', () {
      final base = Directory.systemTemp.createTempSync('yw_export_');
      final target = '${base.path}${Platform.pathSeparator}还没建的子目录';
      add('x', 'y');

      final n = NoteExporter.exportToDirectory(
        notes: repo.listNotes(const NoteFilter()),
        format: ExportFormat.text,
        dir: target,
      );

      expect(n, 1);
      expect(Directory(target).existsSync(), isTrue);
      base.deleteSync(recursive: true);
    });
  });
}
