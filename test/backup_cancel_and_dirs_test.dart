/// 备份能被取消，以及快照/完整备份的目录能改、能回默认。
///
/// 这两件事都是用户明确提的：
/// - "备份支持中断取消" —— 几百兆的包压到一半改主意，得真能停下来；
/// - "自动备份可修改地址可回默认，集成同一栏"。
library;

import 'dart:io';

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
  late AppState state;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('yw_backup_cancel_');
    db = AppDatabase.openAt(root.path);
    repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
  });

  tearDown(() {
    state.dispose();
    db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  void addMedia(String rel, List<int> bytes) {
    final f = File(p.join(db.imageRoot.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes);
  }

  int addNote(String title) => repo.insertNote(
    title: title,
    content: '正文 $title',
    excerpt: '正文',
    publishedAt: DateTime.now(),
  );

  group('备份能取消', () {
    test('一开始就取消：抛 BackupCancelledException，且不留半截包', () async {
      addNote('甲');
      addMedia('1/a.png', List<int>.filled(256, 7));
      final out = File(p.join(root.path, 'cancel-me.zip'));

      await expectLater(
        state.backup.exportAllTo(out, isCancelled: () => true),
        throwsA(isA<BackupCancelledException>()),
      );
      expect(
        out.existsSync(),
        isFalse,
        reason: '半截的 zip 比没有更糟：用户会以为备份好了',
      );
    });

    test('压到一半取消：目标文件被清掉，已写出的字节不留在盘上', () async {
      addNote('甲');
      for (var i = 1; i <= 40; i++) {
        addMedia('1/$i.png', List<int>.filled(1024, i));
      }
      final out = File(p.join(root.path, 'half.zip'));

      // 进度过 30% 之后就当成用户点了取消
      var cancel = false;
      await expectLater(
        state.backup.exportAllTo(
          out,
          onProgress: (v) {
            if (v > 0.3) cancel = true;
          },
          isCancelled: () => cancel,
        ),
        throwsA(isA<BackupCancelledException>()),
      );
      expect(out.existsSync(), isFalse);
    });

    test('取消不算失败：本机的"上次备份"时间不会被写脏', () async {
      addNote('甲');
      addMedia('1/a.png', List<int>.filled(64, 3));
      final before = state.lastFullBackupAt;

      await expectLater(
        state.createFullBackupNow(isCancelled: () => true),
        throwsA(isA<BackupCancelledException>()),
      );
      expect(state.lastFullBackupAt, before);
      expect(state.lastFullBackupError, isNull);
    });

    test('不取消就正常出包（取消回调不影响正常路径）', () async {
      addNote('甲');
      addMedia('1/a.png', List<int>.filled(64, 3));
      final out = File(p.join(root.path, 'fine.zip'));
      await state.backup.exportAllTo(out, isCancelled: () => false);
      expect(out.existsSync(), isTrue);
      expect(out.lengthSync(), greaterThan(0));
    });
  });

  group('快照与完整备份的目录能改能回默认', () {
    test('默认都在数据目录底下', () {
      expect(state.backupSnapshotDirIsCustom, isFalse);
      expect(state.backupFullDirIsCustom, isFalse);
      expect(
        state.backup.snapshotDir.path,
        p.join(db.rootDir.path, 'snapshots'),
      );
      expect(
        state.backup.fullBackupDir.path,
        p.join(db.rootDir.path, 'backups'),
      );
    });

    test('改完之后服务真的往新目录写，设置也存得住', () async {
      final snapDir = Directory(p.join(root.path, 'my-snaps'));
      final fullDir = Directory(p.join(root.path, 'my-full'));
      state.setBackupSnapshotDir(snapDir.path);
      state.setBackupFullDir(fullDir.path);

      expect(state.repo.getSetting('backup.snapshotDir'), snapDir.path);
      expect(state.repo.getSetting('backup.fullDir'), fullDir.path);
      expect(state.backup.snapshotDir.path, snapDir.path);
      expect(state.backup.fullBackupDir.path, fullDir.path);

      // 快照真的落在新目录里
      final snap = state.backup.snapshot();
      expect(p.dirname(snap.path), snapDir.path);

      // 完整备份也真的落在新目录里
      final full = await state.createFullBackupNow();
      expect(p.dirname(full.path), fullDir.path);
    });

    test('重开应用（新建 AppState 走 init）之后目录还在', () async {
      final custom = Directory(p.join(root.path, 'kept'));
      state.setBackupFullDir(custom.path);

      final second = AppState(db, repo, ImportService(db, repo));
      await second.init();
      addTearDown(second.dispose);
      expect(second.backupFullDirIsCustom, isTrue);
      expect(second.backup.fullBackupDir.path, custom.path);
    });

    test('回默认：清掉设置，服务又写回数据目录底下', () {
      final custom = Directory(p.join(root.path, 'temp-dir'));
      state.setBackupFullDir(custom.path);
      expect(state.backupFullDirIsCustom, isTrue);

      state.setBackupFullDir('');

      expect(state.backupFullDirIsCustom, isFalse);
      expect(state.backupFullDir, '');
      expect(
        state.backup.fullBackupDir.path,
        state.backup.defaultFullBackupDir.path,
      );
    });

    test('目录里已经有同名文件也能正常写（不会互相踩）', () async {
      final custom = Directory(p.join(root.path, 'busy'))
        ..createSync(recursive: true);
      // 放一个跟备份包同名的旧文件占位
      File(p.join(custom.path, 'full-20200101-000000.zip'))
          .writeAsStringSync('old');
      state.setBackupFullDir(custom.path);

      final full = await state.createFullBackupNow();
      expect(p.dirname(full.path), custom.path);
      expect(
        File(p.join(custom.path, 'full-20200101-000000.zip')).readAsStringSync(),
        'old',
        reason: '别人的文件一个字节都不能动',
      );
    });
  });
}
