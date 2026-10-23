import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yuan_world/data/backup/backup_service.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';

/// 手动备份要能存到用户当场挑的文件夹里。
///
/// 用户原话：「立即完整备份一次应该先让用户选择/询问存在什么地方，再开始备份」。
/// 这一组守的是「写到指定目录」这件事本身 —— 选位置的那层界面是弹窗，
/// 真正决定落盘位置的还是 [BackupService.createFullBackup] 的 `targetDir`。
void main() {
  late Directory root;
  late AppDatabase db;
  late NoteRepository repo;
  late BackupService backup;

  setUp(() {
    root = Directory.systemTemp.createTempSync('yw_target_');
    db = AppDatabase.openAt(p.join(root.path, 'data'));
    repo = NoteRepository(db);
    backup = BackupService(db);
    repo.insertNote(
      title: '笔记',
      content: '正文' * 20,
      excerpt: '正文',
      publishedAt: DateTime.now(),
    );
  });

  tearDown(() {
    db.close();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('给了目标目录就写到那儿，不往本机 backups 里放', () async {
    final usb = Directory(p.join(root.path, 'usb-drive'));
    final file = await backup.createFullBackup(targetDir: usb);

    expect(file.existsSync(), isTrue);
    expect(p.dirname(file.path), usb.path);
    expect(p.basename(file.path).startsWith('full-'), isTrue);
    expect(p.basename(file.path).endsWith('.zip'), isTrue);
    // 本机的 backups 目录里一份都不该有 —— 用户选的位置就是唯一那份
    expect(backup.fullBackups(), isEmpty);
  });

  test('目标目录还不存在时自动建出来', () async {
    final nested = Directory(p.join(root.path, '新盘', '笔记备份'));
    expect(nested.existsSync(), isFalse);
    final file = await backup.createFullBackup(targetDir: nested);
    expect(nested.existsSync(), isTrue);
    expect(file.existsSync(), isTrue);
  });

  test('写进指定目录的那份是完整包，里面有数据库', () async {
    final usb = Directory(p.join(root.path, 'usb-drive'));
    final file = await backup.createFullBackup(targetDir: usb);
    final zip = await file.readAsBytes();
    // zip 头：PK\x03\x04
    expect(zip.sublist(0, 2), <int>[0x50, 0x4b]);
    expect(zip.length > 1000, isTrue);
  });

  test('指定目录里不轮转 —— 连做两次都留着', () async {
    final usb = Directory(p.join(root.path, 'usb-drive'));
    final a = await backup.createFullBackup(targetDir: usb, keep: 1);
    // 同秒会撞名，改成错开一秒再写第二份
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    final b = await backup.createFullBackup(targetDir: usb, keep: 1);
    expect(a.existsSync(), isTrue);
    expect(b.existsSync(), isTrue);
    expect(usb.listSync().whereType<File>().length, 2);
  });

  test('不给目标目录时行为不变：写进 backups 并按 keep 轮转', () async {
    for (var i = 0; i < 3; i++) {
      await backup.createFullBackup(keep: 2);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
    }
    expect(backup.fullBackups().length, 2);
  });

  test('进度回调在指定目录模式下照样走', () async {
    final usb = Directory(p.join(root.path, 'usb-drive'));
    final seen = <double>[];
    await backup.createFullBackup(targetDir: usb, onProgress: seen.add);
    expect(seen, isNotEmpty);
    expect(seen.last, 1.0);
  });
}
