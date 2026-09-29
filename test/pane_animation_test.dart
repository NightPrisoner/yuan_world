/// 三栏的展开/收起动画。
///
/// 用户的原话：
///   「点开笔记出现第三栏时应该有个动画从右边过来，关闭的时候再到右边去。
///     包括最左边那栏收起侧栏展开侧栏应该有个动画」
///
/// 这里钉的是"真的有动画"，而不只是"最终位置对"：
///   · 动画途中宽度必须落在**起点和终点之间**（说明是补间，不是瞬变）
///   · 收尾必须精确落在终点（否则会留一条缝或挤爆布局）
///   · 关闭动画结束后正文栏要被**拆掉**，不能留一个 0 宽的编辑器在树里
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

const Key detailPaneKey = ValueKey<String>('detail-pane');
const Key listColumnKey = ValueKey<String>('list-column');

/// 正文栏当前宽度。不存在时返回 null。
double? paneWidth(WidgetTester tester) {
  final f = find.byKey(detailPaneKey);
  if (f.evaluate().isEmpty) return null;
  return tester.getSize(f).width;
}

/// 列表栏那一格的宽度（只有"列表在场"时才有这一格）。
double? listColumnWidth(WidgetTester tester) {
  final f = find.byKey(listColumnKey);
  if (f.evaluate().isEmpty) return null;
  return tester.getSize(f).width;
}

