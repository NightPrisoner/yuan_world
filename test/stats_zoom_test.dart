/// 写作趋势 / 累计增长的**横轴**缩放平移。
///
/// 这里是**交互契约**的测试：按钮点了倍率要变、窗口要真的变窄、
/// 没放大时滑块要是禁用的。数值算得对不对由 trend_window_test.dart 管。
///
/// 纵轴已经取消自定义（全自动），所以这里不再有 y 轴那一行 ——
/// 最后一条专门盯着"纵轴不该再出现任何调节控件"。
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

  /// 第一张趋势图的横轴行。
  Finder row() => find.byKey(const Key('stats-zoom-x')).first;

  Finder inRow(String text) =>
      find.descendant(of: row(), matching: find.text(text));

  Finder rowBtn(IconData icon) =>
      find.descendant(of: row(), matching: find.byIcon(icon));

  Finder rowSlider() =>
      find.descendant(of: row(), matching: find.byType(Slider));

  testWidgets('默认 1×，此时平移滑块是禁用的', (tester) async {
    seed();
    await pumpStats(tester);

    // 趋势 + 累计两张图
    expect(find.byKey(const Key('stats-zoom-x')), findsNWidgets(2));
    expect(inRow('1×'), findsOneWidget);
    expect(inRow('全部'), findsOneWidget);
    expect(tester.widget<Slider>(rowSlider()).onChanged, isNull);
  });

  testWidgets('点放大倍率上升，再点缩小能回到 1×', (tester) async {
    seed();
    await pumpStats(tester);

    await tester.tap(rowBtn(Icons.add_rounded));
    await tester.pumpAndSettle();
    expect(inRow('2×'), findsOneWidget);
    // 两张图共用一套缩放状态
    expect(
      find.descendant(
        of: find.byKey(const Key('stats-zoom-x')).last,
        matching: find.text('2×'),
      ),
      findsOneWidget,
    );

    await tester.tap(rowBtn(Icons.add_rounded));
    await tester.pumpAndSettle();
    expect(inRow('3×'), findsOneWidget);

    await tester.tap(rowBtn(Icons.remove_rounded));
    await tester.pumpAndSettle();
    await tester.tap(rowBtn(Icons.remove_rounded));
    await tester.pumpAndSettle();
    expect(inRow('1×'), findsOneWidget);
    expect(inRow('全部'), findsOneWidget);
  });

  testWidgets('放大后能看出是哪一段，且滑块可拖动', (tester) async {
    seed();
    await pumpStats(tester);

    await tester.tap(rowBtn(Icons.add_rounded));
    await tester.pumpAndSettle();

    expect(inRow('全部'), findsNothing);
    final out = tester
        .widgetList<Text>(find.descendant(of: row(), matching: find.byType(Text)))
        .map((t) => t.data)
        .whereType<String>()
        .last;
    expect(out, contains(' – '));
    expect(tester.widget<Slider>(rowSlider()).onChanged, isNotNull);
  });

  testWidgets('缩回 1× 后窗口回到开头（不会停在上次平移的位置）', (tester) async {
    seed();
    await pumpStats(tester);

    await tester.tap(rowBtn(Icons.add_rounded));
    await tester.pumpAndSettle();
    await tester.drag(rowSlider(), const Offset(120, 0));
    await tester.pumpAndSettle();

    await tester.tap(rowBtn(Icons.remove_rounded));
    await tester.pumpAndSettle();
    expect(inRow('1×'), findsOneWidget);

    await tester.tap(rowBtn(Icons.add_rounded));
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(rowSlider()).value, 0);
  });

  testWidgets('倍率到顶后加号不再生效（不越界）', (tester) async {
    seed();
    await pumpStats(tester);

    for (var i = 0; i < 10; i++) {
      await tester.tap(rowBtn(Icons.add_rounded));
      await tester.pumpAndSettle();
    }
    expect(inRow('12×'), findsOneWidget);
  });

  testWidgets('缩放时图表本身不报错（切片长度和轴一致）', (tester) async {
    seed();
    await pumpStats(tester);

    for (var i = 0; i < 4; i++) {
      await tester.tap(rowBtn(Icons.add_rounded));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(TrendChart), findsWidgets);
    }
  });

  testWidgets('倍率会存进设置，存坏了退回 1×', (tester) async {
    seed();
    await pumpStats(tester);
    await tester.tap(rowBtn(Icons.add_rounded));
    await tester.pumpAndSettle();
    expect(state.repo.getSetting('stats.zoom'), '2.0');

    // 存一个不在档位里的值 —— 不该卡在那个倍率上。
    // **先 pump 一个别的页面**：直接重复 pumpWidget 会复用同一个 State，
    // initState/_restoreConfig 不会重跑，测的就不是恢复逻辑了。
    state.repo.setSetting('stats.zoom', '7.5');
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pumpAndSettle();
    await pumpStats(tester);
    expect(inRow('1×'), findsOneWidget);
  });

  testWidgets('**纵轴没有任何调节控件**（所有模块都取消了）', (tester) async {
    seed();
    await pumpStats(tester);

    // 旧的两行式缩放条里有 stats-zoom-y / stats-zoom-len-y
    expect(find.byKey(const Key('stats-zoom-y')), findsNothing);
    expect(find.byKey(const Key('stats-zoom-len-y')), findsNothing);
    expect(find.byKey(const Key('stats-length-zoom-bar')), findsNothing);
    // "纵轴"这个标签也不该再出现在任何缩放条里
    expect(find.text('纵轴'), findsNothing);
    // 显示选项里没有"Y 轴从 0 开始"
    expect(find.textContaining('Y 轴从 0'), findsNothing);
  });

  testWidgets('窄屏（手机宽度）下缩放条不溢出，滑块仍然拖得动', (tester) async {
    seed();
    await pumpStats(tester, size: const Size(360, 5000));

    expect(tester.takeException(), isNull, reason: '缩放条不该溢出');
    await tester.tap(rowBtn(Icons.add_rounded));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.getSize(rowSlider()).width,
      greaterThan(48),
      reason: '滑块被读数挤扁了就拖不动了',
    );
  });
}
