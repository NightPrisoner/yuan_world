/// NoteRepository 的文集部分。
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

extension NoteCollections on NoteRepository {
  /// 全部文集。
  ///
  /// [includeHidden] 为 false（默认）时只看非隐藏的——隐私空间的东西
  /// 不能出现在左栏、选择器、统计里。
  List<Collection> allCollections({bool includeHidden = false}) {
    final rows = _d.select(
      'SELECT c.*, '
      '(SELECT COUNT(*) FROM notes n WHERE n.collection_id = c.id '
      ' AND n.is_archived = 0 AND n.is_hidden = c.is_hidden '
      ' AND n.deleted_at IS NULL) AS note_count '
      'FROM collections c '
      'WHERE ${includeHidden ? 'c.deleted_at IS NULL' : 'c.is_hidden = 0 AND c.deleted_at IS NULL'} '
      // 置顶排在最前：置顶是一票否决，不该被任何排序规则挤下去
      'ORDER BY c.is_pinned DESC, c.sort_order ASC, c.name ASC',
    );
    final list = rows.map((r) => Collection.fromRow(r)).toList();
    return _rollUpCounts(list);
  }

  /// 把子文件夹的笔记数累加到父文件夹上。
  ///
  /// 不做这一步的话，一个只用来分组、自己不放笔记的父文件夹会永远显示 0，
  /// 看起来像空的。
  List<Collection> _rollUpCounts(List<Collection> list) {
    final byParent = <int?, List<int>>{};
    final own = <int, int>{};
    for (final c in list) {
      own[c.id] = c.noteCount;
      (byParent[c.parentId] ??= <int>[]).add(c.id);
    }

    int total(int id) {
      var sum = own[id] ?? 0;
      for (final child in byParent[id] ?? const <int>[]) {
        sum += total(child);
      }
      return sum;
    }

    return <Collection>[for (final c in list) c.withNoteCount(total(c.id))];
  }

  /// 某个文集的直接子文件夹。
  List<Collection> childCollections(
    int? parentId, {
    bool includeHidden = false,
  }) =>
      allCollections(includeHidden: includeHidden)
          .where((c) => c.parentId == parentId)
          .toList();

  /// 递归取某个文集的全部后代 id（不含自己）。
  List<int> descendantCollectionIds(int id) {
    final all = _d.select('SELECT id, parent_id FROM collections');
    final byParent = <int, List<int>>{};
    for (final r in all) {
      final p = r['parent_id'] as int?;
      if (p != null) (byParent[p] ??= <int>[]).add(r['id'] as int);
    }

    final out = <int>[];
    void walk(int pid) {
      for (final child in byParent[pid] ?? const <int>[]) {
        // 防环：数据坏了也不能把界面卡死
        if (out.contains(child)) continue;
        out.add(child);
        walk(child);
      }
    }

    walk(id);
    return out;
  }

  /// 从根到该文集的路径（用于面包屑）。
  List<Collection> collectionPath(int id) {
    final all = {for (final c in allCollections(includeHidden: true)) c.id: c};
    final out = <Collection>[];
    var cursor = all[id];
    var guard = 0;
    while (cursor != null && guard++ < 32) {
      out.insert(0, cursor);
      cursor = cursor.parentId == null ? null : all[cursor.parentId!];
    }
    return out;
  }

  /// 把文集挂到另一个文集下（[parentId] 为 null 即升为顶层）。
  ///
  /// 拒绝把文集挂到自己的后代里，否则会形成环、左栏渲染直接死循环。
  bool setCollectionParent(int id, int? parentId) {
    if (parentId != null) {
      if (parentId == id) return false;
      if (descendantCollectionIds(id).contains(parentId)) return false;
    }
    _d.execute('UPDATE collections SET parent_id = ? WHERE id = ?', <Object?>[
      parentId,
      id,
    ]);
    return true;
  }

