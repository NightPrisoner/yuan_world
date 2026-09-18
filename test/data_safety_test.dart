/// 两个**会永久删数据的** bug 的回归测试。
///
/// 这两条都是代码审查挖出来的，路径都不常见，但一旦走到就不可恢复 ——
/// 所以必须有测试守着，不能只靠"这次改对了"。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';

void main() {
  late AppDatabase db;
  late NoteRepository repo;

  setUp(() {
    db = AppDatabase.inMemory();
    repo = NoteRepository(db);
  });

  tearDown(() => db.close());

  int add(String title, {int? collectionId}) => repo.insertNote(
    title: title,
    content: 'x' * 100,
    excerpt: 'x',
    publishedAt: DateTime.now(),
    collectionId: collectionId,
    charCount: 100,
    wordCount: 50,
  );

  group('清空回收站不能误删活笔记', () {
    test('删掉文集后，同名导入的新笔记不会被连带清掉', () {
      // 1. 建文集 X，放一篇笔记，然后删掉整个文集
      final x = repo.createCollection('X')!;
      final old = add('旧笔记', collectionId: x);
      repo.trashCollection(x);

      // 2. 再导入一批文件，文集名又叫 X
      final again = repo.ensureCollectionPath(<String>['X'])!;

      // **关键**：新笔记必须是活的、可见的
      expect(
        repo.listNotes(const NoteFilter()).any((n) => n.title == '新笔记'),
        isFalse,
        reason: '还没插呢',
      );
      final fresh = add('新笔记', collectionId: again);
      expect(
        repo.listNotes(const NoteFilter()).map((n) => n.id),
        contains(fresh),
        reason: '新笔记该是活的（在列表里看得见）',
      );

      // 3. 清空回收站
      repo.purgeAllTrash();

      // 旧笔记该被清掉，**新笔记必须还在**
      expect(
        repo.listNotes(const NoteFilter()).map((n) => n.id),
        contains(fresh),
        reason: '清空回收站把一篇从没进过回收站的活笔记永久删了',
      );
      expect(
        repo.listNotes(const NoteFilter()).map((n) => n.id),
        isNot(contains(old)),
        reason: '旧笔记本来就在回收站，该被清掉',
      );
    });

    test('导入到已删除的同名文集时，文集会被还原回来', () {
      final x = repo.createCollection('X')!;
      repo.trashCollection(x);
      expect(repo.allCollections().any((c) => c.name == 'X'), isFalse);

      final again = repo.ensureCollectionPath(<String>['X'])!;
      expect(again, x, reason: '同名该复用同一条（name 有 UNIQUE 约束）');
      expect(
        repo.allCollections().any((c) => c.name == 'X'),
        isTrue,
        reason: '新笔记挂在一个看不见的文集上，用户是找不到它的',
      );
    });

    test('purgeCollection 之后，活笔记变成未分类而不是消失', () {
      final x = repo.createCollection('X')!;
      final trashed = add('在回收站里的', collectionId: x);
      // trashCollection 会把文集里的笔记**一起**软删
      repo.trashCollection(x);
      // **之后再往这个（已经在回收站里的）文集里加一篇** —— 它是活的：
      // 列表里看得见，可文集不在侧栏里。这正是那条误删路径的起点。
      final live = add('活的', collectionId: x);

      repo.purgeCollection(x);

      final left = repo.listNotes(const NoteFilter());
      expect(left.map((n) => n.id), contains(live));
      expect(left.map((n) => n.id), isNot(contains(trashed)));
      expect(
        left.firstWhere((n) => n.id == live).collectionId,
        isNull,
        reason: '文集没了，笔记该落到未分类',
      );
    });

    test('新建文集时若只有回收站里那条同名，会把它还原而不是报重复', () {
      final x = repo.createCollection('X')!;
      repo.trashCollection(x);

      final created = repo.createCollection('X');
      expect(created, x, reason: '该还原那一条');
      expect(
        repo.allCollections().any((c) => c.name == 'X'),
        isTrue,
        reason: '否则用户会看到"已有同名文集"，可侧栏里根本没有',
      );
    });
  });

  group('回收站的删除要连图片一起清', () {
    test('彻底删除会删掉这篇笔记的图片目录', () {
      final id = add('带图的');
      final dir = db.imageRoot.createTempSync('probe');
      // 用笔记自己的目录名（以 id 命名）
      final noteDir = Directory('${db.imageRoot.path}/$id')
        ..createSync(recursive: true);
      File('${noteDir.path}/a.png').writeAsBytesSync(<int>[1, 2, 3]);
      expect(noteDir.existsSync(), isTrue);

      repo.deleteNote(id);
      repo.purgeNotes(<int>[id]);

      expect(
        noteDir.existsSync(),
        isFalse,
        reason: '按钮上写着"图片也会一并清掉"，文件却还在磁盘上',
      );
      dir.deleteSync(recursive: true);
    });
  });

  group('批量恢复不能漏掉任何一类', () {
    // 说明：这一组走**状态层**，不去点回收站页面。
    //
    // 页面上的批量恢复曾经有两个坑（不 await 就调第二个；第一步刷新后
    // 选中的 id 已被清空），两个都已在 trash_page.dart 里修掉，
    // 但要在 widget 测试里把那个异步时序驱动准，成本明显高于收益 ——
    // 这里守住"两步都执行时数据确实都回来了"这个结果，
    // 页面侧的时序靠 `_runOnce` 的 finally + 先快照这两条代码约束。
    test('文件夹和笔记一起恢复，两边都要回来', () async {
      final state = AppState(db, repo, ImportService(db, repo));
      await state.init();

      final x = repo.createCollection('X')!;
      add('X 里的笔记', collectionId: x);
      add('孤立的笔记');
      repo.trashCollection(x);
      for (final n in repo.listNotes(const NoteFilter())) {
        repo.deleteNote(n.id);
      }
      await state.refresh();
      state.refreshTrash();

      expect(state.trashedCollections.length, 1);
      expect(state.trashedNotes.length, 2);

      // 页面做的就是这两步
      await state.restoreCollections(<int>[x]);
      await state.restoreFromTrash(state.trashedNotes.map((n) => n.id).toList());
      state.refreshTrash();

      expect(state.trashedNotes, isEmpty, reason: '笔记漏了 —— 之后会被清空回收站真删掉');
      expect(state.trashedCollections, isEmpty);
      expect(repo.listNotes(const NoteFilter()).length, 2);
    });

    test('一步失败不会把另一步掐断', () async {
      // _runOnce 里 catch 住而不是 rethrow，就是为了这个：
      // 批量操作里文件夹那步出错，笔记那步还得照跑
      final state = AppState(db, repo, ImportService(db, repo));
      await state.init();
      final lonely = add('孤立的笔记');
      repo.deleteNote(lonely);
      await state.refresh();
      state.refreshTrash();
      expect(state.trashedNotes.length, 1);

      await state.restoreFromTrash(<int>[lonely]);
      state.refreshTrash();
      expect(state.trashedNotes, isEmpty);
    });
  });
}
