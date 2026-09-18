/// 写作趋势 / 累计增长的缩放平移。
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

  /// 缩放条里的文字。
  ///
  /// 必须限定在这个 key 里面找 —— 页面别处也有"全部"（范围筛选），
  /// 直接 find.text 会撞上。
  Finder inZoomBar(String text) => find.descendant(
    of: find.byKey(const Key('stats-zoom-bar')).first,
    matching: find.text(text),
  );

  testWidgets('默认 1×，此时平移滑块是禁用的', (tester) async {
    seed();
    await pumpStats(tester);

    // 两张图（趋势 + 累计）各一条缩放条
    expect(find.byKey(const Key('stats-zoom-bar')), findsNWidgets(2));
    expect(inZoomBar('1×'), findsOneWidget);
    expect(inZoomBar('全部'), findsOneWidget);

    final sliders = tester
        .widgetList<Slider>(find.byType(Slider))
        .where((s) => s.onChanged == null);
    expect(sliders, isNotEmpty, reason: '没放大时滑块应当置灰');
  });

  testWidgets('点放大倍率上升，再点缩小能回到 1×', (tester) async {
    seed();
    await pumpStats(tester);

    final plus = find.byIcon(Icons.add_rounded);
    expect(plus, findsWidgets);

    await tester.tap(plus.first);
    await tester.pumpAndSettle();
    expect(inZoomBar('2×'), findsOneWidget);
    // 两张图共用一套缩放状态，另一边不该还写着 1×
    expect(inZoomBar('1×'), findsNothing);

    await tester.tap(plus.first);
    await tester.pumpAndSettle();
    expect(inZoomBar('3×'), findsOneWidget);

    final minus = find.byIcon(Icons.remove_rounded);
    await tester.tap(minus.first);
    await tester.pumpAndSettle();
    await tester.tap(minus.first);
    await tester.pumpAndSettle();
    expect(inZoomBar('1×'), findsOneWidget);
    expect(inZoomBar('全部'), findsOneWidget);
  });

  testWidgets('放大后能看出是哪一段，且滑块可拖动', (tester) async {
    seed();
    await pumpStats(tester);

    await tester.tap(find.byIcon(Icons.add_rounded).first);
    await tester.pumpAndSettle();

    // 「全部」被具体的时段取代了 —— 用户得知道自己在看哪一段
    expect(inZoomBar('全部'), findsNothing);
    final range = tester.widget<Text>(
      find
          .descendant(
            of: find.byKey(const Key('stats-zoom-bar')).first,
            matching: find.byType(Text),
          )
          .last,
    );
    expect(range.data, contains(' – '));

    expect(
      tester.widgetList<Slider>(find.byType(Slider)).every(
        (s) => s.onChanged != null,
      ),
      isTrue,
      reason: '放大之后滑块要能拖',
    );
  });

  testWidgets('缩回 1× 后窗口回到开头（不会停在上次平移的位置）', (tester) async {
    seed();
    await pumpStats(tester);

    await tester.tap(find.byIcon(Icons.add_rounded).first);
    await tester.pumpAndSettle();

    // 拖到中段
    final slider = find.byType(Slider).first;
    await tester.drag(slider, const Offset(120, 0));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.remove_rounded).first);
    await tester.pumpAndSettle();
    expect(inZoomBar('1×'), findsOneWidget);

    // 再放大一次，起点应当是 0 而不是刚才拖到的位置
    await tester.tap(find.byIcon(Icons.add_rounded).first);
    await tester.pumpAndSettle();
    expect(tester.widget<Slider>(find.byType(Slider).first).value, 0);
  });

  testWidgets('倍率到顶后加号不再生效（不越界）', (tester) async {
    seed();
    await pumpStats(tester);

    final plus = find.byIcon(Icons.add_rounded).first;
    for (var i = 0; i < 10; i++) {
      await tester.tap(plus);
      await tester.pumpAndSettle();
    }
    // 最高档是 12×，点再多也不会变成 13×
    expect(inZoomBar('12×'), findsOneWidget);
  });

  testWidgets('缩放时图表本身不报错（切片长度和轴一致）', (tester) async {
    seed();
    await pumpStats(tester);

    for (var i = 0; i < 4; i++) {
      await tester.tap(find.byIcon(Icons.add_rounded).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(TrendChart), findsWidgets);
    }
  });

  testWidgets('窄屏（手机宽度）下缩放条不溢出，滑块仍然拖得动', (tester) async {
    seed();
    // 360 逻辑像素 —— 主流安卓机的宽度
    await pumpStats(tester, size: const Size(360, 4000));

    expect(tester.takeException(), isNull, reason: '缩放条不该溢出');

    await tester.tap(find.byIcon(Icons.add_rounded).first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final slider = tester.getSize(find.byType(Slider).first);
    expect(
      slider.width,
      greaterThan(48),
      reason: '滑块被时段文字挤扁了就拖不动了',
    );
  });
}
