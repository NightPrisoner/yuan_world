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

    // 写正文时可能被"改标题级联"改写（见下），所以正文/摘要先在这两个变量上过一手。
    String? nextContent = content;
    String? nextExcerpt = excerpt;
    var linkRewritten = false;

    if (title != null) {
      // **改标题要把指向旧标题的双链一起改掉**（用户明确要求"改名不能让链接断"）。
      //
      // 双链存的是标题字面量，不改的话：目标一改名，所有指向它的 `[[旧标题]]`
      // 就全断了。改写放在这里（而不是编辑器那层）是因为"改标题"的入口不止
      // 一个：编辑器保存、批量重命名、导入回写，任何一个漏掉都会留下断链。
      final before = _d.select(
        'SELECT title FROM notes WHERE id = ?',
        <Object?>[id],
      );
      final oldTitle = before.isEmpty ? null : before.first['title'] as String?;
      set('title', title);
      // 排序键跟着标题走，否则改了标题排序还是旧的
      set('sort_key', windowsSortKey(title));
      if (oldTitle != null && oldTitle.trim() != title.trim()) {
        if (content != null) {
          // 调用方同时要写正文：正文里指向自己的那条 `[[旧标题]]` 也得改成
          // 新标题，然后自己交给下面那句 `set('content')`。
          //
          // 以前是先级联（把包括自己在内的行都改好）、紧接着又被传进来的
          // 旧正文覆盖回去 —— 自引用双链就这么断了。
          nextContent = rewriteWikiLinks(content, from: oldTitle, to: title);
          if (excerpt != null) {
            nextExcerpt = rewriteWikiLinks(
              excerpt,
              from: oldTitle,
              to: title,
            );
          }
          linkRewritten = nextContent != content;
          _cascadeLinkRename(oldTitle, title, skipId: id);
        } else {
          _cascadeLinkRename(oldTitle, title);
        }
      }
    }
    if (nextContent != null) set('content', nextContent);
    if (nextExcerpt != null) set('excerpt', nextExcerpt);
    // 正文被级联改写（改标题连带到自己）时，字数统计必须跟着走 ——
    // 否则改一次标题就制造一次永久偏差：概览总字数、长文排行、
    // 篇幅分布、趋势里的字数全都会偏。
    if (linkRewritten && nextContent != null) {
      charCount ??= countChars(nextContent);
      wordCount ??= countWords(nextContent);
      imageCount ??= countNoteMedia(nextContent).images;
    }
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
    } else if (nextContent != null) {
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
        final first = firstImageOf(nextContent);
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

  /// 把**全库**正文里指向 [oldTitle] 的双链改写成 [newTitle]。
  ///
  /// 先 `LIKE '%[[旧标题%'` 粗筛（几十毫秒内的事），再用
  /// [rewriteWikiLinks] 精确认——和反向链接查询同一套口径，
  /// 免得 `[[旧标题2]]` 被 `[[旧标题` 误伤。
  ///
  /// 摘要（excerpt）里也可能带着链接文字，所以一并重写。
  /// **不改 `updated_at`**：这不是用户对那篇笔记的编辑，把"最后编辑"
  /// 时间搅乱了，按时间排序的列表会莫名其妙地跳。
  ///
  /// 但**字数必须跟着重算**：链接改长改短，正文字数就变了。以前只写
  /// `content`/`excerpt`，于是改一次标题就在别的笔记上留下一处永久偏差。
  ///
  /// [skipId] 用于"调用方自己马上要写正文"的情况（见 [updateNote]）：
  /// 那一行由调用方连同正文一起写，这里别抢。
  void _cascadeLinkRename(String oldTitle, String newTitle, {int? skipId}) {
    final rows = _d.select(
      'SELECT id, content FROM notes WHERE content LIKE ?',
      <Object?>['%[[${oldTitle.trim()}%'],
    );
    for (final r in rows) {
      final id = r['id'] as int;
      if (id == skipId) continue;
      final content = (r['content'] as String?) ?? '';
      final next = rewriteWikiLinks(content, from: oldTitle, to: newTitle);
      if (next == content) continue;
      _d.execute(
        'UPDATE notes SET content = ?, excerpt = ?, char_count = ?, '
        'word_count = ?, image_count = ? WHERE id = ?',
        <Object?>[
          next,
          makeExcerpt(next),
          countChars(next),
          countWords(next),
          countNoteMedia(next).images,
          id,
        ],
      );
    }
  }

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
