/// 导入失败必须**完整回退**。
///
/// 以前的顺序是：先 `insertNote` 建行，再逐张写图，最后回写正文。
/// 中间任何一步失败（磁盘满、文件被占用、库被锁）都会留在原地：
///   - 一条正文还写着占位路径的残缺笔记
///   - `images/<id>/` 里已落盘的前几张图 —— 永远没人引用的孤儿文件
///   - 汇总里虚高的「图片 N 张」
/// 用户看到的是"导入失败"，可列表里却多出一篇点开是空的文章。
///
/// 现在整篇是一个单元：要么完整进来，要么一点都不留。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';

void main() {
  late Directory tmp;
  late AppDatabase db;
  late NoteRepository repo;
  late ImportService svc;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yw_rollback');
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

  /// 这个 noteId 的图片目录是否还有东西。
  bool mediaDirExists(int noteId) =>
      Directory(p.join(db.imageRoot.path, '$noteId')).existsSync();

  test('图片写到一半失败：这篇整个回滚，不留残缺行和孤儿图', () async {
    write('a.png', List<int>.filled(32, 1));
    write('b.png', List<int>.filled(32, 2));
    final doc = write(
      '会失败的.txt',
      utf8.encode('正文\n\n![](a.png)\n\n![](b.png)\n'),
    );

    // 造"第二张图写不进去"：落盘路径是 images/<id>/2.png，
    // 预先在这个位置放一个**目录**，writeAsBytes 就会抛。
    // 第一张（1.png）会先写成功 —— 正是要验证的那种半成品。
    final noteId = 1; // 空库第一篇，自增从 1 开始
    Directory(p.join(db.imageRoot.path, '$noteId', '2.png'))
        .createSync(recursive: true);

    final s = await svc.importDocx(<File>[doc]);

    expect(s.failed, 1, reason: '该算失败');
    expect(s.imported, 0);
    expect(s.images, 0, reason: '失败的那篇不能把图片数算进汇总');
    expect(s.errors.single, contains('会失败的.txt'));

    expect(
      repo.listNotes(const NoteFilter()),
      isEmpty,
      reason: '不能留下一篇点开是空的笔记',
    );
    expect(mediaDirExists(noteId), isFalse, reason: '已经写进去的第一张图也得清掉，否则是孤儿文件');
  });

  test('回写正文失败（库被锁）同样整篇回滚，图片一张不留', () async {
    write('a.png', List<int>.filled(32, 1));
    final doc = write('锁库.txt', utf8.encode('正文\n\n![](a.png)\n'));

    db.db.execute(
      "CREATE TRIGGER IF NOT EXISTS fail_note_update BEFORE UPDATE ON notes "
      "BEGIN SELECT RAISE(ABORT, 'database is locked: simulated'); END;",
    );

    final s = await svc.importDocx(<File>[doc]);

    expect(s.failed, 1);
    expect(s.imported, 0);
    expect(s.images, 0);
    expect(s.errors.single, contains('database is locked'));
    expect(repo.listNotes(const NoteFilter()), isEmpty);
    expect(mediaDirExists(1), isFalse);

    // 把故障拿掉之后重导，能正常进来 —— 说明回滚没留下阻塞后续导入的东西
    db.db.execute('DROP TRIGGER IF EXISTS fail_note_update');
    final again = await svc.importDocx(<File>[doc]);
    expect(again.imported, 1, reason: '重试该成功：${again.errors}');
    // 自增 id 不会复用被回滚掉的那个，图片目录跟着新 id 走
    final retried = repo.listNotes(const NoteFilter()).single;
    expect(mediaDirExists(retried.id), isTrue);
    expect(repo.getNoteContent(retried.id), contains('${retried.id}/'));
  });

  test('一篇失败不拖累同批其它篇：成功的两篇内容完整', () async {
    write('a.png', List<int>.filled(32, 1));
    write('b.png', List<int>.filled(32, 2));
    final first = write('一.txt', utf8.encode('第一篇\n\n正文一\n'));
    // 中间这篇会失败：它的 noteId 是 2，第二张图在 images/2/2.png 抛
    final bad = write(
      '二.txt',
      utf8.encode('第二篇\n\n![](a.png)\n\n![](b.png)\n'),
    );
    final third = write('三.txt', utf8.encode('第三篇\n\n正文三\n'));

    Directory(p.join(db.imageRoot.path, '2', '2.png'))
        .createSync(recursive: true);

    final s = await svc.importDocx(<File>[first, bad, third]);

    expect(s.imported, 2, reason: '失败详情：${s.errors}');
    expect(s.failed, 1);
    expect(s.images, 0, reason: '只有失败的那篇带图，它没进来就不能计数');

    final titles = repo
        .listNotes(const NoteFilter())
        .map((n) => n.title)
        .toSet();
    expect(titles, <String>{'第一篇', '第三篇'}, reason: '中间那篇不该留下');

    final thirdNote = repo
        .listNotes(const NoteFilter())
        .firstWhere((n) => n.title == '第三篇');
    expect(repo.getNoteContent(thirdNote.id), contains('正文三'));
    expect(mediaDirExists(2), isFalse, reason: '失败那篇的图片目录要清干净');
  });
}
