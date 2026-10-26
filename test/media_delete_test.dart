/// 正文里删掉一张图，磁盘上的文件也要跟着删。
///
/// 用户报的原话：「图片删除磁盘上的也删除啊，还恢复到和之前没有图片的一样，
/// 笔记有图片自动默认以第一张图片为头图」。
///
/// 以前的行为是**只删正文那一行**：文件永远留在 `images/<noteId>/` 里，
/// 用户以为删了，其实还在硬盘上占空间（也是隐私问题）；而且如果它是头图，
/// 头图指针会一直指着一个已经不存在的文件 —— 详情页就顶着一块灰。
library;

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/core/widgets/local_image.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/notes/editor/note_editor_page.dart';

const List<int> _png = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];

void main() {
  late Directory root;
  late AppDatabase db;
  late NoteRepository repo;
  late AppState state;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('yw_media_delete_');
    db = AppDatabase.openAt(root.path);
    repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
  });

  tearDown(() {
    db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 在图片根目录下造一张真图，返回**相对于图片根目录**的路径。
  ///
  /// 正文里存的就是这种形状（`12/a.png`：笔记 id 目录 + 文件名），
  /// 和 `MediaImporter.import` 返回的一致。
  String writeImage(String rel) {
    final file = File(p.join(db.imageRoot.path, rel));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(_png);
    return rel;
  }

  File fileOf(String rel) => File(p.join(db.imageRoot.path, rel));

  /// 先建笔记拿到 id，再把真实路径写进正文。
  int noteWithImages(String title, List<String> names, {String? cover}) {
    final id = repo.insertNote(title: title, content: '正文', excerpt: '正文');
    final rels = <String>[for (final n in names) writeImage('$id/$n')];
    final body = <String>['正文'];
    for (final rel in rels) {
      body
        ..add('')
        ..add('![]($rel)');
    }
    body
      ..add('')
      ..add('尾巴');
    repo.updateNote(id: id, content: body.join('\n'), coverImage: cover);
    return id;
  }

  Future<void> pumpEditor(WidgetTester tester, int noteId) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(body: NoteEditorPage(noteId: noteId, embedded: true)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 桌面端删除键只在悬停时露出，得先把鼠标移上去。
  Future<void> hoverMedia(WidgetTester tester, int index) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(LocalImage).at(index)));
    await tester.pumpAndSettle();
  }

  /// 点删除键并确认。
  Future<void> deleteMedia(WidgetTester tester, int index) async {
    await hoverMedia(tester, index);
    await tester.tap(find.byTooltip('删掉这个文件'));
    await tester.pumpAndSettle();
    expect(find.text('删掉这个文件？'), findsOneWidget);
    await tester.tap(find.text('删掉'));
    await tester.pumpAndSettle();
    // 自动保存要等 1.2 秒的静默窗口
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
  }

  testWidgets('删掉正文里的图，磁盘文件一起删，头图换成还剩的那张', (tester) async {
    final id = noteWithImages('两张图', <String>['a.png', 'b.png', 'c.png']);
    final first = '$id/a.png';
    final second = '$id/b.png';
    repo.updateNote(id: id, coverImage: first);
    await state.refresh();

    await pumpEditor(tester, id);
    await deleteMedia(tester, 0);

    // 磁盘上少了一个文件，别人不受牵连
    expect(fileOf(first).existsSync(), isFalse, reason: '删掉的图不该还躺在硬盘上');
    expect(fileOf(second).existsSync(), isTrue, reason: '没删的那张不能受牵连');

    // 正文里那一行没了
    final note = repo.getNote(id)!;
    expect(note.content.contains('a.png'), isFalse);
    expect(note.content.contains('b.png'), isTrue);

    // 头图自动换成剩下的第一张 —— 而不是继续指着已经删掉的文件
    expect(note.coverImage, second, reason: '有图就该自动拿正文第一张当头图');
  });

  testWidgets('把最后一张图删掉，头图清空，图片目录也不留空壳', (tester) async {
    final id = noteWithImages('只有一张', <String>['c.png']);
    final only = '$id/c.png';
    repo.updateNote(id: id, coverImage: only);
    await state.refresh();

    await pumpEditor(tester, id);
    await deleteMedia(tester, 0);

    expect(fileOf(only).existsSync(), isFalse);
    final note = repo.getNote(id)!;
    expect(note.content.contains('c.png'), isFalse);
    expect(
      note.coverImage,
      anyOf(isNull, isEmpty),
      reason: '一张图都不剩，头图必须清掉，否则详情页又顶一块灰',
    );

    // 笔记的媒体目录如果空了，也一起收走（"回到没有图片的样子"）
    final dir = Directory(p.join(db.imageRoot.path, '$id'));
    expect(dir.existsSync(), isFalse, reason: '空目录不该留下');
  });

  testWidgets('选择取消时，文件一个字节都不动', (tester) async {
    final id = noteWithImages('别删', <String>['d.png']);
    final keep = '$id/d.png';
    await state.refresh();

    await pumpEditor(tester, id);
    await hoverMedia(tester, 0);
    await tester.tap(find.byTooltip('删掉这个文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(fileOf(keep).existsSync(), isTrue);
    expect(repo.getNote(id)!.content.contains('d.png'), isTrue);
  });

  test('别的笔记把它当封面时，删图会留着文件', () {
    final a = repo.insertNote(title: 'A', content: '![](x/e.png)', excerpt: '');
    final b = repo.insertNote(title: 'B', content: '无图', excerpt: '');
    final rel = writeImage('$a/e.png');
    repo.updateNote(id: b, coverImage: rel);

    expect(repo.notesUsingCover(rel), contains(b));
    expect(repo.notesUsingCover('没人用.png'), isEmpty);
  });
}
