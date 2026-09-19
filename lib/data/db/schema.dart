/// 「元世界」数据库结构定义。
///
/// 设计要点
/// ─────────────────────────────────────────────────────────────
/// 1. [notes] 只存正文纯文本（Markdown 子集），图片单独落盘，
///    正文中用 `![](images/xxx.png)` 引用。这样数据库文件小、查询快。
/// 2. [collections] 对应小米笔记里的「文件夹」，也就是文集。
/// 3. [tags] 与文集是正交关系：一篇文章属于一个文集，但可以有多个标签。
/// 4. [notes_fts] 是 FTS5 虚拟表，**必须用 trigram 分词器**。
///    默认的 unicode61 按空格切词，对中文完全无效（实测「笔记」命中 0 条）；
///    trigram 按三字符滑动窗口建索引，才能支持中文子串检索。
/// 5. [note_events] 记录每次打开笔记的行为，用于「活跃度热力图」等可视化。
library;

/// 当前 schema 版本。每次改表结构都要 +1，并在 [kMigrations] 里补一段。
const int kSchemaVersion = 8;

/// v8：按文件名规则排序用的键。
///
/// SQLite 的 `ORDER BY title` 按码点比，和资源管理器看到的顺序不同
/// （最明显的是「笔记10」会排到「笔记2」前面）。这里存一份排好序的键，
/// 让标题排序对齐 Windows 的文件名规则。
///
/// 键由 `windowsSortKey()` 生成，**纯函数**，改规则时重新回填即可。
const List<String> kSortKeyStatements = <String>[
  "ALTER TABLE notes ADD COLUMN sort_key TEXT NOT NULL DEFAULT ''",
  'CREATE INDEX idx_notes_sort_key ON notes(sort_key)',
];

/// v7：回收站。
///
/// 删除从**物理删除**改成**软删除** —— 只打一个 `deleted_at` 时间戳，
/// 数据还在库里。误删能捞回来，也让"什么时候真正清掉"变成
/// 用户可以自己决定的事。
const List<String> kTrashStatements = <String>[
  'ALTER TABLE notes ADD COLUMN deleted_at INTEGER',
  'ALTER TABLE collections ADD COLUMN deleted_at INTEGER',
  'CREATE INDEX idx_notes_deleted ON notes(deleted_at)',
  'CREATE INDEX idx_collections_deleted ON collections(deleted_at)',
];

/// v6：文件夹支持置顶。
///
/// 置顶排在 `sort_order` **之前**：置顶是一票否决，
/// 用户把它钉上去就是不想让任何排序规则把它挤下去。
const List<String> kCollectionPinStatements = <String>[
  'ALTER TABLE collections ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0',
  'CREATE INDEX idx_collections_pinned ON collections(is_pinned DESC, sort_order ASC)',
];

/// v5：头参数也改成按**创建时间**自动生成。
///
/// v4 时头参数是留空的填空块，实际用起来每次都要手填年月日，
/// 而绝大多数笔记写的就是当天 —— 白白多四个动作。
/// 改成自动填创建时间；自动值只是**默认值**，想改随时能改。
const List<String> kHeadAutoStatements = <String>[
  "UPDATE field_defs SET auto_source = 'created' "
      "WHERE slot = 'head' AND auto_source = '' "
      "AND name IN ('年', '月', '日', '时间')",
];

