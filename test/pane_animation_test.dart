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

/// 正文栏当前宽度。不存在时返回 null。
double? paneWidth(WidgetTester tester) {
  final f = find.byKey(detailPaneKey);
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
      expect(mid, lessThan(settled!),
          reason: '途中宽度必须小于最终宽度 —— 说明是从右边长出来的，而不是瞬间出现');
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

      expect(paneWidth(tester), 1400,
          reason: '全屏时列表栏不在场，正文栏应占满，否则按钮会被推到屏幕外');
      // 按钮必须仍然点得到
      expect(find.byTooltip('退出占满页面'), findsOneWidget);
      final at = tester.getCenter(find.byTooltip('退出占满页面'));
      expect(at.dx, greaterThan(0));
      expect(at.dx, lessThan(1400));
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
      expect(find.text('收起侧栏'), findsWidgets,
          reason: '动画途中面板还没消失，标签应该还在');

      await tester.pumpAndSettle();
      expect(find.byTooltip('展开侧栏'), findsOneWidget);
      // 收起态只留图标列：导航文字标签不该再出现
      expect(find.text('未分类'), findsNothing);

      // 展开回去
      await tester.tap(find.byTooltip('展开侧栏'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      expect(find.text('未分类'), findsOneWidget,
          reason: '展开动画途中导航项就该在了');
      await tester.pumpAndSettle();
      expect(find.text('未分类'), findsOneWidget);
    });
  });
}
