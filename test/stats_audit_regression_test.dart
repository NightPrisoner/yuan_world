import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/field_repository.dart';
import 'package:yuan_world/features/stats/stats_page.dart';
import 'package:yuan_world/features/stats/field_stats_card.dart';
import 'package:yuan_world/features/stats/stats_charts.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/repositories/note_repository.dart'
    hide TrendPoint;
import 'package:yuan_world/data/repositories/stats_repository.dart';

void main() {
  late AppDatabase db;
  late NoteRepository repo;
  late StatsRepository stats;
  setUp(() {
    db = AppDatabase.inMemory();
    repo = NoteRepository(db);
    stats = StatsRepository(db);
  });
  tearDown(() => db.close());
  test('清除文件夹筛选同时清除单选与多选', () {
    const query = StatsQuery(collectionId: 1, collectionIds: [1, 2]);
    final cleared = query.copyWith(clearCollection: true);
    expect(cleared.collectionId, isNull);
    expect(cleared.collectionIds, isEmpty);
    expect(
      query.copyWith(clearCollection: true, collectionIds: [3]).collectionIds,
      [3],
    );
  });
  test('未分类比較的图片不混入视频或历史媒体总数', () {
    repo.insertNote(
      title: '媒体',
      content: '![](a.png)\n![](b.mp4)',
      excerpt: '',
      imageCount: 2,
    );
    expect(stats.compareCollections().single.images, 1);
  });
  test('夏令时切换附近的每日桶按日历日期推进', () {
    final query = StatsQuery(
      from: DateTime(2026, 3, 27),
      to: DateTime(2026, 3, 31),
    );
    final daily = stats.trend(query: query, granularity: StatsGranularity.day);
    expect(daily.map((p) => p.bucket), [
      '2026-03-27',
      '2026-03-28',
      '2026-03-29',
      '2026-03-30',
      '2026-03-31',
    ]);
  });
  test('自动参数分布也排除回收站与归档', () {
    final fields = FieldRepository(db);
    final field = fields.createField(name: '自动年', autoSource: 'created')!;
    for (var i = 0; i < 3; i++) {
      final id = repo.insertNote(title: '$i', content: '', excerpt: '');
      if (i == 1) {
        repo.deleteNote(id);
      }
      if (i == 2) {
        db.db.execute('UPDATE notes SET is_archived = 1 WHERE id = ?', [id]);
      }
    }
    expect(
      fields.valueDistribution(field).fold<int>(0, (sum, p) => sum + p.count),
      1,
    );
  });
  test('长序列绘图压缩保留合计，累计保留末值', () {
    final points = List.generate(
      1000,
      (i) => TrendPoint(
        bucket: '$i',
        label: '$i',
        notes: 1,
        chars: 2,
        words: 3,
        images: 4,
        videos: 5,
      ),
    );
    final compact = compactTrendPoints(points, 2);
    expect(compact.length, 500);
    expect(compact.fold<int>(0, (s, p) => s + p.notes), 1000);
    expect(compact.fold<int>(0, (s, p) => s + p.videos), 5000);
    final cumulative = compactTrendPoints(points, 2, cumulative: true);
    expect(cumulative.last.chars, points.last.chars);
  });
  void add(DateTime date) => repo.insertNote(
    title: '探针',
    content: '内容',
    excerpt: '',
    publishedAt: date,
    charCount: 2,
  );

  test('空库选择只有起点的近期范围应正常返回', () {
    expect(
      () => stats.trend(query: StatsQuery(from: DateTime(2026, 8, 1))),
      returnsNormally,
    );
  });
  test('周趋势合计应等于概览', () {
    add(DateTime(2026, 10, 14, 12));
    final weekly = stats.trend(granularity: StatsGranularity.week);
    expect(
      weekly.fold<int>(0, (sum, p) => sum + p.notes),
      stats.overview().noteCount,
    );
  });
  test('跨年同一周只计一个桶，周日和下周一分开', () {
    for (final date in [
      DateTime(2025, 12, 29, 12),
      DateTime(2026, 1, 1, 12),
      DateTime(2026, 1, 4, 12),
      DateTime(2026, 1, 5, 12),
    ]) {
      add(date);
    }
    final weekly = stats.trend(granularity: StatsGranularity.week);
    expect(weekly.map((p) => p.bucket), ['2025-12-29', '2026-01-05']);
    expect(weekly.map((p) => p.notes), [3, 1]);
    expect(weekly.first.label, '2026年1周');
  });
  test('超过260周仍保留最新数据与累计总数', () {
    add(DateTime(2010, 1, 1));
    add(DateTime(2026, 10, 14));
    final query = StatsQuery(
      from: DateTime(2010, 1, 1),
      to: DateTime(2026, 10, 14),
    );
    expect(
      stats
          .trend(query: query, granularity: StatsGranularity.week)
          .fold<int>(0, (s, p) => s + p.notes),
      2,
    );
    expect(
      stats
          .cumulative(query: query, granularity: StatsGranularity.day)
          .last
          .notes,
      2,
    );
  });
  test('图片视频按正文区分，累计词数和媒体不会固定为0', () {
    for (final date in [DateTime(2026, 1, 1), DateTime(2026, 2, 1)]) {
      repo.insertNote(
        title: '图文',
        content: '![](a.png)\n![视频](b.mp4)\n![动图](c.gif "说明")',
        excerpt: '',
        publishedAt: date,
        charCount: 4,
        wordCount: 3,
        imageCount: 3,
      );
    }
    final overview = stats.overview();
    expect(overview.imageCount, 4);
    expect(overview.videoCount, 2);
    final trend = stats.trend();
    expect(trend.fold<int>(0, (s, p) => s + p.images), 4);
    expect(trend.fold<int>(0, (s, p) => s + p.videos), 2);
    final last = stats.cumulative().last;
    expect((last.words, last.images, last.videos), (6, 4, 2));
  });
  test('单文件夹筛选的比较与文集数一致且不混入未分类', () {
    final a = repo.createCollection('甲')!;
    repo.createCollection('乙');
    repo.insertNote(title: '甲', content: '', excerpt: '', collectionId: a);
    repo.insertNote(title: '散', content: '', excerpt: '');
    final query = StatsQuery(collectionId: a);
    expect(stats.overview(query: query).collectionCount, 1);
    expect(stats.compareCollections(query: query).map((p) => p.id), [a]);
  });
  test('参数统计同时遵守时间文件夹隐私和归档筛选', () {
    final fields = FieldRepository(db);
    final number = fields.createField(name: '分数', kind: 'number')!;
    final a = repo.createCollection('甲')!;
    final b = repo.createCollection('乙')!;
    for (var i = 0; i < 5; i++) {
      final id = repo.insertNote(
        title: '$i',
        content: '',
        excerpt: '',
        collectionId: i == 1 ? b : a,
        publishedAt: DateTime(i == 2 ? 2020 : 2026, 10, 1),
      );
      fields.setValue(id, number, '10');
      if (i == 3) {
        db.db.execute('UPDATE notes SET is_archived = 1 WHERE id = ?', [id]);
      }
      if (i == 4) {
        db.db.execute('UPDATE notes SET is_hidden = 1 WHERE id = ?', [id]);
      }
    }
    final query = StatsQuery(from: DateTime(2026, 1, 1), collectionId: a);
    expect(fields.valueDistribution(number, query: query), [
      (value: '10', count: 1),
    ]);
    expect(
      fields
          .numericSummary(query: query)
          .singleWhere((r) => r.def.id == number)
          .sum,
      10,
    );
    expect(
      fields.valueDistribution(number, query: query.copyWith(hiddenOnly: true)),
      [(value: '10', count: 1)],
    );
  });
  test('多于400天的范围不应漏掉后面的笔记', () {
    add(DateTime(2024, 1, 1, 12));
    add(DateTime(2026, 10, 14, 12));
    final daily = stats.trend(granularity: StatsGranularity.day);
    expect(
      daily.fold<int>(0, (sum, p) => sum + p.notes),
      stats.overview().noteCount,
    );
  });
  test('未来发布日期不应被算作当前连续发布', () {
    add(DateTime.now().add(const Duration(days: 20)));
    expect(stats.streak().current, 0);
  });
  test('不含子文件夹时对比应和概览一致', () {
    final parent = repo.createCollection('父')!;
    final child = repo.createCollection('子', parentId: parent)!;
    repo.insertNote(
      title: '子笔记',
      content: '内容',
      excerpt: '',
      collectionId: child,
    );
    final query = StatsQuery(
      collectionIds: [parent],
      includeDescendants: false,
    );
    expect(
      stats.compareCollections(query: query).single.notes,
      stats.overview(query: query).noteCount,
    );
  });
  test('参数分布应排除回收站和归档笔记', () {
    final fields = FieldRepository(db);
    final field = fields.createField(name: '测试参数')!;
    final id = repo.insertNote(title: '删除的', content: '内容', excerpt: '');
    fields.setValue(id, field, '值');
    repo.deleteNote(id);
    expect(fields.valueDistribution(field), isEmpty);
  });
  testWidgets('统计页保留期间数据刷新应更新概览', (tester) async {
    add(DateTime(2026, 10, 14, 12));
    final state = AppState(db, repo, ImportService(db, repo));
    await state.init();
    tester.view.physicalSize = const Size(1300, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: state,
        child: MaterialApp(theme: AppTheme.light(), home: const StatsPage()),
      ),
    );
    await tester.pumpAndSettle();
    add(DateTime(2026, 10, 14, 13));
    await state.refresh();
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('ov-notes')),
        matching: find.text('2'),
      ),
      findsOneWidget,
    );
    add(DateTime(2026, 10, 14, 14));
    state.refreshListOnly(dataChanged: true);
    await tester.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const Key('ov-notes')),
        matching: find.text('3'),
      ),
      findsOneWidget,
    );
  });
  testWidgets('保留中的参数卡随筛选、隐私与数据版本刷新', (tester) async {
    final state = AppState(db, repo, ImportService(db, repo));
    await state.init();
    final field = state.fields.createField(name: '测试字段')!;
    final a = repo.createCollection('甲')!;
    for (var i = 0; i < 2; i++) {
      final id = repo.insertNote(
        title: '$i',
        content: '',
        excerpt: '',
        collectionId: a,
        publishedAt: DateTime(i == 0 ? 2026 : 2020, 1, 1),
      );
      state.fields.setValue(id, field, i == 0 ? '新值' : '旧值');
    }
    final privateId = repo.insertNote(
      title: '隐私',
      content: '',
      excerpt: '',
      collectionId: a,
      publishedAt: DateTime(2026, 1, 1),
    );
    db.db.execute('UPDATE notes SET is_hidden = 1 WHERE id = ?', [privateId]);
    state.fields.setValue(privateId, field, '私密值');
    Future<void> pump(StatsQuery query, {int revision = 0}) async {
      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: FieldStatsCard(query: query, revision: revision),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    final all = StatsQuery(collectionId: a);
    await pump(all);
    await tester.tap(find.text('测试字段'));
    await tester.pumpAndSettle();
    expect(find.text('取值分布 · 共 2 篇'), findsOneWidget);
    await pump(all.copyWith(from: DateTime(2026, 1, 1)));
    expect(find.text('取值分布 · 共 1 篇'), findsOneWidget);
    final hidden = all.copyWith(hiddenOnly: true);
    await pump(hidden);
    expect(find.text('私密值'), findsWidgets);
    state.fields.setValue(privateId, field, '改后私密值');
    await pump(hidden, revision: 1);
    expect(find.text('改后私密值'), findsWidgets);
    expect(find.text('新值'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
