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
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/collections/collection_sheets.dart';
import 'package:yuan_world/features/collections/manage_collections_page.dart';
import 'package:yuan_world/features/importer/import_page.dart';
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

  group('手机端导入文集', () {
    testWidgets('导入页能打开，两个入口都在', (tester) async {
      await state.refresh();
      await pumpPhone(tester, const ImportPage());
      expect(find.text('选择文件夹'), findsOneWidget);
      expect(find.text('选择文件'), findsOneWidget);
    });

    testWidgets('桌面端保留"拖文件进来"的提示', (tester) async {
      // 这条只测得到**桌面分支**：判断用的是 `Platform.isWindows`
      // （`isDesktopPlatform()`），widget 测试里改不了它。
      // 手机分支（提示消失）是在真机上截图确认的 —— 见提交说明。
      await state.refresh();
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(theme: AppTheme.light(), home: const ImportPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('拖到页面任意位置'), findsOneWidget,
          reason: '桌面端这句是真能用的，不能一起删掉');
    });
  });

  group('手机端隐私空间', () {
    testWidgets('进了隐私空间：列表里有出口，设置页那行也变成"退出"', (tester) async {
      add('公开的');
      final secret = add('秘密');
      state.repo.setNoteHidden(secret, true);
      await state.refresh();

      // 从设置页进（手机端唯一的入口）。设置页很长，先滚到那一行再点
      await pumpPhone(tester, const SettingsPage());
      expect(find.text('进入隐私空间'), findsOneWidget);
      await tester.ensureVisible(find.text('进入隐私空间'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('进入隐私空间'));
      await tester.pumpAndSettle();
      expect(state.privacyMode, isTrue);

      // 设置页那行必须变成出口 —— 手机上原本进了就退不出来
      expect(find.text('退出隐私空间'), findsOneWidget);
      await tester.ensureVisible(find.text('退出隐私空间'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('退出隐私空间'));
      await tester.pumpAndSettle();
      expect(state.privacyMode, isFalse);

      // 列表里也有出口（光看列表得知道自己在哪个空间）
      state.enterPrivacyMode();
      await state.refresh();
      await pumpPhone(tester, const HomeShell());
      expect(find.textContaining('隐私空间 · 退出'), findsOneWidget);
      expect(find.text('秘密'), findsOneWidget, reason: '隐私空间里就该只看到隐藏内容');
      expect(find.text('公开的'), findsNothing);

      await tester.tap(find.textContaining('隐私空间 · 退出'));
      await tester.pumpAndSettle();
      expect(state.privacyMode, isFalse);
      expect(find.text('公开的'), findsOneWidget);
    });

    testWidgets('从设置页退出隐私空间，也要走那层过渡，不是啪一下换掉', (tester) async {
      add('公开的');
      final secret = add('秘密');
      state.repo.setNoteHidden(secret, true);
      state.enterPrivacyMode();
      await state.refresh();

      await pumpPhone(tester, const SettingsPage());
      expect(find.text('退出隐私空间'), findsOneWidget);
      await tester.ensureVisible(find.text('退出隐私空间'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('退出隐私空间'));
      // 过渡一共 620ms，推到中段时锁和那句字应该在画面上。
      // 以前这里直接调 state.exitPrivacyMode()，这一帧什么都不会出现 ——
      // 同一件事，从设置点出去是「啪」一下，从左栏点出去才有动画。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        find.text('已离开隐私空间'),
        findsOneWidget,
        reason: '设置页的出口也得有那层过渡',
      );

      await tester.pumpAndSettle();
      expect(state.privacyMode, isFalse);
      expect(find.text('已离开隐私空间'), findsNothing, reason: '过渡要收干净');
    });
  });

  group('手机端目录面板', () {
    testWidgets('窄屏开目录是浮层：不挤正文、不出溢出条纹', (tester) async {
      final id = state.repo.insertNote(
        title: '带标题的',
        content: '# 第一章\n\n正文一。\n\n## 小节 A\n\n正文二。\n\n# 第二章\n\n正文三。',
        excerpt: '正文',
        publishedAt: DateTime.now(),
        charCount: 30,
      );
      await state.refresh();
      await pumpPhone(tester, NoteDetailPage(noteId: id));

      // 打开目录
      await tester.tap(find.byTooltip('目录'));
      await tester.pumpAndSettle();

      // 真机上这里是"RIGHT OVERFLOWED BY ..."的条纹
      expect(tester.takeException(), isNull);
      expect(find.text('第一章'), findsWidgets, reason: '目录条目要出来');
      // 浮层：正文还在（没被挤掉），目录盖在上面
      expect(find.textContaining('正文一'), findsWidgets);
    });
  });

  group('手机端筛选胶囊高亮', () {
    /// 找到某个胶囊并读它的 selected。
    ///
    /// `_Pill` 是 notes_page 的私有类，测试里没法直接引用类型 —— 用
    /// `runtimeType.toString()` 认它，再用 dynamic 读公开字段 `selected`。
    bool pillSelected(WidgetTester tester, String label) {
      final pill = tester
          .widgetList(find.byWidgetPredicate(
            (w) => w.runtimeType.toString() == '_Pill',
          ))
          .cast<dynamic>()
          .firstWhere((p) => p.label == label);
      return pill.selected as bool;
    }

    testWidgets('点「归档」之后「全部」不能跟着一起亮（用户报的两个同时高亮）', (tester) async {
      add('甲');
      await state.refresh();
      await pumpPhone(tester, const HomeShell());

      expect(pillSelected(tester, '全部'), isTrue);
      expect(pillSelected(tester, '归档'), isFalse);

      await tester.tap(find.text('归档'));
      await tester.pumpAndSettle();

      expect(state.filter.archivedOnly, isTrue);
      expect(pillSelected(tester, '归档'), isTrue);
      expect(pillSelected(tester, '全部'), isFalse,
          reason: '归档是「全部」之外的另一条口径，两个同时亮是 bug');

      // 收藏同理（互斥筛选都要排掉）
      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      expect(pillSelected(tester, '收藏'), isTrue);
      expect(pillSelected(tester, '全部'), isFalse);
    });

    testWidgets('点过收藏/归档再点文件夹，不能两个同时亮（用户报的）', (tester) async {
      final col = await state.createCollection('甲文件夹');
      add('里面的');
      await state.refresh();
      await pumpPhone(tester, const HomeShell());

      // 收藏 → 文件夹
      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      expect(pillSelected(tester, '收藏'), isTrue);
      await tester.tap(find.text('甲文件夹'));
      await tester.pumpAndSettle();
      expect(pillSelected(tester, '甲文件夹'), isTrue);
      expect(pillSelected(tester, '收藏'), isFalse,
          reason: '文件夹和收藏是同一排的单选视图，不能同时高亮');
      expect(state.filter.collectionId, col);

      // 归档 → 文件夹
      await tester.tap(find.text('归档'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('甲文件夹'));
      await tester.pumpAndSettle();
      expect(pillSelected(tester, '甲文件夹'), isTrue);
      expect(pillSelected(tester, '归档'), isFalse);
      // 归档口径也确实被清掉了（不然列表是空的，看着像"笔记没了"）
      expect(state.filter.archivedOnly, isFalse);
      expect(state.filter.favoritesOnly, isFalse);
    });
  });

  group('手机端瀑布流列数', () {
    testWidgets('设置里改列数，手机瀑布流真的跟着变', (tester) async {
      // 以前手机上是 `gridColumns.clamp(2, fit)`，而 fit 在手机上恒为 2 ——
      // 改列数**一点效果都没有**。
      for (final cols in <int>[2, 4]) {
        add('笔记 $cols');
        state.setGridColumns(cols);
        state.setGridMode(true);
        await state.refresh();
        await pumpPhone(tester, const HomeShell());
        await tester.pumpAndSettle();

        final grid = tester.widget<SliverMasonryGrid>(
          find.byType(SliverMasonryGrid),
        );
        final delegate = grid.gridDelegate
            as SliverSimpleGridDelegateWithFixedCrossAxisCount;
        expect(delegate.crossAxisCount, cols,
            reason: '$cols 列的设置必须生效');
      }
    });
  });

  group('手机端文件夹嵌套展示', () {
    testWidgets('子文件夹在「文件夹管理」页里缩进显示（和 Windows 左栏一样）', (tester) async {
      final parent = await state.createCollection('父文件夹');
      await state.createCollection('子文件夹', parentId: parent);
      await state.refresh();
      await pumpPhone(tester, const ManageCollectionsPage());

      final px = tester.getTopLeft(find.text('父文件夹')).dx;
      final cx = tester.getTopLeft(find.text('子文件夹')).dx;
      expect(cx, greaterThan(px), reason: '子文件夹必须缩进，否则看不出归属');
      // 父在前、子紧随其后
      expect(
        tester.getTopLeft(find.text('子文件夹')).dy,
        greaterThan(tester.getTopLeft(find.text('父文件夹')).dy),
      );
    });
  });

  group('手机端编辑后列表要跟着变', () {
    testWidgets('系统返回（手势/返回键）也要先落库 + 刷新列表', (tester) async {
      final id = state.repo.insertNote(
        title: '原标题',
        content: '原正文',
        excerpt: '原正文',
        publishedAt: DateTime.now(),
        charCount: 3,
      );
      await state.refresh();
      await pumpPhone(tester, NoteEditorPage(noteId: id));
      await tester.pumpAndSettle();

      // 改标题，**不等** 1.2 秒的自动保存定时器
      await tester.enterText(find.byType(TextField).first, '手势返回改的');
      await tester.pump(const Duration(milliseconds: 60));

      // 模拟手机的返回手势/返回键
      tester.binding.handlePopRoute();
      await tester.pumpAndSettle();

      expect(state.notes.first.title, '手势返回改的',
          reason: '以前这条路不落库也不刷新：刚敲的字可能丢，列表还是旧的，'
              '得下拉才更新（用户报的正是这个）');
    });
  });

  group('手机端空列表的说法', () {
    testWidgets('空文件夹说"还是空的"，不能说"换个关键词"（用户报的）', (tester) async {
      final col = await state.createCollection('空文件夹');
      add('有正文的');
      await state.refresh();
      await pumpPhone(tester, const HomeShell());

      await tester.tap(find.text('空文件夹'));
      await tester.pumpAndSettle();

      expect(find.textContaining('还是空的'), findsOneWidget);
      expect(find.text('没有匹配的笔记'), findsNothing,
          reason: '没有搜索词却说"换个关键词"是答非所问');
      expect(find.text('看全部笔记'), findsOneWidget, reason: '要给一个脱困的动作');

      // 点了就回到全部
      await tester.tap(find.text('看全部笔记'));
      await tester.pumpAndSettle();
      expect(state.filter.collectionId, isNull);
      expect(find.text('有正文的'), findsOneWidget);
      expect(col, isNotNull);
    });

    testWidgets('空收藏 / 空归档 / 空标签各自说自己的话', (tester) async {
      add('有正文的');
      await state.refresh();
      await pumpPhone(tester, const HomeShell());

      await tester.tap(find.text('收藏'));
      await tester.pumpAndSettle();
      expect(find.textContaining('还没有收藏的笔记'), findsOneWidget);

      await tester.tap(find.text('归档'));
      await tester.pumpAndSettle();
      expect(find.textContaining('归档里还没有笔记'), findsOneWidget);

      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      state.selectTag('不存在的标签');
      await tester.pumpAndSettle();
      expect(find.textContaining('没有带「不存在的标签」标签的笔记'), findsOneWidget);
    });

    testWidgets('搜不到时才说"没有匹配的笔记"', (tester) async {
      add('有正文的');
      await state.refresh();
      await pumpPhone(tester, const HomeShell());

      state.setQuery('zzz查不到');
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的笔记'), findsOneWidget);
      expect(find.textContaining('换个关键词'), findsOneWidget);
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
