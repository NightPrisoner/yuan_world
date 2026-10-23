/// 应用级状态。用 Provider 暴露给整棵组件树。
///
/// 这里只放「跨页面共享」的状态：当前筛选、笔记列表、文集、标签、主题。
/// 单个页面的局部状态（比如滚动位置、输入框内容）留在各自的 State 里，
/// 避免整棵树无谓重建。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'core/app_paths.dart';
import 'data/backup/backup_service.dart';
import 'data/db/app_database.dart';
import 'data/importer/import_service.dart';
import 'data/models.dart';
import 'data/repositories/field_repository.dart';
import 'data/repositories/note_repository.dart';
import 'data/repositories/todo_repository.dart';

class AppState extends ChangeNotifier {
  AppState(this.db, this.repo, this.importer) : todos = TodoRepository(db);

  final AppDatabase db;
  final NoteRepository repo;
  final ImportService importer;

  int _dataRevision = 0;

  /// 数据刷新版本。布局、主题等偏好通知不触发统计重算。
  int get dataRevision => _dataRevision;

  /// 备份/恢复。数据层的纯 Dart 服务，UI 只是它的一个入口。
  late final BackupService backup = BackupService(db);

  /// 每天自动快照（默认开）。关掉的话就只能靠手动备份了。
  bool get backupAutoSnapshot => repo.getSetting('backup.auto') != '0';

  /// 自动快照保留几份。
  int get backupKeep => int.tryParse(repo.getSetting('backup.keep') ?? '') ?? 7;

  void setBackupAutoSnapshot(bool v) {
    repo.setSetting('backup.auto', v ? '1' : '0');
    notifyListeners();
  }

  /// 每周自动完整备份（默认开）。快照只有数据库，图片视频不在里面 ——
  /// 硬盘坏了照样全没，所以还得有一份带媒体的、留在本机的完整备份。
  bool get backupAutoFull => repo.getSetting('backup.full') != '0';

  /// 自动完整备份保留几份（默认 2：够回退一次，又不至于占太多盘）。
  int get backupFullKeep =>
      int.tryParse(repo.getSetting('backup.fullKeep') ?? '') ?? 2;

  void setBackupAutoFull(bool v) {
    repo.setSetting('backup.full', v ? '1' : '0');
    notifyListeners();
  }

  /// 快照目录（用户可改）。空表示用默认的 `<数据目录>/snapshots/`。
  String get backupSnapshotDir => repo.getSetting('backup.snapshotDir') ?? '';

  /// 完整备份目录（用户可改）。空表示用默认的 `<数据目录>/backups/`。
  String get backupFullDir => repo.getSetting('backup.fullDir') ?? '';

  bool get backupSnapshotDirIsCustom => backupSnapshotDir.trim().isNotEmpty;

  bool get backupFullDirIsCustom => backupFullDir.trim().isNotEmpty;

  /// 改快照目录（空串 = 回默认）。
  void setBackupSnapshotDir(String path) {
    repo.setSetting('backup.snapshotDir', path.trim());
    _syncBackupDirs();
    notifyListeners();
  }

  /// 改完整备份目录（空串 = 回默认）。
  void setBackupFullDir(String path) {
    repo.setSetting('backup.fullDir', path.trim());
    _syncBackupDirs();
    notifyListeners();
  }

  /// 把设置里的目录同步给 [BackupService]。
  ///
  /// 服务本身不碰设置表 —— 启动、改设置、搬家之后都得来这里推一次，
  /// 否则它还在往旧位置写。
  void _syncBackupDirs() {
    backup
      ..snapshotDirPath = backupSnapshotDir
      ..fullBackupDirPath = backupFullDir;
  }

  /// 自动快照的节奏与保留份数 —— 默认值，可以在设置里改。
  static const Duration autoSnapshotEvery = Duration(hours: 24);

  /// 自动完整备份的节奏（一周一次）。几百兆，不能天天来。
  static const Duration autoFullEvery = Duration(days: 7);

  /// 运行期间多久回头看一次有没有到期。
  static const Duration autoBackupCheckEvery = Duration(minutes: 30);

  /// 自动快照间隔（小时）。0 = 关掉日常快照，只能手动做。
  ///
  /// 之所以做成"几小时一次"而不是"每天几点"，是因为很多人不是每天都开机 ——
  /// 定死一个时刻，错过那天就整周没备份。
  int get snapshotEveryHours {
    final raw = int.tryParse(repo.getSetting('backup.snapshotEveryH') ?? '');
    if (raw == null) return autoSnapshotEvery.inHours;
    return raw.clamp(0, 24 * 30);
  }

