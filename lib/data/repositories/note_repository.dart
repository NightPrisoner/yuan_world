/// 笔记仓储层。所有 SQL 集中在这里，UI 层不直接碰数据库。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../core/utils/filename_sort.dart';
import '../../core/utils/text_stats.dart';
import '../db/app_database.dart';
import '../db/query_scope.dart';
import '../models.dart';

/// 排序**字段**。与方向分开，对应 Windows 资源管理器那种
/// 「先选字段、再选递增/递减」的两段式菜单。
enum SortField {
  // 名字要写清楚"依据到底是什么"：
  // 「创建日期」听着像文章创作时间，实际是这条**记录**进入应用的时间；
  // 导入的笔记全挤在几秒内，和「最后编辑」几乎同序，用户会以为排序坏了。
  //
  // ⚠️ **列名必须带 `n.` 前缀**：listNotes 是
  // `notes n LEFT JOIN collections c`，而两张表**都有 `created_at`**。
  // 不写前缀就是歧义列，SQLite 直接抛异常 → 列表永不刷新，
  // 表现出来就是"菜单勾上了，列表纹丝不动"。
  updated('最后编辑', 'n.updated_at'),
  created('创建日期', 'n.created_at'),
  // 名称排序走预生成的键，对齐 Windows 文件名规则（数字按数值、忽略大小写）
  title('名称', 'n.sort_key'),
  charCount('字数', 'n.char_count');

  const SortField(this.label, this.column);
  final String label;
  final String column;

  /// 这一项排序时，列表里该显示哪个时间。
  ///
  /// 必须跟着排序字段走：按「创建日期」排却在每条上显示别的日期，
  /// 用户看到的就是"顺序不对"——哪怕排序本身完全正确。
  DateTime timeOf(Note n) => switch (this) {
    SortField.updated => n.updatedAt,
    // 名称 / 字数跟时间无关，用创建时间，至少是稳定且说得通的
    _ => n.createdAt,
  };
}

/// 排序**方向**。
enum SortDir {
  asc('递增', 'ASC', '↑'),
  desc('递减', 'DESC', '↓');

  const SortDir(this.label, this.sql, this.arrow);
  final String label;
  final String sql;
  final String arrow;
}

/// 列表排序方式 = 字段 + 方向。
///
/// 之前是 9 个平铺的选项（「最近修改 ↓」「最早修改 ↑」…），
/// 选起来像在做排列组合题。拆成两段之后，字段和方向各点一次就完事，
/// 也和用户在文件管理器里的习惯一致。
enum NoteSort {
  updatedDesc(SortField.updated, SortDir.desc),
  updatedAsc(SortField.updated, SortDir.asc),
  createdDesc(SortField.created, SortDir.desc),
  createdAsc(SortField.created, SortDir.asc),
  titleAsc(SortField.title, SortDir.asc),
  titleDesc(SortField.title, SortDir.desc),
  charCountDesc(SortField.charCount, SortDir.desc),
  charCountAsc(SortField.charCount, SortDir.asc);

  const NoteSort(this.field, this.dir);
  final SortField field;
  final SortDir dir;

  String get orderBy => '${field.column} ${dir.sql}';

  /// 列表栏上方那行说明用，带上方向箭头。
  String get label => '${field.label} ${dir.arrow}';

  /// 纯字段名，菜单里勾选状态用。
  String get fieldLabel => field.label;

  /// 按「字段 + 方向」取到对应项。
  ///
  /// 菜单位里改字段时保留方向、改方向时保留字段 ——
  /// 用户的两次点击是独立的，不该互相重置。
  static NoteSort of(SortField f, SortDir d) =>
      values.firstWhere((s) => s.field == f && s.dir == d);
}

/// 列表筛选项。
class NoteFilter {
  const NoteFilter({
    this.collectionId,
    this.tag,
    this.favoritesOnly = false,
    this.uncategorizedOnly = false,
    this.query = '',
    this.sort = NoteSort.updatedDesc,
    this.hiddenOnly = false,
    this.archivedOnly = false,
    this.includeDescendants = true,
  });