/// v4：文章自定义参数（头参数 / 尾参数）。
///
/// 两块表：
///   - [field_defs]   参数**定义**：叫什么、归头还是尾、什么类型、单位是什么。
///     用户在设置里增删改，全体笔记共用一份。
///   - [note_fields]  参数**值**：每篇笔记自己填的内容。
///
/// 自动参数（创建时间 / 最后编辑）**默认不落 [note_fields]**，渲染时现取，
/// 免得改一次笔记就要同步一堆冗余行；但用户一旦手动改过，
/// 就会写进 [note_fields] 覆盖自动值 —— 始终保留用户改写的权力。
const List<String> kFieldStatements = <String>[
  '''
  CREATE TABLE field_defs (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT    NOT NULL UNIQUE,
    -- 'head' | 'tail'：显示在标题与正文之间，还是文章末尾
    slot        TEXT    NOT NULL DEFAULT 'head',
    -- 'text' | 'number' | 'select'
    kind        TEXT    NOT NULL DEFAULT 'text',
    -- 显示在输入框右侧的后缀，如「年」「月」「日」
    unit        TEXT    NOT NULL DEFAULT '',
    -- '' | 'created' | 'updated'：非空表示默认自动取时间
    auto_source TEXT    NOT NULL DEFAULT '',
    -- select 类型的候选项，逗号分隔
    options     TEXT    NOT NULL DEFAULT '',
    -- 尾参数行是否右对齐并加破折号前缀
    tail_style  TEXT    NOT NULL DEFAULT 'dash',
    sort_order  INTEGER NOT NULL DEFAULT 0,
    created_at  INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE note_fields (
    note_id  INTEGER NOT NULL REFERENCES notes(id)      ON DELETE CASCADE,
    field_id INTEGER NOT NULL REFERENCES field_defs(id) ON DELETE CASCADE,
    value    TEXT    NOT NULL DEFAULT '',
    PRIMARY KEY (note_id, field_id)
  )
  ''',
  'CREATE INDEX idx_field_defs_slot ON field_defs(slot, sort_order)',
  'CREATE INDEX idx_note_fields_fid ON note_fields(field_id)',
];

/// 首次建库时预置的参数。
///
/// 默认放置（「放置」= 这个参数显示在头部还是尾部）：
///   - 头：年、月、日、时间 —— 开箱就是 `2026年 9月 14日 18:43`，
///     **按创建时间自动填**
///   - 尾：年、月、日、时间 —— 合成一行右对齐，形如
///     `——2026年9月14日18:43`，**按最后编辑时间自动填**
///
/// 两边都只是默认值，用户随时能改；改过就不再跟自动更新走。
/// `tail_style = 'dash'` 的那几个尾参数会被合成一行渲染。
const List<String> kDefaultFields = <String>[
  // ── 头参数：按创建时间自动填 ──
  "INSERT INTO field_defs (name, slot, kind, unit, auto_source, options, tail_style, sort_order, created_at) "
      "VALUES ('年', 'head', 'number', '年', 'created', '', 'plain', 0, 0)",
  "INSERT INTO field_defs (name, slot, kind, unit, auto_source, options, tail_style, sort_order, created_at) "
      "VALUES ('月', 'head', 'number', '月', 'created', '', 'plain', 1, 0)",
  "INSERT INTO field_defs (name, slot, kind, unit, auto_source, options, tail_style, sort_order, created_at) "
      "VALUES ('日', 'head', 'number', '日', 'created', '', 'plain', 2, 0)",
  "INSERT INTO field_defs (name, slot, kind, unit, auto_source, options, tail_style, sort_order, created_at) "
      "VALUES ('时间', 'head', 'time', '', 'created', '', 'plain', 3, 0)",
  // ── 尾参数：合成一行 `——2026年9月14日18:43` ──
  "INSERT INTO field_defs (name, slot, kind, unit, auto_source, options, tail_style, sort_order, created_at) "
      "VALUES ('尾年', 'tail', 'number', '年', 'updated', '', 'dash', 0, 0)",
  "INSERT INTO field_defs (name, slot, kind, unit, auto_source, options, tail_style, sort_order, created_at) "
      "VALUES ('尾月', 'tail', 'number', '月', 'updated', '', 'dash', 1, 0)",
  "INSERT INTO field_defs (name, slot, kind, unit, auto_source, options, tail_style, sort_order, created_at) "
      "VALUES ('尾日', 'tail', 'number', '日', 'updated', '', 'dash', 2, 0)",
  "INSERT INTO field_defs (name, slot, kind, unit, auto_source, options, tail_style, sort_order, created_at) "
      "VALUES ('尾时间', 'tail', 'time', '', 'updated', '', 'dash', 3, 0)",
];

