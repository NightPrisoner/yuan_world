/// 应用级状态。用 Provider 暴露给整棵组件树。
///
/// 这里只放「跨页面共享」的状态：当前筛选、笔记列表、文集、标签、主题。
/// 单个页面的局部状态（比如滚动位置、输入框内容）留在各自的 State 里，
/// 避免整棵树无谓重建。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import 'data/db/app_database.dart';
import 'data/importer/import_service.dart';
import 'data/models.dart';
import 'data/repositories/field_repository.dart';
import 'data/repositories/note_repository.dart';
import 'data/repositories/todo_repository.dart';

class AppState extends ChangeNotifier {
  AppState(this.db, this.repo, this.importer)
      : todos = TodoRepository(db);

  final AppDatabase db;
  final NoteRepository repo;
  final ImportService importer;
  final TodoRepository todos;

  // ── 状态 ────────────────────────────────────────────────────────────────

  NoteFilter _filter = const NoteFilter();
  NoteFilter get filter => _filter;

  List<Note> _notes = <Note>[];
  List<Note> get notes => _notes;

  List<Collection> _collections = <Collection>[];
  List<Collection> get collections => _collections;

  List<TagStat> _tags = <TagStat>[];
  List<TagStat> get tags => _tags;

  Overview? _overview;
  Overview? get overview => _overview;

  ThemeMode _themeMode = ThemeMode.system;
  ThemeMode get themeMode => _themeMode;

  bool _loading = true;
  bool get loading => _loading;

  /// 列表布局：true = 瀑布流卡片，false = 紧凑列表。
  bool _gridMode = false;
  bool get gridMode => _gridMode;

  bool get isEmpty => !_loading && _notes.isEmpty && _filter.query.isEmpty;

  // ── 生命周期 ────────────────────────────────────────────────────────────

  Future<void> init() async {
    final mode = repo.getSetting('themeMode');
    if (mode != null) {
      _themeMode = switch (mode) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
    }
    final grid = repo.getSetting('gridMode');
    _gridMode = grid == '1';
    final cols = int.tryParse(repo.getSetting('gridColumns') ?? '');
    if (cols != null) {
      _gridColumns = cols.clamp(minGridColumns, sanityMaxGridColumns);
    }
    final scale = double.tryParse(repo.getSetting('textScale') ?? '');
    if (scale != null && textScaleOptions.contains(scale)) {
      _textScale = scale;
    }
    // 调试用：YW_GRID=1/0 可强制指定视图模式，方便截图与演示
    if (kDebugMode) {
      final forced = Platform.environment['YW_GRID'];
      if (forced == '1') _gridMode = true;
      if (forced == '0') _gridMode = false;
    }
    // 头图默认取正文第一张图。导入时已经会设，这里补**存量数据**：
    // 老库里的笔记没这个字段，启动时补一次，用设置里的标记保证不重复跑。
    if (repo.getSetting('cover.backfilled') != '1') {
      repo.backfillCovers();
      repo.setSetting('cover.backfilled', '1');
    }

    // 同上：旧导入把「最后编辑」写成了导入时刻，几十篇挤在几秒内，
    // 排序等于没排。一次性对齐到原文的编辑时间。
    if (repo.getSetting('times.aligned') != '1') {
      repo.alignImportedTimes();
      repo.setSetting('times.aligned', '1');
    }

    // v8 加的排序键列默认是空串，老数据要回填一次 ——
    // 否则按名称排序时所有笔记的键都是空串，顺序完全乱掉。
    if (repo.getSetting('sortkey.pinyinBackfilled') != '1') {
      repo.backfillSortKeys();
      repo.setSetting('sortkey.pinyinBackfilled', '1');
    }

    // 回收站的自动清理：过期内容在启动时清掉。
    // 只在启动跑一次，不在运行中定时跑 —— 用户正用着的时候
    // 东西突然消失会很吓人。
    repo.purgeTrashOlderThan(trashRetentionDays);

    await refresh();
    refreshTodos();
    refreshTrash();
    _loading = false;
    notifyListeners();
  }

  // ── 回收站 ──────────────────────────────────────────────────────────────

  List<Note> _trashed = const <Note>[];
  List<Note> get trashedNotes => _trashed;

  List<Collection> _trashedCollections = const <Collection>[];

  /// 回收站里的文件夹。用户需要能单独看到并恢复它们 ——
  /// 只显示笔记的话，一个空文件夹被删掉之后就永远捞不回来了。
  List<Collection> get trashedCollections => _trashedCollections;