  final int? collectionId;
  final String? tag;
  final bool favoritesOnly;

  /// 只看没有归入任何文集的笔记。
  final bool uncategorizedOnly;

  final String query;
  final NoteSort sort;

  /// 只看隐私空间里的内容。默认（false）是**只看非隐藏内容**。
  final bool hiddenOnly;

  /// 只看归档的笔记。默认（false）是**只看未归档的** ——
  /// 归档的意义就是"从日常列表里挪走"，两边不能同时为真。
  final bool archivedOnly;

  /// 选中某个文件夹时，是否连同子文件夹里的笔记一起列出。
  /// 对"这个分类下有什么"的直觉来说，默认应该带上子文件夹。
  final bool includeDescendants;

  NoteFilter copyWith({
    int? collectionId,
    bool clearCollection = false,
    String? tag,
    bool clearTag = false,
    bool? favoritesOnly,
    bool? uncategorizedOnly,
    String? query,
    NoteSort? sort,
    bool? hiddenOnly,
    bool? archivedOnly,
    bool? includeDescendants,
  }) => NoteFilter(
    collectionId: clearCollection ? null : (collectionId ?? this.collectionId),
    tag: clearTag ? null : (tag ?? this.tag),
    favoritesOnly: favoritesOnly ?? this.favoritesOnly,
    uncategorizedOnly: uncategorizedOnly ?? this.uncategorizedOnly,
    query: query ?? this.query,
    sort: sort ?? this.sort,
    hiddenOnly: hiddenOnly ?? this.hiddenOnly,
    archivedOnly: archivedOnly ?? this.archivedOnly,
    includeDescendants: includeDescendants ?? this.includeDescendants,
  );
}

/// 总览统计。
class Overview {
  const Overview({
    required this.noteCount,
    required this.totalChars,
    required this.totalWords,
    required this.imageCount,
    required this.collectionCount,
    required this.tagCount,
    required this.favoriteCount,
    required this.firstAt,
    required this.lastAt,
  });

  final int noteCount;
  final int totalChars;
  final int totalWords;
  final int imageCount;
  final int collectionCount;
  final int tagCount;
  final int favoriteCount;
  final DateTime? firstAt;
  final DateTime? lastAt;
}

/// 一个时间点的写作量。
class TrendPoint {
  const TrendPoint({required this.bucket, required this.count, required this.chars});
  final String bucket; // yyyy-MM
  final int count;
  final int chars;
}

/// 文集分布。
class CollectionSlice {
  const CollectionSlice({
    required this.name,
    required this.color,
    required this.count,
    required this.chars,
  });
  final String name;
  final int color;
  final int count;
  final int chars;
}

class NoteRepository {
  NoteRepository(this.db);

  final AppDatabase db;

  Database get _d => db.db;

  /// 列表查询统一的列清单。抽出来是为了让回收站和普通列表
  /// 保证字段完全一致 —— 少一列 `Note.fromRow` 就会拿到 null。
  static String _noteColumns() =>
      'n.id, n.title, n.excerpt, n.author, n.source_url, n.collection_id, '
      'n.published_at, n.created_at, n.updated_at, n.char_count, n.word_count, '
      'n.image_count, n.is_pinned, n.is_favorite, n.is_archived, n.is_hidden, '
      'n.deleted_at, n.sort_index, '
      'n.cover_image, c.name AS collection_name, c.color AS collection_color ';

