/// 笔记仓储层。所有 SQL 集中在这里，UI 层不直接碰数据库。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../core/utils/filename_sort.dart';
import '../../core/utils/text_stats.dart';
import '../../core/utils/wiki_links.dart';
import '../db/app_database.dart';
import '../db/query_scope.dart';
import '../models.dart';

/// 排序**字段**。与方向分开，对应 Windows 资源管理器那种
/// 「先选字段、再选递增/递减」的两段式菜单。
part 'note_aggregates.dart';
part 'note_collections.dart';
part 'note_mutations.dart';
part 'note_queries.dart';
part 'note_tags.dart';
part 'note_trash.dart';

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

}
