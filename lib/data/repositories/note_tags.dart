/// NoteRepository 的标签部分。
///
/// 这里是 `note_repository.dart` 的一部分（`part of`）：这些方法本来就是
/// `NoteRepository` 的方法，拆出来只是**为了让单个文件别太长** ——
/// 之前 1600 行 SQL 挤在一个文件里，找一条查询要滚半天。`part` 不引入
/// 新的抽象层，调用点一个字都不用改（同一个 library，私有字段照样可见）。
///
/// 扩展名**不带下划线**是有意的：私有扩展只在本 library 内可见，而
/// `app_state.dart` 那些地方是 import 进来用的（仓库方法原本是公开的，
/// 拆完必须还是公开的）。
part of 'note_repository.dart';

extension NoteTags on NoteRepository {
  /// 覆盖一篇笔记的标签。
  ///
  /// **整段包在一个事务里**：先删后插，中途失败的话会把这篇笔记的标签
  /// 全丢光（删已经生效、插还没做）。
  void setNoteTags(int noteId, List<String> names) {
    _d.execute('BEGIN');
    try {
      _d.execute('DELETE FROM note_tags WHERE note_id = ?', [noteId]);
      for (final raw in names) {
        final name = raw.trim();
        if (name.isEmpty) continue;
        _d.execute(
          'INSERT OR IGNORE INTO tags (name, created_at) VALUES (?, ?)',
          [name, DateTime.now().millisecondsSinceEpoch],
        );
        final found = _d.select('SELECT id FROM tags WHERE name = ?', [name]);
        if (found.isEmpty) continue;
        final tid = found.first['id'] as int;
        _d.execute(
          'INSERT OR IGNORE INTO note_tags (note_id, tag_id) VALUES (?, ?)',
          [noteId, tid],
        );
      }
      _d.execute('COMMIT');
    } catch (_) {
      _d.execute('ROLLBACK');
      rethrow;
    }
  }

  List<TagStat> allTags({bool hiddenOnly = false}) {
    final rows = _d.select(
      // 回收站里的笔记不算数：不然标签会一直挂在侧栏上，
      // 计数还包含已经删掉的内容，点进去却是空的
      'SELECT t.id, t.name, t.color, COUNT(n.id) AS cnt FROM tags t '
      'JOIN note_tags nt ON nt.tag_id = t.id '
      'JOIN notes n ON n.id = nt.note_id '
      ' AND ${hiddenOnly ? hiddenNote("n") : liveNote("n")} '
      'GROUP BY t.id HAVING cnt > 0 ORDER BY cnt DESC',
    );
    return rows.map((r) => TagStat.fromRow(r)).toList();
  }

  /// 改标签名。新名字**已经存在**时就是合并（返回合并到的那个 id）。
  ///
  /// 合并不能靠"直接改名"：`tags.name` 上有唯一约束，改过去会直接报错；
  /// 而且就算改成了，两边的笔记也得真的并到一个标签下。所以是
  /// **先把 note_tags 指到目标标签，再把旧标签删掉**，整段一个事务。
  ///
  /// 返回最终生效的标签 id（合并时是目标标签的）。
  int renameTag(int id, String newName) {
    final name = newName.trim();
    if (name.isEmpty) return id;

    final current = _d.select('SELECT name FROM tags WHERE id = ?', [id]);
    if (current.isEmpty) return id;
    if (current.first['name'] == name) return id;

    final target = _d.select('SELECT id FROM tags WHERE name = ?', [name]);
    if (target.isNotEmpty) {
      final into = target.first['id'] as int;
      if (into == id) return id;
      return _mergeTag(from: id, into: into);
    }

    _d.execute('UPDATE tags SET name = ? WHERE id = ?', [name, id]);
    return id;
  }

  /// 把 [from] 合并进 [into]（[from] 消失）。
  int _mergeTag({required int from, required int into}) {
    _d.execute('BEGIN');
    try {
      // OR IGNORE：两篇笔记本来就同时挂着这两个标签时，这条会撞主键，
      // 忽略即可 —— 它已经指向目标标签了，下面的 DELETE 会收尾。
      _d.execute(
        'UPDATE OR IGNORE note_tags SET tag_id = ? WHERE tag_id = ?',
        [into, from],
      );
      _d.execute('DELETE FROM note_tags WHERE tag_id = ?', [from]);
      _d.execute('DELETE FROM tags WHERE id = ?', [from]);
      _d.execute('COMMIT');
    } catch (_) {
      _d.execute('ROLLBACK');
      rethrow;
    }
    return into;
  }

  /// 删掉一个标签。**只解绑，不碰笔记** —— 笔记本身一篇都不会少。
  void deleteTag(int id) {
    _d.execute('BEGIN');
    try {
      _d.execute('DELETE FROM note_tags WHERE tag_id = ?', [id]);
      _d.execute('DELETE FROM tags WHERE id = ?', [id]);
      _d.execute('COMMIT');
    } catch (_) {
      _d.execute('ROLLBACK');
      rethrow;
    }
  }

  void setTagColor(int id, int color) =>
      _d.execute('UPDATE tags SET color = ? WHERE id = ?', [color, id]);

  // ── 文集 ────────────────────────────────────────────────────────────────
}
