import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

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
  AppDatabase._(this.db, this.rootDir);

  final Database db;
  final Directory rootDir;

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

    final file = p.join(root.path, 'yuanworld.db');
    final db = sqlite3.open(file);

    // 每个连接都要单独设置
    db.execute('PRAGMA foreign_keys = ON');
    db.execute('PRAGMA journal_mode = WAL');
    db.execute('PRAGMA synchronous = NORMAL');
    db.execute('PRAGMA temp_store = MEMORY');
    // 大页面缓存，笔记列表滚动更顺
    db.execute('PRAGMA cache_size = -16000');

    final instance = AppDatabase._(db, root);
    instance._migrate();
    return instance;
  }

  /// 内存数据库，仅测试用。
  static AppDatabase inMemory() {
    final db = sqlite3.openInMemory();
    db.execute('PRAGMA foreign_keys = ON');
    final instance = AppDatabase._(db, Directory.systemTemp);
    instance._migrate();
    return instance;
  }

  void _migrate() {
    // PRAGMA 语句不支持 AS 别名，只能按下标取值
    final current =
        db.select('PRAGMA user_version').first.columnAt(0) as int;

    if (current == 0) {
      db.execute('BEGIN');
      try {
        for (final sql in kCreateStatements) {
          db.execute(sql);
        }
        db.execute('PRAGMA user_version = $kSchemaVersion');
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
      return;
    }

    if (current < kSchemaVersion) {
      db.execute('BEGIN');
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
            db.execute(sql);
          }
        }
        db.execute('PRAGMA user_version = $kSchemaVersion');
        db.execute('COMMIT');
      } catch (_) {
        db.execute('ROLLBACK');
        rethrow;
      }
    }

    // ── 自愈 ──────────────────────────────────────────────────────────────
    //
    // 光靠版本号不可靠：曾经出现过"版本号写成了 7，但迁移其实是空的"，
    // 于是列不存在、迁移又永远不会再跑，启动就白屏。
    // 这里对关键列做一次存在性检查，缺了就补 —— 幂等，且不依赖版本号。
    _ensureColumn('notes', 'deleted_at', 'INTEGER');
    _ensureColumn('collections', 'deleted_at', 'INTEGER');
  }

  /// 表里没有这一列就加上。已经有就什么都不做。
  void _ensureColumn(String table, String column, String type) {
    final cols = db.select('PRAGMA table_info($table)');
    for (final r in cols) {
      if (r['name'] == column) return;
    }
    db.execute('ALTER TABLE $table ADD COLUMN $column $type');
  }

  void close() {
    db.close();
  }
}
