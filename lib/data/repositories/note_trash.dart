/// NoteRepository 的回收站部分。
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

extension NoteTrash on NoteRepository {
  /// 把笔记移进回收站。
  void deleteNote(int id) => deleteNotes(<int>[id]);

  void deleteNotes(Iterable<int> ids) {
    final list = ids.toList();
    if (list.isEmpty) return;
    _d.execute(
      'UPDATE notes SET deleted_at = ? WHERE id IN (${list.join(',')})',
      <Object?>[DateTime.now().millisecondsSinceEpoch],
    );
  }

  /// 把文件夹移进回收站，连同它**下面的所有笔记**。
  ///
  /// 只标记文件夹、不管里面的笔记的话，那些笔记会变成孤儿 ——
  /// 顶层列表里看不见（父文件夹没了），回收站里也找不到。
  void trashCollection(int id) {
    final ids = <int>[id, ...descendantCollectionIds(id)];
    final now = DateTime.now().millisecondsSinceEpoch;
    _d.execute(
      'UPDATE collections SET deleted_at = ? WHERE id IN (${ids.join(',')})',
      <Object?>[now],
    );
    _d.execute(
      'UPDATE notes SET deleted_at = ? WHERE collection_id IN (${ids.join(',')})',
      <Object?>[now],
    );
  }

  /// 回收站里的笔记，最近删的在前。
  List<Note> listTrashedNotes() {
    final rows = _d.select(
      'SELECT ${NoteRepository._noteColumns()} FROM notes n '
      'LEFT JOIN collections c ON c.id = n.collection_id '
      'WHERE n.deleted_at IS NOT NULL '
      'ORDER BY n.deleted_at DESC',
    );
    final notes = rows.map((r) => Note.fromRow(r)).toList();
    _attachTags(notes);
    return notes;
  }

  /// 回收站里的文件夹。
  List<Collection> listTrashedCollections() {
    final rows = _d.select(
      'SELECT c.*, 0 AS note_count FROM collections c '
      'WHERE c.deleted_at IS NOT NULL ORDER BY c.deleted_at DESC',
    );
    return rows.map((r) => Collection.fromRow(r)).toList();
  }

  int trashedCount() =>
      _d
              .select(
                'SELECT COUNT(*) AS c FROM notes WHERE deleted_at IS NOT NULL',
              )
              .first['c']
          as int;

  /// 从回收站恢复笔记。
  ///
  /// **连同它们所属的文件夹一起恢复**。只把笔记的 deleted_at 清掉的话，
  /// 它的 collection_id 仍然指着一个还在回收站里的文件夹 ——
  /// 表现就是"文章回来了，但文件夹没回来，文章变成未分类了"。
  void restoreNotes(Iterable<int> ids) {
    final list = ids.toList();
    if (list.isEmpty) return;
    _d.execute(
      'UPDATE notes SET deleted_at = NULL WHERE id IN (${list.join(',')})',
    );

    final cols = _d.select(
      'SELECT DISTINCT collection_id AS id FROM notes '
      'WHERE id IN (${list.join(',')}) AND collection_id IS NOT NULL',
    );
    for (final r in cols) {
      _restoreCollectionChain(r['id'] as int);
    }
  }

  /// 恢复一个文件夹，以及它的**全部祖先**。
  ///
  /// 祖先不一起恢复的话，这个文件夹会挂在一个还在回收站里的父节点下面，
  /// 而左栏的树是从顶层往下走的 —— 父级不在，整条分支都显示不出来，
  /// 用户会以为"文件夹还是没恢复"。
  void _restoreCollectionChain(int id) {
    var cur = id;
    final seen = <int>{};
    while (seen.add(cur)) {
      _d.execute(
        'UPDATE collections SET deleted_at = NULL WHERE id = ?',
        <Object?>[cur],
      );
      final rows = _d.select(
        'SELECT parent_id FROM collections WHERE id = ?',
        <Object?>[cur],
      );
      if (rows.isEmpty) break;
      final parent = rows.first['parent_id'] as int?;
      if (parent == null) break;
      cur = parent;
    }
  }

  /// 从回收站恢复文件夹，连同它下面的笔记。
  ///
  /// 只恢复文件夹的话，里面的笔记还留在回收站，
  /// 用户会以为"恢复没生效"。
  void restoreCollection(int id) {
    _restoreCollectionChain(id);
    final ids = <int>[id, ...descendantCollectionIdsIncludingTrashed(id)];
    _d.execute(
      'UPDATE collections SET deleted_at = NULL WHERE id IN (${ids.join(',')})',
    );
    _d.execute(
      'UPDATE notes SET deleted_at = NULL WHERE collection_id IN (${ids.join(',')})',
    );
  }

  /// **真正**删掉（不可恢复）。调用方必须已经明确征得用户同意。
  void purgeNotes(Iterable<int> ids) {
    final list = ids.toList();
    if (list.isEmpty) return;
    _d.execute('DELETE FROM notes WHERE id IN (${list.join(',')})');
    _purgeMedia(list);
    // 历史和草稿也跟着笔记走。它们没有外键，留着就是永远没人读的孤儿行：
    // 用户"彻底删除"之后，正文副本还躺在库里（也是隐私问题）。
    for (final id in list) {
      deleteRevisionsOf(id);
    }
  }

