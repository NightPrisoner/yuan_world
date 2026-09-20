/// NoteRepository 的写入部分。
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

extension NoteMutations on NoteRepository {
  int insertNote({
    required String title,
    required String content,
    required String excerpt,
    String author = '',
    String sourceUrl = '',
    int? collectionId,
    DateTime? publishedAt,
    String? coverImage,
    int charCount = 0,
    int wordCount = 0,
    int imageCount = 0,
    List<String> tags = const [],
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    final now = DateTime.now();
    final ts = (createdAt ?? now).millisecondsSinceEpoch;
    // 导入的笔记：用**文件本身**的时间，而不是"导入这一刻"。
    // 否则 76 篇笔记的创建时间全挤在几秒内，按时间排序毫无意义。
    final uts = (updatedAt ?? createdAt ?? now).millisecondsSinceEpoch;
    final stmt = _d.prepare(
      'INSERT INTO notes (title, content, excerpt, author, source_url, collection_id, '
      'published_at, created_at, updated_at, char_count, word_count, image_count, cover_image, sort_key) '
      'VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
    );
    stmt.execute([
      title,
      content,
      excerpt,
      author,
      sourceUrl,
      collectionId,
      publishedAt?.millisecondsSinceEpoch,
      ts,
      uts,
      charCount,
      wordCount,
      imageCount,
      // 没显式给头图就用正文第一张图兜底
      coverImage ?? firstImageOf(content),
      // 排序键：插入时就算好，之后改标题会跟着更新
      windowsSortKey(title),
    ]);
    stmt.close();
    final id = _d.lastInsertRowId;
    if (tags.isNotEmpty) setNoteTags(id, tags);
    logEvent(id, 'create');
    return id;
  }

  void updateNote({
    required int id,
    String? title,
    String? content,
    String? excerpt,
    int? collectionId,
    bool clearCollection = false,
    int? charCount,
    int? wordCount,
    int? imageCount,
    String? coverImage,
    List<String>? tags,
    bool touch = true,
  }) {
    final sets = <String>[];
    final args = <Object?>[];
    void set(String col, Object? v) {
      sets.add('$col = ?');
      args.add(v);
    }

    if (title != null) {
      set('title', title);
      // 排序键跟着标题走，否则改了标题排序还是旧的
      set('sort_key', windowsSortKey(title));
    }
    if (content != null) set('content', content);
    if (excerpt != null) set('excerpt', excerpt);
    if (clearCollection) {
      sets.add('collection_id = NULL');
    } else if (collectionId != null) {
      set('collection_id', collectionId);
    }
    if (charCount != null) set('char_count', charCount);
    if (wordCount != null) set('word_count', wordCount);
    // 图片数也要跟着正文走。之前这里没有它，于是**在编辑器里插了图，
    // 列表和详情页的"N 图"永远不变** —— 那个数字只在导入时写过一次。
    if (imageCount != null) set('image_count', imageCount);
    if (coverImage != null) {
      set('cover_image', coverImage);
    } else if (content != null) {
      // 没显式给头图时用正文第一张图兜底 —— 但**只在还没设过头图时**，
      // 否则用户手动选的头图会被每次自动保存覆盖掉。
      final cur = _d.select(
        'SELECT cover_image FROM notes WHERE id = ?',
        <Object?>[id],
      );
      final existing = cur.isEmpty ? null : cur.first['cover_image'] as String?;
      // **用户明确选过"不设置头图"就不能再自动补。**
      // 以前只看 isEmpty，于是点了"不设置头图"之后只要再编辑一下正文
      // （触发一次自动保存），头图就自己回来了 —— 用户会觉得这开关坏了。
      if (existing != kCoverNone && (existing == null || existing.isEmpty)) {
        final first = firstImageOf(content);
        if (first != null) set('cover_image', first);
      }
    }
    // 导入流程会紧跟着 insertNote 回写一次正文，那次**不能碰修改时间** ——
    // 否则刚按"文件修改时间"设好的值会被冲成"现在"，
    // 「最后编辑」排序又变回一堆挤在同一秒的记录。
    if (touch) set('updated_at', DateTime.now().millisecondsSinceEpoch);

    args.add(id);
    _d.execute('UPDATE notes SET ${sets.join(', ')} WHERE id = ?', args);
    if (tags != null) setNoteTags(id, tags);
    // 导入时的回写不是用户编辑，不该记成一次 edit
    if (touch) logEvent(id, 'edit');
  }

  void setPinned(int id, bool value) =>
      _d.execute('UPDATE notes SET is_pinned = ? WHERE id = ?', [value ? 1 : 0, id]);

  void setFavorite(int id, bool value) => _d
      .execute('UPDATE notes SET is_favorite = ? WHERE id = ?', [value ? 1 : 0, id]);

  void setArchived(int id, bool value) => _d
      .execute('UPDATE notes SET is_archived = ? WHERE id = ?', [value ? 1 : 0, id]);

  // ── 批量操作 ────────────────────────────────────────────────────────────
  //
  // 多选之后一次改几十篇，逐条执行会慢得肉眼可见，所以都走一条 IN 语句。

  void setNotesArchived(Iterable<int> ids, bool value) {
    final list = ids.toList();
    if (list.isEmpty) return;
    _d.execute(
      'UPDATE notes SET is_archived = ?, updated_at = ? '
      'WHERE id IN (${list.join(',')})',
      <Object?>[value ? 1 : 0, DateTime.now().millisecondsSinceEpoch],
    );
  }

  void setNotesHidden(Iterable<int> ids, bool value) {
    final list = ids.toList();
    if (list.isEmpty) return;
    _d.execute(
      'UPDATE notes SET is_hidden = ? WHERE id IN (${list.join(',')})',
      <Object?>[value ? 1 : 0],
    );
  }

  // ── 回收站 ──────────────────────────────────────────────────────────────
  //
  // 删除一律**软删除**：只打一个 deleted_at 时间戳。真删要用户
  // 在回收站里明确点"彻底删除"，或者等自动清理到期。
  // 这样误删能捞回来，而且"什么时候清掉"由用户决定。

  /// 把笔记移到某个文集（传 null 表示移出到「未分类」）。
  void moveNoteToCollection(int noteId, int? collectionId) {
    _d.execute(
      'UPDATE notes SET collection_id = ?, updated_at = ? WHERE id = ?',
      <Object?>[collectionId, DateTime.now().millisecondsSinceEpoch, noteId],
    );
  }

  /// 批量移动，供多选场景使用。
  void moveNotesToCollection(Iterable<int> noteIds, int? collectionId) {
    final ids = noteIds.toList();
    if (ids.isEmpty) return;
    _d.execute(
      'UPDATE notes SET collection_id = ?, updated_at = ? '
      'WHERE id IN (${ids.join(',')})',
      <Object?>[collectionId, DateTime.now().millisecondsSinceEpoch],
    );
  }

  // ── 事件 ────────────────────────────────────────────────────────────────

  void logEvent(int noteId, String kind) {
    final now = DateTime.now();
    final day =
        '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    _d.execute(
      'INSERT INTO note_events (note_id, kind, day, at) VALUES (?,?,?,?)',
      [noteId, kind, day, now.millisecondsSinceEpoch],
    );
  }

  // ── 设置 ────────────────────────────────────────────────────────────────

  String? getSetting(String key) {
    final rows = _d.select('SELECT value FROM settings WHERE key = ?', [key]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  void setSetting(String key, String value) {
    _d.execute(
      'INSERT INTO settings (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }

  // ── 统计（可视化数据源） ────────────────────────────────────────────────
  //
  // 这里所有查询都带 `is_hidden = 0`：隐私空间的内容**不纳入任何统计**。
  // 用户把东西藏起来，就是不想在任何地方看到它的痕迹，包括数字。
}
