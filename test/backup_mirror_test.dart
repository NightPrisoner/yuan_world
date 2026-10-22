import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/data/backup/backup_service.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';

/// 异地备份：本机的备份和数据库在同一块盘上，盘坏了两个一起没。
///
/// 这一组守的是「真的写到别的地方去了」这件事 —— 只要写入逻辑还在，
/// 用户换成网盘同步目录就自动获得一份离线副本。
void main() {
  late Directory root;
  late AppDatabase db;
  late NoteRepository repo;
  late BackupService backup;

  setUp(() {
    root = Directory.systemTemp.createTempSync('yw_mirror_');
    db = AppDatabase.openAt(p.join(root.path, 'data'));
    repo = NoteRepository(db);
    backup = BackupService(db);
    for (var i = 0; i < 3; i++) {
      repo.insertNote(
        title: '笔记 $i',
        content: '正文 $i' * 20,
        excerpt: '正文',
        publishedAt: DateTime.now(),
      );
    }
  });

  tearDown(() {
    db.close();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  Directory mirror() {
    final d = Directory(p.join(root.path, 'usb-drive'));
    d.createSync(recursive: true);
    return d;
  }

  group('异地完整备份', () {
    test('复制出去的那份是完整的 zip，里面有数据库和清单', () async {
      final source = await backup.createFullBackup(keep: 2);
      final target = mirror();
      final copied = await backup.mirrorFullBackup(source, target, keep: 2);

      expect(copied.existsSync(), isTrue);
      // 放在子目录里，不往用户选的目录根上乱丢东西
      expect(p.basename(copied.parent.path), 'yuanworld-backups');
      expect(copied.lengthSync(), source.lengthSync());
      // 内容一致（逐字节比，别只看大小）
      expect(copied.readAsBytesSync(), source.readAsBytesSync());
    });

    test('同一个文件名再复制一次不会抛，直接覆盖', () async {
      final source = await backup.createFullBackup(keep: 2);
      final target = mirror();
      await backup.mirrorFullBackup(source, target, keep: 2);
      // 第二次复制同一份（用户连点两次"立即备份"就会这样）
      await backup.mirrorFullBackup(source, target, keep: 2);
      expect(backup.mirroredFullBackups(target).length, 1);
    });

    test('异地目录里也轮转，只留最近 N 份', () async {
      final target = mirror();
      final made = <String>[];
      for (var i = 0; i < 4; i++) {
        // 同一秒内连做四份会撞名（文件名精确到秒），隔一秒再造
        if (i > 0) await Future<void>.delayed(const Duration(milliseconds: 1100));
        final source = await backup.createFullBackup(keep: 10);
        made.add(p.basename(source.path));
        await backup.mirrorFullBackup(source, target, keep: 2);
      }
      // 留下来的是最后两份（文件名带时间戳，字典序即时间序）
      final kept =
          backup.mirroredFullBackups(target).map((f) => p.basename(f.path)).toList();
      expect(kept, made.sublist(made.length - 2).reversed.toList());
    });

    test('只删自己放的 full-*.zip，别人的文件一概不动', () async {
      final target = mirror();
      final stranger = File(p.join(target.path, 'yuanworld-backups', '别人的.zip'));
      stranger.createSync(recursive: true);
      stranger.writeAsStringSync('别删我');
      final note = File(p.join(target.path, '我的备忘.txt'))..writeAsStringSync('x');

      for (var i = 0; i < 4; i++) {
        final source = await backup.createFullBackup(keep: 10);
        await backup.mirrorFullBackup(source, target, keep: 1);
      }
      expect(backup.mirroredFullBackups(target).length, 1);
      expect(stranger.existsSync(), isTrue, reason: '不是本应用放的文件不能删');
      expect(note.existsSync(), isTrue, reason: '用户目录里的东西更不能删');
    });

    test('源文件不存在时明确报错，而不是悄悄什么也没做', () async {
      final ghost = File(p.join(root.path, 'nope.zip'));
      expect(
        () => backup.mirrorFullBackup(ghost, mirror(), keep: 2),
        throwsA(isA<StateError>()),
      );
    });

    test('异地目录还没建出来也能用（第一周就是这种情况）', () async {
      final source = await backup.createFullBackup(keep: 2);
      final notYet = Directory(p.join(root.path, '还没插上的U盘'));
      expect(notYet.existsSync(), isFalse);
      final copied = await backup.mirrorFullBackup(source, notYet, keep: 2);
      expect(copied.existsSync(), isTrue);
    });

    test('还没复制过时，列出来是空的（界面据此显示"还没复制过"）', () {
      expect(backup.mirroredFullBackups(mirror()), isEmpty);
      expect(backup.mirroredFullBackups(Directory(p.join(root.path, 'x'))), isEmpty);
    });
  });

  group('AppState 接上异地备份', () {
    late AppState state;

    setUp(() async {
      state = AppState(db, repo, ImportService(db, repo));
      await state.init();
    });

    tearDown(() => state.dispose());

    test('设了目录之后，手动完整备份会在那个目录留一份', () async {
      final target = mirror();
      state.setBackupMirrorDir(target.path);
      expect(state.backupMirrorEnabled, isTrue);

      await state.createFullBackupNow();

      final copied = backup.mirroredFullBackups(target);
      expect(copied.length, 1);
      expect(state.lastMirrorAt, isNotNull);
      expect(state.lastMirrorError, anyOf(isNull, isEmpty));
    });

    test('没设目录时什么也不做，也不会报错', () async {
      expect(state.backupMirrorEnabled, isFalse);
      await state.createFullBackupNow();
      expect(state.lastMirrorAt, isNull);
    });

    test('目录写不进去时：本机备份照样成功，只把异地那栏标红', () async {
      // 用一个普通文件占住"目录"的位置，任何写入都会失败
      final blocked = File(p.join(root.path, '占位文件'))..writeAsStringSync('x');
      state.setBackupMirrorDir(blocked.path);

      await state.createFullBackupNow();

      // 本机那份是好的
      expect(backup.fullBackups(), isNotEmpty);
      expect(state.lastFullBackupAt, isNotNull);
      expect(state.lastFullBackupError, anyOf(isNull, isEmpty),
          reason: '异地失败不能污染本机备份的记账');
      // 异地那栏记下了原因
      expect(state.lastMirrorError, isNotNull);
      expect(state.lastMirrorError, isNotEmpty);
    });

    test('关掉异地备份只是清空设置，已经复制过去的文件不动', () async {
      final target = mirror();
      state.setBackupMirrorDir(target.path);
      await state.createFullBackupNow();
      final before = backup.mirroredFullBackups(target).length;
      expect(before, 1);

      state.setBackupMirrorDir('');
      expect(state.backupMirrorEnabled, isFalse);
      expect(backup.mirroredFullBackups(target).length, before);
    });
  });
}
