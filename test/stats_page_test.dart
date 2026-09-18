/// 统计页的测试。
///
/// 页面上模块很多，折叠区外的部分截图根本看不到，
/// 所以这里用一个超高视口让**所有模块一次性渲染出来**，
/// 任何模块报错都会直接让测试失败。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/stats/stats_charts.dart';
import 'package:yuan_world/features/stats/stats_page.dart';

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

  /// 造一批有发布时间的笔记，让每个图表都有内容可画。
  void seed() {
    final now = DateTime.now();
    final cid = state.repo.createCollection('随笔')!;
    for (var i = 0; i < 40; i++) {
      final at = DateTime(
        now.year,
        now.month - (i % 14),
        1 + (i % 27),
        6 + (i % 18), // 让 24 小时分布也有数据
      );
      state.repo.insertNote(
        title: '第 $i 篇 深夜写作记录',
        content: 'x' * (200 + i * 350),
        excerpt: '深夜写作的时候最有感觉，写的是关于生活的观察',
        publishedAt: at,
        collectionId: i % 3 == 0 ? cid : null,
        charCount: 200 + i * 350,
        wordCount: 100 + i * 100,
        imageCount: i % 4,
        tags: i % 2 == 0 ? <String>['随笔'] : <String>[],
      );
    }
  }

  /// 超高视口 = 所有模块同时渲染。
  Future<void> pumpStats(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1300, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const StatsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('全部模块默认都渲染出来', (tester) async {
    seed();
    await state.refresh();
    await pumpStats(tester);

    for (final title in <String>[
      '概览',
      '写作趋势',
      '累计增长',
      '文集分布',
      '发布热力图',
      '写作时段',
      '篇幅分布',
      '连续写作',
      '长文排行',
      '标签分布',
      '高频词',
      '参数统计',
    ]) {
      expect(find.text(title), findsWidgets, reason: '「$title」模块没渲染出来');
    }
  });

  testWidgets('概览显示核心指标', (tester) async {
    seed();
    await state.refresh();
    await pumpStats(tester);

    expect(find.text('笔记'), findsWidgets);
    expect(find.text('总字数'), findsWidgets);
    expect(find.text('图片'), findsWidgets);
    expect(find.text('活跃天数'), findsWidgets);
    // 40 篇
    expect(find.text('40'), findsWidgets);
  });

  testWidgets('写作时段能算出最常写作的小时', (tester) async {
    seed();
    await state.refresh();
    await pumpStats(tester);

    expect(find.textContaining('最常在'), findsOneWidget);
  });

  testWidgets('高频词会真的提取出重复词', (tester) async {
    seed();
    await state.refresh();
    await pumpStats(tester);

    // 种子里反复出现「深夜」「写作」
    expect(find.text('深夜'), findsWidgets);
  });

  testWidgets('热力图格子必须有实际尺寸，而且**不为每格建 widget**', (tester) async {
    // 这条挡的是两个真实 bug：
    //   1. 格子一度是没有子节点的 DecoratedBox，落在 Column 的松宽度约束里
    //      会缩成 0 宽 —— 整张热力图一片空白，而且不报任何错。
    //   2. 后来每格挂了一个 Tooltip：时间范围放开之后一屏七百多格
    //      ≈ 三千个 widget，滚到它卡一下、页面上任何一次 setState 也卡。
    //      现在整张图是一个 CustomPaint。
    final today = DateTime.now();
    final key = '${today.year}-'
        '${today.month.toString().padLeft(2, '0')}-'
        '${today.day.toString().padLeft(2, '0')}';

    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: DensityHeatmap(
              data: <String, int>{key: 5},
              // 两年的窗口 —— 以前这里会建出七百多个 Tooltip
              from: today.subtract(const Duration(days: 730)),
              to: today,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 没有 per-cell 的 Tooltip 了
    expect(find.byType(Tooltip), findsNothing);

    final paint = find.byType(CustomPaint);
    expect(paint, findsWidgets);
    final size = tester.getSize(paint.last);
    expect(size.width, greaterThan(100), reason: '网格宽度不能塌成 0');
    expect(size.height, greaterThan(4), reason: '网格高度不能塌成 0');

    // 整张图的 widget 数量**不随窗口长度增长**。
    // 这比钉一个具体数字结实：真正要防的是"每格一个 widget"，
    // 那种写法下两个月的窗口和两年的窗口差着几十倍。
    final widgetCount = find
        .descendant(
          of: find.byType(DensityHeatmap),
          matching: find.byWidgetPredicate((_) => true),
        )
        .evaluate()
        .length;
    expect(
      widgetCount,
      lessThan(80),
      reason: '每格一个 widget 的写法会让这个数字变成几千',
    );

    // 换成两个月的短窗口，widget 数量必须**一样**
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: DensityHeatmap(
              data: <String, int>{key: 5},
              from: today.subtract(const Duration(days: 60)),
              to: today,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final shortCount = find
        .descendant(
          of: find.byType(DensityHeatmap),
          matching: find.byWidgetPredicate((_) => true),
        )
        .evaluate()
        .length;
    expect(
      shortCount,
      widgetCount,
      reason: '窗口长短不该改变 widget 数量（格子是画出来的）',
    );
  });

  testWidgets('文件夹对比模块会列出各文件夹', (tester) async {
    seed();
    await state.refresh();
    await pumpStats(tester);

    expect(find.text('文件夹对比'), findsWidgets);
    // 种子里建了「随笔」，另有未分类，两个可比对象
    expect(find.text('随笔'), findsWidgets);
    expect(find.text('未分类'), findsWidgets);
    expect(find.text('点一行可以只看该文件夹的数据'), findsOneWidget);
  });

  testWidgets('按文件夹筛选会只统计该文件夹', (tester) async {
    seed();
    await state.refresh();
    await pumpStats(tester);

    // 文件夹筛选是**多选对话框**：点开 → 勾 → 确定
    await tester.tap(find.text('全部文件夹').first);
    await tester.pumpAndSettle();
    expect(find.text('选择文件夹'), findsOneWidget);

    await tester.tap(find.text('随笔').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // 存的是多选列表（复数键）
    expect(state.repo.getSetting('stats.collectionIds'), isNotEmpty);
    expect(find.textContaining('只看「随笔」'), findsOneWidget);
  });

  testWidgets('可以同时选多个文件夹做对比', (tester) async {
    seed();
    // seed 只建了一个文件夹，多选至少要有两个才测得出来
    final second = state.repo.createCollection('第二个')!;
    state.repo.insertNote(
      title: '第二篇',
      content: 'x',
      excerpt: 'x',
      collectionId: second,
    );
    await state.refresh();
    await pumpStats(tester);

    await tester.tap(find.text('全部文件夹').first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    final saved = state.repo.getSetting('stats.collectionIds') ?? '';
    expect(
      saved.split(',').where((s) => s.isNotEmpty).length,
      greaterThan(1),
      reason: '多选要能存下多个文件夹',
    );
  });

  testWidgets('时间范围有自定义入口', (tester) async {
    seed();
    await state.refresh();
    await pumpStats(tester);

    // 时间范围收在下拉里了，先点开
    await tester.tap(find.byIcon(Icons.schedule_rounded));
    await tester.pumpAndSettle();
    expect(find.text('自定义'), findsOneWidget);
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    // 弹出的自绘范围选择器（不是 Material 的全屏那个）
    expect(find.text('统计时间范围'), findsOneWidget);
    // 两种方式都在
    expect(find.text('选择'), findsOneWidget);
    expect(find.text('输入'), findsOneWidget);
  });

  testWidgets('自定义范围：月历能切月切年，也能手打日期', (tester) async {
    seed();
    await state.refresh();
    await pumpStats(tester);

    await tester.tap(find.byIcon(Icons.schedule_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();

    // 默认在月历模式，标题是「YYYY 年 M 月」
    expect(find.textContaining('年'), findsWidgets);
    // 切月、切年四个按钮都在（<> 和 《》）
    expect(find.byTooltip('上一月'), findsOneWidget);
    expect(find.byTooltip('下一月'), findsOneWidget);
    expect(find.byTooltip('上一年'), findsOneWidget);
    expect(find.byTooltip('下一年'), findsOneWidget);

    // 切到「输入」模式
    await tester.tap(find.text('输入'));
    await tester.pumpAndSettle();
    expect(find.text('开始'), findsOneWidget);
    expect(find.text('结束'), findsOneWidget);

    // 手打一个区间
    await tester.enterText(find.byType(TextField).at(0), '2023-06-01');
    await tester.enterText(find.byType(TextField).at(1), '2023-08-31');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(state.repo.getSetting('stats.from'), isNotNull);
    expect(find.textContaining('2023'), findsWidgets);
  });

  testWidgets('手打非法日期会被挡住，不会悄悄变成别的日子', (tester) async {
    seed();
    await state.refresh();
    await pumpStats(tester);

    await tester.tap(find.byIcon(Icons.schedule_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('输入'));
    await tester.pumpAndSettle();

    // 2023-02-30 这一天不存在，DateTime 会把它滚成 3 月 2 日 —— 必须挡住
    await tester.enterText(find.byType(TextField).at(0), '2023-02-30');
    await tester.enterText(find.byType(TextField).at(1), '2023-03-01');
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.textContaining('格式要像'), findsOneWidget);
    // 对话框没关，说明没有误提交
    expect(find.text('统计时间范围'), findsOneWidget);
  });

  testWidgets('隐藏的笔记不进入统计', (tester) async {
    seed();
    await state.refresh();

    final before = state.repo.overview().noteCount;
    // 藏一篇
    final target = state.repo.listNotes(const NoteFilter()).first;
    state.repo.setNoteHidden(target.id, true);
    await state.refresh();

    expect(state.repo.overview().noteCount, before - 1,
        reason: '隐私空间的内容不能被统计进去');
    // 列表里也看不到了
    expect(
      state.repo.listNotes(const NoteFilter()).any((n) => n.id == target.id),
      isFalse,
    );
  });

  // ── 模块排序 ────────────────────────────────────────────────────────────

  group('模块排序', () {
    testWidgets('每个模块卡片都有拖拽把手', (tester) async {
      seed();
      await state.refresh();
      await pumpStats(tester);

      // 14 个模块各一个把手（加了「存储与数据」之后）
      final handles = find.byIcon(Icons.drag_indicator_rounded);
      expect(handles.evaluate().length, 14);
    });

    test('排序只动可见模块，隐藏的留在原位', () {
      const full = <String>['a', 'b', 'c', 'd', 'e'];
      // b、d、e 可见；a、c 被隐藏
      const visible = <String>['b', 'd', 'e'];

      // 把 e 拖到最前
      final next = applyModuleReorder(
        full: full,
        visible: visible,
        oldIndex: 2,
        newIndex: 0,
      );

      // 真正有意义的是「可见子序列」的顺序 —— 隐藏模块根本不渲染
      expect(next.where(visible.contains).toList(), <String>['e', 'b', 'd']);
      // 隐藏模块保持原有相对顺序，不参与重排
      expect(
        next.where((id) => !visible.contains(id)).toList(),
        <String>['a', 'c'],
      );
    });

    test('排序边界不会崩', () {
      const full = <String>['a', 'b', 'c'];
      const visible = <String>['a', 'b', 'c'];

      expect(
        applyModuleReorder(full: full, visible: visible, oldIndex: 0, newIndex: 0),
        full,
      );
      // 越界直接原样返回，不能抛
      expect(
        applyModuleReorder(full: full, visible: visible, oldIndex: 9, newIndex: 0),
        full,
      );
      expect(
        applyModuleReorder(full: full, visible: visible, oldIndex: 0, newIndex: 9),
        full,
      );
    });

    test('把最后一个拖到最前', () {
      const full = <String>['a', 'b', 'c'];
      const visible = <String>['a', 'b', 'c'];
      expect(
        applyModuleReorder(full: full, visible: visible, oldIndex: 2, newIndex: 0),
        <String>['c', 'a', 'b'],
      );
    });

    test('把第一个拖到最后', () {
      const full = <String>['a', 'b', 'c'];
      const visible = <String>['a', 'b', 'c'];
      expect(
        applyModuleReorder(full: full, visible: visible, oldIndex: 0, newIndex: 3),
        <String>['b', 'c', 'a'],
      );
    });

    testWidgets('存的顺序会在下次打开时生效', (tester) async {
      seed();
      await state.refresh();

      // 把「高频词」提到最前
      state.repo.setSetting(
        'stats.order',
        '["keywords","overview","trend"]',
      );
      await pumpStats(tester);

      final yKeywords = tester.getTopLeft(find.text('高频词')).dy;
      final yOverview = tester.getTopLeft(find.text('概览')).dy;
      final yTrend = tester.getTopLeft(find.text('写作趋势')).dy;

      expect(yKeywords, lessThan(yOverview), reason: '高频词应该排到最前');
      expect(yOverview, lessThan(yTrend));
    });

    testWidgets('顺序里没提到的新模块会补到末尾，不会丢', (tester) async {
      seed();
      await state.refresh();

      // 只存了三个 id，其余模块应该仍然渲染出来
      state.repo.setSetting('stats.order', '["keywords","overview"]');
      await pumpStats(tester);

      for (final title in <String>['高频词', '概览', '写作趋势', '文件夹对比', '连续写作']) {
        expect(find.text(title), findsWidgets, reason: '「$title」不该被丢掉');
      }
    });

    testWidgets('把手确实挂在可拖拽列表上', (tester) async {
      seed();
      await state.refresh();
      await pumpStats(tester);

      // 光有图标不够，得确认它被包在 ReorderableDragStartListener 里，
      // 否则拖了没反应
      expect(find.byType(ReorderableDragStartListener), findsWidgets);
      expect(find.byType(SliverReorderableList), findsOneWidget);
    });

    testWidgets('顺序里已不存在的 id 会被忽略', (tester) async {
      seed();
      await state.refresh();

      state.repo.setSetting(
        'stats.order',
        '["早就删掉的模块","overview","trend"]',
      );
      await pumpStats(tester);

      expect(find.text('概览'), findsWidgets);
      expect(find.text('写作趋势'), findsWidgets);
    });
  });

  testWidgets('空数据时页面不崩，并给出引导', (tester) async {
    await pumpStats(tester);

    expect(find.text('还没有数据'), findsOneWidget);
    expect(find.text('概览'), findsWidgets);
    // 没有笔记时这些应该是空态而不是异常
    expect(find.text('还没有笔记'), findsWidgets);
  });

  testWidgets('可以把某个模块关掉，并写进设置', (tester) async {
    seed();
    await state.refresh();
    await pumpStats(tester);

    expect(find.text('写作趋势'), findsWidgets);

    await tester.tap(find.byTooltip('选择要显示的模块'));
    await tester.pumpAndSettle();

    expect(find.text('显示哪些模块'), findsOneWidget);

    // 按标题定位开关，而不是按下标 —— 模块会增删，下标一改测试就假失败。
    // 用靠前的模块，避免依赖列表滚动。
    final dialog = find.byType(Dialog);
    final row = find
        .ancestor(
          of: find.descendant(of: dialog, matching: find.text('写作趋势')),
          matching: find.byType(Row),
        )
        .first;
    await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(find.text('写作趋势'), findsNothing);
    // 偏好已经落库，下次打开还是这样
    expect(state.repo.getSetting('stats.hidden'), contains('trend'));
  });

  testWidgets('面板里的排序跟着页面上的顺序走', (tester) async {
    // 这条对应一个真实的反馈：在页面上把模块拖到前面之后，
    // 打开这个面板看到的却还是固定顺序（因为面板一直用 _kModules 渲染）。
    seed();
    await state.refresh();

    state.repo.setSetting('stats.order', '["keywords","overview","trend"]');
    await pumpStats(tester);

    await tester.tap(find.byTooltip('选择要显示的模块'));
    await tester.pumpAndSettle();

    final dialog = find.byType(Dialog);
    double yOf(String title) => tester
        .getTopLeft(find.descendant(of: dialog, matching: find.text(title)))
        .dy;

    expect(yOf('高频词'), lessThan(yOf('概览')),
        reason: '面板里也要按用户排的顺序显示');
    expect(yOf('概览'), lessThan(yOf('写作趋势')));
  });

  testWidgets('面板里的模块可以拖拽（把手挂在可拖拽列表上）', (tester) async {
    seed();
    await state.refresh();
    await pumpStats(tester);

    await tester.tap(find.byTooltip('选择要显示的模块'));
    await tester.pumpAndSettle();

    final dialog = find.byType(Dialog);
    expect(
      find.descendant(of: dialog, matching: find.byType(ReorderableListView)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: dialog,
        matching: find.byType(ReorderableDragStartListener),
      ),
      findsWidgets,
    );
  });

  testWidgets('切换时间范围会重新算趋势', (tester) async {
    seed();
    await state.refresh();
    await pumpStats(tester);

    // 默认「全部」——下拉按钮上写的就是当前范围
    expect(find.text('全部'), findsWidgets);

    await tester.tap(find.byIcon(Icons.schedule_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('近 3 个月').last);
    await tester.pumpAndSettle();

    expect(state.repo.getSetting('stats.range'), 'm3');
  });
}
