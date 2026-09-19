/// 导入时把正文里**按相对路径引用**的图片/视频一并搬进来。
///
/// docx 内嵌的图本来就能导；这里盯的是另一种形态：文件躺在文档旁边
/// （或同级的 assets/、xxx_files/），正文里写着它的相对路径。
/// 以前这些引用会被原样留在正文里 —— 笔记里看到一个打不开的路径，
/// 文件其实就在旁边，用户以为图丢了。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/importer/media_refs.dart';
import 'package:yuan_world/data/importer/txt_importer.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';

void main() {
  late Directory tmp;
  late AppDatabase db;
  late NoteRepository repo;
  late ImportService svc;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yw_media');
    db = AppDatabase.openAt(p.join(tmp.path, 'db'));
    repo = NoteRepository(db);
    svc = ImportService(db, repo);
  });

  tearDown(() {
    db.close();
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  File write(String rel, List<int> bytes) {
    final f = File(p.join(tmp.path, rel));
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes);
    return f;
  }

  group('找出相对路径引用', () {
    test('Markdown 图片、HTML img、视频链接都能识别', () {
      write('a.png', <int>[1, 2, 3]);
      write('assets/b.jpg', <int>[4, 5, 6]);
      write('clip.mp4', <int>[7, 8, 9, 10]);

      final md = '''
正文

![](a.png)
<img src="assets/b.jpg">
[点我看视频](clip.mp4)
''';
      final refs = resolveLocalMedia(md, tmp);
      expect(refs.map((r) => r.reference).toSet(),
          <String>{'a.png', 'assets/b.jpg', 'clip.mp4'});
      expect(refs.map((r) => r.bytes.length).toSet(), <int>{3, 4});
    });

    test('网络地址、data:、锚点都不当本地文件', () {
      final md = '''
![](https://example.com/a.png)
![](data:image/png;base64,AAAA)
[跳转](#section)
![](//cdn.example.com/b.png)
''';
      expect(resolveLocalMedia(md, tmp), isEmpty);
    });

    test('不认识的扩展名跳过', () {
      write('doc.pdf', <int>[1]);
      expect(resolveLocalMedia('![](doc.pdf)', tmp), isEmpty);
    });

    test('文件不存在就静默跳过，不让整篇导入失败', () {
      expect(resolveLocalMedia('![](根本没有这个文件.png)', tmp), isEmpty);
    });

    test('能按常见附件目录找到（assets/ images/ media/ xxx_files 约定）', () {
      write('assets/deep.png', <int>[1, 1]);
      write('images/deep2.png', <int>[2, 2]);
      // 正文里只写了文件名
      final refs = resolveLocalMedia('![](deep.png)\n![](deep2.png)', tmp);
      expect(refs.length, 2);
    });

    test('%20 这类编码能解码', () {
      write('my pic.png', <int>[9]);
      final refs = resolveLocalMedia('![](my%20pic.png)', tmp);
      expect(refs.length, 1);
    });
  });

  group('走完整导入流程', () {
    test('txt 里引用的图片和视频会被搬进笔记并改写路径', () async {
      final img = write('assets/图 1.png', List<int>.filled(64, 7));
      final vid = write('片段.mp4', List<int>.filled(128, 9));
      final doc = write(
        '文章.txt',
        // **必须 utf8 编码**：用 codeUnits 写出来是 UTF-16，中文全坏
        utf8.encode('''
标题行

![插图](assets/图%201.png)

[视频](片段.mp4)
'''),
      );

      final s = await svc.importDocx(<File>[doc]);
      // ignore: avoid_print
      // ignore: avoid_print
      expect(s.imported, 1, reason: '没导进来：${s.errors}');

      final note = repo.listNotes(const NoteFilter()).single;
      // listNotes 不查 content 列，正文得单独取
      final body = repo.getNoteContent(note.id);
      // 落盘到 images/<noteId>/ 下，且正文里已经是可用的相对路径
      expect(body, isNot(contains('assets/图')));
      expect(body, isNot(contains('片段.mp4')));
      expect(body, contains('${note.id}/'));

      final files = Directory(p.join(db.imageRoot.path, '${note.id}'))
          .listSync()
          .whereType<File>()
          .map((f) => p.basename(f.path))
          .toList()
        ..sort();
      expect(files.length, 2, reason: '图片和视频都该落盘：$files');
      expect(files.any((f) => f.endsWith('.mp4')), isTrue, reason: '视频没进来');
      expect(img.existsSync(), isTrue, reason: '原文件不该被删');
      expect(vid.existsSync(), isTrue);
    });

    test('引用不到本地文件时正文保持原样，不影响导入', () async {
      final doc = write(
        '没有附件.txt',
        utf8.encode('正文\n\n![](不存在的图.png)\n'),
      );
      final s = await svc.importDocx(<File>[doc]);
      expect(s.imported, 1);
      final note = repo.listNotes(const NoteFilter()).single;
      expect(repo.getNoteContent(note.id), contains('不存在的图.png'));
    });
  });
}
