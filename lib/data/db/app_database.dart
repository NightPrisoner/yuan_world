import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../search_grams.dart';
import 'schema.dart';

/// 应用数据库。负责打开 SQLite、执行迁移、暴露图片目录。
///
/// 这一层**不依赖 Flutter**：目录由调用方传入。
/// UI 侧用 `core/app_paths.dart` 的 `resolveAppRoot()` 拿到平台默认目录；
/// 命令行工具则可以直接指定任意目录，复用同一套逻辑。
///
/// 目录结构：
///   `<root>/yuanworld.db`      数据库
///   `<root>/images/<noteId>/`  该笔记的图片
class AppDatabase {
  AppDatabase._(this._db, this.rootDir);

  /// 连接。**不是 final**：恢复备份时要关掉、换掉文件、再打开
  /// （见 [closeForRestore] / [reopen]），而 repo、importer 里存的是
  /// 这个 AppDatabase 对象的引用，所以只能是换里面的连接，不能换对象。
  Database _db;
  Database get db => _db;

  /// 数据根目录。**不是 final**：设置里可以把整个数据目录搬到别的盘，
  /// 搬完要就地换掉，而不是重建 AppDatabase —— repo、importer、AppState
  /// 里都存着这个对象的引用，换对象等于所有缓存全部失效。
  Directory rootDir;

  /// 数据库文件路径。
  String get dbPath => p.join(rootDir.path, 'yuanworld.db');

