/// 头图文件被删掉之后，界面上不该再留一块灰色的占位。
///
/// 用户报的现象：设置头图 → 去文件管理器把那张图删了 → 打开笔记，
/// 标题上方顶着一整块浅灰色圆角矩形。看着像"图片加载失败"，可那上面
/// 什么也没有，也没有任何能操作的东西 —— 实际上只是数据库里还留着
/// 一个指向已删除文件的路径。
///
/// 现在的规矩：`displayCover` 会连文件存在性一起判，文件不在就当没设过
/// 头图，阅读页不留空位、列表卡片不显示灰条。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/models.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/notes/note_detail_page.dart';
import 'package:yuan_world/features/notes/widgets/note_card.dart';

void main() {
  late Directory root;
  late AppDatabase db;
  late NoteRepository repo;
  late AppState state;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('yw_cover_missing_');
    db = AppDatabase.openAt(root.path);
    repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
  });

  tearDown(() {
    db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 造一张真的图片文件（1×1 PNG），返回它相对 `images/` 的路径。
  String writeCover(int noteId) {
    final rel = '$noteId/cover.png';
    final file = File(p.join(db.imageRoot.path, rel));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(const <int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
      0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
      0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
      0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
      0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
      0x42, 0x60, 0x82,
    ]);
    return rel;
  }

  Future<void> pumpDetail(WidgetTester tester, int noteId) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: NoteDetailPage(noteId: noteId),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('头图文件删掉之后，阅读页不再留一块灰色占位', (tester) async {
    final id = repo.insertNote(
      title: '测试笔记',
      content: '4354665\n\n657656',
      excerpt: '4354665',
      charCount: 5,
      wordCount: 5,
    );
    repo.updateNote(id: id, coverImage: writeCover(id));
    await state.refresh();

    // 先确认：图还在的时候横幅是有的
    await pumpDetail(tester, id);
    expect(
      find.byType(AspectRatio),
      findsWidgets,
      reason: '有头图时应该渲染出 16:10 的横幅',
    );

    // 用户把图删了
    File(p.join(db.imageRoot.path, '$id/cover.png')).deleteSync();
    await pumpDetail(tester, id);

    // 横幅整块不出现；页面上也不该有 LocalImage 的兜底色块
    expect(
      find.byType(AspectRatio),
      findsNothing,
      reason: '文件没了就不该再占一块位置（灰色占位就是这么来的）',
    );
  });

  testWidgets('列表卡片同样不再显示已经消失的封面', (tester) async {
    final id = repo.insertNote(
      title: '带图的',
      content: '正文',
      excerpt: '正文',
      charCount: 2,
      wordCount: 2,
    );
    repo.updateNote(id: id, coverImage: writeCover(id));
    await state.refresh();

    final note = repo.getNote(id)!;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: NoteCard(
            note: note,
            imageRoot: db.imageRoot.path,
            compact: true,
            onTap: () {},
            onLongPress: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = tester.getSize(find.byType(NoteCard));

    File(p.join(db.imageRoot.path, '$id/cover.png')).deleteSync();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: NoteCard(
            note: note,
            imageRoot: db.imageRoot.path,
            compact: true,
            onTap: () {},
            onLongPress: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester.getSize(find.byType(NoteCard)).height,
      lessThan(before.height),
      reason: '封面块应该整块消失，卡片跟着变矮，而不是留一条空灰条',
    );
  });

  test('displayCover 对不存在的文件返回 null', () {
    final id = repo.insertNote(
      title: 'x',
      content: 'y',
      excerpt: 'y',
      charCount: 1,
    );
    final rel = writeCover(id);
    expect(displayCover(rel, db.imageRoot.path), rel);
    File(p.join(db.imageRoot.path, rel)).deleteSync();
    expect(displayCover(rel, db.imageRoot.path), isNull);
  });
}
