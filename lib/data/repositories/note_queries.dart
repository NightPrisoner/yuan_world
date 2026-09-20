/// NoteRepository 的查询部分。
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

extension NoteQueries on NoteRepository {
  /// 按标题精确找一篇笔记（`[[双链]]` 跳转用）。
  ///
  /// 去掉首尾空白再比：标题里带个尾空格是手滑，不该因此找不到。
  /// 同名取**最近改过的那篇** —— 总得有个确定的说法。
  /// 回收站里的不算：链到一个已删的笔记，点进去是空的更莫名其妙。
  int? noteIdByTitle(String title) {
    final t = title.trim();
    if (t.isEmpty) return null;
    final rows = _d.select(
      'SELECT id FROM notes WHERE title = ? AND ${liveNote("notes")} '
      'ORDER BY updated_at DESC LIMIT 1',
      <Object?>[t],
    );
    return rows.isEmpty ? null : rows.first['id'] as int;
  }

  /// 谁的正文里链到了这篇笔记（反向链接）。
  ///
  /// 口径：只算**活着的**笔记（非归档、非隐藏、不在回收站），
  /// 也不含自己 —— 和列表、标签、统计保持同一套"什么算存在"。
  ///
  /// 实现是 `content LIKE`：正文里可能写 `[[标题]]` 也可能写
  /// `[[标题|显示名]]`，所以用 `[[标题` 前缀匹配再交给
  /// `parseWikiLinks` 复核（避免"标题是别人前缀"的误命中）。
  List<Note> backlinksOf(int noteId, {int limit = 50, bool hiddenOnly = false}) {
    final target = getNote(noteId);
    if (target == null) return const <Note>[];
    final name = target.title.trim();
    if (name.isEmpty) return const <Note>[];

    final rows = _d.select(
      // `n.*` 而不是 `_noteColumns()`：后者为了列表性能不带 content，
      // 而这里正要看正文
      'SELECT n.* FROM notes n '
      'WHERE n.id != ? AND n.content LIKE ? AND '
      '${hiddenOnly ? hiddenNote("n") : liveNote("n")} '
      'ORDER BY n.updated_at DESC LIMIT ?',
      <Object?>[noteId, '%[[$name%', limit],
    );
    final notes = rows.map((r) => Note.fromRow(r)).toList();
    _attachTags(notes);
    // LIKE 只是粗筛（`[[标题` 也能命中 `[[标题B]]`），这里精确复核
    return notes
        .where((n) => wikiTargetsIn(n.content).contains(name))
        .toList();
  }

