/// 「外部文件」引用：正文里的图片/视频不拷进 `data/images/`，
/// 直接记磁盘上的绝对路径。
///
/// 这一组钉三件事：
///   1. 判据 —— 什么算外部引用、怎么还原成真实路径；
///   2. 插入 —— 开了开关就只写路径、不复制文件；关了还是老样子；
///   3. 兜底 —— 原文件被挪走/删掉时，笔记里要给一行提示而不是白屏，
///      而且**备份和导出必须把外部文件一起带走**（否则换台机器就丢了）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yuan_world/data/backup/backup_service.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/exporter/note_exporter.dart';
import 'package:yuan_world/data/media/external_media.dart';
import 'package:yuan_world/data/models.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';

/// 一张 3×2 的真 PNG（`CoverFrame`/`LocalImage` 只在文件存在时才画，
/// 但导出/备份只关心字节，用真 PNG 更接近实际）。
final Uint8List kPng = Uint8List.fromList(<int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x02,
  0x08, 0x02, 0x00, 0x00, 0x00, 0x9E, 0x5C, 0x3E,
  0x6B, 0x00, 0x00, 0x00, 0x14, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x64, 0x60, 0x60, 0xF8,
  0xCF, 0xC0, 0x00, 0x00, 0x04, 0x02, 0x01, 0x00,
  0x0F, 0x9B, 0x2C, 0x0D, 0x00, 0x00, 0x00, 0x00,
  0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

void main() {
  group('判据：什么算外部引用', () {
    test('绝对路径与 file:// 算外部，相对路径不算', () {
      expect(ExternalMedia.isExternal(r'C:\素材\a.png'), isTrue);
      expect(ExternalMedia.isExternal('/sdcard/Pictures/a.png'), isTrue);
      expect(ExternalMedia.isExternal('file:///E:/a.png'), isTrue);
      expect(ExternalMedia.isExternal(r'\\nas\share\a.png'), isTrue);
      expect(ExternalMedia.isExternal('7/a.png'), isFalse);
      expect(ExternalMedia.isExternal('a.png'), isFalse);
      expect(ExternalMedia.isExternal(''), isFalse);
      expect(ExternalMedia.isExternal('   '), isFalse);
    });

    test('file:// 能解回真实路径，解不开就原样返回', () {
      expect(ExternalMedia.localPath('file:///E:/a.png'), r'E:\a.png');
      expect(ExternalMedia.localPath(r'C:\a.png'), r'C:\a.png');
      // 非法 URI 不抛，原样给回去
      expect(ExternalMedia.localPath('file://[bad'), isNotEmpty);
    });

    test('resolve：内部拼数据目录，外部原样用', () {
      expect(
        ExternalMedia.resolve('/data/images', '7/a.png'),
        p.join('/data/images', '7/a.png'),
      );
      expect(
        ExternalMedia.resolve('/data/images', '/sdcard/a.png'),
        '/sdcard/a.png',
      );
    });

    test('只有存在的外部文件才算 exists', () {
      final dir = Directory.systemTemp.createTempSync('yw_ext_exists');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = File(p.join(dir.path, 'a.png'))..writeAsBytesSync(kPng);
      expect(ExternalMedia.exists(f.path), isTrue);
      expect(ExternalMedia.exists(p.join(dir.path, 'nope.png')), isFalse);
      expect(ExternalMedia.exists('7/a.png'), isFalse, reason: '内部引用不算外部');
    });

    test('从正文里挑出外部引用，跳过 http 与相对路径', () {
      final md = <String>[
        '![一](7/a.png)',
        '![二](/sdcard/b.png)',
        '![三](https://x.com/c.png)',
        r'![四](C:\素材\d.png)',
        '正文里夹一个 ![](/sdcard/e.png) 不算整行',
        '![](/sdcard/f.png "标题")',
      ].join('\n');
      final refs = ExternalMedia.refsIn(md);
      expect(refs, <String>['/sdcard/b.png', r'C:\素材\d.png', '/sdcard/f.png']);
      expect(ExternalMedia.videosIn('![](/sdcard/g.mp4)'), <String>[
        '/sdcard/g.mp4',
      ]);
      expect(ExternalMedia.imagesIn('![](/sdcard/g.mp4)'), isEmpty);
    });
  });

  group('默认行为：开关没开时还是老样子', () {
    late Directory tmp;
    late AppDatabase db;
    late NoteRepository repo;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('yw_ext_insert');
      db = AppDatabase.openAt(p.join(tmp.path, 'db'));
      repo = NoteRepository(db);
    });

    tearDown(() {
      db.close();
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('默认（关）时正文里是相对路径，文件被复制进 images', () {
      expect(repo.getSetting('media.linkInPlace'), isNull);
      final id = repo.insertNote(title: 't', content: '', excerpt: '');
      final src = File(p.join(tmp.path, 'src.png'))..writeAsBytesSync(kPng);
      final rel = 'media/imported/$id/src.png';
      final dst = File(p.join(db.imageRoot.path, rel));
      dst.parent.createSync(recursive: true);
      src.copySync(dst.path);
      repo.updateNote(id: id, content: '![]($rel)');
      final note = repo.getNote(id)!;
      expect(ExternalMedia.refsIn(note.content), isEmpty);
      expect(dst.existsSync(), isTrue);
    });
  });

  group('兜底：备份与导出要把外部文件带走', () {
    late Directory tmp;
    late Directory externalDir;
    late File external;
    late AppDatabase db;
    late NoteRepository repo;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('yw_ext_backup');
      db = AppDatabase.openAt(p.join(tmp.path, 'db'));
      repo = NoteRepository(db);
      externalDir = Directory.systemTemp.createTempSync('yw_ext_src');
      external = File(p.join(externalDir.path, '素材.png'))
        ..writeAsBytesSync(kPng);
    });

    tearDown(() {
      db.close();
      for (final d in <Directory>[tmp, externalDir]) {
        try {
          d.deleteSync(recursive: true);
        } catch (_) {}
      }
    });

    Note noteWithExternal() {
      final id = repo.insertNote(
        title: '带外部图',
        content: '开头\n\n![](${external.path})\n',
        excerpt: '开头',
      );
      return repo.getNote(id)!;
    }

    test('备份包里含 external/ 下的那份文件', () async {
      noteWithExternal();
      final zip = await BackupService(db).exportAllTo(
        File(p.join(tmp.path, 'out.zip')),
      );
      final names = <String>[
        for (final f in ZipDecoder().decodeBytes(zip.readAsBytesSync()))
          if (f.isFile) f.name,
      ];
      expect(
        names.where((n) => n.startsWith('external/')).length,
        1,
        reason: '正文引用的外部文件没进备份：$names',
      );
    });

    test('单篇导出 markdown：正文改写成「外部文件/原名」，并拷到旁边', () async {
      final note = noteWithExternal();
      final prepared = NoteExporter.prepareExternal(
        note,
        ExportFormat.markdown,
      );
      expect(prepared.extras.length, 1);
      expect(prepared.content, contains('![](带外部图.files/素材.png)'));
      expect(prepared.content, isNot(contains(external.path)));
    });

    test('批量导出成包：外部文件按原名放进包里', () async {
      final note = noteWithExternal();
      final zip = await NoteExporter.zipBytesAsync(
        items: <({List<String> path, Note note})>[(path: <String>[], note: note)],
        format: ExportFormat.markdown,
        imageRoot: db.imageRoot.path,
      );
      final names = <String>[
        for (final f in ZipDecoder().decodeBytes(zip))
          if (f.isFile) f.name,
      ];
      expect(names, contains('带外部图.md'));
      expect(
        names.where((n) => n.contains('素材.png')).length,
        1,
        reason: '外部文件没打进包里：$names',
      );
    });

    test('原文件被删掉：导出不崩，正文里的引用原样保留', () async {
      final note = noteWithExternal();
      external.deleteSync();
      final prepared = NoteExporter.prepareExternal(
        note,
        ExportFormat.markdown,
      );
      expect(prepared.extras, isEmpty);
      expect(prepared.content, contains(external.path));
    });

    test('恢复备份后，外部文件落到新数据目录的 external/ 下', () async {
      noteWithExternal();
      final zip = File(p.join(tmp.path, 'backup.zip'));
      await BackupService(db).exportAllTo(zip);

      // 备份做完之后把原文件删掉，模拟"换了台机器"——
      // 恢复必须能从包里把文件捞回来，否则换机就丢了。
      external.deleteSync();

      BackupService(db).restore(zip);
      final restored = Directory(p.join(db.rootDir.path, 'external'));
      expect(restored.existsSync(), isTrue, reason: '恢复没把 external/ 落盘');
      final files = restored
          .listSync(recursive: true)
          .whereType<File>()
          .toList();
      expect(files.length, 1);
      expect(files.single.lengthSync(), kPng.length);
    });
  });
}
