/// 待办清单仓储。
///
/// 排序规则（和主流待办应用一致）：
///   未完成的按「手动排序 sort_index」升序，高优先级的排在前面；
///   已完成的沉到列表末尾，按完成时间倒序（最近完成的在最上）。
///
/// 这样勾掉一项后它会平滑地"落"到已完成区，不会打乱未完成区的顺序。
library;

import 'package:sqlite3/sqlite3.dart';

import '../db/app_database.dart';
import '../models.dart';

class TodoRepository {
  TodoRepository(this.db);

  final AppDatabase db;

  Database get _d => db.db;

  /// 未完成在前、已完成在后。
  List<Todo> allTodos() {
    final rows = _d.select('''
      SELECT * FROM todos
      ORDER BY
        is_done ASC,
        CASE WHEN is_done = 1 THEN 0 ELSE sort_index END ASC,
        priority DESC,
        CASE WHEN is_done = 1 THEN IFNULL(done_at, 0) ELSE created_at END DESC
    ''');
    return rows.map((r) => Todo.fromRow(r)).toList();
  }

  /// 概览用：未完成数、已完成数、逾期数。
  ({int open, int done, int overdue}) counts() {
    final r = _d.select('''
      SELECT
        (SELECT COUNT(*) FROM todos WHERE is_done = 0) AS open,
        (SELECT COUNT(*) FROM todos WHERE is_done = 1) AS done,
        (SELECT COUNT(*) FROM todos
          WHERE is_done = 0 AND due_at IS NOT NULL AND due_at < ?) AS overdue
    ''', <Object?>[DateTime.now().millisecondsSinceEpoch]).first;
    return (
      open: r['open'] as int,
      done: r['done'] as int,
      overdue: r['overdue'] as int,
    );
  }

  /// 新建待办，追加到未完成区末尾。
  int add(String content, {DateTime? dueAt, int priority = 0, int? noteId}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final next = (_d
                .select('SELECT IFNULL(MAX(sort_index), 0) AS m FROM todos WHERE is_done = 0')
                .first['m'] as int) +
        1;
    final stmt = _d.prepare(
      'INSERT INTO todos (content, due_at, priority, sort_index, note_id, created_at, updated_at) '
      'VALUES (?,?,?,?,?,?,?)',
    );
    stmt.execute([content, dueAt?.millisecondsSinceEpoch, priority, next, noteId, now, now]);
    stmt.close();
    return _d.lastInsertRowId;
  }

  void setDone(int id, bool done) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _d.execute(
      'UPDATE todos SET is_done = ?, done_at = ?, updated_at = ? WHERE id = ?',
      <Object?>[done ? 1 : 0, done ? now : null, now, id],
    );
  }

  void setContent(int id, String content) {
    _d.execute(
      'UPDATE todos SET content = ?, updated_at = ? WHERE id = ?',
      <Object?>[content, DateTime.now().millisecondsSinceEpoch, id],
    );
  }

  void setDueAt(int id, DateTime? dueAt) {
    _d.execute(
      'UPDATE todos SET due_at = ?, updated_at = ? WHERE id = ?',
      <Object?>[dueAt?.millisecondsSinceEpoch, DateTime.now().millisecondsSinceEpoch, id],
    );
  }

  void setPriority(int id, int priority) {
    _d.execute(
      'UPDATE todos SET priority = ?, updated_at = ? WHERE id = ?',
      <Object?>[priority, DateTime.now().millisecondsSinceEpoch, id],
    );
  }

  void delete(int id) => _d.execute('DELETE FROM todos WHERE id = ?', <Object?>[id]);

  /// 清空所有已完成的待办，返回删除条数。
  int clearCompleted() {
    final n = _d.select('SELECT COUNT(*) AS c FROM todos WHERE is_done = 1').first['c'] as int;
    _d.execute('DELETE FROM todos WHERE is_done = 1');
    return n;
  }

  /// 拖拽排序：按传入的 id 顺序重写 sort_index。
  ///
  /// 整体包一个事务，避免中途失败导致顺序错乱。
  void reorder(List<int> orderedIds) {
    if (orderedIds.isEmpty) return;
    _d.execute('BEGIN');
    try {
      final stmt = _d.prepare('UPDATE todos SET sort_index = ?, updated_at = ? WHERE id = ?');
      final now = DateTime.now().millisecondsSinceEpoch;
      for (var i = 0; i < orderedIds.length; i++) {
        stmt.execute(<Object?>[i, now, orderedIds[i]]);
      }
      stmt.close();
      _d.execute('COMMIT');
    } catch (_) {
      _d.execute('ROLLBACK');
      rethrow;
    }
  }
}
