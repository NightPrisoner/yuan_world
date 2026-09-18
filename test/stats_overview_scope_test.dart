/// 概览的筛选口径。
///
/// 概览以前读的是全库总数：勾了两个文件夹、时间范围换成"近一年"，
/// 它还写着全库的篇数和字数，和下面每一张卡片都对不上。
/// 一个页面里两套口径，用户只会得出"筛选坏了"这一个结论。
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

  final now = DateTime.now();

  int add(
    String title, {
    required DateTime at,
    int? collectionId,
    int chars = 100,
    List<String> tags = const <String>[],
  }) => repo.insertNote(
    title: title,
    content: 'x' * chars,
    excerpt: 'x' * chars,
    publishedAt: at,
    collectionId: collectionId,
    tags: tags,
    charCount: chars,
    wordCount: chars ~/ 2,
  );

  test('不筛选时就是全库口径', () {
    final a = repo.createCollection('甲')!;
    add('一', at: DateTime(now.year, now.month, 3), collectionId: a, chars: 500, tags: <String>['x']);
    add('二', at: DateTime(now.year - 1, 3, 3), chars: 300, tags: <String>['y']);
    final three = add('三', at: DateTime(now.year - 2, 3, 3), chars: 200);
    repo.setFavorite(three, true);

    final o = stats.overview();
    expect(o.noteCount, 3);
    expect(o.totalChars, 1000);
    expect(o.favoriteCount, 1);
    expect(o.collectionCount, 1);
    expect(o.tagCount, 2);
    expect(o.firstAt, isNotNull);
    expect(o.lastAt, isNotNull);
  });

  test('勾了文件夹就只算这几个', () {
    final a = repo.createCollection('甲')!;
    final b = repo.createCollection('乙')!;
    add('甲的', at: DateTime(now.year, now.month, 3), collectionId: a, chars: 500);
    add('乙的', at: DateTime(now.year, now.month, 3), collectionId: b, chars: 700);
    add('没归类', at: DateTime(now.year, now.month, 3), chars: 900);

    final o = stats.overview(query: StatsQuery(collectionIds: <int>[a]));
    expect(o.noteCount, 1);
    expect(o.totalChars, 500);
    // 文集数也收窄成选中的这一个
    expect(o.collectionCount, 1);
  });

  test('多选文件夹是并集', () {
    final a = repo.createCollection('甲')!;
    final b = repo.createCollection('乙')!;
    add('甲的', at: DateTime(now.year, now.month, 3), collectionId: a, chars: 500);
    add('乙的', at: DateTime(now.year, now.month, 3), collectionId: b, chars: 700);
    add('没归类', at: DateTime(now.year, now.month, 3), chars: 900);

    final o = stats.overview(query: StatsQuery(collectionIds: <int>[a, b]));
    expect(o.noteCount, 2);
    expect(o.totalChars, 1200);
    expect(o.collectionCount, 2);
  });

  test('子文件夹的笔记算进父文件夹', () {
    final parent = repo.createCollection('父')!;
    final child = repo.createCollection('子', parentId: parent)!;
    add('子里的', at: DateTime(now.year, now.month, 3), collectionId: child);

    final o = stats.overview(query: StatsQuery(collectionIds: <int>[parent]));
    expect(o.noteCount, 1);
    expect(o.collectionCount, 2, reason: '父 + 子');
  });

  test('时间范围同样生效', () {
    final a = repo.createCollection('甲')!;
    add('新的', at: DateTime(now.year, now.month, 3), collectionId: a);
    add('老的', at: DateTime(now.year - 3, 3, 3), collectionId: a);

    final o = stats.overview(
      query: StatsQuery(from: DateTime(now.year, 1, 1)),
    );
    expect(o.noteCount, 1);
  });

  test('标签数只数这些笔记真正用到的', () {
    final a = repo.createCollection('甲')!;
    final b = repo.createCollection('乙')!;
    add('甲的', at: DateTime(now.year, now.month, 3), collectionId: a, tags: <String>['只甲有']);
    add('乙的', at: DateTime(now.year, now.month, 3), collectionId: b, tags: <String>['只乙有']);

    final o = stats.overview(query: StatsQuery(collectionIds: <int>[a]));
    expect(o.tagCount, 1);
  });

  test('空的筛选结果不报错，全是 0', () {
    repo.createCollection('甲');
    final o = stats.overview(query: StatsQuery(collectionIds: <int>[999]));
    expect(o.noteCount, 0);
    expect(o.totalChars, 0);
    expect(o.collectionCount, 0);
    expect(o.firstAt, isNull);
  });
}
