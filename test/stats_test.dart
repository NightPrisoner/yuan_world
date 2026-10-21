/// 统计查询层的测试。
///
/// 这些聚合直接决定图表长什么样，算错了图不会报错、只会静静地骗人，
/// 所以每个查询都单独钉一遍。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/repositories/note_repository.dart' hide TrendPoint;
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

  int add(
    String title, {
    int chars = 100,
    DateTime? publishedAt,
    int? collectionId,
    List<String> tags = const <String>[],
    String excerpt = '',
    int images = 0,
  }) =>
      repo.insertNote(
        title: title,
        content: 'x' * chars,
        excerpt: excerpt.isEmpty ? 'x' * chars : excerpt,
        publishedAt: publishedAt,
        collectionId: collectionId,
        tags: tags,
        charCount: chars,
        wordCount: chars ~/ 2,
        imageCount: images,
      );

  // ── 趋势 ────────────────────────────────────────────────────────────────

  group('发布趋势', () {
    test('按月聚合，并且把没有笔记的月份补成 0', () {
      final now = DateTime.now();
      final thisMonth = DateTime(now.year, now.month, 1, 12);
      final twoAgo = DateTime(now.year, now.month - 2, 1, 12);

      add('本月一', chars: 100, publishedAt: thisMonth);
      add('本月二', chars: 200, publishedAt: thisMonth);
      add('前两月', chars: 50, publishedAt: twoAgo);

      final t = stats.trend(granularity: StatsGranularity.month);

      // 三个月都要在，中间那个是补出来的 0
      final keys = t.map((p) => p.bucket).toList();
      final mid = DateTime(now.year, now.month - 1, 1);
      final midKey = '${mid.year}-${mid.month.toString().padLeft(2, '0')}';
      expect(keys, contains(midKey));

      final midPoint = t.firstWhere((p) => p.bucket == midKey);
      expect(midPoint.notes, 0);
      expect(midPoint.chars, 0);

      // 排序必须是从早到晚
      expect(keys, orderedEquals(List<String>.from(keys)..sort()));

      final thisKey =
          '${now.year}-${now.month.toString().padLeft(2, '0')}';
      final p = t.firstWhere((x) => x.bucket == thisKey);
      expect(p.notes, 2);
      expect(p.chars, 300);
    });

    test('按天聚合', () {
      final today = DateTime.now();
      add('今天', publishedAt: today);
      add('昨天', publishedAt: today.subtract(const Duration(days: 1)));

      final t = stats.trend(
        query: StatsQuery(from: today.subtract(const Duration(days: 90))),
        granularity: StatsGranularity.day,
      );
      expect(t.length, greaterThanOrEqualTo(2));
      expect(t.map((p) => p.notes).reduce((a, b) => a + b), 2);
      // 按天时标签是 M/D
      expect(t.last.label, contains('/'));
    });

    test('按年聚合', () {
      add('去年', publishedAt: DateTime(DateTime.now().year - 1, 6, 1));
      add('今年', publishedAt: DateTime(DateTime.now().year, 6, 1));

      final t = stats.trend(granularity: StatsGranularity.year);
      expect(t.length, greaterThanOrEqualTo(2));
      expect(t.every((p) => p.label.endsWith('年')), isTrue);
    });

    test('时间范围筛选会排除范围外的笔记', () {
      final now = DateTime.now();
      add('很久以前', publishedAt: DateTime(now.year - 5, 1, 1));
      add('上个月', publishedAt: DateTime(now.year, now.month - 1, 5));

      final t = stats.trend(
        query: StatsQuery(from: DateTime(now.year, now.month - 2, 1)),
        granularity: StatsGranularity.month,
      );
      final total = t.fold<int>(0, (s, p) => s + p.notes);
      expect(total, 1, reason: '5 年前那篇应该被范围排除');
    });

    test('没有发布时间的笔记按创建时间计入', () {
      add('没有发布时间');
      final t = stats.trend(granularity: StatsGranularity.month);
      expect(t.fold<int>(0, (s, p) => s + p.notes), 1);
    });

    test('归档的笔记不计入统计', () {
      final id = add('会被归档的');
      add('留下的');
      repo.setArchived(id, true);

      final t = stats.trend(granularity: StatsGranularity.month);
      expect(t.fold<int>(0, (s, p) => s + p.notes), 1);
    });

    test('累计曲线单调不减，末项等于总量', () {
      final now = DateTime.now();
      add('a', chars: 100, publishedAt: DateTime(now.year, now.month - 2, 3));
      add('b', chars: 200, publishedAt: DateTime(now.year, now.month - 1, 3));
      add('c', chars: 300, publishedAt: DateTime(now.year, now.month, 3));

      final cum = stats.cumulative(granularity: StatsGranularity.month);
      expect(cum.length, greaterThanOrEqualTo(2));

      for (var i = 1; i < cum.length; i++) {
        expect(cum[i].notes, greaterThanOrEqualTo(cum[i - 1].notes));
        expect(cum[i].chars, greaterThanOrEqualTo(cum[i - 1].chars));
      }
      expect(cum.last.notes, 3);
      expect(cum.last.chars, 600);
    });
  });

  // ── 分布 ────────────────────────────────────────────────────────────────

  group('分布统计', () {
    test('篇幅分布分桶正确', () {
      add('很短', chars: 100);
      add('中短', chars: 800);
      add('中等', chars: 3000);
      add('较长', chars: 8000);
      add('很长', chars: 15000);
      add('极长', chars: 50000);

      final b = stats.lengthDistribution();
      // 六档都返回，空的也要在（坐标轴不能跳档）
      expect(b.length, 6);
      expect(b.every((x) => x.count == 1), isTrue);
      expect(b.first.count, 1); // < 500
    });

    test('24 小时分布按发布时间取值', () {
      add('早', publishedAt: DateTime(2025, 3, 1, 9, 30));
      add('早2', publishedAt: DateTime(2025, 3, 2, 9, 5));
      add('晚', publishedAt: DateTime(2025, 3, 3, 23, 10));

      final h = stats.hourlyDistribution();
      expect(h.length, 24);
      expect(h[9], 2);
      expect(h[23], 1);
      expect(h[12], 0);
    });

    test('星期分布以周一为起点', () {
      // 2025-01-06 是周一
      add('周一', publishedAt: DateTime(2025, 1, 6, 10));
      // 2025-01-11 是周六
      add('周六', publishedAt: DateTime(2025, 1, 11, 10));

      final w = stats.weekdayDistribution();
      expect(w.length, 7);
      expect(w[0], 1, reason: '下标 0 应该是周一');
      expect(w[5], 1, reason: '下标 5 应该是周六');
    });

    test('每日密度供热力图使用', () {
      add('a', publishedAt: DateTime(2025, 3, 1, 8));
      add('b', publishedAt: DateTime(2025, 3, 1, 20));
      add('c', publishedAt: DateTime(2025, 3, 3, 8));

      final d = stats.dailyDensity();
      expect(d['2025-03-01'], 2);
      expect(d['2025-03-03'], 1);
      expect(d.containsKey('2025-03-02'), isFalse);
    });

    test('文集占比包含未分类', () {
      final cid = repo.createCollection('有名字的')!;
      add('归了类', collectionId: cid);
      add('没归类');

      final share = stats.collectionShare();
      expect(share.length, 2);
      final names = share.map((s) => s.name).toSet();
      expect(names, containsAll(<String>['有名字的', '未分类']));
    });
  });

  // ── 连续发布 ────────────────────────────────────────────────────────────

  group('连续发布', () {
    test('连续三天', () {
      final today = DateTime.now();
      for (var i = 0; i < 3; i++) {
        add('day$i', publishedAt: today.subtract(Duration(days: i)));
      }
      final s = stats.streak();
      expect(s.current, 3);
      expect(s.longest, 3);
      expect(s.activeDays, 3);
    });

    test('断掉之后当前连续归零，但最长记录保留', () {
      final today = DateTime.now();
      // 10 天前连写 5 天
      for (var i = 0; i < 5; i++) {
        add('old$i', publishedAt: today.subtract(Duration(days: 10 + i)));
      }
      final s = stats.streak();
      expect(s.current, 0, reason: '上次写作是 10 天前，连续已断');
      expect(s.longest, 5);
      expect(s.activeDays, 5);
    });

    test('没有任何笔记时全是 0', () {
      final s = stats.streak();
      expect(s.current, 0);
      expect(s.longest, 0);
      expect(s.totalDays, 0);
      expect(s.density, 0);
    });
  });

  // ── 排行与词频 ──────────────────────────────────────────────────────────

  group('排行与词频', () {
    test('长文排行按字数倒序', () {
      add('短', chars: 100);
      add('长', chars: 9000);
      add('中', chars: 3000);

      final top = stats.topByLength(limit: 10);
      expect(top.map((t) => t.title).toList(), <String>['长', '中', '短']);
      expect(top.first.chars, 9000);
    });

    test('标签频次统计', () {
      add('a', tags: <String>['随笔', '技术']);
      add('b', tags: <String>['随笔']);

      final tags = stats.tagFrequency();
      final map = <String, int>{
        for (final t in tags) t.name: t.count,
      };
      expect(map['随笔'], 2);
      expect(map['技术'], 1);
    });

    test('高频词能提取重复出现的二字组合', () {
      for (var i = 0; i < 4; i++) {
        add('深夜食堂', excerpt: '深夜写作的时候最有感觉');
      }
      final kws = stats.keywords(minCount: 3);
      final words = kws.map((k) => k.word).toSet();
      expect(words, contains('深夜'));
      expect(words, contains('写作'));
    });

    test('高频词会过滤掉虚词组合', () {
      for (var i = 0; i < 5; i++) {
        add('随便什么标题', excerpt: '这个东西的时候就是这样');
      }
      final words = stats.keywords(minCount: 3).map((k) => k.word).toSet();
      expect(words, isNot(contains('什么')));
      expect(words, isNot(contains('这个')));
      expect(words, isNot(contains('时候')));
    });

    test('内容不足时高频词为空而不是报错', () {
      add('短');
      expect(stats.keywords(), isEmpty);
    });
  });
}
