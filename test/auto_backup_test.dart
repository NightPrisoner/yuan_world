/// 自动备份：**光有开关不算数，得看真备成了没有**。
///
/// 这里钉住四件事：
///   · 完整备份能边压边写盘，产出的 zip 与老的内存版内容一致；
///   · 完整备份按份数轮转，不会悄悄把盘塞满；
///   · 每次自动备份的结果（成功时间 / 失败原因）都留得下来，界面能显示；
///   · 运行期间的定时器真的会到点检查，且 dispose 之后不再动。
library;

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/data/backup/backup_service.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';

void main() {
  late Directory root;
  late AppDatabase db;
  late NoteRepository repo;
  late BackupService backup;
  late AppState state;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('yw_autobackup_');
    db = AppDatabase.openAt(root.path);
    repo = NoteRepository(db);
    backup = BackupService(db);
    state = AppState(db, repo, ImportService(db, repo));
    repo.insertNote(
      title: '备份测试',
      content: '正文',
      excerpt: '正文',
      publishedAt: DateTime.now(),
    );
    await state.init();
  });

  tearDown(() {
    state.dispose();
    db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Map<String, ArchiveFile> unzip(List<int> bytes) => <String, ArchiveFile>{
    for (final f in ZipDecoder().decodeBytes(bytes))
      if (f.isFile) f.name: f,
  };

  void addMedia(String rel, List<int> bytes) {
    final f = File(p.join(db.imageRoot.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes);
  }

  group('完整备份写盘', () {
    test('导出到文件：数据库、媒体、清单都在，进度走到 1', () async {
      addMedia('7/a.png', <int>[1, 2, 3, 4]);
      addMedia('7/b.png', <int>[5, 6]);

      final target = File(p.join(root.path, 'out.zip'));
      final seen = <double>[];
      await backup.exportAllTo(target, onProgress: seen.add);

      expect(target.existsSync(), isTrue);
      final files = unzip(target.readAsBytesSync());
      expect(files.keys, contains(BackupService.manifestEntryName));
      expect(files.keys, contains(BackupService.databaseEntryName));
      expect(files.keys, contains('images/7/a.png'));
      expect(files.keys, contains('images/7/b.png'));
      expect(seen, isNotEmpty);
      expect(seen.last, 1.0);
      expect(seen, orderedEquals(List<double>.from(seen)..sort()));
    });

    test('目标位置写不进去：抛错，且不留下半截包', () async {
      // 父路径是个普通文件 → 建目录这一步就失败
      final blocker = File(p.join(root.path, 'blocker'))
        ..writeAsStringSync('x');
      final target = File(p.join(blocker.path, 'out.zip'));
      await expectLater(backup.exportAllTo(target), throwsA(anything));
      expect(File(target.path).existsSync(), isFalse);
      expect(blocker.readAsStringSync(), 'x', reason: '别把别的东西写坏了');
    });

    test('备份目录里的旧包会被轮转掉', () async {
      await backup.createFullBackup(keep: 2);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await backup.createFullBackup(keep: 2);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await backup.createFullBackup(keep: 2);
      expect(backup.fullBackups().length, 2);
    });

    test('一周内不重复做完整备份', () async {
      expect(backup.fullBackupDue(), isTrue, reason: '一次都没有，肯定该做');
      final first = await backup.createFullBackup();
      expect(backup.fullBackupDue(), isFalse);
      first.setLastModifiedSync(
        DateTime.now().subtract(const Duration(days: 8)),
      );
      expect(backup.fullBackupDue(), isTrue);
    });
  });

  group('自动备份的账本', () {
    test('做完快照和完整备份都记下时间', () async {
      await state.checkAutoBackup();
      expect(state.lastSnapshotAt, isNotNull);
      expect(state.lastFullBackupAt, isNotNull);
      expect(state.lastSnapshotError, anyOf(isNull, isEmpty));
      expect(state.lastFullBackupError, anyOf(isNull, isEmpty));
      expect(backup.fullBackups(), isNotEmpty);
    });

    test('刚备过就不再重复做', () async {
      await state.checkAutoBackup();
      final first = backup.snapshots().length;
      final fullFirst = backup.fullBackups().length;
      await state.checkAutoBackup();
      expect(backup.snapshots().length, first);
      expect(backup.fullBackups().length, fullFirst);
    });

    test('快照失败要留下原因，而且不能把上次成功时间抹掉', () async {
      await state.checkAutoBackup();
      final good = state.lastSnapshotAt;
      expect(good, isNotNull);

      // 造一个必然写不进去的现场：把 snapshots 换成同名文件。
      // snapshotDir 是 getter，会先 make 目录 —— 所以先删目录再放文件，
      // 之后 getter 的 existsSync 为 true（是文件），createSync 不会跑。
      backup.snapshotDir.deleteSync(recursive: true);
      File(p.join(root.path, 'snapshots')).writeAsStringSync('not a dir');

      await state.checkAutoBackup();
      expect(state.lastSnapshotError, isNotNull);
      expect(state.lastSnapshotErrorAt, isNotNull);
      expect(state.lastSnapshotAt, good, reason: '失败不该抹掉上次成功的时间');
    });

    test('关掉开关就不做完整备份', () async {
      state.setBackupAutoFull(false);
      await state.checkAutoBackup();
      expect(backup.fullBackups(), isEmpty);
      expect(state.lastFullBackupAt, isNull);
    });

    test('手动做一次完整备份也会更新账本', () async {
      state.setBackupAutoFull(false);
      final file = await state.createFullBackupNow();
      expect(file.existsSync(), isTrue);
      expect(state.lastFullBackupAt, isNotNull);
    });
  });

  group('运行期间的定时检查', () {
    test('到点会自动检查一次', () async {
      // 这条只验"定时器会不会到点触发检查"，把两类自动备份关掉，
      // 免得测试里真去写几百兆的文件。
      state.setBackupAutoSnapshot(false);
      state.setBackupAutoFull(false);
      var calls = 0;
      state.addListener(() {
        if (state.autoBackupBusy) calls++;
      });
      state.startAutoBackupWatcher(every: const Duration(milliseconds: 30));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(calls, greaterThan(0), reason: '定时器到点应该跑去检查');
    });

    test('dispose 之后定时器不再触发', () async {
      state.setBackupAutoSnapshot(false);
      state.setBackupAutoFull(false);
      var calls = 0;
      state.addListener(() {
        if (state.autoBackupBusy) calls++;
      });
      state.startAutoBackupWatcher(every: const Duration(milliseconds: 30));
      state.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(calls, 0);
      // tearDown 还会再 dispose 一次，补一个新的避免 double dispose 报错
      state = AppState(db, repo, ImportService(db, repo));
    });
  });
}