  /// 移入 / 移出隐私空间。
  ///
  /// 隐藏文件夹时把**子文件夹和里面的笔记一并标记**（物化），
  /// 这样所有查询只要一句 `is_hidden = 0` 就够，不用递归 join。
  void setCollectionHidden(int id, bool hidden) {
    final ids = <int>[id, ...descendantCollectionIds(id)];
    final v = hidden ? 1 : 0;
    _d.execute(
      'UPDATE collections SET is_hidden = ? WHERE id IN (${ids.join(',')})',
      <Object?>[v],
    );
    _d.execute(
      'UPDATE notes SET is_hidden = ? WHERE collection_id IN (${ids.join(',')})',
      <Object?>[v],
    );
  }

  void setNoteHidden(int id, bool hidden) => _d.execute(
    'UPDATE notes SET is_hidden = ? WHERE id = ?',
    <Object?>[hidden ? 1 : 0, id],
  );

  /// 把某个文集（含后代）里的笔记全部移出，或移到别处。隐私空间"移出"用。
  void unhideCollectionContents(int id) {
    final ids = <int>[id, ...descendantCollectionIds(id)];
    _d.execute(
      'UPDATE collections SET is_hidden = 0 WHERE id IN (${ids.join(',')})',
    );
    _d.execute(
      'UPDATE notes SET is_hidden = 0 WHERE collection_id IN (${ids.join(',')})',
    );
  }

