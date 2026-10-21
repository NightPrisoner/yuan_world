/// 备份与恢复。
///
/// ## 为什么必须有
///
/// 这是个**纯本地**应用：533 篇笔记、几百兆图片视频全在一台机器的
/// 一个目录里。没有云、没有同步，也没有任何自动兜底 —— 误删、误改、
/// 硬盘故障、换机，任何一次都是"全没了"。以前设置里只有一句
/// "备份时手动复制这两个目录"，等于把最要紧的事交给用户自己记得。
///
/// ## 两种备份，各有各的用途
///
///   · **全量备份**（`exportAll`）：数据库 + 全部图片视频，打成一个 zip。
///     给"换机 / 长期归档"用，文件大（可能几百兆），由用户主动触发。
///   · **每日快照**（`snapshot`）：**只含数据库**，几兆，自动跑、自动轮转。
///     图片是文件、不会被"误删一条笔记"影响，真正容易丢的是数据库里的
///     内容本身。所以快照不重复存媒体，省空间也省时间。
///
/// ## 一致性问题（这块不能想当然）
///
/// 数据库开了 WAL：**直接拷 `.db` 文件可能少掉最近的事务**。
/// 所以一律用 SQLite 的 `VACUUM INTO` 导出 —— 它写出的是一个完整、
/// 一致、已整理过的副本，和原库的日志状态无关。
///
/// 恢复时同理：先关连接 → 换文件 → 再打开，中途不让任何人查询
/// （见 [AppDatabase.closeForRestore] / [AppDatabase.reopen]）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../db/app_database.dart';
import '../db/schema.dart';

/// 备份清单，压在包里的 `backup.json`，恢复前先认一下是不是我们的包。
class BackupManifest {
  const BackupManifest({
    required this.createdAt,
    required this.schemaVersion,
    required this.noteCount,
    required this.withMedia,
  });

  final DateTime createdAt;
  final int schemaVersion;
  final int noteCount;

  /// 这份备份里有没有图片视频。
  final bool withMedia;

  Map<String, Object?> toJson() => <String, Object?>{
    'app': 'yuan_world',
    'createdAt': createdAt.toIso8601String(),
    'schemaVersion': schemaVersion,
    'noteCount': noteCount,
    'withMedia': withMedia,
  };

  static BackupManifest? fromJson(Map<String, Object?> j) {
    if (j['app'] != 'yuan_world') return null;
    return BackupManifest(
      createdAt:
          DateTime.tryParse('${j['createdAt']}') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      schemaVersion: (j['schemaVersion'] as int?) ?? 0,
      noteCount: (j['noteCount'] as int?) ?? 0,
      withMedia: j['withMedia'] == true,
    );
  }
}

/// 恢复的结果，用来给用户一句人话。
class RestoreResult {
  const RestoreResult({
    required this.notes,
    required this.collections,
    required this.mediaFiles,
    required this.safetyCopy,
  });

  final int notes;
  final int collections;
  final int mediaFiles;

  /// 恢复前的**安全副本**路径（恢复错了还能再回去）。
  final String? safetyCopy;

  String get summary =>
      '已恢复 $notes 篇笔记、$collections 个文集'
      '${mediaFiles > 0 ? '，$mediaFiles 个媒体文件' : ''}';
}

class BackupService {
  BackupService(this.db);

  final AppDatabase db;

