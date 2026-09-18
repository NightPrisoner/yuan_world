/// 「文件夹对比」的口径。
///
/// 这个模块以前只认隐私空间：时间范围换成"近一年"，别的卡片都变了，
/// 它还照算全部；勾了文件夹它也不理。数字对不上用户只会觉得
/// "筛选坏了"——所以这里把口径钉死。
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

  int add(
    String title, {
    required DateTime at,
    int? collectionId,
    int chars = 100,
  }) => repo.insertNote(
    title: title,
    content: 'x' * chars,
    excerpt: 'x' * chars,
    publishedAt: at,
    collectionId: collectionId,
    charCount: chars,
    wordCount: chars ~/ 2,
  );

  final now = DateTime.now();

  /// 甲、乙、丙三个文件夹 + 两篇未分类。
  ({int jia, int yi, int bing}) seed() {
    final jia = repo.createCollection('甲')!;
    final yi = repo.createCollection('乙')!;
    final bing = repo.createCollection('丙')!;
    // 每个文件夹各有：一篇近期、一篇两年前
    for (final id in <int>[jia, yi, bing]) {
      add('近期 $id', at: DateTime(now.year, now.month, 5), collectionId: id);
      add('很久以前 $id', at: DateTime(now.year - 2, 3, 5), collectionId: id);
    }
    add('未分类近期', at: DateTime(now.year, now.month, 6));
    add('未分类很久以前', at: DateTime(now.year - 2, 4, 6));
    return (jia: jia, yi: yi, bing: bing);
  }

  Map<String, int> asMap(List<CollectionComparison> list) => <String, int>{
    for (final c in list) c.name: c.notes,
  };

  test('不筛选时列出所有顶级文件夹，未分类也在里面', () {
    seed();
    final rows = stats.compareCollections();
    expect(rows.map((r) => r.name).toSet(), <String>{'甲', '乙', '丙', '未分类'});
    // 每个文件夹两篇
    expect(asMap(rows)['甲'], 2);
    expect(asMap(rows)['未分类'], 2);
  });

  test('时间范围会真的生效（以前这块完全不理 from/to）', () {
    seed();
    final recent = stats.compareCollections(
      query: StatsQuery(from: DateTime(now.year, now.month - 1, 1)),
    );
    expect(asMap(recent)['甲'], 1, reason: '近一个月只该有一篇');
    expect(asMap(recent)['未分类'], 1);

    // 全部在范围之外：行还在，但篇数是 0 ——
    // 和别的图一样保留空位，比整块消失好，用户知道"这段时间没写"
    final future = stats.compareCollections(
      query: StatsQuery(from: DateTime(now.year + 1, 1, 1)),
    );
    expect(future, isNotEmpty);
    expect(future.every((r) => r.notes == 0), isTrue);
    // 未分类 0 篇就没必要占一行（它本来就是个兜底行）
    expect(future.map((r) => r.name), isNot(contains('未分类')));
  });

  test('结束时间按当天结束算，包含当天', () {
    final cid = repo.createCollection('甲')!;
    add('当天', at: DateTime(now.year, now.month, 10, 23, 30), collectionId: cid);
    final rows = stats.compareCollections(
      query: StatsQuery(
        from: DateTime(now.year, now.month, 10),
        to: DateTime(now.year, now.month, 10),
      ),
    );
    expect(asMap(rows)['甲'], 1);
  });

  test('勾了文件夹就只比这几个，未分类不掺进来', () {
    final ids = seed();
    final rows = stats.compareCollections(
      query: StatsQuery(collectionIds: <int>[ids.jia, ids.yi]),
    );
    expect(rows.map((r) => r.name).toList(), <String>['甲', '乙']);
    expect(asMap(rows).containsKey('未分类'), isFalse);
  });

  test('勾一个文件夹时只有它一行', () {
    final ids = seed();
    final rows = stats.compareCollections(
      query: StatsQuery(collectionIds: <int>[ids.bing]),
    );
    expect(rows.length, 1);
    expect(rows.single.name, '丙');
  });

  test('子文件夹的笔记算进父文件夹', () {
    final parent = repo.createCollection('父')!;
    final child = repo.createCollection('子', parentId: parent)!;
    add('子里的', at: DateTime(now.year, now.month, 3), collectionId: child);
    final rows = stats.compareCollections();
    expect(asMap(rows)['父'], 1);
  });

  test('勾了子文件夹时按子文件夹自己出一行', () {
    final parent = repo.createCollection('父')!;
    final child = repo.createCollection('子', parentId: parent)!;
    add('子里的', at: DateTime(now.year, now.month, 3), collectionId: child);

    final rows = stats.compareCollections(
      query: StatsQuery(collectionIds: <int>[parent, child]),
    );
    expect(rows.map((r) => r.name).toList(), <String>['父', '子']);
    expect(asMap(rows)['子'], 1);
    // 父**含子文件夹**，这是全页面统一的口径（includeDescendants 默认开）。
    // 父子都勾上时同一篇会被算两次 —— 这是用户自己勾的重叠，
    // 对比表本来就是各看各的，不求和。
    expect(asMap(rows)['父'], 1);
  });

  test('时间范围 + 文件夹筛选能叠加', () {
    final ids = seed();
    final rows = stats.compareCollections(
      query: StatsQuery(
        collectionIds: <int>[ids.jia, ids.yi, ids.bing],
        from: DateTime(now.year, now.month - 1, 1),
      ),
    );
    expect(rows.length, 3);
    expect(rows.every((r) => r.notes == 1), isTrue);
  });

  test('已删除的文件夹不会出现在结果里', () {
    final ids = seed();
    repo.trashCollection(ids.yi);
    final rows = stats.compareCollections(
      query: StatsQuery(collectionIds: <int>[ids.jia, ids.yi]),
    );
    expect(rows.map((r) => r.name).toList(), <String>['甲']);
  });

  test('按篇数从多到少排', () {
    seed();
    final rows = stats.compareCollections();
    for (var i = 1; i < rows.length; i++) {
      expect(rows[i - 1].notes, greaterThanOrEqualTo(rows[i].notes));
    }
  });
}
