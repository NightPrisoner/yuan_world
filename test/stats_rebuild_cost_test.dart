/// 统计页的**重建代价**。
///
/// 这里不测耗时（机器一忙就飘），测的是**谁被重建了**：
/// 改一个模块的数据，其余模块的 widget 实例必须是同一个对象。
/// Flutter 的 `Element.updateChild` 发现新旧 widget 相同就直接跳过
/// 整棵子树的 build —— 实例相同就等于"这次没有重建它"。
///
/// 这条防的是真实发生过的事：换篇幅分档会让整页三千来个 widget 重造一遍
/// （三张 fl_chart 是大头），实测 300ms 左右，用户看到的就是卡一下。
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

  void seed() {
    final now = DateTime.now();
    for (var i = 0; i < 60; i++) {
      state.repo.insertNote(
        title: '第 $i 篇 深夜写作记录',
        content: 'x' * (400 + i * 200),
        excerpt: '深夜写作的时候最有感觉，写的是关于生活的观察',
        publishedAt: DateTime(now.year, now.month - (i % 30), 1 + (i % 27)),
        charCount: 400 + i * 200,
        wordCount: 100 + i * 60,
        imageCount: i % 3,
        tags: i % 2 == 0 ? <String>['随笔'] : <String>['生活'],
      );
    }
  }

  Future<void> pumpStats(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1300, 9000);
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

  testWidgets('换篇幅分档：只有那张直方图被重建，其余模块原样复用', (tester) async {
    seed();
    await pumpStats(tester);

    // 换之前先记下几个重头的 widget 实例
    final trendBefore = tester.widget<TrendChart>(find.byType(TrendChart).first);
    final histBefore = tester.widget<LengthHistogram>(
      find.byType(LengthHistogram),
    );
    final heatBefore = tester.widget<DensityHeatmap>(
      find.byType(DensityHeatmap),
    );

    await tester.tap(find.text('标准分档').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('细分档').last);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);

    // 直方图该换（分档真的变了）
    final histAfter = tester.widget<LengthHistogram>(
      find.byType(LengthHistogram),
    );
    expect(
      histAfter.buckets.length,
      isNot(histBefore.buckets.length),
      reason: '细分档的档位数和标准分档不一样',
    );

    // 其余模块**必须还是同一个实例** —— 没变的东西不该重建
    expect(
      identical(
        trendBefore,
        tester.widget<TrendChart>(find.byType(TrendChart).first),
      ),
      isTrue,
      reason: '换分档不该重建趋势图',
    );
    expect(
      identical(
        heatBefore,
        tester.widget<DensityHeatmap>(find.byType(DensityHeatmap)),
      ),
      isTrue,
      reason: '换分档不该重建热力图',
    );
  });

  testWidgets('改时间范围：数据变了，所有模块都该重建（不能拿旧图糊弄）', (tester) async {
    seed();
    await pumpStats(tester);

    final trendBefore = tester.widget<TrendChart>(find.byType(TrendChart).first);

    await tester.tap(find.byIcon(Icons.schedule_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('近 3 个月').last);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      identical(
        trendBefore,
        tester.widget<TrendChart>(find.byType(TrendChart).first),
      ),
      isFalse,
      reason: '换了范围还复用旧图 = 显示的是旧数据',
    );
  });

  testWidgets('改文件夹筛选：概览的数值当场变（缓存不能挡刷新）', (tester) async {
    final a = await state.createCollection('甲');
    final now = DateTime.now();
    for (var i = 0; i < 4; i++) {
      state.repo.insertNote(
        title: '甲 $i',
        content: 'x' * 500,
        excerpt: 'x',
        publishedAt: DateTime(now.year, now.month, 2),
        collectionId: a,
        charCount: 500,
        wordCount: 200,
      );
      state.repo.insertNote(
        title: '散 $i',
        content: 'x' * 500,
        excerpt: 'x',
        publishedAt: DateTime(now.year, now.month, 3),
        charCount: 500,
        wordCount: 200,
      );
    }
    await pumpStats(tester);

    String notes() {
      final texts = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byKey(const Key('ov-notes')),
              matching: find.byType(Text),
            ),
          )
          .map((t) => t.data)
          .whereType<String>()
          .toList();
      return texts.length < 2 ? '' : texts[1];
    }

    expect(notes(), '8');

    await tester.tap(find.text('全部文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部（不筛选）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('甲').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    // 模块缓存必须被 _reload 清掉，否则概览会挂着 8
    expect(notes(), '4');
  });

  testWidgets('切换显示选项会真的换掉图表（缓存键漏了的话这条会红）', (tester) async {
    seed();
    await pumpStats(tester);

    final before = tester.widget<TrendChart>(find.byType(TrendChart).first);
    expect(before.showDots, isTrue);

    // 显示选项 → 显示数据点
    await tester.tap(find.byIcon(Icons.tune_rounded).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('显示数据点').last);
    await tester.pumpAndSettle();

    final after = tester.widget<TrendChart>(find.byType(TrendChart).first);
    expect(after.showDots, isFalse, reason: '显示选项没生效 = 缓存键漏了这个开关');
  });
}
