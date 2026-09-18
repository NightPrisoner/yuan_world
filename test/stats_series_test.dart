/// 多文集对比的数据契约测试。
///
/// 这个文件是为一个真实 bug 写的：多选几个文集画对比曲线时，
/// 各条线的桶数和起点都不一样，而 fl_chart 是**按下标**画点的 ——
/// 于是每条线水平错位，叠在一起"对不上"。
///
/// 根因有两处，各钉一条：
///   1. 区间内一条数据都没有时，整个序列返回空（线直接消失）
///   2. 不指定统一起点时，每条线从自己第一条笔记开始补零（起点各异）
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
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

  /// 造一篇指定"发布时间"的笔记。
  int addAt(String title, DateTime when, {int? collectionId}) {
    final id = repo.insertNote(
      title: title,
      content: 'x',
      excerpt: 'x',
      collectionId: collectionId,
      publishedAt: when,
      createdAt: when,
      charCount: 100,
    );
    return id;
  }

  group('数据连续性', () {
    test('区间内没有数据时也要补齐，而不是返回空', () {
      final col = repo.createCollection('停更的')!;
      // 只有 2024 年的数据
      addAt('旧的', DateTime(2024, 3, 10), collectionId: col);

      // 但从 2023 年问起 —— 2023 那一段是空的
      final pts = stats.trend(
        query: StatsQuery(
          collectionIds: <int>[col],
          from: DateTime(2023, 1, 1),
        ),
        granularity: StatsGranularity.month,
      );

      expect(
        pts, isNotEmpty,
        reason: '有起点就该补出完整区间，不能因为 2023 没数据就返回空',
      );
      // 2023 年那几个月都应该是 0，而不是缺失
      final y2023 = pts.where((p) => p.bucket.startsWith('2023')).toList();
      expect(y2023.length, 12, reason: '2023 全年 12 个月都要在');
      expect(y2023.every((p) => p.notes == 0), isTrue);
      // 2024-03 那篇要算进去
      final hit = pts.firstWhere((p) => p.bucket == '2024-03');
      expect(hit.notes, 1);
    });

    test('完全没有数据、也没有起点时才返回空', () {
      final pts = stats.trend(
        query: const StatsQuery(),
        granularity: StatsGranularity.month,
      );
      expect(pts, isEmpty);
    });

    test('默认区间止于最后一条数据，不会拖到今天', () {
      final col = repo.createCollection('甲')!;
      addAt('最后一篇', DateTime(2024, 6, 1), collectionId: col);

      final pts = stats.trend(
        query: StatsQuery(
          collectionIds: <int>[col],
          from: DateTime(2024, 1, 1),
        ),
        granularity: StatsGranularity.month,
      );

      // 只在 2024 年有笔记，时间线就该止于 2024。
      // 一路补到今天的话，一个早已停更的文集会拖出一条什么都没有的空长尾。
      expect(pts.first.bucket, '2024-01');
      expect(pts.last.bucket, '2024-06');
      expect(pts.length, 6);
    });

    test('显式给了结束时间就补满（多序列共用同一条轴靠的是它）', () {
      final col = repo.createCollection('甲')!;
      addAt('最后一篇', DateTime(2024, 6, 1), collectionId: col);

      final pts = stats.trend(
        query: StatsQuery(
          collectionIds: <int>[col],
          from: DateTime(2024, 1, 1),
          to: DateTime(2024, 12, 31),
        ),
        granularity: StatsGranularity.month,
      );

      // 这正是"某文集 2024 有、2025 没有，但和别的文集一起对比时，
      // 2025 那段也要显示成贴着 0 的直线"的实现方式：
      // 由调用方给出**所有序列的公共区间**，每条线都补满它。
      expect(pts.length, 12);
      final after = pts.where((p) => p.bucket.compareTo('2024-06') > 0);
      expect(after, isNotEmpty);
      expect(after.every((p) => p.notes == 0), isTrue);
    });
  });

  group('多条序列必须对齐', () {
    test('给了统一起点后，各文集的桶数完全一致', () {
      final a = repo.createCollection('甲')!;
      final b = repo.createCollection('乙')!;
      final c = repo.createCollection('丙')!;

      addAt('a1', DateTime(2023, 6, 1), collectionId: a);
      addAt('a2', DateTime(2025, 1, 1), collectionId: a);
      addAt('b1', DateTime(2024, 9, 1), collectionId: b);
      // c 只有很久以后的数据
      addAt('c1', DateTime(2026, 5, 1), collectionId: c);

      // **from 和 to 都要给**：只给起点的话，每条线各自止于自己的
      // 最后一条笔记，长度还是会不一样 —— 页面正是靠传满两端来对齐的。
      final from = DateTime(2023, 1, 1);
      final to = DateTime(2026, 12, 31);
      final lengths = <int>[
        for (final id in <int>[a, b, c])
          stats.trend(
            query: StatsQuery(collectionIds: <int>[id], from: from, to: to),
            granularity: StatsGranularity.month,
          ).length,
      ];

      expect(lengths[0], lengths[1], reason: '甲和乙的桶数必须一样');
      expect(lengths[1], lengths[2], reason: '乙和丙的桶数必须一样');
    });

    test('各序列的第一个桶是同一个月份', () {
      final a = repo.createCollection('甲')!;
      final b = repo.createCollection('乙')!;
      addAt('a1', DateTime(2023, 6, 1), collectionId: a);
      addAt('b1', DateTime(2025, 3, 1), collectionId: b);

      final from = DateTime(2023, 1, 1);
      String firstOf(int id) => stats
          .trend(
            query: StatsQuery(collectionIds: <int>[id], from: from),
            granularity: StatsGranularity.month,
          )
          .first
          .bucket;

      expect(firstOf(a), firstOf(b), reason: '起点不同的话整条线会水平错位');
      expect(firstOf(a), '2023-01');
    });

    test('累计增长同样要对齐', () {
      final a = repo.createCollection('甲')!;
      final b = repo.createCollection('乙')!;
      addAt('a1', DateTime(2023, 6, 1), collectionId: a, );
      addAt('b1', DateTime(2025, 3, 1), collectionId: b);

      final from = DateTime(2023, 1, 1);
      final to = DateTime(2026, 12, 31);
      final ca = stats.cumulative(
        query: StatsQuery(collectionIds: <int>[a], from: from, to: to),
        granularity: StatsGranularity.month,
      );
      final cb = stats.cumulative(
        query: StatsQuery(collectionIds: <int>[b], from: from, to: to),
        granularity: StatsGranularity.month,
      );

      expect(ca.length, cb.length, reason: '累计曲线也要共用同一条 X 轴');
      expect(ca.first.label, cb.first.label);
    });

    test('不指定起点时确实会不齐 —— 这是必须传起点的理由', () {
      final a = repo.createCollection('甲')!;
      final b = repo.createCollection('乙')!;
      addAt('a1', DateTime(2023, 6, 1), collectionId: a);
      addAt('b1', DateTime(2025, 3, 1), collectionId: b);

      final la = stats.trend(
        query: StatsQuery(collectionIds: <int>[a]),
        granularity: StatsGranularity.month,
      );
      final lb = stats.trend(
        query: StatsQuery(collectionIds: <int>[b]),
        granularity: StatsGranularity.month,
      );

      // 这条正是当初的现象：起点不同 → 下标对不上 → 线错位。
      // 把它写下来，是为了让"必须传统一起点"这件事有据可依。
      expect(
        la.first.bucket == lb.first.bucket,
        isFalse,
        reason: '不传起点时各自从第一篇开始，起点天然不同',
      );
    });
  });

  group('多文集筛选的口径', () {
    test('选多个文集时取并集（含各自子文件夹）', () {
      final a = repo.createCollection('甲')!;
      final b = repo.createCollection('乙')!;
      final bChild = repo.createCollection('乙的子')!;
      repo.setCollectionParent(bChild, b);
      final other = repo.createCollection('没选的')!;

      addAt('a1', DateTime(2024, 1, 1), collectionId: a);
      addAt('b1', DateTime(2024, 2, 1), collectionId: b);
      addAt('bc1', DateTime(2024, 3, 1), collectionId: bChild);
      addAt('o1', DateTime(2024, 4, 1), collectionId: other);

      final pts = stats.trend(
        query: StatsQuery(
          collectionIds: <int>[a, b],
          from: DateTime(2024, 1, 1),
        ),
        granularity: StatsGranularity.month,
      );
      final total = pts.fold<int>(0, (s, p) => s + p.notes);

      expect(total, 3, reason: '甲 + 乙 + 乙的子，不能算进没选的那个');
    });

    test('collectionIds 优先于单个 collectionId', () {
      final a = repo.createCollection('甲')!;
      final b = repo.createCollection('乙')!;
      addAt('a1', DateTime(2024, 1, 1), collectionId: a);
      addAt('b1', DateTime(2024, 1, 1), collectionId: b);

      final pts = stats.trend(
        query: StatsQuery(
          collectionId: a,
          collectionIds: <int>[b],
          from: DateTime(2024, 1, 1),
        ),
        granularity: StatsGranularity.month,
      );
      expect(pts.fold<int>(0, (s, p) => s + p.notes), 1);
    });
  });
}