/// v3：隐私空间 + 文件夹嵌套。
///
/// 设计取舍：
///   1. **隐藏状态是「物化」的**：隐藏一个文件夹时，会把它的子文件夹和
///      里面的笔记一并标记为隐藏。这样所有既有查询只要加一句
///      `is_hidden = 0` 就够了，不用递归 join，也不会漏。
///      代价是取消隐藏时要一并还原，由仓储层负责。
///   2. `parent_id` 用 `ON DELETE SET NULL`：删父文件夹时子文件夹上浮为顶层，
///      而不是被删掉。用户删文件夹的本意是"不要这个分类了"，
///      顺手删掉里面一整套子目录太危险。
const List<String> kPrivacyAndNestingStatements = <String>[
  "ALTER TABLE notes ADD COLUMN is_hidden INTEGER NOT NULL DEFAULT 0",
  "ALTER TABLE collections ADD COLUMN is_hidden INTEGER NOT NULL DEFAULT 0",
  'ALTER TABLE collections ADD COLUMN parent_id INTEGER '
      'REFERENCES collections(id) ON DELETE SET NULL',
  'CREATE INDEX idx_notes_hidden       ON notes(is_hidden)',
  'CREATE INDEX idx_collections_parent ON collections(parent_id)',
  'CREATE INDEX idx_collections_hidden ON collections(is_hidden)',
];

/// 待办清单相关的表。
///
/// 单独抽出来是为了让「全新安装」和「老库升级」走同一份 DDL，
/// 避免两边写重复的 SQL 后慢慢漂移。
const List<String> kTodoStatements = <String>[
  '''
  CREATE TABLE todos (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    content    TEXT    NOT NULL DEFAULT '',
    is_done    INTEGER NOT NULL DEFAULT 0,
    done_at    INTEGER,
    -- 截止时间（毫秒时间戳），可为空
    due_at     INTEGER,
    -- 0=无 1=低 2=中 3=高
    priority   INTEGER NOT NULL DEFAULT 0,
    -- 手动拖拽排序用
    sort_index INTEGER NOT NULL DEFAULT 0,
    -- 可选：关联到某篇笔记
    note_id    INTEGER REFERENCES notes(id) ON DELETE SET NULL,
    created_at INTEGER NOT NULL,
    updated_at INTEGER NOT NULL
  )
  ''',
  'CREATE INDEX idx_todos_state ON todos(is_done, sort_index)',
  'CREATE INDEX idx_todos_due   ON todos(due_at)',
];