  /// 按筛选条件取笔记列表。默认只取正文元数据，不含大字段 content。
  List<Note> listNotes(NoteFilter f, {int limit = 500, int offset = 0}) {
    final where = <String>[];
    final args = <Object?>[];

    // 隐藏项默认不出现在任何列表里；隐私空间里则只看隐藏项
    where.add(f.hiddenOnly ? 'n.is_hidden = 1' : 'n.is_hidden = 0');
    // 归档同理 —— 之前这里漏了，归档之后笔记还在列表里，
    // 「归档」等于一个没有任何效果的动作
    where.add(f.archivedOnly ? 'n.is_archived = 1' : 'n.is_archived = 0');
    // 回收站里的一律不进普通列表（回收站有自己的查询）
    where.add('n.deleted_at IS NULL');

    if (f.collectionId != null) {
      if (f.includeDescendants) {
        // 带上子文件夹：用户点开一个分类，预期是"这个分类下的全部内容"
        final ids = [f.collectionId!, ...descendantCollectionIds(f.collectionId!)];
        where.add('n.collection_id IN (${ids.join(',')})');
      } else {
        where.add('n.collection_id = ?');
        args.add(f.collectionId);
      }
    }
    if (f.uncategorizedOnly) {
      where.add('n.collection_id IS NULL');
    }
    if (f.favoritesOnly) {
      where.add('n.is_favorite = 1');
    }
    if (f.tag != null && f.tag!.isNotEmpty) {
      where.add('n.id IN (SELECT nt.note_id FROM note_tags nt '
          'JOIN tags t ON t.id = nt.tag_id WHERE t.name = ?)');
      args.add(f.tag);
    }

    var from = 'notes n LEFT JOIN collections c ON c.id = n.collection_id';
    final q = f.query.trim();
    if (q.isNotEmpty) {
      if (q.length >= 3) {
        // trigram 分词器支持中文子串，用引号包成短语避免语法错误
        from += ' JOIN notes_fts fts ON fts.rowid = n.id';
        where.add('notes_fts MATCH ?');
        args.add('"${q.replaceAll('"', '""')}"');
      } else {
        // **短词（1~2 个字）也要搜正文。**
        //
        // FTS5 的 trigram 分词器要求至少 3 个字符，所以两字词只能走 LIKE；
        // 而以前这里只 LIKE 标题和摘要 —— 中文里两字词恰恰最常见
        // （"读书""会议""旅行"），用户的感受就是"明明在正文里，搜不到"。
        // 全表扫 content 在几百篇的量级完全无感（每篇几 KB）。
        where.add(
          '(n.title LIKE ? ESCAPE ? OR n.excerpt LIKE ? ESCAPE ? '
          'OR n.content LIKE ? ESCAPE ?)',
        );
        // **必须转义 % 和 _**。这两个字符在 LIKE 里是通配符，
        // 不转义的话搜一个 "%" 会把整库都匹配出来，搜 "a_b" 也会命中
        // "axb" —— 用户的感受是"搜什么都出一堆"。
        final esc = q
            .replaceAll(r'\', r'\\')
            .replaceAll('%', r'\%')
            .replaceAll('_', r'\_');
        final pat = '%$esc%';
        for (var i = 0; i < 3; i++) {
          args
            ..add(pat)
            ..add(r'\');
        }
      }
    }

    final whereSql = where.isEmpty ? '' : 'WHERE ${where.join(' AND ')}';
    final sql =
        'SELECT ${NoteRepository._noteColumns()} '
        'FROM $from $whereSql '
        // 末尾的 `n.id DESC` 是**兜底排序**：导入的笔记 created_at/updated_at
        // 往往只差几毫秒甚至完全相同，主键一分不出高下时 SQLite 会还一个
        // "任意但稳定"的顺序 —— 表现就是换了排序字段列表却纹丝不动。
        'ORDER BY n.is_pinned DESC, ${f.sort.orderBy}, n.id DESC '
        'LIMIT ? OFFSET ?';

    final rows = _d.select(sql, [...args, limit, offset]);
    final notes = rows.map((r) => Note.fromRow(r)).toList();
    _attachTags(notes);
    return notes;
  }

  /// 批量补上标签，避免 N+1 查询。
  void _attachTags(List<Note> notes) {
    if (notes.isEmpty) return;
    final ids = notes.map((n) => n.id).join(',');
    final rows = _d.select(
      'SELECT nt.note_id, t.name FROM note_tags nt '
      'JOIN tags t ON t.id = nt.tag_id WHERE nt.note_id IN ($ids)',
    );
    final map = <int, List<String>>{};
    for (final r in rows) {
      (map[r['note_id'] as int] ??= <String>[]).add(r['name'] as String);
    }
    for (var i = 0; i < notes.length; i++) {
      final t = map[notes[i].id];
      if (t != null) {
        notes[i] = _withTags(notes[i], t);
      }
    }
  }

  /// 给笔记补上标签。
  ///
  /// **必须逐个字段抄过来。** 这里漏过 `deletedAt`：回收站里的笔记
  /// 读出来 `deletedAt` 是 null，看起来和活着的笔记一模一样 ——
  /// 凡是"靠 deletedAt 判断是否已删"的地方（导出、去重、恢复）
  /// 都会判错。新增字段时记得同步这里。
  Note _withTags(Note n, List<String> tags) => Note(
    id: n.id,
    title: n.title,
    content: n.content,
    excerpt: n.excerpt,
    author: n.author,
    sourceUrl: n.sourceUrl,
    collectionId: n.collectionId,
    publishedAt: n.publishedAt,
    createdAt: n.createdAt,
    updatedAt: n.updatedAt,
    charCount: n.charCount,
    wordCount: n.wordCount,
    imageCount: n.imageCount,
    isPinned: n.isPinned,
    isFavorite: n.isFavorite,
    isArchived: n.isArchived,
    isHidden: n.isHidden,
    deletedAt: n.deletedAt,
    sortIndex: n.sortIndex,
    coverImage: n.coverImage,
    collectionName: n.collectionName,
    collectionColor: n.collectionColor,
    tags: tags,
  );

  /// 导出用：把指定的笔记（或整个文集及其子文集）**连正文**一起取出来。
  ///
  /// 为什么单独开一个方法，而不是让调用方自己拼 `listNotes` + `getNote`：
  /// `listNotes` 走的是不含 `content` 列的轻量查询（列表页只要摘要，
  /// 每行都拖着正文太贵），**拿它的结果直接去导出，出来的 docx 全是空壳**
  /// —— 用户报的"文件夹导出但是没有实际笔记内容"就是这么来的。
  /// 把"导出必须补正文"这件事收在这一个地方，别处就不会再漏。
  ///
  /// [collectionId] 给定时含所有子孙文集；[ids] 给定时按给定顺序取。
  /// 已删除/回收站里的笔记不导出。
  List<Note> notesForExport({int? collectionId, List<int>? ids}) {
    final wanted = <int>[];
    if (ids != null) {
      wanted.addAll(ids);
    } else if (collectionId != null) {
      final scope = <int>[collectionId, ...descendantCollectionIds(collectionId)];
      for (final row in _d.select(
        'SELECT id FROM notes WHERE collection_id IN '
        '(${List.filled(scope.length, '?').join(',')}) '
        'AND ${liveNote('notes')} ORDER BY sort_index, created_at',
        scope,
      )) {
        wanted.add(row['id'] as int);
      }
    }

    final out = <Note>[];
    for (final id in wanted) {
      final n = getNote(id);
      // 回收站里的不导出：用户点"导出文件夹"时并不指望把删掉的也带走
      if (n == null || n.deletedAt != null) continue;
      out.add(n);
    }
    return out;
  }

  /// 取完整笔记（含正文 content）。
  Note? getNote(int id) {
    final rows = _d.select(
      'SELECT n.*, c.name AS collection_name, c.color AS collection_color '
      'FROM notes n LEFT JOIN collections c ON c.id = n.collection_id WHERE n.id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    final tags = <String>[];
    final tr = _d.select(
      'SELECT t.name FROM note_tags nt JOIN tags t ON t.id = nt.tag_id WHERE nt.note_id = ?',
      [id],
    );
    for (final r in tr) {
      tags.add(r['name'] as String);
    }
    return _withTags(Note.fromRow(rows.first), tags);
  }

  /// 只取元数据（不含 content），详情页正文单独取，列表更快。
  Note? getNoteShallow(int id) {
    final rows = _d.select(
      'SELECT n.id, n.title, n.excerpt, n.author, n.source_url, n.collection_id, '
      'n.published_at, n.created_at, n.updated_at, n.char_count, n.word_count, '
      'n.image_count, n.is_pinned, n.is_favorite, n.is_archived, n.is_hidden, '
      'n.sort_index, '
      'n.cover_image, c.name AS collection_name, c.color AS collection_color '
      'FROM notes n LEFT JOIN collections c ON c.id = n.collection_id WHERE n.id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    return Note.fromRow(rows.first);
  }

  String getNoteContent(int id) {
    final rows = _d.select('SELECT content FROM notes WHERE id = ?', [id]);
    if (rows.isEmpty) return '';
    return (rows.first['content'] as String?) ?? '';
  }

  // ── 写入 ────────────────────────────────────────────────────────────────

  /// 全文检索，返回带高亮片段的命中。
  List<Note> search(String q, {int limit = 100}) => listNotes(
        NoteFilter(query: q, sort: NoteSort.updatedDesc),
        limit: limit,
      );

  /// 用于词云/高频词：取全部标题与摘要的原始文本，交给 Dart 侧分词。
  List<String> allTitlesAndExcerpts({int limit = 2000}) {
    final rows = _d.select(
      'SELECT title, excerpt FROM notes '
      'WHERE ${liveNote("notes")} LIMIT ?',
      [limit],
    );
    return rows.map((r) => '${r['title']} ${r['excerpt']}').toList();
  }

  /// 挑链接目标用：id + 标题 + 摘要，最近改的排前面。
  ///
  /// 单独一个方法而不是复用 [allTitlesAndExcerpts]：那个把标题和摘要**拼成
  /// 一个字符串**（给全文搜索的候选词用的），拿不回来 id，也就没法确认
  /// 选中的是哪一篇 —— 同名笔记会挑错。
  List<({int id, String title, String excerpt})> noteTitlesForPicker({
    int limit = 2000,
  }) {
    final rows = _d.select(
      'SELECT id, title, excerpt FROM notes WHERE ${liveNote("notes")} '
      'ORDER BY updated_at DESC LIMIT ?',
      [limit],
    );
    return <({int id, String title, String excerpt})>[
      for (final r in rows)
        (
          id: r['id'] as int,
          title: (r['title'] as String?) ?? '',
          excerpt: (r['excerpt'] as String?) ?? '',
        ),
    ];
  }
}
