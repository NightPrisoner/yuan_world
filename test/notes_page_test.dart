/// 界面测试：窄屏的笔记列表页 + 宽屏的三栏工作区。
///
/// 布局在 1000px 处分叉：
///   - 宽屏 → DesktopWorkspace（分类导航 | 列表 | 阅读/编辑）
///   - 窄屏 → NotesPage（底部标签栏那套）
/// 两边是两套完全不同的组件树，所以要分别断言。
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/notes/note_detail_page.dart';
import 'package:yuan_world/features/notes/widgets/note_card.dart';
import 'package:yuan_world/features/shell/home_shell.dart';

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

  Future<void> pumpApp(WidgetTester tester, {required Size size}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const HomeShell(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpDetail(WidgetTester tester, int noteId) async {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: NoteDetailPage(noteId: noteId),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // ── 三栏工作区（宽屏） ──────────────────────────────────────────────────

  group('三栏工作区（宽屏）', () {
    testWidgets('左栏显示分类与文件夹导航', (tester) async {
      final cid = state.repo.ensureCollection('杂碎记');
      state.repo.insertNote(
        title: '一篇散文',
        content: '正文',
        excerpt: '正文',
        collectionId: cid,
      );
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      // 分类
      expect(find.text('全部笔记'), findsWidgets);
      expect(find.text('未分类'), findsOneWidget);
      expect(find.text('收藏'), findsWidgets);
      // 文件夹
      expect(find.text('杂碎记'), findsWidgets);
      // 其它板块入口
      expect(find.text('待办'), findsOneWidget);
      expect(find.text('统计'), findsOneWidget);
      expect(find.text('设置'), findsOneWidget);
      expect(find.text('导入文集'), findsOneWidget);
    });

    testWidgets('中栏列表显示笔记，右栏自动选中第一篇', (tester) async {
      state.repo.insertNote(
        title: '自动选中的笔记',
        content: '这里是正文内容',
        excerpt: '这里是正文内容',
      );
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      // 搜索框与计数
      expect(find.text('搜索全部笔记'), findsOneWidget);
      expect(find.textContaining('共 1 篇'), findsOneWidget);

      // 标题在「列表行 + 右栏标题栏 + 右栏正文标题」三处出现
      expect(find.text('自动选中的笔记'), findsWidgets);
      // 正文被渲染出来，说明右栏确实打开了这篇
      expect(find.textContaining('这里是正文内容'), findsWidgets);
    });

    testWidgets('默认只开两栏，正文栏收起', (tester) async {
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      // 冷启动是「导航 + 列表」，不先甩给用户一块空白
      expect(find.text('从左侧选一篇笔记'), findsNothing);
      expect(find.text('这里还没有笔记'), findsOneWidget);
      expect(find.textContaining('共 0 篇'), findsOneWidget);
    });

    testWidgets('点一篇笔记才把正文栏拉出来', (tester) async {
      state.repo.insertNote(title: '要看的那篇', content: '正文', excerpt: '正文');
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      expect(find.text('从左侧选一篇笔记'), findsNothing);

      await tester.tap(find.text('要看的那篇').first);
      await tester.pumpAndSettle();

      // 正文栏出来了，右上角有关闭按钮
      expect(find.byTooltip('收起正文栏'), findsOneWidget);

      // 收起后回到两栏
      await tester.tap(find.byTooltip('收起正文栏'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('收起正文栏'), findsNothing);
    });

    testWidgets('新建笔记会自动展开正文栏', (tester) async {
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      await tester.tap(find.byTooltip('新建笔记（Ctrl+N）'));
      await tester.pumpAndSettle();

      // 新建后直接进编辑器，正文栏必然是展开的
      expect(find.byTooltip('加粗'), findsOneWidget);
    });

    testWidgets('点文件夹会筛选列表', (tester) async {
      final a = state.repo.ensureCollection('文集甲');
      state.repo.insertNote(
        title: '属于甲',
        content: 'x',
        excerpt: '',
        collectionId: a,
      );
      state.repo.insertNote(title: '没有归类', content: 'y', excerpt: '');
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      expect(find.textContaining('共 2 篇'), findsOneWidget);

      await tester.tap(find.text('文集甲').first);
      await tester.pumpAndSettle();

      expect(find.textContaining('共 1 篇'), findsOneWidget);
      expect(state.filter.collectionId, a);
    });

    testWidgets('「未分类」只看没有文集的笔记', (tester) async {
      final a = state.repo.ensureCollection('有分类');
      state.repo.insertNote(
        title: '归了类',
        content: 'x',
        excerpt: '',
        collectionId: a,
      );
      state.repo.insertNote(title: '没归类', content: 'y', excerpt: '');
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      await tester.tap(find.text('未分类'));
      await tester.pumpAndSettle();

      expect(state.filter.uncategorizedOnly, isTrue);
      expect(find.textContaining('共 1 篇'), findsOneWidget);
      expect(find.text('没归类'), findsWidgets);
    });

    testWidgets('搜索框能过滤列表', (tester) async {
      state.repo.insertNote(title: '火车巡礼', content: 'x', excerpt: '');
      state.repo.insertNote(title: '别的主题', content: 'y', excerpt: '');
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      await tester.enterText(find.byType(TextField).first, '火车');
      await tester.pumpAndSettle();

      expect(state.filter.query, '火车');
      expect(find.textContaining('共 1 篇'), findsOneWidget);
    });

    testWidgets('点「待办」切到待办页', (tester) async {
      await pumpApp(tester, size: const Size(1400, 900));

      await tester.tap(find.text('待办').first);
      await tester.pumpAndSettle();

      // 待办页的特征元素
      expect(find.text('添加待办…'), findsOneWidget);
    });

    testWidgets('可以新建文件夹', (tester) async {
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      expect(find.text('还没有文件夹'), findsOneWidget);

      // 「我的文件夹」右侧的 + 按钮
      await tester.tap(find.byTooltip('新建文件夹'));
      await tester.pumpAndSettle();

      expect(find.text('新建文集'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, '我的新文件夹');
      await tester.pumpAndSettle();
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();

      expect(state.collections.length, 1);
      expect(state.collections.first.name, '我的新文件夹');
      expect(find.text('我的新文件夹'), findsWidgets);
    });

    testWidgets('文件夹的 ⋯ 菜单可以打开重命名面板', (tester) async {
      state.repo.createCollection('待改名');
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      // 悬停到文件夹那一行，⋯ 才会出现
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pumpAndSettle();

      await gesture.moveTo(tester.getCenter(find.text('待改名')));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_horiz_rounded).first);
      await tester.pumpAndSettle();

      expect(find.text('重命名 / 改颜色'), findsOneWidget);
      expect(find.text('删除文件夹'), findsOneWidget);
    });

    testWidgets('瀑布流视图可以切换，并且真的换了渲染方式', (tester) async {
      for (var i = 0; i < 3; i++) {
        state.repo.insertNote(
          title: '笔记 $i',
          content: '正文 $i',
          excerpt: '正文 $i',
        );
      }
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      // 默认列表视图
      expect(state.gridMode, isFalse);
      expect(find.byTooltip('瀑布流视图'), findsOneWidget);

      await tester.tap(find.byTooltip('瀑布流视图'));
      await tester.pumpAndSettle();

      expect(state.gridMode, isTrue);
      // 切完按钮语义反转
      expect(find.byTooltip('列表视图'), findsOneWidget);
      // 三条笔记仍然都在
      expect(find.text('笔记 0'), findsWidgets);
      expect(find.text('笔记 2'), findsWidgets);
    });

    testWidgets('列表栏有新建入口，点完直接进编辑器', (tester) async {
      await pumpApp(tester, size: const Size(1400, 900));
      expect(state.overview?.noteCount, 0);

      await tester.tap(find.byTooltip('新建笔记（Ctrl+N）'));
      await tester.pumpAndSettle();

      expect(state.overview?.noteCount, 1);
      // 关键：新建后落在编辑器里，而不是空白阅读页
      expect(find.byTooltip('加粗'), findsOneWidget);
      expect(find.text('编辑'), findsWidgets);
    });

    testWidgets('在某个文件夹下新建，会归入该文件夹', (tester) async {
      final cid = state.repo.createCollection('目标文集')!;
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      await tester.tap(find.text('目标文集').first);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('新建笔记（Ctrl+N）'));
      await tester.pumpAndSettle();

      final created = state.repo.getNote(1)!;
      expect(created.collectionId, cid);
    });

    testWidgets('操作菜单贴着触发处弹出，而不是从底部升起', (tester) async {
      state.repo.insertNote(title: '锚定测试', content: '正文', excerpt: '');
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      // 悬停列表行，点右上角的 ⋯
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pumpAndSettle();
      await gesture.moveTo(tester.getCenter(find.text('锚定测试').first));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.more_horiz_rounded).first);
      await tester.pumpAndSettle();

      // 菜单出来了
      expect(find.text('复制全文'), findsOneWidget);

      // 关键断言：不是底部面板，而是锚定弹出的下拉菜单
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        find.byWidgetPredicate((w) => w is PopupMenuItem),
        findsWidgets,
      );

      // 菜单位于屏幕上半部分（贴着上方列表行），而不是贴在窗口底部
      // 断言**菜单本身**贴着上方，而不是某一项的位置 ——
      // 菜单项会增删，钉死某一项的坐标等于给未来埋雷
      final menuTop = tester
          .getTopLeft(find.byWidgetPredicate((w) => w is PopupMenuItem).first)
          .dy;
      expect(menuTop, lessThan(450));
    });

    testWidgets('右键列表项打开操作面板并能删除', (tester) async {
      state.repo.insertNote(title: '右键删掉我', content: 'x', excerpt: '');
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      expect(state.overview?.noteCount, 1);

      final row = find.text('右键删掉我').first;
      final gesture = await tester.startGesture(
        tester.getCenter(row),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();

      expect(find.text('复制全文'), findsOneWidget);
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '删除'));
      await tester.pumpAndSettle();

      expect(state.overview?.noteCount, 0);
      expect(find.text('这里还没有笔记'), findsOneWidget);
    });
  });

  // ── 拖拽 ────────────────────────────────────────────────────────────────

  /// 把 [from] 拖到 [to] 的位置。
  ///
  /// 分两步移动：Draggable 需要指针先跨过触摸阈值才会真正起拖，
  /// 一步到位有时会被判定成点击。
  Future<void> dragTo(WidgetTester tester, Finder from, Finder to) async {
    final start = tester.getCenter(from);
    final end = tester.getCenter(to);
    final g = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 40));
    await g.moveTo(Offset((start.dx + end.dx) / 2, (start.dy + end.dy) / 2));
    await tester.pump(const Duration(milliseconds: 40));
    await g.moveTo(end);
    await tester.pump(const Duration(milliseconds: 40));
    await g.up();
    await tester.pumpAndSettle();
  }

  group('拖拽', () {
    testWidgets('把笔记拖到文件夹上就归入该文件夹', (tester) async {
      final cid = state.repo.createCollection('目标文件夹')!;
      final noteId =
          state.repo.insertNote(title: '待归类的文章', content: '正文', excerpt: '');
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      expect(state.repo.getNote(noteId)!.collectionId, isNull);

      await dragTo(
        tester,
        find.text('待归类的文章').first,
        find.text('目标文件夹').first,
      );

      expect(state.repo.getNote(noteId)!.collectionId, cid);
    });

    testWidgets('把笔记拖到「未分类」会移出文件夹', (tester) async {
      final cid = state.repo.createCollection('原来的文件夹')!;
      final noteId = state.repo.insertNote(
        title: '要搬走的文章',
        content: '正文',
        excerpt: '',
        collectionId: cid,
      );
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      expect(state.repo.getNote(noteId)!.collectionId, cid);

      await dragTo(
        tester,
        find.text('要搬走的文章').first,
        find.text('未分类').first,
      );

      expect(state.repo.getNote(noteId)!.collectionId, isNull);
    });

    testWidgets('把文件夹拖到另一个文件夹上会变成子文件夹', (tester) async {
      state.repo.createCollection('父文件夹');
      state.repo.createCollection('要嵌套的');
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      expect(
        // 后建的排在最上面（新建/导入位于置顶之下第一个位置）
        state.collections.map((c) => c.name).toList(),
        <String>['要嵌套的', '父文件夹'],
      );
      expect(state.collections.every((c) => c.parentId == null), isTrue);

      await dragTo(
        tester,
        find.text('要嵌套的').first,
        find.text('父文件夹').first,
      );

      final nested =
          state.collections.firstWhere((c) => c.name == '要嵌套的');
      final parent = state.collections.firstWhere((c) => c.name == '父文件夹');
      expect(nested.parentId, parent.id, reason: '应该挂到父文件夹下面');
    });

    testWidgets('不能把文件夹拖进自己的子文件夹（防成环）', (tester) async {
      final parent = state.repo.createCollection('外层')!;
      final child = state.repo.createCollection('内层')!;
      state.repo.setCollectionParent(child, parent);
      await state.refresh();

      // 直接走数据层验证拒绝逻辑，UI 拖拽路径同源
      final ok = state.repo.setCollectionParent(parent, child);
      expect(ok, isFalse, reason: '会形成环，必须拒绝');
    });
  });

  // ── 全屏编辑 ────────────────────────────────────────────────────────────

  group('全屏编辑', () {
    testWidgets('切换全屏会收起导航与列表，且不丢失未保存内容', (tester) async {
      final id = state.repo.insertNote(
        title: '全屏编辑测试',
        content: '原文内容',
        excerpt: '',
      );
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      // 正文栏默认收起，先点开那篇笔记
      await tester.tap(find.text('全屏编辑测试').first);
      await tester.pumpAndSettle();

      // 右侧栏点「编辑」
      await tester.tap(find.byTooltip('编辑'));
      await tester.pumpAndSettle();

      expect(find.byTooltip('占满页面'), findsOneWidget);

      // 输入内容，但**不给自动保存的定时器机会**（只推帧不推时间）
      await tester.enterText(find.byType(TextField).last, '未保存的临时内容');
      await tester.pump();

      await tester.tap(find.byTooltip('占满页面'));
      await tester.pump();
      await tester.pump();

      // 内容还在 —— 说明编辑器 State 被复用而不是重建
      // （若被重建，initState 会从数据库重新读，这里就会变回「原文内容」）
      expect(find.text('未保存的临时内容'), findsOneWidget);
      expect(find.text('原文内容'), findsNothing);

      // **而且要真的看得见**：曾经出过"占满页面后一片白" ——
      // 那一层 Opacity 被设成了 0，控件都还在树里（所以上面那条断言照样过），
      // 但屏幕上什么都没有。所以这里查透明度。
      final opacities = tester.widgetList<Opacity>(
        find.ancestor(
          of: find.text('未保存的临时内容'),
          matching: find.byType(Opacity),
        ),
      );
      expect(
        opacities.every((o) => o.opacity > 0.99),
        isTrue,
        reason: '全屏时正文不能是透明的，否则就是白屏',
      );

      // 导航栏与列表栏都收起来了
      expect(find.text('全部笔记'), findsNothing);
      expect(find.text('未分类'), findsNothing);
      expect(find.text('搜索全部笔记'), findsNothing);

      // 按钮语义反转
      expect(find.byTooltip('退出占满页面'), findsOneWidget);

      // 退出之后三栏回来
      await tester.tap(find.byTooltip('退出占满页面'));
      await tester.pumpAndSettle();
      expect(find.text('未分类'), findsOneWidget);
      expect(find.byTooltip('占满页面'), findsOneWidget);
      expect(id, greaterThan(0));
    });

    testWidgets('「占满页面」和「窗口全屏」是两个独立按钮', (tester) async {
      state.repo.insertNote(title: 'T', content: 'x', excerpt: '');
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      await tester.tap(find.text('T').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('编辑'));
      await tester.pumpAndSettle();

      // 两个都在：一个改版式，一个改窗口。
      // 混成一个的后果就是用户点"占满页面"整个屏幕却被放大了。
      expect(find.byTooltip('占满页面'), findsOneWidget);
      expect(find.byTooltip('窗口全屏'), findsOneWidget);

      // 点"占满页面"只收三栏，**窗口全屏按钮不应跟着变成退出态**
      await tester.tap(find.byTooltip('占满页面'));
      await tester.pumpAndSettle();
      expect(find.text('未分类'), findsNothing, reason: '三栏收起来了');
      expect(
        find.byTooltip('窗口全屏'),
        findsOneWidget,
        reason: '窗口全屏是独立状态，不该被占满页面带着走',
      );
      expect(find.byTooltip('退出占满页面'), findsOneWidget);
    });

    testWidgets('「完成」退出编辑并保存', (tester) async {
      final id = state.repo.insertNote(
        title: '保存测试',
        content: '旧内容',
        excerpt: '',
      );
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      // 正文栏默认收起，先点开那篇笔记
      await tester.tap(find.text('保存测试').first);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('编辑'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).last, '改完的新内容');
      await tester.pump();

      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      // 回到阅读态，且内容已落库
      expect(find.text('全屏编辑'), findsNothing);
      expect(state.repo.getNote(id)!.content, contains('改完的新内容'));
    });
  });

  // ── 瀑布流列数 / 三栏宽度 ────────────────────────────────────────────────

  group('布局自定义', () {
    /// 鼠标悬停到某个控件上（悬停才会露出 ⋯ 按钮）。
    Future<void> hover(WidgetTester tester, Finder target) async {
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.addPointer(location: Offset.zero);
      addTearDown(g.removePointer);
      await tester.pumpAndSettle();
      await g.moveTo(tester.getCenter(target));
      await tester.pumpAndSettle();
    }

    testWidgets('瀑布流里没有封面的笔记也有 ⋯ 按钮', (tester) async {
      // 这条对应一个真实的 bug：⋯ 按钮原本塞在封面的 Stack 里，
      // 导致没有封面的笔记（新建的都是纯文字）完全没有操作入口。
      state.repo.insertNote(title: '纯文字笔记', content: '正文', excerpt: '正文');
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      await tester.tap(find.byTooltip('瀑布流视图'));
      await tester.pumpAndSettle();

      await hover(tester, find.text('纯文字笔记').first);

      expect(
        find.byIcon(Icons.more_horiz_rounded),
        findsWidgets,
        reason: '无封面卡片也要有操作入口',
      );
    });

    testWidgets('列表里没有封面的笔记也有 ⋯ 按钮', (tester) async {
      state.repo.insertNote(title: '纯文字笔记', content: '正文', excerpt: '正文');
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      await hover(tester, find.text('纯文字笔记').first);
      expect(find.byIcon(Icons.more_horiz_rounded), findsWidgets);
    });

    testWidgets('列数入口从工具栏移走了，只留视图切换', (tester) async {
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      await tester.tap(find.byTooltip('瀑布流视图'));
      await tester.pumpAndSettle();

      // 列数挪到设置里了，列表栏只保留「列表 / 瀑布流」这一个切换
      expect(find.byTooltip('每行几列'), findsNothing);
      expect(find.byTooltip('列表视图'), findsOneWidget);
      expect(state.gridColumns, 2, reason: '默认仍是两列');
    });

    test('列数可以自定义并落库，没有产品上限', () async {
      state.setGridColumns(4);
      expect(state.gridColumns, 4);
      expect(state.repo.getSetting('gridColumns'), '4');

      // 上限已经取消，交给用户；只剩一个防手滑的兜底
      state.setGridColumns(99);
      expect(state.gridColumns, 50);

      state.setGridColumns(0);
      expect(state.gridColumns, 1);
      state.setGridColumns(-3);
      expect(state.gridColumns, 1);
    });

    testWidgets('点排序菜单里的字段会真的切换', (tester) async {
      for (var i = 0; i < 3; i++) {
        state.repo.insertNote(title: '笔记 $i', content: 'x', excerpt: 'x');
      }
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      expect(state.filter.sort.field, SortField.updated);

      await tester.tap(find.byTooltip('排序'));
      await tester.pumpAndSettle();

      // 菜单里字段项在方向项上面，取第一组里的「名称」
      expect(find.text('名称'), findsWidgets);
      await tester.tap(find.text('名称').last);
      await tester.pumpAndSettle();

      expect(
        state.filter.sort.field,
        SortField.title,
        reason: '点「名称」应该把排序字段换成名称',
      );
      expect(
        state.filter.sort.dir,
        SortDir.desc,
        reason: '换字段要保留原来的方向',
      );
    });

    testWidgets('切到创建日期递增后，列表顺序真的跟着变', (tester) async {
      // 之前那条只断言了「筛选状态变了」，没断言**列表顺序**，
      // 所以"菜单勾上了但列表没动"这种情况它抓不到。
      state.repo.insertNote(
        title: '最早的', content: 'x', excerpt: 'x',
        createdAt: DateTime(2020, 1, 1),
      );
      state.repo.insertNote(
        title: '中间的', content: 'x', excerpt: 'x',
        createdAt: DateTime(2022, 1, 1),
      );
      state.repo.insertNote(
        title: '最新的', content: 'x', excerpt: 'x',
        createdAt: DateTime(2024, 1, 1),
      );
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      state.setSort(NoteSort.createdAsc);
      await tester.pumpAndSettle();

      expect(
        state.notes.map((n) => n.title).toList(),
        <String>['最早的', '中间的', '最新的'],
        reason: '递增就该从早到晚',
      );

      state.setSort(NoteSort.createdDesc);
      await tester.pumpAndSettle();
      expect(
        state.notes.map((n) => n.title).toList(),
        <String>['最新的', '中间的', '最早的'],
      );
    });

    testWidgets('点方向项只换方向，字段不动', (tester) async {
      for (var i = 0; i < 3; i++) {
        state.repo.insertNote(title: '笔记 $i', content: 'x', excerpt: 'x');
      }
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      await tester.tap(find.byTooltip('排序'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('递增 ↑').last);
      await tester.pumpAndSettle();

      expect(state.filter.sort.dir, SortDir.asc);
      expect(state.filter.sort.field, SortField.updated,
          reason: '换方向不该把字段重置掉');
    });

    testWidgets('切到瀑布流时中栏会自动撑开，避免两列挤成一团', (tester) async {
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      final before =
          double.tryParse(state.repo.getSetting('layout.listWidth') ?? '') ?? 316;
      await tester.tap(find.byTooltip('瀑布流视图'));
      await tester.pumpAndSettle();

      final after =
          double.tryParse(state.repo.getSetting('layout.listWidth') ?? '') ?? 316;
      expect(after, greaterThan(before));
    });

    testWidgets('拖动分隔条可以改变左栏宽度并落库', (tester) async {
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      expect(state.repo.getSetting('layout.navWidth'), isNull);

      // 左栏默认 236 宽，分隔条就在它右边那几个像素
      await tester.dragFrom(const Offset(240, 400), const Offset(70, 0));
      await tester.pumpAndSettle();

      final saved = int.tryParse(state.repo.getSetting('layout.navWidth') ?? '');
      expect(saved, isNotNull, reason: '拖动后要写库');
      expect(saved, greaterThan(240), reason: '往右拖应该变宽');
    });

    testWidgets('连续拖动不会中断（分隔条不能被从树里拿掉）', (tester) async {
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      // 分 6 步慢慢拖。以前分隔条的"在不在"是看**动画值**算的：
      // 拖一下宽度变了，动画值跟着掉，分隔条就被从树里拿掉 ——
      // 手还按着，后面的位移全丢了（用户说的"拉着拉着断掉"）。
      // 每步 6px、共 36px，全部生效才算没断。
      final g = await tester.startGesture(const Offset(240, 400));
      for (var i = 0; i < 6; i++) {
        await g.moveBy(const Offset(6, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pumpAndSettle();

      final saved = int.tryParse(state.repo.getSetting('layout.navWidth') ?? '') ?? 0;
      expect(saved, greaterThanOrEqualTo(236 + 30),
          reason: '只吃掉第一步的位移，说明中途分隔条没了、拖拽断了');
    });

    testWidgets('宽度有上下限，拖过头也不会把别的栏挤没', (tester) async {
      await state.refresh();
      await pumpApp(tester, size: const Size(1400, 900));

      // 往左狂拖
      await tester.dragFrom(const Offset(240, 400), const Offset(-2000, 0));
      await tester.pumpAndSettle();
      final narrow =
          int.tryParse(state.repo.getSetting('layout.navWidth') ?? '') ?? 0;
      expect(narrow, greaterThanOrEqualTo(160));

      // 往右狂拖
      await tester.dragFrom(const Offset(240, 400), const Offset(3000, 0));
      await tester.pumpAndSettle();
      final wide =
          int.tryParse(state.repo.getSetting('layout.navWidth') ?? '') ?? 0;
      expect(wide, lessThanOrEqualTo(560));
    });
  });

  // ── 笔记列表页（窄屏） ──────────────────────────────────────────────────

  group('笔记列表页（窄屏）', () {
    testWidgets('空库时显示导入引导', (tester) async {
      await pumpApp(tester, size: const Size(420, 900));

      expect(find.text('还没有内容'), findsOneWidget);
      expect(find.textContaining('导入你的 .docx 文集'), findsOneWidget);
      expect(find.text('导入文集'), findsOneWidget);
    });

    testWidgets('有笔记时显示卡片', (tester) async {
      state.repo.insertNote(
        title: '第一篇笔记',
        content: '正文内容',
        excerpt: '正文内容',
        charCount: 4,
        wordCount: 4,
      );
      await state.refresh();
      await pumpApp(tester, size: const Size(420, 900));

      expect(find.text('还没有内容'), findsNothing);
      expect(find.byType(NoteCard), findsOneWidget);
      expect(find.text('第一篇笔记'), findsWidgets);
    });

    testWidgets('底部标签栏四个标签都在', (tester) async {
      await pumpApp(tester, size: const Size(420, 900));

      expect(find.text('笔记'), findsWidgets);
      expect(find.text('待办'), findsWidgets);
      expect(find.text('统计'), findsWidgets);
      expect(find.text('设置'), findsWidgets);
    });

    testWidgets('筛选栏最右边固定一个文件夹图标，点进「笔记文件夹」页', (tester) async {
      state.repo.createCollection('已有文件夹');
      await state.refresh();
      await pumpApp(tester, size: const Size(420, 900));

      // 建文件夹的入口从筛选胶囊里挪到了这个固定图标（它不进滚动区）
      expect(find.byTooltip('笔记文件夹'), findsOneWidget);
      await tester.tap(find.byTooltip('笔记文件夹'));
      await tester.pumpAndSettle();

      expect(find.text('文件夹管理'), findsOneWidget);
      expect(find.text('已有文件夹'), findsOneWidget);

      // 那一页里能新建
      await tester.tap(find.byTooltip('新建文件夹'));
      await tester.pumpAndSettle();
      expect(find.text('新建文集'), findsOneWidget);
    });

    testWidgets('悬浮按钮新建后会直接进编辑器', (tester) async {
      await pumpApp(tester, size: const Size(420, 900));
      expect(state.overview?.noteCount, 0);

      await tester.tap(find.byIcon(Icons.edit_rounded));
      await tester.pumpAndSettle();

      expect(state.overview?.noteCount, 1);
      expect(find.byTooltip('加粗'), findsOneWidget);
    });

    testWidgets('搜索无结果显示对应空状态', (tester) async {
      state.repo.insertNote(title: '火车', content: '圣地巡礼', excerpt: '');
      await state.refresh();
      await pumpApp(tester, size: const Size(420, 900));

      state.setQuery('完全不存在的关键词');
      await tester.pumpAndSettle();

      expect(find.text('没有匹配的笔记'), findsOneWidget);
    });

    testWidgets('长按卡片弹出面板，可以删除', (tester) async {
      state.repo.insertNote(title: '待删除', content: '正文', excerpt: '');
      await state.refresh();
      await pumpApp(tester, size: const Size(420, 900));

      await tester.longPress(find.byType(NoteCard).first);
      await tester.pumpAndSettle();
      expect(find.text('复制全文'), findsOneWidget);

      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      expect(find.text('删除这篇笔记？'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '删除'));
      await tester.pumpAndSettle();

      expect(state.overview?.noteCount, 0);
    });

    testWidgets('确认框点取消不会删除', (tester) async {
      state.repo.insertNote(title: '别删我', content: '正文', excerpt: '');
      await state.refresh();
      await pumpApp(tester, size: const Size(420, 900));

      await tester.longPress(find.byType(NoteCard).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();

      expect(state.overview?.noteCount, 1);
    });

    testWidgets('鼠标悬停卡片浮出 ⋯ 按钮', (tester) async {
      state.repo.insertNote(title: '悬停', content: '正文', excerpt: '');
      await state.refresh();
      await pumpApp(tester, size: const Size(420, 900));

      expect(find.byIcon(Icons.more_horiz_rounded), findsNothing);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pumpAndSettle();

      await gesture.moveTo(tester.getCenter(find.byType(NoteCard).first));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.more_horiz_rounded), findsOneWidget);
    });
  });

  // ── 详情页 ──────────────────────────────────────────────────────────────

  group('详情页', () {
    testWidgets('可以通过 ⋯ 菜单删除', (tester) async {
      final id = state.repo.insertNote(
        title: '详情页里删掉',
        content: '正文内容',
        excerpt: '正文内容',
      );
      await state.refresh();
      await pumpDetail(tester, id);

      expect(find.text('详情页里删掉'), findsWidgets);

      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, '删除'));
      await tester.pumpAndSettle();

      expect(state.overview?.noteCount, 0);
    });

    testWidgets('点编辑会打开编辑器', (tester) async {
      final id = state.repo.insertNote(title: '去编辑', content: '原文', excerpt: '');
      await state.refresh();
      await pumpDetail(tester, id);

      await tester.tap(find.byTooltip('编辑'));
      await tester.pumpAndSettle();

      // 编辑器已经不再有"编辑/预览"两个模式，打开就是所见即所得
      expect(find.byTooltip('加粗'), findsOneWidget);
      expect(find.text('预览'), findsNothing);
    });
  });
}
