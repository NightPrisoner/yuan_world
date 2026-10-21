/// 备份与恢复。
///
/// 这是个纯本地应用：全部数据在一台机器的一个目录里。备份是**唯一**的
/// 兜底手段，所以每条规则都得钉住：
///   · 全量备份要真的含数据库 + 媒体，并且带清单；
///   · WAL 模式下导出的库必须**一致**（用 VACUUM INTO，不是拷文件）；
///   · 快照按份数轮转；
///   · 恢复要能回到备份时的状态；
///   · 坏文件、空库备份**绝不能**把现有数据搞坏（先校验再动手）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yuan_world/data/backup/backup_service.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';

void main() {
  late Directory root;
  late AppDatabase db;
  late NoteRepository repo;
  late BackupService backup;

  setUp(() {
    root = Directory.systemTemp.createTempSync('yw_backup_');
    db = AppDatabase.openAt(root.path);
    repo = NoteRepository(db);
    backup = BackupService(db);
  });

  tearDown(() {
    try {
      db.close();
    } catch (_) {}
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  int addNote(String title) => repo.insertNote(
    title: title,
    content: '正文 $title',
    excerpt: '正文',
    publishedAt: DateTime.now(),
  );

  void addMedia(String rel, List<int> bytes) {
    final f = File(p.join(db.imageRoot.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes);
  }

  Map<String, ArchiveFile> unzip(List<int> bytes) => <String, ArchiveFile>{
    for (final f in ZipDecoder().decodeBytes(bytes))
      if (f.isFile) f.name: f,
  };

  group('全量备份', () {
    test('含数据库、媒体和清单', () {
      addNote('甲的笔记');
      addNote('乙的笔记');
      addMedia('7/a.png', <int>[1, 2, 3, 4]);

      final files = unzip(backup.exportAll());

      expect(files.keys, contains('yuanworld.db'));
      // zip 里的路径一律用正斜杠（跨平台解压的标准做法）
      expect(files.keys, contains('images/7/a.png'));
      expect(files.keys, contains('backup.json'));

      final manifest = BackupManifest.fromJson(
        jsonDecode(utf8.decode(files['backup.json']!.content as List<int>))
            as Map<String, Object?>,
      )!;
      expect(manifest.noteCount, 2);
      expect(manifest.withMedia, isTrue);
      expect(manifest.schemaVersion, greaterThan(0));
    });

    test('清单能认出不是本应用的包', () {
      expect(BackupManifest.fromJson(<String, Object?>{'app': 'other'}), isNull);
    });

    test('导出的数据库是完整可用的（WAL 下直接拷文件会丢数据）', () {
      // 刚写完就导出：此刻数据还在 WAL 里，直接拷 .db 会少内容
      final id = addNote('在 WAL 里的笔记');
      expect(repo.getNote(id)!.title, '在 WAL 里的笔记');

      final files = unzip(backup.exportAll());
      final tmp = Directory.systemTemp.createTempSync('yw_verify_');
      addTearDown(() => tmp.deleteSync(recursive: true));
      final out = File(p.join(tmp.path, 'yuanworld.db'))
        ..writeAsBytesSync(files['yuanworld.db']!.content as List<int>);

      final probe = AppDatabase.openAt(tmp.path);
      addTearDown(probe.close);
      final titles = NoteRepository(probe).listNotes(const NoteFilter()).map((n) => n.title);
      expect(titles, contains('在 WAL 里的笔记'));
      expect(out.lengthSync(), greaterThan(0));
    });
  });

  group('每日快照', () {
    test('写进 snapshots/ 并轮转，只留最新的 N 份', () {
      addNote('一篇');
      for (var i = 0; i < 8; i++) {
        backup.snapshot(keep: 7);
      }
      final shots = backup.snapshots();
      expect(shots.length, 7, reason: '超出份数的要被删掉');
      expect(backup.lastSnapshot(), isNotNull);
    });

    test('一天内不重复拍', () {
      backup.snapshot();
      expect(backup.snapshotDue(), isFalse, reason: '刚拍过就不该再拍');

      // 把最后一份的时间改成两天前
      final last = backup.lastSnapshot()!;
      last.setLastModifiedSync(
        DateTime.now().subtract(const Duration(days: 2)),
      );
      expect(backup.snapshotDue(), isTrue);
    });

    test('还没有快照时认为是"该拍了"', () {
      expect(backup.snapshotDue(), isTrue);
    });
  });

  group('恢复', () {
    test('拒绝写出临时目录的 ZIP 条目', () {
      final escaped = File(
        p.join(
          Directory.systemTemp.path,
          'yw_zip_slip_${DateTime.now().microsecondsSinceEpoch}.txt',
        ),
      );
      addTearDown(() {
        if (escaped.existsSync()) escaped.deleteSync();
      });
      final archive = Archive()
        ..addFile(ArchiveFile('../${p.basename(escaped.path)}', 1, <int>[1]));
      final zip = File(p.join(root.path, 'malicious.zip'))
        ..writeAsBytesSync(ZipEncoder().encodeBytes(archive));

      expect(() => backup.restore(zip), throwsA(isA<StateError>()));
      expect(escaped.existsSync(), isFalse);
    });

    test('从全量 zip 恢复到备份时的状态', () {
      addNote('旧笔记一');
      addNote('旧笔记二');
      addMedia('7/cover.png', <int>[9, 9, 9]);
      final zip = backup.exportAll();

      // 备份之后又把数据改了（模拟"误删/误改")
      final gone = addNote('备份之后才有的');
      repo.deleteNote(gone);
      final keep = repo.listNotes(const NoteFilter()).first;
      repo.updateNote(id: keep.id, content: '被我改坏了');
      File(p.join(db.imageRoot.path, '7', 'cover.png')).deleteSync();

      final result = backup.restore(
        File(p.join(root.path, 'backup.zip'))..writeAsBytesSync(zip),
      );

      final titles = repo.listNotes(const NoteFilter()).map((n) => n.title).toList();
      expect(titles, containsAll(<String>['旧笔记一', '旧笔记二']));
      expect(result.notes, 2);
      expect(result.mediaFiles, 1, reason: '媒体要一起回来');
      expect(
        File(p.join(db.imageRoot.path, '7', 'cover.png')).existsSync(),
        isTrue,
      );
      expect(result.safetyCopy, isNotNull, reason: '恢复前必须留安全副本');
      expect(File(result.safetyCopy!).existsSync(), isTrue);
    });

    test('从裸数据库快照恢复：数据回来，但**不动**现有图片', () {
      addNote('快照里的笔记');
      final shot = backup.snapshot();

      // 快照之后新增笔记 + 一张图
      addNote('快照之后加的');
      addMedia('7/later.png', <int>[7]);

      backup.restore(shot);

      expect(
        repo.listNotes(const NoteFilter()).map((n) => n.title),
        <String>['快照里的笔记'],
      );
      expect(
        File(p.join(db.imageRoot.path, '7', 'later.png')).existsSync(),
        isTrue,
        reason: '快照不含媒体，不能因为恢复就把图片删了',
      );
    });

    test('不是数据库的文件：报错，且现有数据纹丝不动', () {
      addNote('保命笔记');
      final junk = File(p.join(root.path, 'junk.db'))
        ..writeAsStringSync('这不是数据库');

      expect(() => backup.restore(junk), throwsA(isA<StateError>()));
      expect(
        repo.listNotes(const NoteFilter()).map((n) => n.title),
        <String>['保命笔记'],
      );
    });

    test('空库的备份：拒绝恢复（否则等于一键清空）', () {
      addNote('我还在');

      // 造一份"一篇笔记都没有"的合法备份
      final other = Directory.systemTemp.createTempSync('yw_empty_');
      addTearDown(() => other.deleteSync(recursive: true));
      final emptyDb = AppDatabase.openAt(other.path);
      final emptyBackup = BackupService(emptyDb).snapshot();
      emptyDb.close();

      expect(() => backup.restore(emptyBackup), throwsA(isA<StateError>()));
      expect(
        repo.listNotes(const NoteFilter()).map((n) => n.title),
        <String>['我还在'],
      );
    });

    test('恢复后连接仍然可用（不是关掉就忘了重开）', () {
      addNote('恢复前的');
      final zip = backup.exportAll();
      backup.restore(File(p.join(root.path, 'b.zip'))..writeAsBytesSync(zip));

      // 再写一条：能写进去说明 reopen 成功了
      addNote('恢复后新写的');
      expect(
        repo.listNotes(const NoteFilter()).map((n) => n.title),
        containsAll(<String>['恢复前的', '恢复后新写的']),
      );
    });
  });
}
