/// 标签管理：改名（含合并）、删除、换色，以及它在各处可见性上的口径。
///
/// 这些操作最容易出的错是"看着改好了，数据其实裂开了"：
///   · 改名撞上已有标签 → 直接 UPDATE 会被 UNIQUE 约束挡下（或者更糟，
///     静默失败），合并必须真的把两边笔记并到一起、且不留孤儿行；
///   · 删除 → 用户要的是"标签不要了"，**不是"笔记不要了"**；
///   · 隐私空间里的标签不能出现在普通空间的左栏上。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/shell/home_shell.dart';
import 'package:yuan_world/features/tags/manage_tags_page.dart';
import 'package:yuan_world/features/tags/tag_sheets.dart';

void main() {
  late AppDatabase db;
  late NoteRepository repo;
  late AppState state;

  setUp(() async {
    db = AppDatabase.inMemory();
    repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
  });

  tearDown(() => db.close());

  int add(String title, {List<String> tags = const <String>[]}) => repo.insertNote(
        title: title,
        content: '正文',
        excerpt: '正文',
        publishedAt: DateTime.now(),
        charCount: 2,
        tags: tags,
      );

  int tagId(String name) =>
      repo.allTags().firstWhere((t) => t.name == name).id;

  List<String> tagsOf(int noteId) => repo.getNote(noteId)!.tags;

  group('改名', () {
    test('普通改名：名字变了，笔记还挂着它', () async {
      final id = add('一', tags: <String>['随笔']);
      await state.renameTag(tagId('随笔'), '杂记');

      expect(tagsOf(id), <String>['杂记']);
      expect(repo.allTags().map((t) => t.name), <String>['杂记']);
    });

    test('改成已有的名字 = 合并：两边笔记并到一起，旧标签消失', () async {
      final a = add('甲', tags: <String>['随笔']);
      final b = add('乙', tags: <String>['日记']);
      await state.renameTag(tagId('日记'), '随笔');

      expect(tagsOf(a), <String>['随笔']);
      expect(tagsOf(b), <String>['随笔']);
      final tags = repo.allTags();
      expect(tags.length, 1, reason: '合并之后不该留两个标签');
      expect(tags.first.name, '随笔');
      expect(tags.first.count, 2);
    });

    test('一篇笔记**同时**有两个标签时合并：只留一条，不炸', () async {
      // 这条走的是 UPDATE OR IGNORE 撞主键那条路：
      // 直接 UPDATE 会报 UNIQUE 冲突，整个合并就失败了
      final a = add('甲', tags: <String>['随笔', '日记']);
      add('乙', tags: <String>['日记']);
      await state.renameTag(tagId('日记'), '随笔');

      expect(tagsOf(a), <String>['随笔']);
      expect(repo.allTags().length, 1);
      expect(repo.allTags().first.count, 2);
    });

    test('改成空格 / 同名：什么也不做', () async {
      final a = add('一', tags: <String>['随笔']);
      await state.renameTag(tagId('随笔'), '   ');
      expect(tagsOf(a), <String>['随笔']);
      await state.renameTag(tagId('随笔'), '随笔');
      expect(tagsOf(a), <String>['随笔']);
    });
  });

  group('删除', () {
    test('只摘标签，**笔记一篇都不会少**', () async {
      final a = add('一', tags: <String>['随笔']);
      final b = add('二', tags: <String>['随笔', '技术']);
      final before = repo.listNotes(const NoteFilter()).length;

      await state.deleteTag(tagId('随笔'));

      expect(repo.listNotes(const NoteFilter()).length, before,
          reason: '删标签绝不能顺手删笔记');
      expect(tagsOf(a), isEmpty);
      expect(tagsOf(b), <String>['技术']);
      expect(repo.allTags().map((t) => t.name), <String>['技术']);
    });

    test('正按这个标签筛选时删掉它：筛选自动放开，不留空列表', () async {
      add('一', tags: <String>['随笔']);
      add('二');
      state.selectTag('随笔');
      await state.refresh();
      expect(state.notes.length, 1);

      await state.deleteTag(tagId('随笔'));

      expect(state.filter.tag, isNull);
      expect(state.notes.length, 2, reason: '标签没了就该看到全部，而不是空白');
    });
  });

  group('换色', () {
    test('写进去就生效', () async {
      add('一', tags: <String>['随笔']);
      await state.setTagColor(tagId('随笔'), 0xFF34C759);
      expect(repo.allTags().first.color, 0xFF34C759);
    });
  });

  group('隐私空间', () {
    test('隐私笔记的标签不出现在普通空间，进隐私空间才看得见', () async {
      add('公开', tags: <String>['公开']);
      final secret = add('秘密', tags: <String>['私密']);
      repo.setNoteHidden(secret, true);

      expect(repo.allTags().map((t) => t.name), <String>['公开']);
      expect(repo.allTags(hiddenOnly: true).map((t) => t.name), <String>['私密']);
    });
  });

  group('计数', () {
    test('回收站里的笔记不算进标签计数', () async {
      final a = add('一', tags: <String>['随笔']);
      add('二', tags: <String>['随笔']);
      repo.deleteNote(a);

      final t = repo.allTags().single;
      expect(t.count, 1, reason: '删掉的那篇不该还算在标签上');
    });
  });

  group('按标签筛选笔记', () {
    test('selectTag 之后列表只剩这个标签的笔记', () async {
      add('一', tags: <String>['随笔']);
      add('二', tags: <String>['技术']);
      add('三');
      state.selectTag('技术');
      await state.refresh();
      expect(state.notes.map((n) => n.title), <String>['二']);

      state.selectAll();
      await state.refresh();
      expect(state.notes.length, 3);
    });
  });

  // ── 界面：标签的入口和出口 ──────────────────────────────────────────────
  //
  // 这一组盯的是"标签有没有露脸"：数据层一直支持标签，但界面上曾经
  // **一个入口都没有** —— 看不到、也加不了，功能等于不存在。
  group('界面入口', () {
    Future<void> pump(WidgetTester tester, Widget home) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(theme: AppTheme.light(), home: home),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('左栏列出标签，点一下就按它筛笔记', (tester) async {
      add('随笔一', tags: <String>['随笔']);
      add('别的');
      await state.refresh();
      await pump(tester, const HomeShell());

      expect(find.text('随笔'), findsWidgets, reason: '左栏要能看到标签');
      await tester.tap(find.text('随笔').last);
      await tester.pumpAndSettle();

      expect(state.filter.tag, '随笔');
      expect(state.notes.map((n) => n.title), <String>['随笔一']);
    });

    testWidgets('手机端：筛选胶囊条里也有标签，点一下筛、再点取消', (tester) async {
      // 手机上前端没有左栏，标签只能靠这条胶囊 ——
      // 之前这里**只有文件夹**，标签贴得上去却筛不出来
      add('随笔一', tags: <String>['随笔']);
      add('别的');
      await state.refresh();

      tester.view.physicalSize = const Size(420, 900); // 窄屏 → 走 NotesPage
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(theme: AppTheme.light(), home: const HomeShell()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('随笔'), findsOneWidget, reason: '手机筛选条里要有标签胶囊');
      await tester.tap(find.text('随笔'));
      await tester.pumpAndSettle();
      expect(state.filter.tag, '随笔');
      expect(state.notes.map((n) => n.title), <String>['随笔一']);

      // 再点一下取消（标签是随手贴的，不该逼用户找取消入口）
      await tester.tap(find.text('随笔'));
      await tester.pumpAndSettle();
      expect(state.filter.tag, isNull);
      expect(state.notes.length, 2);
    });

    testWidgets('标签弹窗：输入回车就加上，点 × 就去掉', (tester) async {
      final id = add('一');
      await state.refresh();
      await pump(
        tester,
        Scaffold(
          body: Builder(
            builder: (c) => TextButton(
              onPressed: () => showNoteTagEditor(c, id),
              child: const Text('开标签'),
            ),
          ),
        ),
      );

      await tester.tap(find.text('开标签'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '随笔');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(repo.getNote(id)!.tags, <String>['随笔']);

      await tester.tap(find.byIcon(Icons.close_rounded).first);
      await tester.pumpAndSettle();
      expect(repo.getNote(id)!.tags, isEmpty);
    });

    testWidgets('标签管理页：重命名走通', (tester) async {
      add('一', tags: <String>['随笔']);
      await state.refresh();
      await pump(tester, const ManageTagsPage());

      expect(find.text('随笔'), findsOneWidget);
      expect(find.text('1 篇笔记'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.drive_file_rename_outline_rounded));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '杂记');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(repo.allTags().map((t) => t.name), <String>['杂记']);
    });

    testWidgets('标签管理页：改名撞已有标签时提示"会合并"并且按钮变成合并', (tester) async {
      add('一', tags: <String>['随笔']);
      add('二', tags: <String>['日记']);
      await state.refresh();
      await pump(tester, const ManageTagsPage());

      // 第二行的重命名按钮（列表按 count 排，都是 1 篇，按名字顺序不定；
      // 直接找「日记」那一行里的按钮更稳）
      final row = find.ancestor(
        of: find.text('日记'),
        matching: find.byType(Row),
      );
      await tester.tap(
        find.descendant(
          of: row.first,
          matching: find.byIcon(Icons.drive_file_rename_outline_rounded),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '随笔');
      await tester.pumpAndSettle();

      expect(find.textContaining('会合并到一起'), findsOneWidget);
      await tester.tap(find.text('合并'));
      await tester.pumpAndSettle();

      expect(repo.allTags().map((t) => t.name), <String>['随笔']);
      expect(repo.allTags().first.count, 2);
    });

    testWidgets('标签管理页：删除只摘标签，笔记还在', (tester) async {
      final id = add('一', tags: <String>['随笔']);
      await state.refresh();
      await pump(tester, const ManageTagsPage());

      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pumpAndSettle();
      // 弹窗必须把"笔记不会被删"说清楚
      expect(find.textContaining('笔记本身不会被删除'), findsWidgets);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(repo.allTags(), isEmpty);
      expect(repo.getNote(id), isNotNull);
      expect(repo.getNote(id)!.tags, isEmpty);
    });
  });
}