/// 建库语句。按顺序执行，整体包在一个事务里。
const List<String> kCreateStatements = <String>[
  // ── 文集 ──────────────────────────────────────────────────────────────
  '''
  CREATE TABLE collections (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT    NOT NULL UNIQUE,
    description TEXT    NOT NULL DEFAULT '',
    -- 展示用的主题色，ARGB 整数
    color       INTEGER NOT NULL DEFAULT 0xFF3B82F6,
    icon        TEXT    NOT NULL DEFAULT 'folder',
    sort_order  INTEGER NOT NULL DEFAULT 0,
    -- 嵌套：父文件夹。NULL = 顶层
    parent_id   INTEGER REFERENCES collections(id) ON DELETE SET NULL,
    -- 1 = 已移入隐私空间
    is_hidden   INTEGER NOT NULL DEFAULT 0,
    -- 1 = 置顶，排在所有非置顶项之前
    is_pinned   INTEGER NOT NULL DEFAULT 0,
    -- 非空 = 在回收站里
    deleted_at  INTEGER,
    created_at  INTEGER NOT NULL
  )
  ''',

  // ── 笔记 ──────────────────────────────────────────────────────────────
  '''
  CREATE TABLE notes (
    id           INTEGER PRIMARY KEY AUTOINCREMENT,
    title        TEXT    NOT NULL DEFAULT '',
    -- 正文，Markdown 子集
    content      TEXT    NOT NULL DEFAULT '',
    -- 纯文本摘要，用于列表预览与统计
    excerpt      TEXT    NOT NULL DEFAULT '',
    author       TEXT    NOT NULL DEFAULT '',
    source_url   TEXT    NOT NULL DEFAULT '',
    collection_id INTEGER REFERENCES collections(id) ON DELETE SET NULL,
    -- 原文发布时间（可能为空），以及本地创建/修改时间（毫秒时间戳）
    published_at INTEGER,
    created_at   INTEGER NOT NULL,
    updated_at   INTEGER NOT NULL,
    -- 统计字段，写入时算好，避免每次全表扫描
    char_count   INTEGER NOT NULL DEFAULT 0,
    word_count   INTEGER NOT NULL DEFAULT 0,
    image_count  INTEGER NOT NULL DEFAULT 0,
    -- 排序与标记
    is_pinned    INTEGER NOT NULL DEFAULT 0,
    is_favorite  INTEGER NOT NULL DEFAULT 0,
    is_archived  INTEGER NOT NULL DEFAULT 0,
    -- 1 = 已移入隐私空间
    is_hidden    INTEGER NOT NULL DEFAULT 0,
    -- 非空 = 在回收站里（软删除，数据还在）
    deleted_at   INTEGER,
    sort_index   INTEGER NOT NULL DEFAULT 0,
    -- 按文件名规则生成的排序键（见 windowsSortKey）
    sort_key     TEXT    NOT NULL DEFAULT '',
    -- 封面图（相对于图片根目录的路径）
    cover_image  TEXT
  )
  ''',

  'CREATE INDEX idx_notes_collection ON notes(collection_id)',
  'CREATE INDEX idx_notes_updated    ON notes(updated_at DESC)',
  'CREATE INDEX idx_notes_published  ON notes(published_at DESC)',
  'CREATE INDEX idx_notes_pinned     ON notes(is_pinned DESC, sort_index ASC)',
  'CREATE INDEX idx_notes_hidden     ON notes(is_hidden)',
  'CREATE INDEX idx_notes_deleted    ON notes(deleted_at)',
  'CREATE INDEX idx_notes_sort_key   ON notes(sort_key)',
  'CREATE INDEX idx_collections_parent ON collections(parent_id)',
  'CREATE INDEX idx_collections_hidden ON collections(is_hidden)',
  'CREATE INDEX idx_collections_pinned ON collections(is_pinned DESC, sort_order ASC)',
  'CREATE INDEX idx_collections_deleted ON collections(deleted_at)',

  // ── 标签 ──────────────────────────────────────────────────────────────
  '''
  CREATE TABLE tags (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    name       TEXT    NOT NULL UNIQUE,
    color      INTEGER NOT NULL DEFAULT 0xFF8B5CF6,
    created_at INTEGER NOT NULL
  )
  ''',
  '''
  CREATE TABLE note_tags (
    note_id INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    tag_id  INTEGER NOT NULL REFERENCES tags(id)  ON DELETE CASCADE,
    PRIMARY KEY (note_id, tag_id)
  )
  ''',
  'CREATE INDEX idx_note_tags_tag ON note_tags(tag_id)',

  // ── 图片 ──────────────────────────────────────────────────────────────
  //
  // ⚠️ **这张表目前没有任何代码在读写，是历史遗留。**
  //
  // 图片信息实际存在两个地方：`notes.image_count`（计数）和磁盘上的
  // `images/<noteId>/`（文件本身），正文里的相对路径就是索引。
  // 当初设想的"图片元信息表"没有落地。
  //
  // **没有删它，是刻意的**：删表要写迁移，而迁移是唯一会动用户数据的
  // 地方 —— 为了一张空表去冒数据风险不值得。留着的代价只是 schema 里
  // 多一段。但**别再往上加东西**：新功能要存图片元信息的话，
  // 先想清楚和磁盘目录谁是权威，而不是顺手用它。
  '''
  CREATE TABLE note_images (
    id       INTEGER PRIMARY KEY AUTOINCREMENT,
    note_id  INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    -- 相对于图片根目录的相对路径，如 "3/1a2b3c.png"
    rel_path TEXT    NOT NULL,
    mime     TEXT    NOT NULL DEFAULT 'image/png',
    bytes    INTEGER NOT NULL DEFAULT 0,
    width    INTEGER,
    height   INTEGER,
    created_at INTEGER NOT NULL
  )
  ''',
  'CREATE INDEX idx_note_images_note ON note_images(note_id)',

  // ── 行为事件（阅读/编辑），用于活跃度可视化 ──────────────────────────
  '''
  CREATE TABLE note_events (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    note_id   INTEGER NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
    -- 'open' | 'edit' | 'create'
    kind      TEXT    NOT NULL,
    -- 事件发生的「天」，格式 yyyy-MM-dd，方便按天聚合
    day       TEXT    NOT NULL,
    at        INTEGER NOT NULL
  )
  ''',
  'CREATE INDEX idx_events_day  ON note_events(day)',
  'CREATE INDEX idx_events_note ON note_events(note_id)',

  // ── 应用设置（键值对） ────────────────────────────────────────────────
  '''
  CREATE TABLE settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
  )
  ''',

  // ── 待办清单 ──────────────────────────────────────────────────────────
  ...kTodoStatements,

  // ── 文章自定义参数（头参数 / 尾参数） ─────────────────────────────────
  ...kFieldStatements,
  ...kDefaultFields,

  // ── 全文检索（trigram 分词，中文可用） ───────────────────────────────
  '''
  CREATE VIRTUAL TABLE notes_fts USING fts5(
    title,
    content,
    content='notes',
    content_rowid='id',
    tokenize='trigram'
  )
  ''',
  // 触发器：保持 FTS 与主表同步
  '''
  CREATE TRIGGER notes_fts_ai AFTER INSERT ON notes BEGIN
    INSERT INTO notes_fts(rowid, title, content) VALUES (new.id, new.title, new.content);
  END
  ''',
  '''
  CREATE TRIGGER notes_fts_ad AFTER DELETE ON notes BEGIN
    INSERT INTO notes_fts(notes_fts, rowid, title, content) VALUES ('delete', old.id, old.title, old.content);
  END
  ''',
  '''
  CREATE TRIGGER notes_fts_au AFTER UPDATE ON notes BEGIN
    INSERT INTO notes_fts(notes_fts, rowid, title, content) VALUES ('delete', old.id, old.title, old.content);
    INSERT INTO notes_fts(rowid, title, content) VALUES (new.id, new.title, new.content);
  END
  ''',
];

/// 版本迁移脚本。key 是「要升到的版本」，value 是要执行的语句。
///
/// 例：将来加字段时
/// ```dart
/// 3: ['ALTER TABLE notes ADD COLUMN mood TEXT NOT NULL DEFAULT ""'],
/// ```
const Map<int, List<String>> kMigrations = <int, List<String>>{
  // v1 → v2：引入待办清单
  2: kTodoStatements,
  // v2 → v3：隐私空间 + 文件夹嵌套
  3: kPrivacyAndNestingStatements,
  // v3 → v4：文章自定义参数（头参数 / 尾参数）
  4: <String>[...kFieldStatements, ...kDefaultFields],
  // v4 → v5：头参数改成按创建时间自动生成
  5: kHeadAutoStatements,
  // v5 → v6：文件夹支持置顶
  6: kCollectionPinStatements,
  // v6 → v7：回收站（软删除）
  7: kTrashStatements,
  // v7 → v8：标题排序键（对齐 Windows 文件名规则）
  8: kSortKeyStatements,
};
