/// 数据模型。
///
/// 注意：这一层**刻意不依赖 Flutter**（不用 `Color`、不用 `@immutable`），
/// 这样批量导入工具（tool/import_cli.dart）才能在纯 Dart 环境下复用同一套
/// 数据库与导入逻辑，而不用把整个 Flutter 引擎拉进来。
/// 颜色一律用 ARGB 整数表示，由 UI 层负责转成 `Color`。
library;

/// 文集（小米笔记里叫「文件夹」）。支持嵌套：`parentId` 非空即为子文件夹。
/// 「用户明确不要头图」的标记。
///
/// 头图有三种状态，必须能分开：
///   - `null` / `''`  —— 没设过，按正文第一张图自动派生
///   - [kCoverNone]   —— 用户**明确选了"不设置头图"**，谁也别自作主张补上
///   - 其它非空串     —— 用户指定的那张图
///
/// 为什么不能拿 `''` 兼作"不要"：自动派生的条件是"当前是空就补一张"，
/// 于是用户点了"不设置头图"之后，**只要再编辑一下正文触发自动保存，
/// 头图就自己回来了** —— 看起来像开关坏了。用一个不会被误判的标记才能
/// 把"没设过"和"明确不要"分开。
const String kCoverNone = '__none__';

/// 这篇笔记实际该显示的头图；null 表示不显示（含用户明确不要的情况）。
String? effectiveCover(String? cover) {
  if (cover == null || cover.isEmpty || cover == kCoverNone) return null;
  return cover;
}

/// 用户是否明确选择了"不设置头图"。
bool isCoverDisabled(String? cover) => cover == kCoverNone;

class Collection {
  const Collection({
    required this.id,
    required this.name,
    this.description = '',
    this.color = 0xFF3B82F6,
    this.icon = 'folder',
    this.sortOrder = 0,
    this.parentId,
    this.isHidden = false,
    this.isPinned = false,
    this.deletedAt,
    required this.createdAt,
    this.noteCount = 0,
  });

  final int id;
  final String name;
  final String description;
  final int color;
  final String icon;
  final int sortOrder;

  /// 父文件夹 id；null = 顶层。
  final int? parentId;

  /// 是否已移入隐私空间。
  final bool isHidden;

  /// 是否置顶。置顶项排在所有非置顶项之前。
  final bool isPinned;

  /// 删进回收站的时间。非空 = 在回收站里。
  final DateTime? deletedAt;

  final DateTime createdAt;

  /// 冗余字段：该文集下**本级**的笔记数（不含子文件夹），由查询附带。
  final int noteCount;

  bool get isTopLevel => parentId == null;

  factory Collection.fromRow(Map<String, Object?> r) => Collection(
    id: r['id'] as int,
    name: r['name'] as String,
    description: (r['description'] as String?) ?? '',
    color: r['color'] as int,
    icon: (r['icon'] as String?) ?? 'folder',
    sortOrder: (r['sort_order'] as int?) ?? 0,
    parentId: r['parent_id'] as int?,
    isHidden: ((r['is_hidden'] as int?) ?? 0) != 0,
    isPinned: ((r['is_pinned'] as int?) ?? 0) != 0,
    deletedAt: r['deleted_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(r['deleted_at'] as int),
    createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
    noteCount: (r['note_count'] as int?) ?? 0,
  );

  /// 换一个笔记数（父文件夹做数量累加时用）。
  Collection withNoteCount(int count) => Collection(
    id: id,
    name: name,
    description: description,
    color: color,
    icon: icon,
    sortOrder: sortOrder,
    parentId: parentId,
    isHidden: isHidden,
    isPinned: isPinned,
    createdAt: createdAt,
    noteCount: count,
  );

  Collection copyWith({int? parentId, bool clearParent = false}) => Collection(
    id: id,
    name: name,
    description: description,
    color: color,
    icon: icon,
    sortOrder: sortOrder,
    parentId: clearParent ? null : (parentId ?? this.parentId),
    isHidden: isHidden,
    isPinned: isPinned,
    deletedAt: deletedAt,
    createdAt: createdAt,
    noteCount: noteCount,
  );
}

/// 笔记。
class Note {
  const Note({
    required this.id,
    required this.title,
    required this.content,
    required this.excerpt,
    this.author = '',
    this.sourceUrl = '',
    this.collectionId,
    this.publishedAt,
    required this.createdAt,
    required this.updatedAt,
    this.charCount = 0,
    this.wordCount = 0,
    this.imageCount = 0,
    this.isPinned = false,
    this.isFavorite = false,
    this.isArchived = false,
    this.isHidden = false,
    this.deletedAt,
    this.sortIndex = 0,
    this.coverImage,
    this.collectionName,
    this.collectionColor,
    this.tags = const <String>[],
  });