  void refreshTrash() {
    _trashed = repo.listTrashedNotes();
    _trashedCollections = repo.listTrashedCollections();
    notifyListeners();
  }

  Future<void> restoreFromTrash(Iterable<int> ids) async {
    // 恢复笔记时数据层会**连带把它所属的文件夹链恢复出来**，
    // 否则那些文章会挂在一个还在回收站里的文件夹上
    repo.restoreNotes(ids);
    refreshTrash();
    await refresh();
  }

  Future<void> restoreCollections(Iterable<int> ids) async {
    for (final id in ids) {
      repo.restoreCollection(id);
    }
    refreshTrash();
    await refresh();
  }

  /// 彻底删除，**不可恢复**。
  Future<void> purgeFromTrash(Iterable<int> ids) async {
    repo.purgeNotes(ids);
    refreshTrash();
    await refresh();
  }

  Future<void> purgeCollections(Iterable<int> ids) async {
    for (final id in ids) {
      repo.purgeCollection(id);
    }
    refreshTrash();
    await refresh();
  }

  Future<int> emptyTrash() async {
    final n = repo.purgeAllTrash();
    refreshTrash();
    await refresh();
    return n;
  }

  /// 回收站保留天数。**0 = 永不自动清理**。
  int get trashRetentionDays =>
      int.tryParse(repo.getSetting('trash.retentionDays') ?? '') ?? 30;

  void setTrashRetentionDays(int days) {
    repo.setSetting('trash.retentionDays', '$days');
    notifyListeners();
  }

  /// 重新拉取列表与侧边数据。
  Future<void> refresh() async {
    _collections = _visibleCollections();
    _tags = repo.allTags();
    _notes = repo.listNotes(_effectiveFilter);
    _overview = repo.overview(hiddenOnly: _privacyMode);
    notifyListeners();
  }

  /// 只刷新列表（筛选变化时用，避免重算文集统计）。
  void refreshListOnly() {
    _notes = repo.listNotes(_effectiveFilter);
    notifyListeners();
  }

  Future<void> refreshOverview() async {
    _overview = repo.overview(hiddenOnly: _privacyMode);
    _collections = _visibleCollections();
    _tags = repo.allTags();
    notifyListeners();
  }

  // ── 隐私空间 ────────────────────────────────────────────────────────────
  //
  // 设计：**同一套界面，只换数据源**。
  // 进来之后左栏、列表、详情、参数、目录……该有的全都有，
  // 只是看到的全是隐藏内容。不像原来那样另做一个简陋的独立页面。

  /// 是否处于隐私空间。不持久化 —— 重启回到普通空间，
  /// 免得别人打开应用直接看到隐私内容。
  bool get privacyMode => _privacyMode;
  bool _privacyMode = false;

  void enterPrivacyMode() {
    _privacyMode = true;
    _filter = const NoteFilter();
    refresh();
  }

  void exitPrivacyMode() {
    _privacyMode = false;
    _filter = const NoteFilter();
    refresh();
  }

  /// 当前生效的筛选条件：隐私空间里只取隐藏内容。
  NoteFilter get _effectiveFilter =>
      _privacyMode ? _filter.copyWith(hiddenOnly: true) : _filter;

  /// 当前该显示哪些文件夹。
  List<Collection> _visibleCollections() => _privacyMode
      ? repo
          .allCollections(includeHidden: true)
          .where((c) => c.isHidden)
          .toList()
      : repo.allCollections();

  // ── 筛选 ────────────────────────────────────────────────────────────────

  void setFilter(NoteFilter f) {
    _filter = f;
    refreshListOnly();
  }

  void setQuery(String q) => setFilter(_filter.copyWith(query: q));

  void selectCollection(int? id) => setFilter(
    id == null
        ? _filter.copyWith(clearCollection: true, uncategorizedOnly: false)
        : _filter.copyWith(collectionId: id, uncategorizedOnly: false),
  );

  /// 只看没有归类的笔记。
  ///
  /// **保留当前的排序**：以前这里新建了一个 `const NoteFilter()`，
  /// 于是点「未分类」会把排序悄悄重置成默认值 —— 列表突然重排，
  /// 而旁边的「全部笔记」「收藏」都是保留的。
  ///
  /// 另外**必须清掉收藏等其它筛选**：以前是往当前筛选上叠
  /// `uncategorizedOnly: true`，于是"先点收藏、再点未分类"会变成
  /// 「收藏 且 未分类」两个条件同时成立 —— 侧栏里两行**同时高亮**
  /// （用户截到的就是这个），列表也几乎一定是空的。
  /// 侧栏这些入口是**互斥**的：点谁就是只看谁。
  void selectUncategorized() => setFilter(
    NoteFilter(uncategorizedOnly: true, sort: _filter.sort),
  );

