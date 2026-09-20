/// 手机端和桌面端的功能对齐。
///
/// 起因：桌面左栏有一批"视图/系统入口"（回收站、归档…），而手机是
/// 底部四个标签 + 设置页。之前 `TrashPage` 只被 `desktop_workspace` 引用，
/// `archivedOnly` 也只有桌面在设 —— 于是在手机上：
///   · 删掉的笔记**永远找不回来**；
///   · 长按「归档」之后那篇笔记直接消失，**看不到也取消不了**。
///
/// 这一组把两条路钉住：设置页里的「回收站」、筛选条里的「归档」。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/collections/collection_sheets.dart';
import 'package:yuan_world/features/collections/manage_collections_page.dart';
import 'package:yuan_world/features/notes/editor/note_editor_page.dart';
import 'package:yuan_world/features/notes/note_detail_page.dart';
import 'package:yuan_world/features/search/search_page.dart';
import 'package:yuan_world/features/settings/settings_page.dart';
import 'package:yuan_world/features/shell/home_shell.dart';
import 'package:yuan_world/features/trash/trash_page.dart';

void main() {
  late AppDatabase db;
  late AppState state;

  setUp(() async {
    db = AppDatabase.inMemory();
    final repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
  });

  tearDown(() => db.close());

  int add(String title) => state.repo.insertNote(
        title: title,
        content: '正文',
        excerpt: '正文',
        publishedAt: DateTime.now(),
        charCount: 2,
      );

  /// 窄屏 → 走手机的底部标签那套（不是三栏工作区）
  Future<void> pumpPhone(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(420, 900);
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

  testWidgets('筛选条里的「归档」：点开只看归档，再点回来', (tester) async {
    add('正常的');
    final archived = add('归档的');
    state.repo.setArchived(archived, true);
    await state.refresh();
    await pumpPhone(tester, const HomeShell());

    // 默认看不到归档的
    expect(find.text('正常的'), findsOneWidget);
    expect(find.text('归档的'), findsNothing);

    await tester.tap(find.text('归档'));
    await tester.pumpAndSettle();
    expect(state.filter.archivedOnly, isTrue);
    expect(find.text('归档的'), findsOneWidget);
    expect(find.text('正常的'), findsNothing);

    await tester.tap(find.text('归档'));
    await tester.pumpAndSettle();
    expect(state.filter.archivedOnly, isFalse);
    expect(find.text('正常的'), findsOneWidget);
  });

  testWidgets('设置页里的「回收站」：能看到数量、点得进去', (tester) async {
    final id = add('要删的');
    state.repo.deleteNote(id);
    // 回收站的列表是**单独缓存**的（refresh() 不带它，省一次全表查询），
    // 界面上的删除流程会自己调 refreshTrash()，这里直接打仓库就得补一下
    state.refreshTrash();
    await state.refresh();
    await pumpPhone(tester, const SettingsPage());

    expect(find.text('回收站'), findsOneWidget);
    expect(find.textContaining('1 篇'), findsWidgets, reason: '要显示里面有几篇');

    await tester.tap(find.text('回收站'));
    await tester.pumpAndSettle();
    expect(find.byType(TrashPage), findsOneWidget, reason: '手机上必须能进回收站');
  });

  testWidgets('回收站空了也要能进（不是隐藏入口）', (tester) async {
    await state.refresh();
    await pumpPhone(tester, const SettingsPage());
    expect(find.text('回收站'), findsOneWidget);
    expect(find.text('空的'), findsOneWidget);
  });

  group('手机端多选', () {
    testWidgets('进多选 → 点卡片是勾选（不会打开笔记）→ 全选 → 取消', (tester) async {
      add('甲');
      add('乙');
      await state.refresh();
      await pumpPhone(tester, const HomeShell());

      // 桌面有多选，手机原本没有（只有长按的单篇菜单）
      expect(find.textContaining('已选'), findsNothing);
      await tester.tap(find.byTooltip('多选'));
      await tester.pumpAndSettle();

      // 进多选后：底部出现操作栏，副标题报已选数
      expect(find.text('已选 0'), findsOneWidget);
      expect(find.textContaining('已选 0 篇'), findsOneWidget);

      // 点卡片是勾选，不是打开那篇笔记
      await tester.tap(find.text('甲'));
      await tester.pumpAndSettle();
      expect(find.text('已选 1'), findsOneWidget);
      expect(find.byType(NoteDetailPage), findsNothing, reason: '多选时不该打开笔记');

      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 2'), findsOneWidget);

      await tester.tap(find.text('反选'));
      await tester.pumpAndSettle();
      expect(find.text('已选 0'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已选'), findsNothing);
      expect(find.text('共 2 篇'), findsOneWidget, reason: '退出后回到普通标题');
    });

    testWidgets('批量操作菜单里有桌面那几项', (tester) async {
      add('甲');
      await state.refresh();
      await pumpPhone(tester, const HomeShell());

      await tester.tap(find.byTooltip('多选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('甲'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();

      for (final label in <String>[
        '移动到文集',
        '导出为压缩包',
        '归档',
        '移入隐私空间',
        '删除',
      ]) {
        // 用 findsWidgets：「归档」在筛选胶囊条里也有一个，这里只要求菜单里存在
        expect(find.text(label), findsWidgets, reason: '批量操作里少了「$label」');
      }
    });

    testWidgets('批量删除会说清"先进回收站"，删完真的进回收站', (tester) async {
      add('甲');
      await state.refresh();
      await pumpPhone(tester, const HomeShell());

      await tester.tap(find.byTooltip('多选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('甲'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('批量操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      // 文案不能吓人：是软删除
      expect(find.textContaining('回收站'), findsWidgets);
      await tester.tap(find.widgetWithText(TextButton, '删除'));
      await tester.pumpAndSettle();

      expect(state.notes, isEmpty);
      expect(state.trashedNotes.length, 1, reason: '应该在回收站里，不是被抹掉');
    });
  });

  group('手机端快捷键', () {
    testWidgets('Ctrl+3 / Ctrl+1 切底部标签（手机上外接键盘也能用）', (tester) async {
      await state.refresh();
      await pumpPhone(tester, const HomeShell());
      expect(find.text('全部'), findsOneWidget, reason: '默认在笔记页');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.text('待办'), findsWidgets);
      expect(find.text('全部'), findsNothing, reason: '已经不在笔记页了');

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.digit1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.text('全部'), findsOneWidget);
    });

    testWidgets('Ctrl+F 打开搜索页', (tester) async {
      await state.refresh();
      await pumpPhone(tester, const HomeShell());

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(find.byType(SearchPage), findsOneWidget);
    });

    testWidgets('Ctrl+N 新建并进编辑器（和 FAB 走同一条路）', (tester) async {
      await state.refresh();
      await pumpPhone(tester, const HomeShell());
      final before = state.notes.length;

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(state.notes.length, before + 1);
      expect(find.byType(NoteEditorPage), findsOneWidget);
    });
  });

  group('手机端文集嵌套', () {    testWidgets('编辑弹窗里能选上级（桌面靠拖拽嵌套，手机拖不了）', (tester) async {
      final a = await state.createCollection('甲');
      final b = await state.createCollection('乙');
      await state.refresh();

      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Builder(
              builder: (c) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => showCollectionEditor(
                      c,
                      existing: state.collections.firstWhere((x) => x.id == b),
                    ),
                    child: const Text('编辑乙'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('编辑乙'));
      await tester.pumpAndSettle();

      // 编辑弹窗里必须有「上级文集」这一项
      expect(find.text('上级文集'), findsOneWidget);
      expect(find.text('顶层'), findsOneWidget, reason: '默认应该在顶层');

      await tester.tap(find.text('上级文集'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('甲'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      final saved = state.repo
          .allCollections()
          .firstWhere((x) => x.id == b);
      expect(saved.parentId, a, reason: '选完上级要真的写进库');
    });

    testWidgets('不能把文集塞进自己的子孙里（会成环）', (tester) async {
      final a = await state.createCollection('甲');
      await state.createCollection('乙', parentId: a);
      await state.refresh();

      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Builder(
              builder: (c) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => showCollectionEditor(
                      c,
                      existing: state.collections.firstWhere((x) => x.id == a),
                    ),
                    child: const Text('编辑甲'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑甲'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('上级文集'));
      await tester.pumpAndSettle();

      // 选项里不该有自己，也不该有子孙（乙）
      expect(find.text('顶层（不在任何文集里）'), findsOneWidget);
      expect(find.text('乙'), findsNothing, reason: '子孙不能当上级，否则树成环');
    });
  });

  group('手机端导出文集', () {
    testWidgets('文件夹管理页里有导出入口，点开是格式菜单', (tester) async {
      final id = await state.createCollection('甲');
      state.repo.insertNote(
        title: '里面的',
        content: '正文',
        excerpt: '正文',
        publishedAt: DateTime.now(),
        charCount: 2,
        collectionId: id,
      );
      await state.refresh();

      await pumpPhone(tester, const ManageCollectionsPage());

      // 桌面是在文件夹上右键导出的，手机没有右键 —— 入口必须在这一页
      expect(find.byTooltip('导出为压缩包'), findsOneWidget);
      await tester.tap(find.byTooltip('导出为压缩包'));
      await tester.pumpAndSettle();
      expect(find.textContaining('.docx'), findsWidgets,
          reason: '应该弹出格式选择，说明入口是通的（真正保存要走系统文件框）');
    });

    testWidgets('文集空的时候会说清楚，而不是弹格式菜单', (tester) async {
      await state.createCollection('空的');
      await state.refresh();
      await pumpPhone(tester, const ManageCollectionsPage());

      await tester.tap(find.byTooltip('导出为压缩包'));
      await tester.pumpAndSettle();
      expect(find.textContaining('还没有笔记'), findsOneWidget);
    });
  });
}