void main() {
  late AppDatabase db;
  late AppState state;

  setUp(() async {
    db = AppDatabase.inMemory();
    final repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
    for (var i = 0; i < 3; i++) {
      repo.insertNote(
        title: '笔记 $i',
        content: '正文 $i',
        excerpt: '正文',
        publishedAt: DateTime.now().subtract(Duration(days: i)),
      );
    }
  });

  tearDown(() => db.close());

  Future<void> pumpWide(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(theme: AppTheme.light(), home: const HomeShell()),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('第三栏（正文）', () {
    testWidgets('冷启动是两栏：正文栏不在树里', (tester) async {
      await state.refresh();
      await pumpWide(tester);
      expect(paneWidth(tester), isNull, reason: '默认收起时不该留一个 0 宽的正文栏');
    });

    testWidgets('点开笔记时宽度是补间过去的，不是瞬间到位', (tester) async {
      await state.refresh();
      await pumpWide(tester);

      await tester.tap(find.text('笔记 0').first);
      // 只推一小段时间：动画应该还在路上
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));

      final mid = paneWidth(tester);
      expect(mid, isNotNull);
      expect(mid!, greaterThan(0), reason: '动画途中应该已经露出来了');

      await tester.pumpAndSettle();
      final settled = paneWidth(tester);
      expect(settled, isNotNull);
      expect(
        mid,
        lessThan(settled!),
        reason: '途中宽度必须小于最终宽度 —— 说明是从右边长出来的，而不是瞬间出现',
      );
    });

    testWidgets('收起时先滑出去，动画结束才从树里拆掉', (tester) async {
      await state.refresh();
      await pumpWide(tester);

      await tester.tap(find.text('笔记 0').first);
      await tester.pumpAndSettle();
      final full = paneWidth(tester)!;

      await tester.tap(find.byTooltip('收起正文栏'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));

      final mid = paneWidth(tester);
      expect(mid, isNotNull, reason: '还在滑出去，不能立刻消失');
      expect(mid!, lessThan(full), reason: '应该正在变窄');
      expect(mid, greaterThan(0));

      await tester.pumpAndSettle();
      expect(paneWidth(tester), isNull, reason: '动画结束后要拆掉');
    });

    testWidgets('全屏编辑时正文栏占满整窗（不会被挤窄或推出屏幕外）', (tester) async {
      await state.refresh();
      await pumpWide(tester);

      await tester.tap(find.text('笔记 0').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('编辑'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('占满页面'));
      await tester.pumpAndSettle();

      expect(paneWidth(tester), 1400, reason: '全屏时列表栏不在场，正文栏应占满，否则按钮会被推到屏幕外');
      // 按钮必须仍然点得到
      expect(find.byTooltip('退出占满页面'), findsOneWidget);
      final at = tester.getCenter(find.byTooltip('退出占满页面'));
      expect(at.dx, greaterThan(0));
      expect(at.dx, lessThan(1400));
    });
  });

  group('「占满页面」进出方向', () {
    testWidgets('退出占满：列表栏从左边长回来，正文原地缩回右边', (tester) async {
      await state.refresh();
      await pumpWide(tester);

      await tester.tap(find.text('笔记 0').first);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('编辑'));
      await tester.pumpAndSettle();

      final twoCol = listColumnWidth(tester);
      final twoColPane = paneWidth(tester);
      expect(twoCol, isNotNull, reason: '编辑态也是三栏，列表栏在场');
      expect(twoColPane, isNotNull);

      await tester.tap(find.byTooltip('占满页面'));
      await tester.pumpAndSettle();
      expect(listColumnWidth(tester), isNull, reason: '占满时列表栏让位给正文');
      expect(paneWidth(tester), 1400);

      // 退出占满：抓中途
      await tester.tap(find.byTooltip('退出占满页面'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));

      final listMid = listColumnWidth(tester);
      final paneMid = paneWidth(tester);
      expect(listMid, isNotNull, reason: '退出时列表栏要滑回来，不能等结束才插进树里');
      expect(listMid!, greaterThan(0));
      expect(
        listMid,
        lessThan(twoCol!),
        reason:
            '列表栏只能从左边一点一点长回来 —— '
            '一上来就铺满整块宽度，正是用户看到的"退出时像从右边冒出来"',
      );
      expect(paneMid, isNotNull);
      expect(paneMid!, lessThan(1400), reason: '正文栏要跟着往右缩，而不是被列表栏盖住');
      expect(paneMid, greaterThan(0));

      await tester.pumpAndSettle();
      expect(listColumnWidth(tester)!, closeTo(twoCol, 0.5));
      expect(
        paneWidth(tester)!,
        closeTo(twoColPane!, 0.5),
        reason: '收尾要精确回到三栏宽度，不能留缝',
      );
    });
  });

  group('最左边那栏（导航）', () {
    testWidgets('收起侧栏有宽度动画，且收起后只留图标', (tester) async {
      await state.refresh();
      await pumpWide(tester);

      final nav = find.byType(HomeShell);
      expect(tester.getSize(nav).width, 1400);

      // 收起：动画途中导航项还在（宽度在补间，不是等结束才换内容）
      await tester.tap(find.text('收起侧栏'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      expect(find.text('收起侧栏'), findsWidgets, reason: '动画途中面板还没消失，标签应该还在');

      await tester.pumpAndSettle();
      expect(find.byTooltip('展开侧栏'), findsOneWidget);
      // 收起态只留图标列：导航文字标签不该再出现
      expect(find.text('未分类'), findsNothing);

      // 展开回去
      await tester.tap(find.byTooltip('展开侧栏'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      expect(find.text('未分类'), findsOneWidget, reason: '展开动画途中导航项就该在了');
      await tester.pumpAndSettle();
      expect(find.text('未分类'), findsOneWidget);
    });
  });

  group('分栏切换的滑入方向', () {
    /// 某个分区页当前横向偏移（占自身宽度的比例）。正 = 还在右边（从右边进来）。
    double? sectionOffset(WidgetTester tester, String name) {
      final page = find.byKey(ValueKey<String>('section-$name'));
      if (page.evaluate().isEmpty) return null;
      final slide = find.ancestor(
        of: page,
        matching: find.byType(SlideTransition),
      );
      if (slide.evaluate().isEmpty) return null;
      return tester.widget<SlideTransition>(slide.first).position.value.dx;
    }

    testWidgets('往后翻从右边进、往回翻从左边进', (tester) async {
      await state.refresh();
      await pumpWide(tester);

      // 待办 → 统计：往后翻，统计页该从右边滑进来
      await tester.tap(find.text('待办').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('统计').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(sectionOffset(tester, 'stats'), isNotNull);
      expect(
        sectionOffset(tester, 'stats')!,
        greaterThan(0),
        reason: '往后翻，新页该从右边进来',
      );
      await tester.pumpAndSettle();

      // 统计 → 待办：往回翻，待办页该从左边滑进来
      await tester.tap(find.text('待办').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(sectionOffset(tester, 'todos'), isNotNull);
      expect(
        sectionOffset(tester, 'todos')!,
        lessThan(0),
        reason: '往回翻，新页该从左边进来（原来不管往哪翻都从右边冒出来）',
      );
      await tester.pumpAndSettle();
    });
  });
}
