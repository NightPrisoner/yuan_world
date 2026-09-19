/// 侧栏筛选是**互斥**的：点谁就只看谁。
///
/// 用户报的 bug：「先点收藏再点未分类」时侧栏里两行**同时高亮**，列表也几乎
/// 一定是空的 —— 因为 `selectUncategorized` 是往当前筛选上**叠加**
/// `uncategorizedOnly`，没清掉 `favoritesOnly`，于是变成「收藏 且 未分类」。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';

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

  test('先点收藏再点未分类：只剩未分类生效', () {
    state.toggleFavorites();
    expect(state.filter.favoritesOnly, isTrue);

    state.selectUncategorized();

    expect(state.filter.uncategorizedOnly, isTrue);
    expect(state.filter.favoritesOnly, isFalse,
        reason: '两个条件同时成立的话，侧栏两行会一起高亮，列表也基本是空的');
  });

  test('先点未分类再点收藏：只剩收藏生效', () {
    state.selectUncategorized();
    expect(state.filter.uncategorizedOnly, isTrue);

    state.toggleFavorites();

    expect(state.filter.favoritesOnly, isTrue);
    expect(state.filter.uncategorizedOnly, isFalse);
  });

  test('点未分类会清掉文集筛选（否则条件是矛盾的）', () {
    final col = state.repo.createCollection('文集甲')!;
    state.selectCollection(col);
    expect(state.filter.collectionId, col);

    state.selectUncategorized();

    expect(state.filter.collectionId, isNull);
    expect(state.filter.uncategorizedOnly, isTrue);
  });

  test('点未分类保留当前排序（以前会被悄悄重置）', () {
    final sort = state.filter.sort;
    state.selectUncategorized();
    expect(state.filter.sort, sort);
  });

  test('点收藏会清掉未分类', () {
    state.selectUncategorized();
    state.toggleFavorites();
    expect(
      state.filter.favoritesOnly && state.filter.uncategorizedOnly,
      isFalse,
      reason: '两个筛选不能同时为真',
    );
  });
}
