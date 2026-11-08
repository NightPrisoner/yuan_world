/// 正文里的图片/视频可以调前后顺序，而且**以行为单位**。
///
/// 用户第一版需求是「笔记中的图片视频等资源文件可以在笔记中调整前后顺序」，
/// 我最初实现成"和上一张/下一张图互换"。用户随后纠正：
/// 「笔记内媒体上下移动应该以行为单位，中间有几行字的话移动应该看到
/// 一行行字被挪走」。
///
/// 这两者的区别是这个文件的重点：段级交换时中间的文字原地不动，
/// 视觉上像两张图隔着文字对调；行级交换时被跨过的那**行字**会挪到另一边，
/// 所以图片的先后顺序其实可能不变 —— 变的是它相对那段文字的位置。
/// 断言因此不能只看"图片顺序"，要看**行号**。
///
/// 另一条约定：空行不算一步。块之间几乎都有空行，把空行算作一次的话
/// 按下去画面一模一样（图和空行互换），得连点好几次才有反应。
library;

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/motion/app_motion.dart';
import 'package:yuan_world/core/widgets/local_image.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/notes/editor/note_editor_page.dart';
import 'package:yuan_world/features/notes/widgets/media_card.dart';

const List<int> _png = <int>[
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
  late Directory root;
  late AppDatabase db;
  late NoteRepository repo;
  late AppState state;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('yw_media_order_');
    db = AppDatabase.openAt(root.path);
    repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
  });

  tearDown(() {
    db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  void writeImage(String rel) {
    final file = File(p.join(db.imageRoot.path, rel));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(_png);
  }

  /// 建一篇笔记。正文形状（重点：图和文字之间**有**空行）：
  ///
  /// ```
  /// 开头
  ///
  /// ![](id/a.png)
  ///
  /// 第 1 张后面的字
  ///
  /// ![](id/b.png)
  /// …
  /// ```
  int noteWithImages(String title, List<String> names, {bool leadWithImage = false}) {
    final id = repo.insertNote(title: title, content: '正文', excerpt: '正文');
    final body = <String>[if (!leadWithImage) '开头'];
    for (var i = 0; i < names.length; i++) {
      writeImage('$id/${names[i]}');
      if (body.isNotEmpty) body.add('');
      body
        ..add('![]($id/${names[i]})')
        ..add('')
        ..add('第 ${i + 1} 张后面的字');
    }
    repo.updateNote(id: id, content: body.join('\n'));
    return id;
  }

  Future<void> pumpEditor(WidgetTester tester, int noteId) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(body: NoteEditorPage(noteId: noteId, embedded: true)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 桌面端按钮只在悬停时露出。
  ///
  /// **只数正文里的媒体**：编辑器顶部现在也有一块头图（`editor-cover`），
  /// 它里面同样是一个 `LocalImage`；头图又是由正文第一张图自动派生出来的，
  /// 于是按 `LocalImage` 数就会把第 0 个错认成正文的图。
  Future<void> hoverMedia(WidgetTester tester, int index) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    final body = find.descendant(
      of: find.byKey(const ValueKey<String>('editor-body')),
      matching: find.byWidgetPredicate(
        (w) => w is LocalImage || w is MediaCard,
      ),
    );
    final visible = body.evaluate().length;
    expect(visible, greaterThan(index), reason: '正文里没找到第 $index 个媒体');
    await gesture.moveTo(tester.getCenter(body.at(index)));
    await tester.pumpAndSettle();
  }

  Future<void> settleSave(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  }

  /// 某张图在正文里是第几行（0 起）。
  int lineOf(String content, String needle) {
    final lines = content.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].contains(needle)) return i;
    }
    return -1;
  }

  testWidgets('往前挪一格：图片和它上面那行字互换，空行不算一步', (tester) async {
    final id = noteWithImages('三张图', <String>['a.png', 'b.png', 'c.png']);
    await state.refresh();
    await pumpEditor(tester, id);

    final before = repo.getNote(id)!.content;
    final lineCount = before.split('\n').length;
    // b 在第 6 行、它上面第 5 行是空行、第 4 行是「第 1 张后面的字」
    expect(lineOf(before, 'b.png'), 6);
    expect(before.split('\n')[4], '第 1 张后面的字');

    await hoverMedia(tester, 1);
    await tester.tap(find.byTooltip('往前挪一个'));
    await tester.pumpAndSettle();
    await settleSave(tester);

    final after = repo.getNote(id)!.content;
    expect(
      lineOf(after, 'b.png'),
      4,
      reason: '一次就该跨过空行贴到文字那一行，不能停在空行上',
    );
    expect(
      lineOf(after, '第 1 张后面的字'),
      6,
      reason: '那行字要真的被挪到另一边 —— 这正是"看到一行行字被挪走"',
    );
    expect(
      after.split('\n').length,
      lineCount,
      reason: '只换位置，不该多出或少掉行',
    );
  });

  testWidgets('往后挪一格：图片和它下面那行字互换', (tester) async {
    final id = noteWithImages('三张图', <String>['a.png', 'b.png', 'c.png']);
    await state.refresh();
    await pumpEditor(tester, id);

    final before = repo.getNote(id)!.content;
    expect(lineOf(before, 'a.png'), 2);

    await hoverMedia(tester, 0);
    await tester.tap(find.byTooltip('往后挪一个'));
    await tester.pumpAndSettle();
    await settleSave(tester);

    final after = repo.getNote(id)!.content;
    expect(lineOf(after, 'a.png'), 4, reason: 'a 该跑到那行字下面去');
    expect(lineOf(after, '第 1 张后面的字'), 2);
  });

  testWidgets('正文最顶上那张图没有「往前挪」', (tester) async {
    final id = noteWithImages(
      '开头就是图',
      <String>['a.png', 'b.png'],
      leadWithImage: true,
    );
    await state.refresh();
    await pumpEditor(tester, id);

    expect(lineOf(repo.getNote(id)!.content, 'a.png'), 0);

    await hoverMedia(tester, 0);
    final up = tester.widget<Pressable>(
      find
          .ancestor(
            of: find.byIcon(Icons.arrow_upward_rounded),
            matching: find.byType(Pressable),
          )
          .first,
    );
    expect(up.onTap, isNull, reason: '上面一行都没有了，前移该是灰的');

    // 越界那一下就算硬点也不该改正文
    final before = repo.getNote(id)!.content;
    await tester.tap(find.byTooltip('往前挪一个'));
    await tester.pumpAndSettle();
    await settleSave(tester);
    expect(repo.getNote(id)!.content, before);
  });

  testWidgets('最后一行是字的时候，最后那张图还能往后挪', (tester) async {
    final id = noteWithImages('三张图', <String>['a.png', 'b.png', 'c.png']);
    await state.refresh();
    await pumpEditor(tester, id);

    // c 下面是「第 3 张后面的字」，所以 c 仍然可以往下走
    await hoverMedia(tester, 2);
    final down = tester.widget<Pressable>(
      find
          .ancestor(
            of: find.byIcon(Icons.arrow_downward_rounded),
            matching: find.byType(Pressable),
          )
          .first,
    );
    expect(down.onTap, isNotNull);
  });

  testWidgets('调顺序不碰磁盘：只换行，文件都还在', (tester) async {
    final id = noteWithImages('三张图', <String>['a.png', 'b.png', 'c.png']);
    await state.refresh();
    await pumpEditor(tester, id);

    await hoverMedia(tester, 1);
    await tester.tap(find.byTooltip('往前挪一个'));
    await tester.pumpAndSettle();
    await settleSave(tester);

    for (final name in <String>['a.png', 'b.png', 'c.png']) {
      expect(
        File(p.join(db.imageRoot.path, '$id', name)).existsSync(),
        isTrue,
        reason: '$name 不该因为调顺序被删掉',
      );
    }
    expect(
      repo.getNote(id)!.content.contains('第 1 张后面的字'),
      isTrue,
      reason: '被挪动的文字不能丢',
    );
  });

  testWidgets('调顺序可以撤销', (tester) async {
    final id = noteWithImages('三张图', <String>['a.png', 'b.png', 'c.png']);
    await state.refresh();
    await pumpEditor(tester, id);

    final before = repo.getNote(id)!.content;

    await hoverMedia(tester, 1);
    await tester.tap(find.byTooltip('往前挪一个'));
    await tester.pumpAndSettle();
    // 库里的写入是 1.2 秒防抖的，先把这一步落盘再断言 ——
    // 否则读到的是换位之前的老内容，测的就不是撤销了
    await settleSave(tester);
    expect(lineOf(repo.getNote(id)!.content, 'b.png'), 4);

    await tester.tap(find.byTooltip('撤销'));
    await tester.pumpAndSettle();
    await settleSave(tester);
    expect(
      repo.getNote(id)!.content,
      before,
      reason: '撤销要把被挪动的那行字也一起退回去',
    );
  });
}