  void setSnapshotEveryHours(int hours) {
    repo.setSetting('backup.snapshotEveryH', '${hours.clamp(0, 24 * 30)}');
    notifyListeners();
  }

  /// 自动完整备份间隔（天）。
  int get fullBackupEveryDays {
    final raw = int.tryParse(repo.getSetting('backup.fullEveryD') ?? '');
    if (raw == null) return autoFullEvery.inDays;
    return raw.clamp(1, 365);
  }

  void setFullBackupEveryDays(int days) {
    repo.setSetting('backup.fullEveryD', '${days.clamp(1, 365)}');
    notifyListeners();
  }

  Duration get _snapshotEvery => Duration(hours: snapshotEveryHours);

  Duration get _fullEvery => Duration(days: fullBackupEveryDays);

  DateTime? _readTime(String key) =>
      DateTime.tryParse(repo.getSetting(key) ?? '');

  /// 当前数据目录是不是用户改过的（不是默认位置）。
  bool get dataLocationIsCustom => configuredAppRoot() != null;

  /// 把整个数据目录搬到 [targetPath]（null / 空 = 回到默认位置）。
  ///
  /// 顺序很讲究：
  ///   1. 先 checkpoint 让 -wal 合并进主库，再把库和 media 搬过去；
  ///   2. 指针文件先写好，再换连接 —— 这样中途崩了下次启动也找得到新位置；
  ///   3. 就地把 AppDatabase 的 rootDir 换掉并重开，不重建对象。
  ///
  /// **搬到新位置之后源位置的数据就删掉了**（见 [migrateDataRoot]）：
  /// 数据只有一份，用户不会在两处看到内容不同的同一个库。
  Future<MoveDataResult> moveDataLocation(
    String? targetPath, {
    void Function(double progress)? onProgress,
  }) async {
    final from = db.rootDir.path;
    final target = (targetPath == null || targetPath.trim().isEmpty)
        ? await defaultAppRoot()
        : dataDirIn(targetPath.trim());
    if (p.equals(p.normalize(from), p.normalize(target))) {
      // 已经在目标位置：只保证指针状态正确
      if (targetPath == null || targetPath.trim().isEmpty) {
        await forgetAppRoot();
      }
      return MoveDataResult(target: from, files: 0, bytes: 0);
    }

    // 别把数据搬进自己里面（选目标时手滑点了当前目录的子目录）
    if (p.isWithin(p.normalize(from), p.normalize(target))) {
      throw StateError('不能把数据目录搬到它自己的子目录里');
    }
    // 反过来也不行：源是目标的子目录时，拷完再删会把自己删掉
    if (p.isWithin(p.normalize(target), p.normalize(from))) {
      throw StateError('不能把数据目录搬到它自己的上层目录里');
    }

    db.checkpoint();
    // **必须先关库再搬。** 数据库开着的时候 yuanworld.db / -wal / -shm
    // 是被当前进程锁着的，Windows 上删不掉；以前直接搬，文件拷过去了、
    // 删源那一步静默失败，于是用户看到「F 盘里还留着一个 yuanworld.db」，
    // 也就是两份数据并存 —— 和「数据只有一份」的约定直接矛盾。
    db.closeForRestore();
    MoveDataResult result;
    try {
      result = await migrateDataRoot(from, target, onProgress: onProgress);
    } catch (_) {
      // 没搬成：把原来的库重新打开，用户还能继续用，源文件一个字节没动
      db.reopen();
      rethrow;
    }

    if (targetPath == null || targetPath.trim().isEmpty) {
      await forgetAppRoot();
    } else {
      await rememberAppRoot(target);
    }

    // relocateTo 内部会 checkpoint + close + reopen；此时连接已经关掉了，
    // close 是幂等的，checkpoint 会静默跳过。
    db.relocateTo(Directory(target));
    // 换库后各种缓存都要重来：列表、文集、概览、待办、回收站
    await init();
    notifyListeners();
    return result;
  }

