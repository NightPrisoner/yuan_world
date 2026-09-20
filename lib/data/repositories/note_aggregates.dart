/// NoteRepository 的维护与聚合部分。
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

extension NoteAggregates on NoteRepository {
  /// 一次性校正：把导入笔记的「最后编辑」对齐到**原文的编辑时间**。
  ///
  /// 旧导入代码把 `updated_at` 写成了"导入这一刻"，于是几十篇全挤在几秒内，
  /// 「最后编辑」排序等于没排 —— 这正是用户看到的"顺序很乱"。
  ///
  /// 而 Word 文档头里的「编辑于 2023年09月10日 05:13」本来就是这篇文章
  /// 最后被编辑的时间，用它才符合直觉。
  ///
  /// 只在 `updated_at` **晚于** `published_at` 时才改（也就是"导入之后
  /// 从没在应用里编辑过"的那些）；真在应用里改过的，时间保持不动。
  /// 返回校正的篇数。
  int alignImportedTimes() {
    const cond = 'published_at IS NOT NULL AND updated_at > published_at';
    final n =
        _d.select('SELECT COUNT(*) AS c FROM notes WHERE $cond').first['c']
            as int;
    if (n == 0) return 0;
    _d.execute('UPDATE notes SET updated_at = published_at WHERE $cond');
    return n;
  }

  /// 给存量笔记补排序键。
  ///
  /// v8 只是加了列（默认空串），老数据得回填一次 ——
  /// 否则按名称排序时所有笔记的键都是空串，顺序完全乱掉。
  int backfillSortKeys() {
    final rows = _d.select(
      "SELECT id, title FROM notes WHERE sort_key = ''",
    );
    if (rows.isEmpty) return 0;
    for (final r in rows) {
      _d.execute(
        'UPDATE notes SET sort_key = ? WHERE id = ?',
        <Object?>[windowsSortKey((r['title'] as String?) ?? ''), r['id']],
      );
    }
    return rows.length;
  }

  /// 给「有图片但没有头图」的笔记补上头图。  ///
  /// 头图的默认值就是正文里的第一张图。导入时已经会设，这里负责
  /// **存量数据**：老库里的笔记没有这个字段，启动时补一次。
  /// 返回补齐的篇数。
  int backfillCovers() {
    final rows = _d.select(
      "SELECT id, content FROM notes "
      "WHERE (cover_image IS NULL OR cover_image = '') AND image_count > 0",
    );
    var fixed = 0;
    for (final r in rows) {
      final first = firstImageOf((r['content'] as String?) ?? '');
      if (first == null) continue;
      _d.execute(
        'UPDATE notes SET cover_image = ? WHERE id = ?',
        <Object?>[first, r['id']],
      );
      fixed++;
    }
    return fixed;
  }

  Overview overview({bool hiddenOnly = false}) {
    // 普通空间排除隐藏项；隐私空间反过来，只看隐藏项。
    //
    // **所有聚合共用同一个 scope。** 以前只有 note_count/字数用了它，
    // 而收藏数、文集数、标签数、起止日期各自漏掉了 `deleted_at IS NULL`
    // （收藏数连 `is_archived` 也没排）—— 于是把一篇收藏过的笔记丢进
    // 回收站，侧栏"收藏 1"还在，点进去却是空的。
    // 两种别名各备一份：同一个 SQL 里既有 `FROM notes`（不带别名）也有
    // `JOIN notes n`。SQLite 在表起了别名之后**不认原名** —— 用错一种
    // 就是 `no such column: notes.is_archived`。所以别名显式传给口径函数，
    // 由调用点自己负责看对。
    final scope = hiddenOnly ? hiddenNote('notes') : liveNote('notes');
    final scopeN = hiddenOnly ? hiddenNote('n') : liveNote('n');
    // 文集/标签这类"结构"只按隐私空间区分，但一样要排掉回收站。
    // **别名是 collections，别顺手写成 notes** —— 这条查的是文集表。
    final liveScope = hiddenOnly
        ? 'collections.is_hidden = 1 AND collections.deleted_at IS NULL'
        : liveCollection('collections');
    final r = _d.select('''
      SELECT
        (SELECT COUNT(*) FROM notes WHERE $scope) AS note_count,
        (SELECT IFNULL(SUM(char_count),0) FROM notes WHERE $scope) AS total_chars,
        (SELECT IFNULL(SUM(word_count),0) FROM notes WHERE $scope) AS total_words,
        (SELECT IFNULL(SUM(image_count),0) FROM notes WHERE $scope) AS image_count,
        (SELECT COUNT(*) FROM collections WHERE $liveScope) AS collection_count,
        (SELECT COUNT(DISTINCT nt.tag_id) FROM note_tags nt
           JOIN notes n ON n.id = nt.note_id
          WHERE $scopeN) AS tag_count,
        (SELECT COUNT(*) FROM notes WHERE is_favorite = 1 AND $scope) AS favorite_count,
        (SELECT MIN(IFNULL(published_at, created_at)) FROM notes WHERE $scope) AS first_at,
        (SELECT MAX(IFNULL(published_at, created_at)) FROM notes WHERE $scope) AS last_at
    ''').first;
    DateTime? dt(Object? v) =>
        v == null ? null : DateTime.fromMillisecondsSinceEpoch(v as int);
    return Overview(
      noteCount: r['note_count'] as int,
      totalChars: r['total_chars'] as int,
      totalWords: r['total_words'] as int,
      imageCount: r['image_count'] as int,
      collectionCount: r['collection_count'] as int,
      tagCount: r['tag_count'] as int,
      favoriteCount: r['favorite_count'] as int,
      firstAt: dt(r['first_at']),
      lastAt: dt(r['last_at']),
    );
  }

