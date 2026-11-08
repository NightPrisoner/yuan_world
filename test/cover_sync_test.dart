/// 头图在三处视图里必须是**同一张画**：桌面列表行、瀑布流卡片、阅读页。
///
/// 用户报过两条相关的问题：
///   1. 头图编辑里预览看着还行，瀑布流里一放大就糊；
///   2. 列表和瀑布流不一致 —— 调完头图只有瀑布流变了，列表还是老样子。
///
/// 第二条的根因是列表行压根没画头图（桌面三栏默认就是列表），
/// 而移动端列表行画的是"原图等比缩进方框"，跟取景参数无关。
library;

import 'dart:io';

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
import 'package:yuan_world/features/notes/widgets/cover_frame.dart';
import 'package:yuan_world/features/shell/home_shell.dart';

/// 3×2 的真 PNG（PIL 生成）。手搓的字节 `instantiateImageCodec` 解不开。
const List<int> _kPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x02,
  0x08, 0x02, 0x00, 0x00, 0x00, 0x12, 0x16, 0xF1,
  0x4D, 0x00, 0x00, 0x00, 0x16, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x60, 0x60, 0x60, 0xF8,
  0xCF, 0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
  0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
];

void main() {
  late Directory root;
  late AppDatabase db;
  late NoteRepository repo;
  late AppState state;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('yw_cover_sync_');
    db = AppDatabase.openAt(root.path);
    repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
  });

  tearDown(() {
    state.dispose();
    db.close();
    root.deleteSync(recursive: true);
  });

  /// 造一篇带头图的笔记：`images/<id>/c.png`。
  int addNote({String title = '带头的笔记', double ratio = 1.6}) {
    final id = repo.insertNote(
      title: title,
      content: '正文',
      excerpt: '正文',
      publishedAt: DateTime.now(),
    );
    final dir = Directory(p.join(root.path, 'images', '$id'))
      ..createSync(recursive: true);
    File(p.join(dir.path, 'c.png')).writeAsBytesSync(_kPng);
    repo.updateNote(
      id: id,
      coverImage: '$id/c.png',
      coverRatio: ratio,
      coverZoom: 2.5,
      coverFocusX: -0.4,
      coverFocusY: 0.6,
    );
    return id;
  }

  Future<void> pumpWide(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await state.refresh();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(theme: AppTheme.light(), home: const HomeShell()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('桌面列表行也画头图，用的是笔记自己的取景参数', (tester) async {
    addNote();
    await pumpWide(tester);

    // 三栏默认是列表（gridMode 关），列表行里必须有一个 CoverFrame。
    final frames = find.byType(CoverFrame);
    expect(frames, findsWidgets, reason: '列表行里一张头图都没有');

    final frame = tester.widgetList<CoverFrame>(frames).first;
    expect(frame.zoom, 2.5);
    expect(frame.focusX, -0.4);
    expect(frame.focusY, 0.6);
    // 缩略图是方块
    expect(frame.ratio, 1.0);
  });

  testWidgets('切到瀑布流，取景参数跟列表完全一致', (tester) async {
    addNote();
    await pumpWide(tester);
    final inList = tester.widgetList<CoverFrame>(find.byType(CoverFrame)).first;

    state.setGridMode(true);
    await tester.pumpAndSettle();

    final inGrid = tester.widgetList<CoverFrame>(find.byType(CoverFrame)).first;
    expect(inGrid.zoom, inList.zoom);
    expect(inGrid.focusX, inList.focusX);
    expect(inGrid.focusY, inList.focusY);
    // 瀑布流用笔记自己的比例，列表缩略图固定方块 —— 这是唯一该不同的地方
    expect(inGrid.ratio, 1.6);
    expect(inList.ratio, 1.0);
  });

  testWidgets('放大之后解码宽度跟着放大，不然位图被拉大就是糊的', (tester) async {
    addNote();
    await pumpWide(tester);

    double decodeScaleOf(WidgetTester t) {
      final img = t.widget<LocalImage>(
        find
            .descendant(
              of: find.byType(CoverFrame).first,
              matching: find.byType(LocalImage),
            )
            .first,
      );
      return img.decodeScale;
    }

    final zoomed = decodeScaleOf(tester);
    // zoom = 2.5 → 至少解 2.5 倍宽，否则等于把位图拉伸 2.5 倍
    expect(zoomed, greaterThanOrEqualTo(2.5));

    // 把放大改回 1，解码倍率必须跟着降下来（说明它真的乘了 zoom）
    final note = repo.listNotes(const NoteFilter()).single;
    repo.updateNote(id: note.id, coverZoom: 1.0);
    await state.refresh();
    await tester.pumpAndSettle();
    expect(decodeScaleOf(tester), lessThan(zoomed));
  });

  testWidgets('没有头图的笔记，列表行不留空方块', (tester) async {
    repo.insertNote(title: '无图', content: '正文', excerpt: '正文');
    await pumpWide(tester);
    expect(find.byType(CoverFrame), findsNothing);
  });
}