  DateTime? get lastSnapshotAt => _readTime('backup.lastSnapshotAt');
  DateTime? get lastSnapshotErrorAt => _readTime('backup.lastSnapshotErrorAt');
  String? get lastSnapshotError => repo.getSetting('backup.lastSnapshotError');
  DateTime? get lastFullBackupAt => _readTime('backup.lastFullAt');
  DateTime? get lastFullBackupErrorAt => _readTime('backup.lastFullErrorAt');
  String? get lastFullBackupError => repo.getSetting('backup.lastFullError');

  bool get autoBackupBusy => _autoBackupBusy;
  bool _autoBackupBusy = false;

  Timer? _autoBackupTimer;

  /// 起一个定时器，运行期间也检查备份是否到期。
  ///
  /// 以前只在启动时看一眼 —— 台式机一开几周不关，等于永远不备份。
  /// 由 `main()` 调用；测试里传个短周期就能验。
  void startAutoBackupWatcher({Duration? every}) {
    _autoBackupTimer?.cancel();
    _autoBackupTimer = Timer.periodic(
      every ?? autoBackupCheckEvery,
      (_) => checkAutoBackup(),
    );
  }

  @override
  void dispose() {
    _autoBackupTimer?.cancel();
    _autoBackupTimer = null;
    _disposed = true;
    super.dispose();
  }

  bool _disposed = false;

  /// 检查并执行到期的自动备份。启动时调一次，之后由定时器调。
  ///
  /// **失败不抛异常**（磁盘满、没权限都不该让应用崩），但会把原因记下来
  /// 并通知界面 —— 用户有权知道自己的备份其实没成。
  Future<void> checkAutoBackup() async {
    if (_disposed || _autoBackupBusy) return;
    _autoBackupBusy = true;
    notifyListeners();
    try {
      // 先让界面画一帧再干重活（快照要跑 VACUUM INTO）
      await Future<void>.delayed(Duration.zero);
      if (_disposed) return;
      _runSnapshotIfDue();
      await _runFullBackupIfDue();
    } finally {
      _autoBackupBusy = false;
      if (!_disposed) notifyListeners();
    }
  }

  /// 兼容老名字：启动时那次检查。
  void snapshotIfDue() {
    unawaited(checkAutoBackup());
  }

  void _runSnapshotIfDue() {
    if (!backupAutoSnapshot) return;
    // 间隔设成 0 = 用户不想要自动快照，只手动做
    if (snapshotEveryHours <= 0) return;
    try {
      final keep = backupKeep;
      if (!backup.snapshotDue(keep: keep, every: _snapshotEvery)) return;
      final file = backup.snapshot(keep: keep);
      repo.setSetting(
        'backup.lastSnapshotAt',
        file.statSync().modified.toIso8601String(),
      );
      repo.setSetting('backup.lastSnapshotError', '');
      repo.setSetting('backup.lastSnapshotErrorAt', '');
    } catch (e) {
      _recordError('backup.lastSnapshotError', 'backup.lastSnapshotErrorAt', e);
    }
  }

  Future<void> _runFullBackupIfDue() async {
    if (!backupAutoFull) return;
    try {
      if (!backup.fullBackupDue(every: _fullEvery)) return;
      final file = await backup.createFullBackup(keep: backupFullKeep);
      repo.setSetting(
        'backup.lastFullAt',
        file.statSync().modified.toIso8601String(),
      );
      repo.setSetting('backup.lastFullError', '');
      repo.setSetting('backup.lastFullErrorAt', '');
    } catch (e) {
      _recordError('backup.lastFullError', 'backup.lastFullErrorAt', e);
    }
  }

  /// 记下失败原因。**写设置失败也不能再抛** —— 否则一次备份失败会变成
  /// 一次崩溃（比如数据库恰好也读不了的时候）。
  void _recordError(String key, String atKey, Object e) {
    try {
      repo.setSetting(key, '$e');
      repo.setSetting(atKey, DateTime.now().toIso8601String());
    } catch (_) {
      // 连错误都记不下来，那也只能算了
    }
  }

