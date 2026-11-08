/// 媒体正下方的图注。
///
/// 用户的话：「媒体正下方可以写一段注释（用以解释说明相关图片是视频），
/// 参考 B 站专栏做法，这段注释和媒体绑定，移动时一起移动」。
///
/// 实现上**不新增任何存储**：图注就是 Markdown 里图片的 alt 文字，
/// `![这是说明](images/7/a.png)`。这样它天然和那行媒体绑在一起 ——
/// 上下移动、拖动、删除永远作用于整行，不会出现"图走了、说明留在原地"。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/core/utils/text_stats.dart';
import 'package:yuan_world/core/widgets/local_image.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/exporter/note_exporter.dart';
import 'package:yuan_world/data/exporter/pdf_exporter.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/models.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/notes/editor/body_segments.dart';
import 'package:yuan_world/features/notes/editor/note_editor_page.dart';

/// 1×1 透明 PNG。
const List<int> kPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];

void main() {
  group('语法层：图注就是 alt 文字', () {
    test('从图片行里取出图注和路径', () {
      expect(imageAltOf('![海边的日落](images/7/a.png)'), '海边的日落');
      expect(imagePathOf('![海边的日落](images/7/a.png)'), '7/a.png');
      expect(imageAltOf('![](images/7/a.png)'), '');
      expect(imageAltOf('不是图片'), '');
    });

    test('生成图片行时会清掉会破坏语法的字符', () {
      final line = imageLineOf('a.png', '带]方括号的说明\n还带换行');
      expect(line, '![带］方括号的说明 还带换行](a.png)');
      // 关键性质：写回去之后再解析，路径还是原路径、说明只剩第一行
      expect(imagePathOf(line), 'a.png');
      expect(imageAltOf(line), '带］方括号的说明 还带换行');
    });

    test('阅读页的块带上了图注', () {
      final blocks = parseContent('正文\n\n![这张图的说明](images/7/a.png)\n');
      final image = blocks.firstWhere((b) => b.type == ContentBlockType.image);
      // 正文块里存的是**原样引用**（带 images/ 前缀），导出时各自剥；
      // 图注则从同一行的 alt 里取出来
      expect(image.text, 'images/7/a.png');
      expect(image.caption, '这张图的说明');
    });

    test('没图注的图片块 caption 是空串，不会有空占位', () {
      final blocks = parseContent('![](images/7/a.png)');
      expect(blocks.single.caption, '');
    });
  });

  group('编辑器：点一下就能改，改完跟着媒体一起走', () {
    late Directory root;
    late AppDatabase db;
    late NoteRepository repo;
    late AppState state;

    setUp(() async {
      root = Directory.systemTemp.createTempSync('yw_caption_');
      db = AppDatabase.openAt(root.path);
      repo = NoteRepository(db);
      state = AppState(db, repo, ImportService(db, repo));
      await state.init();
    });

    tearDown(() {
      db.close();
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    int noteWith({List<String> captions = const <String>['']}) {
      final id = repo.insertNote(title: '图文', content: '正文', excerpt: '正文');
      final body = <String>['开头'];
      for (var i = 0; i < captions.length; i++) {
        final rel = '$id/${i + 1}.png';
        final file = File(p.join(db.imageRoot.path, rel));
        file.parent.createSync(recursive: true);
        file.writeAsBytesSync(kPng);
        body
          ..add('')
          ..add(imageLineOf(rel, captions[i]))
          ..add('')
          ..add('第 ${i + 1} 张后面的字');
      }
      repo.updateNote(id: id, content: body.join('\n'));
      return id;
    }

    Future<void> pumpEditor(WidgetTester tester, int noteId) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: NoteEditorPage(noteId: noteId, embedded: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> settleSave(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();
    }

    /// 图注输入框在对话框里 —— 编辑器自己也有一堆 TextField（标题、正文分段），
    /// 不限定范围的话 `find.byType(TextField).first` 会打到标题上。
    Finder captionField() => find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );

    testWidgets('没写说明时给"加一句说明"的入口，点开能写进那一行', (tester) async {
      final id = noteWith();
      await state.refresh();
      await pumpEditor(tester, id);

      expect(find.text('加一句说明'), findsOneWidget);
      await tester.tap(find.text('加一句说明'));
      await tester.pumpAndSettle();

      expect(find.text('图片说明'), findsOneWidget);
      await tester.enterText(captionField(), '海边的日落');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      await settleSave(tester);

      final content = repo.getNote(id)!.content;
      expect(content, contains('![海边的日落]('));
      // 说明必须和图片在**同一行**：分成两行就会各自被移动
      final line = content
          .split('\n')
          .firstWhere((l) => l.contains('1.png'));
      expect(line, '![海边的日落]($id/1.png)');
    });

    testWidgets('已有的说明直接显示，改掉之后铺回那一行', (tester) async {
      final id = noteWith(captions: const <String>['原来的说明']);
      await state.refresh();
      await pumpEditor(tester, id);

      expect(find.text('原来的说明'), findsOneWidget);
      await tester.tap(find.text('原来的说明'));
      await tester.pumpAndSettle();
      await tester.enterText(captionField(), '改过的说明');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      await settleSave(tester);

      final content = repo.getNote(id)!.content;
      expect(content, contains('![改过的说明]('));
      expect(content, isNot(contains('原来的说明')));
    });

    testWidgets('取消不留痕', (tester) async {
      final id = noteWith(captions: const <String>['原来的说明']);
      await state.refresh();
      await pumpEditor(tester, id);
      final before = repo.getNote(id)!.content;

      await tester.tap(find.text('原来的说明'));
      await tester.pumpAndSettle();
      await tester.enterText(captionField(), '不要了');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await settleSave(tester);

      expect(repo.getNote(id)!.content, before);
    });

    testWidgets('上下移动时图注跟着图走（本来就是同一行）', (tester) async {
      final id = noteWith(captions: const <String>['第一张的说明', '第二张的说明']);
      await state.refresh();
      await pumpEditor(tester, id);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      // 第二张图（索引 1）往上挪一格
      final images = find.byType(LocalImage);
      expect(images.evaluate().length, greaterThan(1));
      await gesture.moveTo(tester.getCenter(images.at(1)));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('往前挪一个'));
      await tester.pumpAndSettle();
      await settleSave(tester);

      final lines = repo.getNote(id)!.content.split('\n');
      final second = lines.indexWhere((l) => l.contains('第二张的说明'));
      final secondImage = lines.indexWhere((l) => l.contains('2.png'));
      expect(
        second,
        secondImage,
        reason: '说明和图永远在同一行，移动时不可能被拆开',
      );
      expect(lines[second], contains('2.png'));
    });
  });

  group('导出：图注跟着文档一起出去', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('yw_caption_export_');
      final db = AppDatabase.openAt(root.path);
      final file = File(p.join(db.imageRoot.path, '77/a.png'));
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(kPng);
    });

    tearDown(() {
      if (root.existsSync()) {
        try {
          root.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    Note noteWithCaption() => Note(
      id: 77,
      title: '带图注的笔记',
      content: '正文\n\n![这是图注](images/77/a.png)\n',
      excerpt: '正文',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );

    testWidgets('docx 里有一行居中的图注', (tester) async {
      final note = noteWithCaption();
      final bytes = NoteExporter.renderDocxBytes(
        note,
        imageRoot: p.join(root.path, 'images'),
      );
      final zip = ZipDecoder().decodeBytes(bytes);
      final doc = zip.firstWhere((f) => f.name == 'word/document.xml');
      final xml = utf8.decode(doc.content as List<int>);
      expect(xml, contains('这是图注'));
      // 图注段带居中，正文段落不带 —— 靠这个区分出来
      expect(xml, contains('<w:jc w:val="center"/>'));
    });

    testWidgets('纯文本里图注跟在图片那行后面', (tester) async {
      final text = NoteExporter.render(noteWithCaption(), ExportFormat.text);
      expect(text, contains('[图片] 77/a.png · 这是图注'));
    });

    testWidgets('PDF 能带着图注导出，不报错', (tester) async {
      final font = await rootBundle.load(
        'assets/fonts/NotoSansSC-GBK-Regular.ttf',
      );
      final bytes = await PdfExporter.renderBytes(
        noteWithCaption(),
        font: ByteData.sublistView(font),
        imageRoot: p.join(root.path, 'images'),
      );
      expect(utf8.decode(bytes.sublist(0, 5)), '%PDF-');
      expect(bytes.length, greaterThan(1000));
    });
  });
}