  /// 按月聚合的写作量趋势。
  List<TrendPoint> monthlyTrend() {
    final rows = _d.select('''
      SELECT strftime('%Y-%m', IFNULL(published_at, created_at)/1000, 'unixepoch', 'localtime') AS bucket,
             COUNT(*) AS cnt, IFNULL(SUM(char_count),0) AS chars
      FROM notes WHERE ${liveNote("notes")}
      GROUP BY bucket ORDER BY bucket ASC
    ''');
    return rows
        .where((r) => r['bucket'] != null)
        .map((r) => TrendPoint(
              bucket: r['bucket'] as String,
              count: r['cnt'] as int,
              chars: r['chars'] as int,
            ))
        .toList();
  }

  List<CollectionSlice> collectionDistribution() {
    final rows = _d.select('''
      SELECT IFNULL(c.name,'未归类') AS name,
             IFNULL(c.color, 0xFF94A3B8) AS color,
             COUNT(n.id) AS cnt,
             IFNULL(SUM(n.char_count),0) AS chars
      FROM notes n LEFT JOIN collections c ON c.id = n.collection_id
      WHERE ${liveNote("n")}
      GROUP BY c.id ORDER BY cnt DESC
    ''');
    return rows
        .map((r) => CollectionSlice(
              name: r['name'] as String,
              color: r['color'] as int,
              count: r['cnt'] as int,
              chars: r['chars'] as int,
            ))
        .toList();
  }

  /// 活跃度热力图数据：{ 'yyyy-MM-dd': 事件数 }
  Map<String, int> activityByDay() {
    final rows = _d.select(
      'SELECT e.day, COUNT(*) AS cnt FROM note_events e '
      // 这里以前只写了 `n.is_hidden = 0` —— 归档的和回收站里的笔记
      // 活跃度照样被算进来。同一类遗漏，一起收进公共口径
      'JOIN notes n ON n.id = e.note_id AND ${liveNote("n")} '
      'GROUP BY e.day ORDER BY e.day ASC',
    );
    return {for (final r in rows) r['day'] as String: r['cnt'] as int};
  }

  /// 字数排行前 N 的笔记。
  List<Note> topNotesByLength({int limit = 10}) {
    final rows = _d.select(
      'SELECT n.id, n.title, n.excerpt, n.char_count, n.word_count, n.image_count, '
      'n.created_at, n.updated_at, n.published_at, n.collection_id, n.author, n.source_url, '
      'n.is_pinned, n.is_favorite, n.is_archived, n.is_hidden, n.sort_index, n.cover_image, '
      'c.name AS collection_name, c.color AS collection_color '
      'FROM notes n LEFT JOIN collections c ON c.id = n.collection_id '
      'WHERE ${liveNote("n")} '
      'ORDER BY n.char_count DESC LIMIT ?',
      [limit],
    );
    return rows.map((r) => Note.fromRow(r)).toList();
  }
}