  final int id;
  final String title;
  final String content;
  final String excerpt;
  final String author;
  final String sourceUrl;
  final int? collectionId;
  final DateTime? publishedAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int charCount;
  final int wordCount;
  final int imageCount;
  final bool isPinned;
  final bool isFavorite;
  final bool isArchived;

  /// 是否已移入隐私空间。隐藏的内容不出现在任何列表、搜索与统计里。
  final bool isHidden;

  /// 删进回收站的时间。非空 = 在回收站里，可以从那里恢复。
  final DateTime? deletedAt;

  final int sortIndex;
  final String? coverImage;

  /// 查询时联表带出的文集名与颜色。
  final String? collectionName;
  final int? collectionColor;

  /// 标签名列表（联表带出）。
  final List<String> tags;

  /// 用于时间线展示的时间：优先原文发布时间，否则用本地创建时间。
  DateTime get displayTime => publishedAt ?? createdAt;

  factory Note.fromRow(Map<String, Object?> r, {List<String> tags = const []}) =>
      Note(
        id: r['id'] as int,
        title: (r['title'] as String?) ?? '',
        content: (r['content'] as String?) ?? '',
        excerpt: (r['excerpt'] as String?) ?? '',
        author: (r['author'] as String?) ?? '',
        sourceUrl: (r['source_url'] as String?) ?? '',
        collectionId: r['collection_id'] as int?,
        publishedAt: r['published_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['published_at'] as int),
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
        charCount: (r['char_count'] as int?) ?? 0,
        wordCount: (r['word_count'] as int?) ?? 0,
        imageCount: (r['image_count'] as int?) ?? 0,
        isPinned: ((r['is_pinned'] as int?) ?? 0) != 0,
        isFavorite: ((r['is_favorite'] as int?) ?? 0) != 0,
        isArchived: ((r['is_archived'] as int?) ?? 0) != 0,
        isHidden: ((r['is_hidden'] as int?) ?? 0) != 0,
        deletedAt: r['deleted_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['deleted_at'] as int),
        sortIndex: (r['sort_index'] as int?) ?? 0,
        coverImage: r['cover_image'] as String?,
        collectionName: r['collection_name'] as String?,
        collectionColor: r['collection_color'] as int?,
        tags: tags,
      );
}

/// 标签及其使用次数。
class TagStat {
  const TagStat({required this.id, required this.name, required this.color, required this.count});

  final int id;
  final String name;
  final int color;
  final int count;

  factory TagStat.fromRow(Map<String, Object?> r) => TagStat(
    id: r['id'] as int,
    name: r['name'] as String,
    color: r['color'] as int,
    count: (r['cnt'] as int?) ?? 0,
  );
}

/// 文章的一个自定义参数（「头参数 / 尾参数」）。
///
/// 「放置」([slot]) 决定它显示在标题与正文之间还是文章末尾；
/// [autoSource] 只决定**默认值从哪来**，不锁定 —— 用户随时可以手动改写。
class FieldDef {
  const FieldDef({
    required this.id,
    required this.name,
    this.slot = 'head',
    this.kind = 'text',
    this.unit = '',
    this.autoSource = '',
    this.options = '',
    this.tailStyle = 'plain',
    this.sortOrder = 0,
  });

  final int id;
  final String name;

  /// `head` | `tail`
  final String slot;

  /// `text` | `number` | `time` | `select`
  final String kind;

  /// 输入框右侧的后缀，如「年」「月」「日」。
  final String unit;

  /// `''` | `created` | `updated`
  final String autoSource;

  /// `select` 的候选项，逗号分隔。
  final String options;

  /// `plain` | `dash`。尾参数里 `dash` 的会合成一行并加 `——` 前缀。
  final String tailStyle;

  final int sortOrder;

  bool get isHead => slot == 'head';
  bool get isTail => slot == 'tail';
  bool get isAuto => autoSource.isNotEmpty;
  bool get isTime => kind == 'time';
  bool get isNumber => kind == 'number';
  bool get isSelect => kind == 'select';
  bool get isDash => tailStyle == 'dash';

  List<String> get choices => options
      .split(',')
      .map((s) => s.trim())
      .where((s) => s.isNotEmpty)
      .toList();

  FieldDef copyWith({
    String? name,
    String? slot,
    String? kind,
    String? unit,
    String? autoSource,
    String? options,
    String? tailStyle,
    int? sortOrder,
  }) => FieldDef(
    id: id,
    name: name ?? this.name,
    slot: slot ?? this.slot,
    kind: kind ?? this.kind,
    unit: unit ?? this.unit,
    autoSource: autoSource ?? this.autoSource,
    options: options ?? this.options,
    tailStyle: tailStyle ?? this.tailStyle,
    sortOrder: sortOrder ?? this.sortOrder,
  );

  factory FieldDef.fromRow(Map<String, Object?> r) => FieldDef(
    id: r['id'] as int,
    name: (r['name'] as String?) ?? '',
    slot: (r['slot'] as String?) ?? 'head',
    kind: (r['kind'] as String?) ?? 'text',
    unit: (r['unit'] as String?) ?? '',
    autoSource: (r['auto_source'] as String?) ?? '',
    options: (r['options'] as String?) ?? '',
    tailStyle: (r['tail_style'] as String?) ?? 'plain',
    sortOrder: (r['sort_order'] as int?) ?? 0,
  );
}

/// 参数在某篇笔记上的最终取值。
class FieldEntry {
  const FieldEntry({
    required this.def,
    required this.value,
    required this.isAuto,
    required this.isOverridden,
  });

  final FieldDef def;

  /// 最终显示的值（自动算的，或用户改过的）。
  final String value;

  /// 当前值是否由时间自动算出。
  final bool isAuto;

  /// 用户是否手动改写过（改过就不再跟自动更新走）。
  final bool isOverridden;

  bool get isEmpty => value.trim().isEmpty;
}

/// 待办事项。
class Todo {
  const Todo({
    required this.id,
    required this.content,
    this.isDone = false,
    this.doneAt,
    this.dueAt,
    this.priority = 0,
    this.sortIndex = 0,
    this.noteId,
    required this.createdAt,
    required this.updatedAt,
  });

  final int id;
  final String content;
  final bool isDone;
  final DateTime? doneAt;

  /// 截止时间，可为空。
  final DateTime? dueAt;

  /// 0=无 1=低 2=中 3=高
  final int priority;

  final int sortIndex;

  /// 可选：关联到某篇笔记。
  final int? noteId;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// 已过期：有截止时间、还没完成，且**截止日已经过去**。
  ///
  /// 注意这里比的是「日期」而不是「时刻」：
  /// 截止时间只精确到天，所以今天到期的待办在今天之内都不算逾期，
  /// 直接拿 dueAt（当天 00:00）和 DateTime.now() 比会把今天误判成已过期。
  bool get isOverdue {
    final due = dueAt;
    if (isDone || due == null) return false;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final dueDay = DateTime(due.year, due.month, due.day);
    return dueDay.isBefore(today);
  }

  /// 今天到期（含已过期但仍是今天）。
  bool get isDueToday {
    final due = dueAt;
    if (due == null) return false;
    final now = DateTime.now();
    return due.year == now.year && due.month == now.month && due.day == now.day;
  }

  /// 明天到期。
  bool get isDueTomorrow {
    final due = dueAt;
    if (due == null) return false;
    final t = DateTime.now().add(const Duration(days: 1));
    return due.year == t.year && due.month == t.month && due.day == t.day;
  }

  /// 人类可读的截止描述。
  String get dueLabel {
    if (dueAt == null) return '';
    if (isDueToday) return '今天';
    if (isDueTomorrow) return '明天';
    final d = dueAt!;
    final now = DateTime.now();
    if (d.year == now.year) return '${_two(d.month)}-${_two(d.day)}';
    return '${d.year}-${_two(d.month)}-${_two(d.day)}';
  }

  static String _two(int v) => v.toString().padLeft(2, '0');

  factory Todo.fromRow(Map<String, Object?> r) => Todo(
    id: r['id'] as int,
    content: (r['content'] as String?) ?? '',
    isDone: ((r['is_done'] as int?) ?? 0) != 0,
    doneAt: r['done_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(r['done_at'] as int),
    dueAt: r['due_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(r['due_at'] as int),
    priority: (r['priority'] as int?) ?? 0,
    sortIndex: (r['sort_index'] as int?) ?? 0,
    noteId: r['note_id'] as int?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
    updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
  );
}
