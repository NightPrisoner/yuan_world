/// 写作趋势 / 累计增长 / 篇幅分布的坐标轴缩放平移。
///
/// 这里是**交互契约**的测试：按钮点了倍率要变、窗口要真的变窄、
/// 没放大时滑块要是禁用的。数值算得对不对由 trend_window_test.dart 管。
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

  /// 铺 36 个月的笔记 —— 桶够多，缩放才有东西可看。
  void seed() {
    final now = DateTime.now();
    for (var i = 0; i < 36; i++) {
      final at = DateTime(now.year, now.month - i, 12);
      state.repo.insertNote(
        title: '第 $i 篇记录',
        content: 'x' * (300 + i * 400),
        excerpt: '深夜写作的时候最有感觉',
        publishedAt: at,
        charCount: 300 + i * 400,
        wordCount: 100 + i * 50,
        imageCount: i % 3,
      );
    }
  }

  Future<void> pumpStats(
    WidgetTester tester, {
    Size size = const Size(1300, 6000),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(theme: AppTheme.light(), home: const StatsPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 第一张趋势图的某一行（'x' 横轴 / 'y' 纵轴）。
  Finder row(String axis) => find.byKey(Key('stats-zoom-$axis')).first;

  Finder inRow(String axis, String text) =>
      find.descendant(of: row(axis), matching: find.text(text));

  Finder rowBtn(String axis, IconData icon) =>
      find.descendant(of: row(axis), matching: find.byIcon(icon));

  Finder rowSlider(String axis) =>
      find.descendant(of: row(axis), matching: find.byType(Slider));

  testWidgets('默认两轴都是 1×，滑块都禁用', (tester) async {
    seed();
    await pumpStats(tester);

    // 趋势 + 累计两张图，各两条轴
    expect(find.byKey(const Key('stats-zoom-x')), findsNWidgets(2));
    expect(find.byKey(const Key('stats-zoom-y')), findsNWidgets(2));
    expect(inRow('x', '1×'), findsOneWidget);
    expect(inRow('y', '1×'), findsOneWidget);
    expect(inRow('x', '全部'), findsOneWidget);

    expect(tester.widget<Slider>(rowSlider('x')).onChanged, isNull);
    expect(tester.widget<Slider>(rowSlider('y')).onChanged, isNull);
  });

  testWidgets('横轴放大只动横轴，纵轴还是 1×', (tester) async {
    seed();
    await pumpStats(tester);

    await tester.tap(rowBtn('x', Icons.add_rounded));
    await tester.pumpAndSettle();

    expect(inRow('x', '2×'), findsOneWidget);
    expect(inRow('y', '1×'), findsOneWidget, reason: '两轴必须各管各的');

    // 累计那张图共用状态
    expect(
      find.descendant(
        of: find.byKey(const Key('stats-zoom-x')).last,
        matching: find.text('2×'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('纵轴放大只动纵轴，横轴还是 1×', (tester) async {
    seed();
    await pumpStats(tester);

    await tester.tap(rowBtn('y', Icons.add_rounded));
    await tester.pumpAndSettle();

    expect(inRow('y', '2×'), findsOneWidget);
    expect(inRow('x', '1×'), findsOneWidget);
    expect(tester.widget<Slider>(rowSlider('y')).onChanged, isNotNull);
    expect(tester.widget<Slider>(rowSlider('x')).onChanged, isNull);
  });

  testWidgets('纵轴放大后读出的范围会跟着变窄', (tester) async {
    seed();
    await pumpStats(tester);

    String readout() {
      final texts = tester
          .widgetList<Text>(
            find.descendant(of: row('y'), matching: find.byType(Text)),
          )
          .map((t) => t.data)
          .whereType<String>()
          .toList();
      return texts.last;
    }

    final before = readout();
    await tester.tap(rowBtn('y', Icons.add_rounded));
    await tester.pumpAndSettle();
    final after = readout();

    expect(after, isNot(before), reason: '放大之后显示的范围必须变');
    // 两端都是「数字 – 数字」的格式
    expect(after, contains(' – '));
  });

  testWidgets('横轴放大后能看出是哪一段', (tester) async {
    seed();
    await pumpStats(tester);

    await tester.tap(rowBtn('x', Icons.add_rounded));
    await tester.pumpAndSettle();

    expect(inRow('x', '全部'), findsNothing);
    final out = tester
        .widgetList<Text>(
          find.descendant(of: row('x'), matching: find.byType(Text)),
        )
        .map((t) => t.data)
        .whereType<String>()
        .last;
    expect(out, contains(' – '));
  });

  testWidgets('缩回 1× 后两轴的窗口都回到开头', (tester) async {
    seed();
    await pumpStats(tester);

    await tester.tap(rowBtn('x', Icons.add_rounded));
    await tester.pumpAndSettle();
    await tester.tap(rowBtn('y', Icons.add_rounded));
    await tester.pumpAndSettle();

    await tester.drag(rowSlider('x'), const Offset(120, 0));
    await tester.pumpAndSettle();
    await tester.drag(rowSlider('y'), const Offset(120, 0));
    await tester.pumpAndSettle();

    await tester.tap(rowBtn('x', Icons.remove_rounded));
    await tester.pumpAndSettle();
    await tester.tap(rowBtn('y', Icons.remove_rounded));
    await tester.pumpAndSettle();
    expect(inRow('x', '1×'), findsOneWidget);
    expect(inRow('y', '1×'), findsOneWidget);

    // 再放大一次，起点应当是 0 而不是刚才拖到的位置
    await tester.tap(rowBtn('x', Icons.add_rounded));
    await tester.pumpAndSettle();
    await tester.tap(rowBtn('y', Icons.add_rounded));
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(rowSlider('x')).value, 0);
    expect(tester.widget<Slider>(rowSlider('y')).value, 0);
  });

  testWidgets('倍率到顶后加号不再生效（不越界）', (tester) async {
    seed();
    await pumpStats(tester);

    for (var i = 0; i < 10; i++) {
      await tester.tap(rowBtn('x', Icons.add_rounded));
      await tester.pumpAndSettle();
      await tester.tap(rowBtn('y', Icons.add_rounded));
      await tester.pumpAndSettle();
    }
    // 最高档是 12×，点再多也不会变成 13×
    expect(inRow('x', '12×'), findsOneWidget);
    expect(inRow('y', '12×'), findsOneWidget);
  });

  testWidgets('缩放时图表本身不报错（切片长度和轴一致）', (tester) async {
    seed();
    await pumpStats(tester);

    for (var i = 0; i < 4; i++) {
      await tester.tap(rowBtn('x', Icons.add_rounded));
      await tester.pumpAndSettle();
      await tester.tap(rowBtn('y', Icons.add_rounded));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(TrendChart), findsWidgets);
    }
  });

  testWidgets('放大倍率会存进设置，重开还在', (tester) async {
    seed();
    await pumpStats(tester);

    await tester.tap(rowBtn('x', Icons.add_rounded));
    await tester.pumpAndSettle();
    await tester.tap(rowBtn('y', Icons.add_rounded));
    await tester.pumpAndSettle();
    await tester.tap(rowBtn('y', Icons.add_rounded));
    await tester.pumpAndSettle();

    expect(state.repo.getSetting('stats.zoom'), '2.0');
    expect(state.repo.getSetting('stats.zoomY'), '3.0');
  });

  testWidgets('存坏的倍率会退回 1×，不会卡在奇怪的值上', (tester) async {
    seed();
    state.repo.setSetting('stats.zoom', '7.5');
    state.repo.setSetting('stats.zoomY', 'abc');
    await pumpStats(tester);

    expect(inRow('x', '1×'), findsOneWidget);
    expect(inRow('y', '1×'), findsOneWidget);
  });

  testWidgets('窄屏（手机宽度）下缩放条不溢出，滑块仍然拖得动', (tester) async {
    seed();
    // 360 逻辑像素 —— 主流安卓机的宽度
    await pumpStats(tester, size: const Size(360, 5000));

    expect(tester.takeException(), isNull, reason: '缩放条不该溢出');

    await tester.tap(rowBtn('x', Icons.add_rounded));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    for (final axis in <String>['x', 'y']) {
      final size = tester.getSize(rowSlider(axis));
      expect(
        size.width,
        greaterThan(40),
        reason: '$axis 轴的滑块被读数挤扁了就拖不动了',
      );
    }
  });
}