  /// 顺手删掉这些笔记的图片目录。
  ///
  /// 回收站的按钮上写着"图片也会一并清掉"，但以前只删了数据库行 ——
  /// 图片永远留在磁盘上。既是空间泄漏，也是**隐私泄漏**：
  /// 用户以为彻底删掉了，文件其实还在 `data/images/<id>/` 里。
  ///
  /// 尽力而为：删不掉（被占用、权限）也不能让"彻底删除"失败，
  /// 行已经删了，留个目录总比让用户以为没删成功好。
  void _purgeMedia(Iterable<int> noteIds) {
    for (final id in noteIds) {
      try {
        final dir = Directory(p.join(db.imageRoot.path, '$id'));
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (_) {
        // 忽略
      }
    }
  }

  void purgeCollection(int id) {
    final ids = <int>[id, ...descendantCollectionIdsIncludingTrashed(id)];
    // **只删真的在回收站里的笔记**。
    //
    // 这里以前是无条件 `DELETE FROM notes WHERE collection_id IN (...)`，
    // 于是有这么一条会把活笔记永久删掉的路径：
    //   删掉文集 X（X 和它的笔记进回收站）→ 再导入一批文件、文集名又叫 X
    //   → 新笔记挂在**已在回收站里的** X 上（ensureCollectionPath 只按名字找）
    //   → 这些新笔记是"活的"、列表里看得见，可 X 不在侧栏里
    //   → 后来清空回收站，它们被一起干掉，而且**从来没进过回收站**，找不回来。
    //
    // 现在活着的笔记不动，靠 notes.collection_id 的 ON DELETE SET NULL
    // 变成未分类 —— 文集没了，笔记还在。
    final doomed = _d
        .select(
          'SELECT id FROM notes WHERE collection_id IN (${ids.join(',')}) '
          'AND deleted_at IS NOT NULL',
        )
        .map((r) => r['id'] as int)
        .toList();
    _d.execute(
      'DELETE FROM notes WHERE collection_id IN (${ids.join(',')}) '
      'AND deleted_at IS NOT NULL',
    );
    _d.execute('DELETE FROM collections WHERE id IN (${ids.join(',')})');
    _purgeMedia(doomed);
    for (final id in doomed) {
      deleteRevisionsOf(id);
    }
  }

  /// 清空回收站。返回清掉的笔记数。
  int purgeAllTrash() {
    final n = trashedCount();
    final doomed = _d
        .select('SELECT id FROM notes WHERE deleted_at IS NOT NULL')
        .map((r) => r['id'] as int)
        .toList();
    final cols = _d
        .select('SELECT id FROM collections WHERE deleted_at IS NOT NULL')
        .map((r) => r['id'] as int)
        .toList();
    if (cols.isNotEmpty) {
      _d.execute('DELETE FROM collections WHERE id IN (${cols.join(',')})');
    }
    _d.execute('DELETE FROM notes WHERE deleted_at IS NOT NULL');
    _purgeMedia(doomed);
    for (final id in doomed) {
      deleteRevisionsOf(id);
    }
    return n;
  }

  /// 清掉回收站里超过 [days] 天的内容。返回清掉的笔记数。
  ///
  /// [days] <= 0 表示"永不自动清理"。
  int purgeTrashOlderThan(int days) {
    if (days <= 0) return 0;
    final cutoff = DateTime.now()
        .subtract(Duration(days: days))
        .millisecondsSinceEpoch;
    final n =
        _d.select(
              'SELECT COUNT(*) AS c FROM notes '
              'WHERE deleted_at IS NOT NULL AND deleted_at < ?',
              <Object?>[cutoff],
            ).first['c']
            as int;

    _d.execute(
      'DELETE FROM collections WHERE deleted_at IS NOT NULL AND deleted_at < ?',
      <Object?>[cutoff],
    );
    final doomed = _d
        .select(
          'SELECT id FROM notes WHERE deleted_at IS NOT NULL AND deleted_at < ?',
          <Object?>[cutoff],
        )
        .map((r) => r['id'] as int)
        .toList();
    _d.execute(
      'DELETE FROM notes WHERE deleted_at IS NOT NULL AND deleted_at < ?',
      <Object?>[cutoff],
    );
    _purgeMedia(doomed);
    for (final id in doomed) {
      deleteRevisionsOf(id);
    }
    return n;
  }

  /// 连回收站里的一起算的子孙文件夹。
  ///
  /// 普通查询会滤掉已删除的文件夹，恢复/彻底删除时必须能看见它们，
  /// 否则子文件夹会变成永远捞不回来的孤儿。
  List<int> descendantCollectionIdsIncludingTrashed(int rootId) {
    final out = <int>[];
    final queue = <int>[rootId];
    while (queue.isNotEmpty) {
      final cur = queue.removeLast();
      final rows = _d.select(
        'SELECT id FROM collections WHERE parent_id = ?',
        <Object?>[cur],
      );
      for (final r in rows) {
        final id = r['id'] as int;
        if (out.contains(id)) continue;
        out.add(id);
        queue.add(id);
      }
    }
    return out;
  }

  // ── 标签 ────────────────────────────────────────────────────────────────
}
