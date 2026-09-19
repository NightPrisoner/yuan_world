/// 关键列的**自愈**。
///
/// 这个应用有过一次真实事故：`kSchemaVersion` 写成了 7，但迁移其实是空的 ——
/// 列不存在、迁移又永远不会再跑，启动直接白屏。
/// 当时的对策是在启动时对关键列做一次存在性检查，缺了就补。
///
/// 这里盯的是那份名单**够不够**。判据不是"这个名字看着重要"，而是
/// "缺了会不会瘫"：每次写入都会碰到的列，缺了就是整个功能报错，
/// 比少一个筛选条件严重得多。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as raw_sqlite;
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('yw_heal'));
  tearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  /// 模拟"版本号写了、迁移是空的"：直接把列从表里拿掉。
  ///
  /// 先把 notes 上的索引**全删掉**：那些列上可能有索引，SQLite 不允许
  /// 直接 DROP 有索引的列。
  void sabotage(String column) {
    final db = raw_sqlite.sqlite3.open(p.join(dir.path, 'yuanworld.db'));
    final idx = db.select(
      "SELECT name FROM sqlite_master "
      "WHERE type='index' AND tbl_name='notes' AND sql IS NOT NULL",
    );
    for (final r in idx) {
      db.execute('DROP INDEX IF EXISTS ${r['name']}');
    }
    db.execute('ALTER TABLE notes DROP COLUMN $column');
    db.close();
  }

  List<String> columnsOf(AppDatabase db) => db.db
      .select('PRAGMA table_info(notes)')
      .map((r) => r['name'] as String)
      .toList();

  test('sort_key 丢了会被补回来，而且补完真的能写入', () {
    AppDatabase.openAt(dir.path).close();
    sabotage('sort_key');

    final db = AppDatabase.openAt(dir.path);
    addTearDown(db.close);

    expect(
      columnsOf(db),
      contains('sort_key'),
      reason: '缺了 sort_key，每次 insertNote 都会报 no such column —— '
          '新建笔记、导入文集全部失败，比少一个筛选条件严重得多',
    );

    // **关键**：不只是列回来了，插入也要真的能跑通
    final repo = NoteRepository(db);
    final id = repo.insertNote(
      title: '自愈之后新建的',
      content: 'x' * 10,
      excerpt: 'x',
      charCount: 10,
      wordCount: 5,
    );
    expect(id, greaterThan(0));
    expect(repo.listNotes(const NoteFilter()).length, 1);
  });

  test('deleted_at 丢了也会被补回来（原有的那条不能退化）', () {
    AppDatabase.openAt(dir.path).close();
    sabotage('deleted_at');

    final db = AppDatabase.openAt(dir.path);
    addTearDown(db.close);
    expect(columnsOf(db), contains('deleted_at'));

    final repo = NoteRepository(db);
    repo.insertNote(
      title: 'n',
      content: 'x' * 10,
      excerpt: 'x',
      charCount: 10,
      wordCount: 5,
    );
    expect(repo.listNotes(const NoteFilter()).length, 1);
  });

  test('列都在时不重复动手（幂等，不破坏已有数据）', () {
    final db = AppDatabase.openAt(dir.path);
    final repo = NoteRepository(db);
    repo.insertNote(
      title: '原来的笔记',
      content: 'x' * 10,
      excerpt: 'x',
      charCount: 10,
      wordCount: 5,
    );
    db.close();

    // 再开一次，自愈逻辑会再跑一遍
    final again = AppDatabase.openAt(dir.path);
    addTearDown(again.close);
    final notes = NoteRepository(again).listNotes(const NoteFilter());
    expect(notes.length, 1, reason: '重复自愈把数据弄丢了');
    expect(notes.single.title, '原来的笔记');
  });
}