  // ── 查询 ────────────────────────────────────────────────────────────────

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
        'SELECT ${_noteColumns()} '
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
      'SELECT ${_noteColumns()} FROM notes n '
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
      _d.select('SELECT COUNT(*) AS c FROM notes WHERE deleted_at IS NOT NULL')
          .first['c'] as int;

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
      _d.execute(
        'DELETE FROM collections WHERE id IN (${cols.join(',')})',
      );
    }
    _d.execute('DELETE FROM notes WHERE deleted_at IS NOT NULL');
    _purgeMedia(doomed);
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
    final n = _d.select(
      'SELECT COUNT(*) AS c FROM notes '
      'WHERE deleted_at IS NOT NULL AND deleted_at < ?',
      <Object?>[cutoff],
    ).first['c'] as int;

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

  /// 全部文集。
  ///
  /// [includeHidden] 为 false（默认）时只看非隐藏的——隐私空间的东西
  /// 不能出现在左栏、选择器、统计里。
  List<Collection> allCollections({bool includeHidden = false}) {
    final rows = _d.select(
      'SELECT c.*, '
      '(SELECT COUNT(*) FROM notes n WHERE n.collection_id = c.id '
      ' AND ${liveNote("n")}) AS note_count '
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

    return <Collection>[
      for (final c in list) c.withNoteCount(total(c.id)),
    ];
  }

  /// 某个文集的直接子文件夹。
  List<Collection> childCollections(int? parentId, {bool includeHidden = false}) =>
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
    _d.execute(
      'UPDATE collections SET parent_id = ? WHERE id = ?',
      <Object?>[parentId, id],
    );
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

  /// 隐私空间里的内容量，用于在设置页显示。
  ({int notes, int collections}) hiddenCounts() {
    final n = _d.select(
      'SELECT COUNT(*) AS c FROM notes WHERE is_hidden = 1 AND deleted_at IS NULL',
    ).first['c'] as int;
    final c = _d.select(
      'SELECT COUNT(*) AS c FROM collections WHERE is_hidden = 1 AND deleted_at IS NULL',
    ).first['c'] as int;
    return (notes: n, collections: c);
  }

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

  int ensureCollection(String name, {int color = 0xFF3B82F6, String icon = 'folder'}) {
    final hit = _d.select('SELECT id FROM collections WHERE name = ?', [name]);
    if (hit.isNotEmpty) return hit.first['id'] as int;
    _d.execute(
      'INSERT INTO collections (name, color, icon, sort_order, created_at) VALUES (?,?,?,?,?)',
      [name, color, icon, _topSortOrder(), DateTime.now().millisecondsSinceEpoch],
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
    final m = _d
        .select('SELECT IFNULL(MIN(sort_order), 0) AS m FROM collections')
        .first['m'] as int;
    return m - 1;
  }

  /// 按层级路径确保文集存在，返回**叶子**文集的 id。
  ///
  /// 导入 `文集/小小说/2023/*.docx` 时传 `['文集','小小说','2023']`，
  /// 会逐级建出嵌套结构，而不是把整棵树压成一个平文集。
  ///
  /// 注意 `collections.name` 有 **UNIQUE 约束**（全局唯一），所以同名一律
  /// 复用已有那条，只是把它挂到需要的父级下 —— 硬插会直接违反约束。
  int? ensureCollectionPath(
    List<String> names, {
    int color = 0xFF3B82F6,
  }) {
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
          final sub = <int>[leafId, ...descendantCollectionIdsIncludingTrashed(leafId)];
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
      _d.execute(
        'UPDATE collections SET is_pinned = 0 WHERE id = ?',
        <Object?>[id],
      );
      return;
    }

    final m = _d.select(
      'SELECT IFNULL(MIN(sort_order), 0) AS m FROM collections '
      'WHERE is_pinned = 1 AND id != ?',
      <Object?>[id],
    ).first['m'] as int;

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
    final count = _d
        .select('SELECT COUNT(*) AS c FROM notes WHERE collection_id = ?', [id])
        .first['c'] as int;
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
    final tops = _d
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

  void reorderCollections(List<int> orderedIds) {
    if (orderedIds.isEmpty) return;
    _d.execute('BEGIN');
    try {
      final stmt = _d.prepare('UPDATE collections SET sort_order = ? WHERE id = ?');
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
}