  /// 快照目录：`<root>/snapshots/`。
  Directory get snapshotDir {
    final d = Directory(p.join(db.rootDir.path, 'snapshots'));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  // ── 导出 ────────────────────────────────────────────────────────────────

  /// 把数据库导成一个**一致**的副本文件（WAL 下不能直接拷文件）。
  File _exportDbTo(String path) {
    final target = File(path);
    if (target.existsSync()) target.deleteSync();
    // VACUUM INTO 只接受字面量路径，单引号按 SQL 规则转义
    final escaped = p.absolute(target.path).replaceAll("'", "''");
    db.db.execute("VACUUM INTO '$escaped'");
    return target;
  }

  int _count(String table) {
    final r = db.db.select(
      'SELECT COUNT(*) AS c FROM $table WHERE deleted_at IS NULL',
    );
    return (r.first['c'] as int?) ?? 0;
  }

  int get _schemaVersion =>
      (db.db.select('PRAGMA user_version').first.columnAt(0) as int?) ?? 0;

  /// 全量备份：数据库 + 全部媒体，打成一个 zip。
  ///
  /// 返回 zip 字节（调用方自己决定存哪、怎么存），大文件也不会写进内存两次 ——
  /// archive 的 `ZipEncoder` 需要完整字节，所以这里的内存占用约等于
  /// 数据库大小 + 媒体大小，几十到几百兆，桌面端可以接受。
  Uint8List exportAll() {
    final archive = Archive();
    final tmp = Directory.systemTemp.createTempSync('yw_backup_');
    try {
      final dbFile = _exportDbTo(p.join(tmp.path, 'yuanworld.db'));
      archive.addFile(
        ArchiveFile(
          'yuanworld.db',
          dbFile.lengthSync(),
          dbFile.readAsBytesSync(),
        ),
      );

      var mediaCount = 0;
      final images = Directory(p.join(db.rootDir.path, 'images'));
      if (images.existsSync()) {
        for (final f in images.listSync(recursive: true)) {
          if (f is! File) continue;
          final rel = p.relative(f.path, from: db.rootDir.path);
          final bytes = f.readAsBytesSync();
          archive.addFile(ArchiveFile(rel, bytes.length, bytes));
          mediaCount++;
        }
      }

      archive.addFile(
        ArchiveFile.string(
          'backup.json',
          const JsonEncoder.withIndent('  ').convert(
            BackupManifest(
              createdAt: DateTime.now(),
              schemaVersion: _schemaVersion,
              noteCount: _count('notes'),
              withMedia: mediaCount > 0,
            ).toJson(),
          ),
        ),
      );
      return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
    } finally {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    }
  }

  // ── 每日快照 ────────────────────────────────────────────────────────────

  /// 写一份数据库快照，并按 [keep] 轮转（删掉最旧的）。
  File snapshot({int keep = 7}) {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
    // 同一秒里连拍两张会同名 —— 后一张会把前一张**覆盖**掉，
    // 于是"轮转保留 N 份"永远只有 1 份。重名就加序号。
    var name = 'yw-$stamp.db';
    var n = 2;
    while (File(p.join(snapshotDir.path, name)).existsSync()) {
      name = 'yw-$stamp-$n.db';
      n++;
    }
    final file = _exportDbTo(p.join(snapshotDir.path, name));
    _rotate(keep);
    return file;
  }

  /// 现有的快照，**新的在前**。
  List<File> snapshots() {
    if (!snapshotDir.existsSync()) return const <File>[];
    final files =
        snapshotDir
            .listSync()
            .whereType<File>()
            .where((f) => f.path.endsWith('.db'))
            .toList()
          ..sort((a, b) => b.path.compareTo(a.path));
    return files;
  }

  File? lastSnapshot() => snapshots().isEmpty ? null : snapshots().first;

  /// 是否需要再拍一张（默认一天一张）。
  bool snapshotDue({int keep = 7, Duration every = const Duration(hours: 24)}) {
    final last = lastSnapshot();
    if (last == null) return true;
    return DateTime.now().difference(last.statSync().modified) >= every;
  }

  void _rotate(int keep) {
    final files = snapshots();
    for (var i = keep; i < files.length; i++) {
      try {
        files[i].deleteSync();
      } catch (_) {
        // 删不掉就算了，不能让轮转把备份流程搞失败
      }
    }
  }

  // ── 恢复 ────────────────────────────────────────────────────────────────

  /// 从备份恢复。**会覆盖当前数据**，调用方必须先跟用户确认。
  ///
  /// [backup] 可以是全量 zip，也可以是一份裸的 .db（快照就是这个形态）。
  /// 步骤刻意分得很清楚：先校验 → 再给当前数据留安全副本 → 最后才换文件，
  /// 任何一步失败都不会把现有数据搞坏。
  RestoreResult restore(File backup) {
    if (!backup.existsSync()) {
      throw StateError('备份文件不存在：${backup.path}');
    }

    final tmp = Directory.systemTemp.createTempSync('yw_restore_');
    try {
      final File incoming;
      List<File> media = const <File>[];
      if (backup.path.toLowerCase().endsWith('.zip')) {
        final archive = ZipDecoder().decodeBytes(backup.readAsBytesSync());
        File? dbEntry;
        for (final f in archive) {
          if (!f.isFile) continue;
          // ZIP 文件名来自外部输入。统一分隔符并检查规范化后的路径，
          // 避免 `../` 或绝对路径把文件写到临时目录之外。
          final entryName = f.name.replaceAll('\\', '/');
          final outPath = p.normalize(p.join(tmp.path, entryName));
          if (!p.isWithin(tmp.path, outPath)) {
            throw StateError('备份包含越界文件路径：${f.name}');
          }
          final out = File(outPath);
          out.parent.createSync(recursive: true);
          out.writeAsBytesSync(f.content as List<int>);
          if (f.name == 'yuanworld.db') dbEntry = out;
        }
        if (dbEntry == null) throw StateError('这个压缩包里没有 yuanworld.db，不是元世界的备份');
        incoming = dbEntry;
        final mediaDir = Directory(p.join(tmp.path, 'images'));
        if (mediaDir.existsSync()) {
          media = mediaDir.listSync(recursive: true).whereType<File>().toList();
        }
      } else {
        incoming = File(p.join(tmp.path, 'incoming.db'))
          ..writeAsBytesSync(backup.readAsBytesSync());
      }

      _assertLooksLikeOurDb(incoming);
      final before = _readStats(incoming);
      if (before.notes == 0) {
        throw StateError('这份备份里一篇笔记都没有，为免误清空，已取消恢复');
      }

      // Run migration against a disposable copy before touching the live DB.
      // An integrity check alone accepts structurally incomplete SQLite files.
      final stagedDir = Directory(p.join(tmp.path, 'validated'))..createSync();
      final stagedFile = incoming.copySync(
        p.join(stagedDir.path, 'yuanworld.db'),
      );
      final staged = AppDatabase.openAt(stagedDir.path);
      try {
        staged.db.select(
          'SELECT title, content, excerpt, collection_id, '
          'char_count, word_count, image_count, is_hidden, is_archived, '
          'is_pinned, is_favorite, updated_at, created_at, cover_image '
          'FROM notes LIMIT 0',
        );
        staged.db.select(
          'SELECT name, color, parent_id, is_hidden, is_pinned, '
          'sort_order FROM collections LIMIT 0',
        );
        staged.db.select('SELECT key, value FROM settings LIMIT 0');
        if (staged.db.select('PRAGMA foreign_key_check').isNotEmpty) {
          throw StateError('备份包含不完整的数据关联，已取消恢复');
        }
      } finally {
        staged.close();
      }

      // 1) 先给**当前**数据留一份安全副本（恢复错了还能回去）
      final safety = _exportDbTo(
        p.join(
          snapshotDir.path,
          'pre-restore-${DateTime.now().millisecondsSinceEpoch}.db',
        ),
      );

      // 2) 关连接 → 换数据库文件 → 再打开（重新跑迁移/自愈）
      // Preserve overwritten media too, so a partial media copy can roll back.
      final previousMedia = <String, File?>{};
      final rollbackDir = Directory(p.join(tmp.path, 'previous-media'))
        ..createSync();
      for (final f in media) {
        final rel = p.relative(f.path, from: p.join(tmp.path, 'images'));
        final target = File(p.join(db.imageRoot.path, rel));
        File? previous;
        if (target.existsSync()) {
          previous = File(p.join(rollbackDir.path, rel));
          previous.parent.createSync(recursive: true);
          target.copySync(previous.path);
        }
        previousMedia[target.path] = previous;
      }

      var copied = 0;
      final changedMedia = <String>[];
      db.closeForRestore();
      try {
        for (final suffix in <String>['', '-wal', '-shm']) {
          final f = File('${db.dbPath}$suffix');
          if (f.existsSync()) f.deleteSync();
        }
        stagedFile.copySync(db.dbPath);
        db.reopen();
        // Snapshots have no media, so retain existing media in that case.
        for (final f in media) {
          final rel = p.relative(f.path, from: p.join(tmp.path, 'images'));
          final target = File(p.join(db.imageRoot.path, rel));
          target.parent.createSync(recursive: true);
          changedMedia.add(target.path);
          f.copySync(target.path);
          copied++;
        }
      } catch (_) {
        db.closeForRestore();
        for (final suffix in <String>['', '-wal', '-shm']) {
          final f = File('${db.dbPath}$suffix');
          if (f.existsSync()) f.deleteSync();
        }
        safety.copySync(db.dbPath);
        db.reopen();
        for (final path in changedMedia.reversed) {
          final previous = previousMedia[path];
          if (previous != null) {
            previous.copySync(path);
          } else {
            final target = File(path);
            if (target.existsSync()) target.deleteSync();
          }
        }
        rethrow;
      }

      final after = _readStats(File(db.dbPath));
      return RestoreResult(
        notes: after.notes,
        collections: after.collections,
        mediaFiles: copied,
        safetyCopy: safety.path,
      );
    } finally {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    }
  }

  /// 校验：能打开、`integrity_check` 通过、而且确实是我们这个库。
  void _assertLooksLikeOurDb(File f) {
    Database? probe;
    try {
      probe = sqlite3.open(f.path, mode: OpenMode.readOnly);
      final check = probe.select('PRAGMA integrity_check').first.columnAt(0);
      if (check != 'ok') throw StateError('备份文件损坏：$check');
      final version =
          probe.select('PRAGMA user_version').first.columnAt(0) as int;
      if (version > kSchemaVersion) {
        throw StateError('备份来自更新版本，请先升级元世界再恢复');
      }
      final tables = probe
          .select("SELECT name FROM sqlite_master WHERE type='table'")
          .map((r) => r['name'])
          .toSet();
      if (!tables.contains('notes')) {
        throw StateError('这个文件里没有 notes 表，不像是元世界的备份');
      }
    } on SqliteException catch (e) {
      throw StateError('无法读取这个文件（不是有效的数据库？）：${e.message}');
    } finally {
      probe?.close();
    }
  }

  ({int notes, int collections}) _readStats(File dbFile) {
    Database? probe;
    try {
      probe = sqlite3.open(dbFile.path, mode: OpenMode.readOnly);
      int count(String t) {
        try {
          final rows = probe!.select(
            'SELECT COUNT(*) AS c FROM $t WHERE deleted_at IS NULL',
          );
          return (rows.first['c'] as int?) ?? 0;
        } catch (_) {
          // 极老的表可能还没 deleted_at 列
          final rows = probe!.select('SELECT COUNT(*) AS c FROM $t');
          return (rows.first['c'] as int?) ?? 0;
        }
      }

      return (notes: count('notes'), collections: count('collections'));
    } finally {
      probe?.close();
    }
  }
}