  /// 回到「全部笔记」。
  void selectAll() => setFilter(NoteFilter(sort: _filter.sort));

  void selectTag(String? tag) => setFilter(
    tag == null ? _filter.copyWith(clearTag: true) : _filter.copyWith(tag: tag),
  );

  void toggleFavorites() => setFilter(
    _filter.favoritesOnly
        ? const NoteFilter().copyWith(sort: _filter.sort)
        : NoteFilter(
            favoritesOnly: true,
            sort: _filter.sort,
          ),
  );

  // ── 文集（文件夹）管理 ──────────────────────────────────────────────────

  /// 新建文集。重名返回 null。
  Future<int?> createCollection(
    String name, {
    int color = 0xFF3B82F6,
    int? parentId,
  }) async {
    final id = repo.createCollection(name, color: color, parentId: parentId);
    if (id != null) await refresh();
    return id;
  }

  Future<bool> renameCollection(int id, String name) async {
    final ok = repo.renameCollection(id, name);
    if (ok) await refresh();
    return ok;
  }

  Future<void> setCollectionColor(int id, int color) async {
    repo.setCollectionColor(id, color);
    await refresh();
  }

  /// 把文集移进回收站（连同里面的笔记）。返回 0 保持旧签名兼容。
  Future<int> deleteCollection(int id) async {
    repo.trashCollection(id);
    if (_filter.collectionId == id) selectCollection(null);
    await refresh();
    // 回收站的缓存也要跟着更新，否则刚删完去看还是空的
    refreshTrash();
    return 0;
  }

  Future<void> reorderCollections(List<Collection> ordered) async {
    repo.reorderCollections(ordered.map((c) => c.id).toList());
    await refresh();
  }

  /// 把笔记移动到某个文集（null = 移出到「未分类」）。
  Future<void> moveNoteToCollection(int noteId, int? collectionId) async {
    repo.moveNoteToCollection(noteId, collectionId);
    await refresh();
  }

  void setSort(NoteSort s) => setFilter(_filter.copyWith(sort: s));

  // ── 主题 / 布局 ─────────────────────────────────────────────────────────

  void setThemeMode(ThemeMode m) {
    _themeMode = m;
    repo.setSetting('themeMode', m.name);
    notifyListeners();
  }

  /// 自定义参数（头参数 / 尾参数）的读写。懒加载，用到才建。
  FieldRepository? _fields;
  FieldRepository get fields => _fields ??= FieldRepository(db);

  /// 参数定义被改动后叫一声，让依赖它的界面重建。
  void notifyDataChanged() => notifyListeners();

  /// 是否显示头参数 / 尾参数。
  ///
  /// 默认都开：参数是这套笔记的一部分，阅读时当然要看得到，
  /// 不能只在编辑态露脸。不想看的人可以在设置里单独关掉。
  bool get headFieldsEnabled =>
      repo.getSetting('fields.headEnabled') != '0';
  bool get tailFieldsEnabled =>
      repo.getSetting('fields.tailEnabled') != '0';

  void setHeadFieldsEnabled(bool v) {
    repo.setSetting('fields.headEnabled', v ? '1' : '0');
    notifyListeners();
  }

  void setTailFieldsEnabled(bool v) {
    repo.setSetting('fields.tailEnabled', v ? '1' : '0');
    notifyListeners();
  }

  /// 全局字号缩放。1.0 = 默认。
  ///
  /// 可选档位而不是无级滑块：档位之间的差异一眼能看出来，
  /// 无级拖动反而让人在 1.02 和 1.04 之间纠结。
  static const List<double> textScaleOptions = <double>[0.9, 1.0, 1.15, 1.3];

  double get textScale => _textScale;
  double _textScale = 1.0;

  void setTextScale(double v) {
    if (!textScaleOptions.contains(v)) return;
    _textScale = v;
    repo.setSetting('textScale', v.toString());
    notifyListeners();
  }

  /// 是否显示文章目录。默认开。
  bool get tocEnabled => repo.getSetting('toc.enabled') != '0';

  void setTocEnabled(bool v) {
    repo.setSetting('toc.enabled', v ? '1' : '0');
    notifyListeners();
  }

  /// 目录停靠在哪一侧（`left` / `right`）。
  String get tocSide => repo.getSetting('toc.side') == 'left' ? 'left' : 'right';