  /// 手动触发一次完整备份。
  ///
  /// [targetDir] 为空时写到设置里的完整备份目录（默认 `backups/`，自动
  /// 轮转）；给了就写到用户当场挑的那个文件夹里 —— 那地方是用户自己的
  /// （移动硬盘、网盘同步目录），我们只放一份进去，不轮转、也不碰里面的
  /// 其它东西。
  Future<File> createFullBackupNow({
    Directory? targetDir,
    void Function(double progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final file = await backup.createFullBackup(
      keep: backupFullKeep,
      targetDir: targetDir,
      onProgress: onProgress,
      isCancelled: isCancelled,
    );
    repo.setSetting(
      'backup.lastFullAt',
      file.statSync().modified.toIso8601String(),
    );
    repo.setSetting('backup.lastFullError', '');
    repo.setSetting('backup.lastFullErrorAt', '');
    notifyListeners();
    return file;
  }

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
    // 备份/快照的自定义目录先同步给服务，后面一整套流程（快照是否到期、
    // 完整备份写哪儿）都读它。
    _syncBackupDirs();
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

    // 图片数这个列以前是三套口径混着写的（导入写落盘文件数、编辑器写
    // 含视频的媒体数、统计页现算的是纯图片数），同一篇能在三个地方
    // 显示三个不同的数字。统一按最终口径回填一次。
    if (repo.getSetting('imagecount.backfilled') != '1') {
      repo.backfillImageCounts();
      repo.setSetting('imagecount.backfilled', '1');
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

  /// 把若干篇笔记移进回收站（软删除）。
  ///
  /// **顺手刷回收站计数**：`refresh()` 不带回收站（那是单独缓存的，
  /// 每次都查一遍全表不划算），所以删完只看 `refresh()` 的话，
  /// 设置页/左栏那个"回收站里几篇"还是旧数字。
  Future<void> trashNotes(Iterable<int> ids) async {
    repo.deleteNotes(ids);
    refreshTrash();
    await refresh();
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
    _dataRevision++;
    _collections = _visibleCollections();
    _tags = repo.allTags(hiddenOnly: _privacyMode);
    _notes = repo.listNotes(_effectiveFilter);
    _overview = repo.overview(hiddenOnly: _privacyMode);
    notifyListeners();
  }

  /// 只刷新列表（筛选变化时用，避免重算文集统计）。
  void refreshListOnly({bool notify = true, bool dataChanged = false}) {
    if (dataChanged) _dataRevision++;
    _notes = repo.listNotes(_effectiveFilter);
    if (notify) notifyListeners();
  }

  Future<void> refreshOverview() async {
    _dataRevision++;
    _overview = repo.overview(hiddenOnly: _privacyMode);
    _collections = _visibleCollections();
    _tags = repo.allTags(hiddenOnly: _privacyMode);
    notifyListeners();
  }

  // ── 标签 ────────────────────────────────────────────────────────────────

  /// 改标签名 / 合并 / 删除 / 改颜色。
  ///
  /// 都走这里而不是让页面直接摸 repo：改完必须重算标签列表和笔记列表
  /// （合并之后旧标签没了、计数也变了），漏一次界面就和数据库对不上。
  Future<void> renameTag(int id, String name) async {
    final selected = repo
        .allTags(hiddenOnly: _privacyMode)
        .where((t) => t.id == id)
        .firstOrNull;
    final renamedId = repo.renameTag(id, name);
    if (selected != null && _filter.tag == selected.name) {
      final renamed = repo
          .allTags(hiddenOnly: _privacyMode)
          .where((t) => t.id == renamedId)
          .firstOrNull;
      if (renamed != null) _filter = _filter.copyWith(tag: renamed.name);
    }
    await refresh();
  }

  Future<void> deleteTag(int id) async {
    repo.deleteTag(id);
    // 正看着这个标签就先跳回全部：留着筛一个不存在的标签只会是空列表
    if (_filter.tag != null) {
      final still = repo.allTags().any((t) => t.name == _filter.tag);
      if (!still) _filter = NoteFilter(sort: _filter.sort);
    }
    await refresh();
  }

  Future<void> setTagColor(int id, int color) async {
    repo.setTagColor(id, color);
    await refresh();
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

  /// 选文件夹。
  ///
  /// **要清掉「收藏」「归档」这些互斥口径** —— 和 [selectUncategorized] 里
  /// 记的是同一个坑，只是换了个入口：点「收藏」再点某个文件夹，两个胶囊会
  /// **同时高亮**，而且列表口径到底是哪个也说不清（用户报的就是这个）。
  /// 标签不清：标签是横切的筛选，允许叠在某个文件夹之上。
  void selectCollection(int? id) => setFilter(
    id == null
        ? _filter.copyWith(
            clearCollection: true,
            uncategorizedOnly: false,
            favoritesOnly: false,
            archivedOnly: false,
          )
        : _filter.copyWith(
            collectionId: id,
            uncategorizedOnly: false,
            favoritesOnly: false,
            archivedOnly: false,
          ),
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
  void selectUncategorized() =>
      setFilter(NoteFilter(uncategorizedOnly: true, sort: _filter.sort));

  /// 回到「全部笔记」。
  void selectAll() => setFilter(NoteFilter(sort: _filter.sort));

  void selectTag(String? tag) => setFilter(
    tag == null ? _filter.copyWith(clearTag: true) : _filter.copyWith(tag: tag),
  );

  void toggleFavorites() => setFilter(
    _filter.favoritesOnly
        ? const NoteFilter().copyWith(sort: _filter.sort)
        : NoteFilter(favoritesOnly: true, sort: _filter.sort),
  );

  // ── 文集（文件夹）管理 ──────────────────────────────────────────────────

  /// 新建文集。重名返回 null。
  Future<int?> createCollection(
    String name, {
    int color = 0xFF3B82F6,
    int? parentId,
  }) async {
    final id = repo.createCollection(name, color: color, parentId: parentId);
    if (id != null) {
      final parent = repo
          .allCollections(includeHidden: true)
          .where((c) => c.id == parentId)
          .firstOrNull;
      if (_privacyMode || (parent?.isHidden ?? false)) {
        repo.setCollectionHidden(id, true);
      }
      await refresh();
    }
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

  /// 整篇笔记的标签一次定完（标签弹窗用）。
  ///
  /// 会顺带刷新：左栏标签列表的计数、以及"当前正按某个标签筛选"的列表
  /// 都得跟着变 —— 正在看「随笔」时去掉这篇的标签，它就该从列表里消失。
  Future<void> setNoteTags(int noteId, List<String> names) async {
    repo.setNoteTags(noteId, names);
    await refresh();
  }

  void setSort(NoteSort s) => setFilter(_filter.copyWith(sort: s));

  // ── 主题 / 布局 ─────────────────────────────────────────────────────────

  void setThemeMode(ThemeMode m) {
    _themeMode = m;
    repo.setSetting('themeMode', m.name);
    notifyListeners();
  }

  /// 自定义主题色（强调色种子的 ARGB）；null = 用系统蓝。
  ///
  /// 只存种子色，不存整套调色板 —— 明暗两套主题都由它现推出来，
  /// 以后改派生规则时所有用户自动跟着更新。
  Color? get themeSeed {
    final raw = int.tryParse(repo.getSetting('theme.seed') ?? '');
    return raw == null ? null : Color(raw);
  }

  void setThemeSeed(Color? seed) {
    if (seed == null) {
      repo.setSetting('theme.seed', '');
    } else {
      repo.setSetting('theme.seed', '${seed.toARGB32()}');
    }
    notifyListeners();
  }

  /// 一键回到出厂主题：去掉强调色与自定义背景。
  ///
  /// 只清这几项，不动明暗模式 —— 用户调成深色是他要的，不该跟着一起被重置。
  void resetTheme() {
    repo.setSetting('theme.seed', '');
    repo.setSetting('theme.bgPath', '');
    repo.setSetting('theme.bgOpacity', '');
    repo.setSetting('theme.bgBlur', '');
    repo.setSetting('theme.bgScale', '');
    repo.setSetting('theme.bgFocus', '');
    notifyListeners();
  }

  /// 界面背景图（本地绝对路径）；null = 纯色背景。
  String? get themeBackgroundPath {
    final raw = repo.getSetting('theme.bgPath') ?? '';
    if (raw.isEmpty) return null;
    // 图被用户删了就当没设过，否则每帧都在 File 上失败一次
    if (!File(raw).existsSync()) return null;
    return raw;
  }

  void setThemeBackgroundPath(String? path) {
    repo.setSetting('theme.bgPath', (path ?? '').trim());
    notifyListeners();
  }

  /// 背景图的浓度：0 = 完全看不见，1 = 原图不透明。
  ///
  /// 默认给 0.5 —— 满浓度铺在文字底下基本没法读，而太淡又看不出有图。
  double get themeBackgroundOpacity {
    final raw = double.tryParse(repo.getSetting('theme.bgOpacity') ?? '');
    return (raw ?? 0.5).clamp(0.0, 1.0);
  }

  void setThemeBackgroundOpacity(double v) {
    repo.setSetting('theme.bgOpacity', v.clamp(0.0, 1.0).toStringAsFixed(2));
    notifyListeners();
  }

  /// 背景图的模糊半径（逻辑像素）：调大一点，图就不跟正文抢注意力。
  double get themeBackgroundBlur {
    final raw = double.tryParse(repo.getSetting('theme.bgBlur') ?? '');
    return (raw ?? 0.0).clamp(0.0, 40.0);
  }

  void setThemeBackgroundBlur(double v) {
    repo.setSetting('theme.bgBlur', v.clamp(0.0, 40.0).toStringAsFixed(1));
    notifyListeners();
  }

  /// 背景图的缩放：1 = 铺满（等比裁切），大于 1 是放大后取其中一块。
  ///
  /// 下限 1 而不是更小 —— 小于 1 会露出底色，看起来像图没铺满，用户
  /// 真正想要的是「把画面里那一块放大看」，那就只有 >= 1。
  double get themeBackgroundScale {
    final raw = double.tryParse(repo.getSetting('theme.bgScale') ?? '');
    return (raw ?? 1.0).clamp(1.0, 4.0);
  }

  void setThemeBackgroundScale(double v) {
    repo.setSetting('theme.bgScale', v.clamp(1.0, 4.0).toStringAsFixed(2));
    notifyListeners();
  }

  /// 背景图的对焦点：0~1 归一化坐标，(0.5, 0.5) 是正中。
  ///
  /// 存归一化值而不是像素偏移：窗口一拉大、手机上横竖屏一换，像素偏移
  /// 立刻失去意义，而「我要看图的右下角」这个意图不变。
  Offset get themeBackgroundFocus {
    final raw = repo.getSetting('theme.bgFocus') ?? '';
    final parts = raw.split(',');
    if (parts.length == 2) {
      final x = double.tryParse(parts[0]);
      final y = double.tryParse(parts[1]);
      if (x != null && y != null) {
        return Offset(x.clamp(0.0, 1.0), y.clamp(0.0, 1.0));
      }
    }
    return const Offset(0.5, 0.5);
  }

  void setThemeBackgroundFocus(Offset v) {
    final x = v.dx.clamp(0.0, 1.0).toStringAsFixed(3);
    final y = v.dy.clamp(0.0, 1.0).toStringAsFixed(3);
    repo.setSetting('theme.bgFocus', '$x,$y');
    notifyListeners();
  }

  /// 自定义参数（头参数 / 尾参数）的读写。懒加载，用到才建。
  FieldRepository? _fields;
  FieldRepository get fields => _fields ??= FieldRepository(db);

  /// 参数定义被改动后叫一声，让依赖它的界面重建。
  void notifyDataChanged() {
    _dataRevision++;
    notifyListeners();
  }

  /// 是否显示头参数 / 尾参数。
  ///
  /// 默认都开：参数是这套笔记的一部分，阅读时当然要看得到，
  /// 不能只在编辑态露脸。不想看的人可以在设置里单独关掉。
  bool get headFieldsEnabled => repo.getSetting('fields.headEnabled') != '0';
  bool get tailFieldsEnabled => repo.getSetting('fields.tailEnabled') != '0';

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
  String get tocSide =>
      repo.getSetting('toc.side') == 'left' ? 'left' : 'right';

  void setTocSide(String side) {
    repo.setSetting('toc.side', side == 'left' ? 'left' : 'right');
    notifyListeners();
  }

  /// 目录栏宽度，可拖动。
  double get tocWidth =>
      (double.tryParse(repo.getSetting('toc.width') ?? '') ?? 220).clamp(
        160.0,
        420.0,
      );

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
    // 置顶不算"内容变了"，但**统计页的排序/活跃度也跟着它走**，
    // 而且需求上"点了星标，收藏数要立刻变"。这里统一报一次数据变更。
    refreshListOnly(dataChanged: true);
  }

  Future<void> toggleFavorite(Note n) async {
    repo.setFavorite(n.id, !n.isFavorite);
    // 同上：收藏数在概览卡片里，不涨 revision 的话统计页不会重算 ——
    // 用户点了星标回到统计页，收藏数还是老数字。
    refreshListOnly(dataChanged: true);
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
    final collection = repo
        .allCollections(includeHidden: true)
        .where((c) => c.id == (collectionId ?? _filter.collectionId))
        .firstOrNull;
    if (_privacyMode || (collection?.isHidden ?? false)) {
      repo.setNoteHidden(id, true);
    }
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