  int ensureCollection(
    String name, {
    int color = 0xFF3B82F6,
    String icon = 'folder',
  }) {
    final hit = _d.select(
      'SELECT id, deleted_at FROM collections WHERE name = ?',
      [name],
    );
    if (hit.isNotEmpty) {
      final id = hit.first['id'] as int;
      if (hit.first['deleted_at'] != null) _restoreCollectionChain(id);
      return id;
    }
    _d.execute(
      'INSERT INTO collections (name, color, icon, sort_order, created_at) VALUES (?,?,?,?,?)',
      [
        name,
        color,
        icon,
        _topSortOrder(),
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    return _d.lastInsertRowId;
  }

  /// 新建/导入的文件夹要排的位置。
  ///
  /// 取**当前最小值再减一**，而不是"最大值加一" ——
  /// 用户的心智是"我刚建的应该在最上面（置顶之下）"，
  /// 追加到末尾会让他每次都要滚到底去找。
  ///
  /// 因为排序是 `is_pinned DESC, sort_order ASC`，
  /// 置顶的永远在前面，所以这个值只会影响非置顶之间的顺序。
  int _topSortOrder() {
    final m =
        _d
                .select(
                  'SELECT IFNULL(MIN(sort_order), 0) AS m FROM collections',
                )
                .first['m']
            as int;
    return m - 1;
  }

  /// 按层级路径确保文集存在，返回**叶子**文集的 id。
  ///
  /// 导入 `文集/小小说/2023/*.docx` 时传 `['文集','小小说','2023']`，
  /// 会逐级建出嵌套结构，而不是把整棵树压成一个平文集。
  ///
  /// 注意 `collections.name` 有 **UNIQUE 约束**（全局唯一），所以同名一律
  /// 复用已有那条，只是把它挂到需要的父级下 —— 硬插会直接违反约束。
  int? ensureCollectionPath(List<String> names, {int color = 0xFF3B82F6}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    int? parentId;
    int? leafId;

    for (final raw in names) {
      final name = raw.trim();
      if (name.isEmpty) continue;

      final hit = _d.select(
        // **不能捡起回收站里的同名文集。**
        //
        // 捡起来的话，新导入的笔记会挂在一个"看不见"的文集上：
        // 侧栏里没有它（被软删了），可笔记是活的 —— 之后清空回收站
        // 会连这些活笔记一起永久删掉（purgeCollection 那条路径）。
        // 这里优先用活着的；只剩回收站里的那条时，把它**还原**回来，
        // 让导入落到一个用户看得见、也找得回的地方。
        'SELECT id, parent_id, deleted_at FROM collections '
        'WHERE name = ? ORDER BY (deleted_at IS NULL) DESC LIMIT 1',
        <Object?>[name],
      );

      if (hit.isNotEmpty) {
        leafId = hit.first['id'] as int;
        if (hit.first['deleted_at'] != null) {
          // 连同它的子孙一起还原，否则子树还是残缺的
          final sub = <int>[
            leafId,
            ...descendantCollectionIdsIncludingTrashed(leafId),
          ];
          _d.execute(
            'UPDATE collections SET deleted_at = NULL WHERE id IN (${sub.join(',')})',
          );
        }
        final currentParent = hit.first['parent_id'] as int?;
        // 已有这条但还挂在顶层（或别的父级）时，把它挂到正确的父下。
        // 不能把它挂到自己的子孙下面，否则树会成环。
        if (parentId != null &&
            parentId != leafId &&
            !descendantCollectionIds(leafId).contains(parentId)) {
          if (currentParent != parentId) {
            _d.execute(
              'UPDATE collections SET parent_id = ? WHERE id = ?',
              <Object?>[parentId, leafId],
            );
          }
        }
      } else {
        _d.execute(
          'INSERT INTO collections (name, color, icon, sort_order, parent_id, created_at) '
          'VALUES (?,?,?,?,?,?)',
          <Object?>[name, color, 'folder', _topSortOrder(), parentId, now],
        );
        leafId = _d.lastInsertRowId;
      }
      parentId = leafId;
    }
    return leafId;
  }

  /// 新建文集。名字重复时返回 null（调用方据此提示用户）。
  ///
  /// 名字在全局唯一 —— 数据库上是 `UNIQUE` 约束。代价是不能在两个父文件夹下
  /// 各建一个同名子文件夹，好处是不用重建表（老库升级零风险）。
  int? createCollection(
    String name, {
    int color = 0xFF3B82F6,
    String icon = 'folder',
    int? parentId,
  }) {
    final n = name.trim();
    if (n.isEmpty) return null;
    // name 上的 UNIQUE 是**全表**的，回收站里的行也占着名字。
    // 所以这里不能只看"活着的有没有重名"：
    //   - 活着的同名 → 真的重复，返回 null
    //   - 只有回收站里那条同名 → 把它还原回来（否则用户会看到
    //     "名字重复"，可侧栏里根本没有这个名字，完全摸不着头脑）
    final hit = _d.select(
      'SELECT id, deleted_at FROM collections WHERE name = ?',
      <Object?>[n],
    );
    if (hit.isNotEmpty) {
      if (hit.first['deleted_at'] == null) return null;
      final id = hit.first['id'] as int;
      final sub = <int>[id, ...descendantCollectionIdsIncludingTrashed(id)];
      _d.execute(
        'UPDATE collections SET deleted_at = NULL WHERE id IN (${sub.join(',')})',
      );
      return id;
    }
    _d.execute(
      'INSERT INTO collections (name, color, icon, sort_order, parent_id, created_at) '
      'VALUES (?,?,?,?,?,?)',
      [
        n,
        color,
        icon,
        _topSortOrder(),
        parentId,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    return _d.lastInsertRowId;
  }

  /// 重命名。与已有文集重名时返回 false。
  ///
  /// 这里**必须**连回收站里的同名一起算重名：`name` 的 UNIQUE 是全表的，
  /// 只比对活着的行，重命名会直接撞约束抛异常。
  bool renameCollection(int id, String name) {
    final n = name.trim();
    if (n.isEmpty) return false;
    final clash = _d.select(
      'SELECT 1 FROM collections WHERE name = ? AND id <> ?',
      [n, id],
    );
    if (clash.isNotEmpty) return false;
    _d.execute('UPDATE collections SET name = ? WHERE id = ?', [n, id]);
    return true;
  }

  void setCollectionColor(int id, int color) =>
      _d.execute('UPDATE collections SET color = ? WHERE id = ?', [color, id]);

  void setCollectionIcon(int id, String icon) =>
      _d.execute('UPDATE collections SET icon = ? WHERE id = ?', [icon, id]);

  /// 置顶 / 取消置顶。
  ///
  /// 置顶的规则是**后置顶的排在最上面**：再置顶一个，之前那个就被顶下去，
  /// 依次类推。实现上取"其他已置顶里最小的 sort_order 再减一"，
  /// 这样它必然排在所有已置顶的前面。
  void setCollectionPinned(int id, bool pinned) {
    if (!pinned) {
      _d.execute('UPDATE collections SET is_pinned = 0 WHERE id = ?', <Object?>[
        id,
      ]);
      return;
    }

    final m =
        _d.select(
              'SELECT IFNULL(MIN(sort_order), 0) AS m FROM collections '
              'WHERE is_pinned = 1 AND id != ?',
              <Object?>[id],
            ).first['m']
            as int;

    _d.execute(
      'UPDATE collections SET is_pinned = 1, sort_order = ? WHERE id = ?',
      <Object?>[m - 1, id],
    );
  }

  /// 删除文集。
  ///
  /// 里面的笔记**不会跟着删**：外键是 ON DELETE SET NULL，
  /// 它们会变成「未分类」，可在那里找回。这一点在确认框里要讲清楚。
  int deleteCollection(int id) {
    final count =
        _d.select('SELECT COUNT(*) AS c FROM notes WHERE collection_id = ?', [
              id,
            ]).first['c']
            as int;
    _d.execute('DELETE FROM collections WHERE id = ?', [id]);
    return count;
  }

  /// 拖拽移动文件夹。
  ///
  /// [asChild] 为 true 时挂到 [targetId] 下面；否则与它**同层**，
  /// 按 [after] 决定插在它前面还是后面。
  ///
  /// 分开这两种意图是必须的：只做嵌套的话，用户想把文件夹拖到最上面
  /// 就会变成第一个文件夹的子文件夹 —— 看起来就是"置顶不管用"。
  void moveCollection(
    int draggedId,
    int targetId, {
    required bool asChild,
    bool after = false,
  }) {
    if (draggedId == targetId) return;

    final rows = _d.select(
      'SELECT id, parent_id FROM collections WHERE id = ?',
      <Object?>[targetId],
    );
    if (rows.isEmpty) return;
    final targetParent = rows.first['parent_id'] as int?;

    final parentId = asChild ? targetId : targetParent;
    if (!setCollectionParent(draggedId, parentId)) return;

    if (asChild) return;

    // 同层重排：只重排这一层的兄弟，别的层级不受影响
    final siblings = _d
        .select(
          'SELECT id FROM collections WHERE parent_id IS ? AND id <> ? '
          'ORDER BY sort_order ASC, name ASC',
          <Object?>[parentId, draggedId],
        )
        .map((r) => r['id'] as int)
        .toList();

    final at = siblings.indexOf(targetId);
    final insertAt = at < 0 ? siblings.length : (after ? at + 1 : at);
    siblings.insert(insertAt.clamp(0, siblings.length), draggedId);
    reorderCollections(siblings);
  }

  /// 把一个文件夹直接挪到顶层末尾。
  void moveCollectionToTopLevel(int id) {
    setCollectionParent(id, null);
    final tops =
        _d
            .select(
              'SELECT id FROM collections WHERE parent_id IS NULL AND id <> ? '
              'ORDER BY sort_order ASC, name ASC',
              <Object?>[id],
            )
            .map((r) => r['id'] as int)
            .toList()
          ..add(id);
    reorderCollections(tops);
  }

  void reorderCollections(List<int> orderedIds) {
    if (orderedIds.isEmpty) return;
    _d.execute('BEGIN');
    try {
      final stmt = _d.prepare(
        'UPDATE collections SET sort_order = ? WHERE id = ?',
      );
      for (var i = 0; i < orderedIds.length; i++) {
        stmt.execute(<Object?>[i, orderedIds[i]]);
      }
      stmt.close();
      _d.execute('COMMIT');
    } catch (_) {
      _d.execute('ROLLBACK');
      rethrow;
    }
  }
}