  void setTocSide(String side) {
    repo.setSetting('toc.side', side == 'left' ? 'left' : 'right');
    notifyListeners();
  }

  /// 目录栏宽度，可拖动。
  double get tocWidth =>
      (double.tryParse(repo.getSetting('toc.width') ?? '') ?? 220)
          .clamp(160.0, 420.0);

  void setTocWidth(double w) =>
      repo.setSetting('toc.width', w.clamp(160.0, 420.0).round().toString());

  void setGridMode(bool v) {
    _gridMode = v;
    repo.setSetting('gridMode', v ? '1' : '0');
    notifyListeners();
  }

  /// 瀑布流的列数。
  ///
  /// **没有产品意义上的上限**，用户想铺几列就几列。
  /// 只留一个 50 的兜底：那不是在限制用户，是防手滑 ——
  /// 万一输入框里打进去 99999，布局会当场炸掉。
  static const int minGridColumns = 1;
  static const int sanityMaxGridColumns = 50;

  int get gridColumns => _gridColumns;
  int _gridColumns = 2;

  void setGridColumns(int v) {
    final next = v.clamp(minGridColumns, sanityMaxGridColumns);
    if (next == _gridColumns) return;
    _gridColumns = next;
    repo.setSetting('gridColumns', '$next');
    notifyListeners();
  }

  // ── 笔记操作 ────────────────────────────────────────────────────────────

  Future<void> togglePin(Note n) async {
    repo.setPinned(n.id, !n.isPinned);
    refreshListOnly();
  }

  Future<void> toggleFavorite(Note n) async {
    repo.setFavorite(n.id, !n.isFavorite);
    refreshListOnly();
    // **必须带上 hiddenOnly**：漏了的话，在隐私空间里收藏一篇，
    // 侧栏的计数会当场换成普通空间的数字 —— 隐私空间的意义就是
    // 外面看不到里面的痕迹，数字也算痕迹。
    _overview = repo.overview(hiddenOnly: _privacyMode);
    notifyListeners();
  }

  Future<void> deleteNote(int id) async {
    repo.deleteNote(id);
    // 回收站缓存也要刷：侧栏的回收站角标读的是 trashedNotes.length，
    // 不刷的话删完笔记角标还是旧数字（要点进回收站才对）
    refreshTrash();
    await refresh();
  }

  Future<void> toggleArchive(Note n) async {
    repo.setArchived(n.id, !n.isArchived);
    await refresh();
  }

  /// 新建一篇空白笔记，返回新 id。
  int createNote({int? collectionId}) {
    final id = repo.insertNote(
      title: '',
      content: '',
      excerpt: '',
      collectionId: collectionId ?? _filter.collectionId,
      charCount: 0,
      wordCount: 0,
    );
    return id;
  }

  // ── 待办清单 ────────────────────────────────────────────────────────────

  List<Todo> _todoList = <Todo>[];
  List<Todo> get todoList => _todoList;

  int _openTodos = 0;
  int _doneTodos = 0;
  int _overdueTodos = 0;
  int get openTodoCount => _openTodos;
  int get doneTodoCount => _doneTodos;
  int get overdueTodoCount => _overdueTodos;

  void refreshTodos() {
    _todoList = todos.allTodos();
    final c = todos.counts();
    _openTodos = c.open;
    _doneTodos = c.done;
    _overdueTodos = c.overdue;
    notifyListeners();
  }

  void addTodo(String content, {DateTime? dueAt, int priority = 0}) {
    final text = content.trim();
    if (text.isEmpty) return;
    todos.add(text, dueAt: dueAt, priority: priority);
    refreshTodos();
  }

  void toggleTodo(Todo t) {
    todos.setDone(t.id, !t.isDone);
    refreshTodos();
  }

  void updateTodoContent(int id, String content) {
    final text = content.trim();
    if (text.isEmpty) return;
    todos.setContent(id, text);
    refreshTodos();
  }

  void setTodoDue(int id, DateTime? dueAt) {
    todos.setDueAt(id, dueAt);
    refreshTodos();
  }

  void setTodoPriority(int id, int priority) {
    todos.setPriority(id, priority);
    refreshTodos();
  }

  void deleteTodo(int id) {
    todos.delete(id);
    refreshTodos();
  }

  void clearCompletedTodos() {
    todos.clearCompleted();
    refreshTodos();
  }

  /// 拖拽结束后按新顺序落库。
  void reorderTodos(List<Todo> ordered) {
    todos.reorder(ordered.map((t) => t.id).toList());
    refreshTodos();
  }
}