  /// 图片根目录。
  Directory get imageRoot {
    final d = Directory(p.join(rootDir.path, 'images'));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 在指定目录打开（或创建）数据库。
  static AppDatabase openAt(String rootPath) {
    final root = Directory(rootPath);
    if (!root.existsSync()) root.createSync(recursive: true);

    final instance = AppDatabase._(sqlite3.open(p.join(root.path, 'yuanworld.db')), root);
    instance._tune();
    instance._migrate();
    return instance;
  }

  /// 内存数据库，仅测试用。
  static AppDatabase inMemory() {
    final instance = AppDatabase._(sqlite3.openInMemory(), Directory.systemTemp);
    instance._db.execute('PRAGMA foreign_keys = ON');
    // 自定义函数必须在这里也注册：内存库不走 _tune()，而迁移要用
    // search_segments() 回填 note_segments —— 漏了就是
    // "no such function: search_segments"，且**只有测试会炸**，
    // 真机上反而正常，最容易漏。
    instance._registerFunctions();
    instance._migrate();
    return instance;
  }

  /// 每个连接都要单独设置的 PRAGMA。
  void _tune() {
    _db.execute('PRAGMA foreign_keys = ON');
    _db.execute('PRAGMA journal_mode = WAL');
    _db.execute('PRAGMA synchronous = NORMAL');
    _db.execute('PRAGMA temp_store = MEMORY');
    // 大页面缓存，笔记列表滚动更顺
    _db.execute('PRAGMA cache_size = -16000');
    _registerFunctions();
  }

  /// 注册 SQL 里能用的 Dart 函数。
  ///
  /// 目前只有一个：`search_segments(text)` —— 把正文切成「每个汉字一个
  /// token」的分段文本，供 [note_segments] 的触发器与 v11 回填使用。
  ///
  /// **为什么不让 SQLite 触发器直接维护 note_segments**：SQL 里没有能力
  /// 逐字符判断 CJK 再插空格（能写，但要用 recursive CTE 逐字处理，
  /// 又慢又难读）。而切分规则必须与查询侧共用同一份实现（见
  /// `search_grams.dart` 的铁律），所以只能走自定义函数。
  ///
  /// **`directOnly: false` 是必须的**：sqlite3 包默认只允许在直接执行的
  /// 语句里调用自定义函数，放进触发器里会抛
  /// `unsafe use of search_segments()`。而这个函数恰恰主要就是给触发器用的。
  void _registerFunctions() {
    _db.createFunction(
      functionName: 'search_segments',
      argumentCount: const AllowedArgumentCount(1),
      deterministic: true,
      directOnly: false,
      function: (args) {
        final text = args.isEmpty ? null : args.first;
        if (text == null) return '';
        return searchSegments(text as String);
      },
    );
  }

  /// 关掉连接，好让调用方替换数据库文件（恢复备份用）。
  ///
  /// 替换完必须调 [reopen]，否则后面所有查询都会打在已关闭的连接上。
  void closeForRestore() => close();

  /// 把数据目录换到 [next]（文件已经拷过去了），重新打开连接。
  ///
  /// 换目录比换文件多一层坑：`-wal` / `-shm` 是跟着连接走的，
  /// 关库之后残留的 wal 会被下一次打开当成"未合并的改动"重放，
  /// 所以我们关库前先 checkpoint，保证主库文件是完整的。
  void relocateTo(Directory next) {
    checkpoint();
    close();
    rootDir = next;
    if (!next.existsSync()) next.createSync(recursive: true);
    reopen();
  }

  /// 把 WAL 里还没合并的改动写回主库，让文件可以安全复制。
  void checkpoint() {
    try {
      _db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    } catch (_) {
      // 只读连接、库刚关掉之类的情况，尽力而为
    }
  }

  /// 重新打开（恢复完调用）。会重新跑一遍迁移/自愈 ——
  /// 恢复进来的可能是**更旧的**库，得让它升级到当前 schema。
  void reopen() {
    _db = sqlite3.open(dbPath);
    _closed = false;
    _tune();
    _migrate();
  }

  void _migrate() {
    // PRAGMA 语句不支持 AS 别名，只能按下标取值
    final current =
        _db.select('PRAGMA user_version').first.columnAt(0) as int;

    if (current == 0) {
      _db.execute('BEGIN');
      try {
        for (final sql in kCreateStatements) {
          _db.execute(sql);
        }
        _db.execute('PRAGMA user_version = $kSchemaVersion');
        _db.execute('COMMIT');
      } catch (_) {
        _db.execute('ROLLBACK');
        rethrow;
      }
      return;
    }

    if (current < kSchemaVersion) {
      _db.execute('BEGIN');
      try {
        for (var v = current + 1; v <= kSchemaVersion; v++) {
          final steps = kMigrations[v];
          if (steps == null) {
            // **宁可炸在这里，也不要静默跳过。**
            // 之前 v7 的迁移漏配，循环什么都没做却把版本号写成了 7，
            // 结果库被标成"已升级"而列根本不存在，之后永远不会再迁移，
            // 启动直接白屏。
            throw StateError(
              'schema v$v 缺少迁移步骤：kMigrations 里没有 $v 这一项。'
              '要么补上，要么把 kSchemaVersion 调回去。',
            );
          }
          for (final sql in steps) {
            _db.execute(sql);
          }
        }
        _db.execute('PRAGMA user_version = $kSchemaVersion');
        _db.execute('COMMIT');
      } catch (_) {
        _db.execute('ROLLBACK');
        rethrow;
      }
    }

    // ── 自愈 ──────────────────────────────────────────────────────────────
    //
    // 光靠版本号不可靠：曾经出现过"版本号写成了 7，但迁移其实是空的"，
    // 于是列不存在、迁移又永远不会再跑，启动就白屏。
    // 这里对关键列做一次存在性检查，缺了就补 —— 幂等，且不依赖版本号。
    //
    // **哪些列该进这个名单**：每次写入都会碰到、缺了整个功能就瘫掉的。
    //   - deleted_at：所有查询都带 `deleted_at IS NULL`，缺了每条查询都报错
    //   - sort_key：每次 insertNote 都写它（标题拼音序也靠它），缺了
    //     **新建/导入全部失败**，比少一个筛选条件严重得多
    // 只加不删、且都带默认值，所以对老库是安全的。
    _ensureColumn('notes', 'deleted_at', 'INTEGER');
    _ensureColumn('collections', 'deleted_at', 'INTEGER');
    _ensureColumn('notes', 'sort_key', "TEXT NOT NULL DEFAULT ''");
  }

  /// 表里没有这一列就加上。已经有就什么都不做。
  void _ensureColumn(String table, String column, String type) {
    final cols = _db.select('PRAGMA table_info($table)');
    for (final r in cols) {
      if (r['name'] == column) return;
    }
    _db.execute('ALTER TABLE $table ADD COLUMN $column $type');
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _db.close();
  }

  bool _closed = false;
}
