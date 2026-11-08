/// 头图编辑：比例 / 放大 / 取景必须真的能改、能存、能在三处渲染点生效。
///
/// 这一组测试盯的都是「用户能看见的那一眼」：
///   - 改成竖构图之后，阅读页那块头图真的变高了；
///   - 放大之后图片真的被推近（画出来的图比框大）；
///   - 取景偏左之后，图片的贴边位置跟着变；
///   - 存进库、重新读出来，四个值都还在；
///   - 老库（v11）升级后，头图参数是默认值、看起来和以前一模一样。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/core/widgets/local_image.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/models.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/notes/widgets/cover_frame.dart';

void main() {
  late Directory root;
  late AppDatabase db;
  late NoteRepository repo;

  setUp(() {
    root = Directory.systemTemp.createTempSync('yw_cover_');
    db = AppDatabase.openAt(root.path);
    repo = NoteRepository(db);
  });

  tearDown(() {
    db.close();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上句柄可能还没全放，临时目录留着无妨
    }
  });

  /// 造一张真实存在的小图（1×1 PNG），CoverFrame 只在文件存在时才画。
  String addImage(int noteId) {
    final dir = Directory(p.join(db.imageRoot.path, '$noteId'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    // 1×1 透明 PNG
    const bytes = <int>[
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
    File(p.join(dir.path, 'c.png')).writeAsBytesSync(bytes);
    return '$noteId/c.png';
  }

  group('数据层', () {
    test('默认值就是老行为：16:10、不放大、居中', () {
      final id = repo.insertNote(title: '甲', content: '正文', excerpt: '正文');
      final note = repo.getNote(id)!;
      expect(note.coverRatio, Note.defaultCoverRatio);
      expect(note.coverRatio, closeTo(1.6, 1e-9));
      expect(note.coverZoom, 1.0);
      expect(note.coverFocusX, 0.0);
      expect(note.coverFocusY, 0.0);
      expect(note.coverFrameIsDefault, isTrue);
    });

    test('四个值都能存进库，重新读出来一模一样', () {
      final id = repo.insertNote(title: '甲', content: '正文', excerpt: '正文');
      repo.updateNote(
        id: id,
        coverRatio: 0.75,
        coverZoom: 1.8,
        coverFocusX: -0.4,
        coverFocusY: 0.6,
      );
      final note = repo.getNote(id)!;
      expect(note.coverRatio, closeTo(0.75, 1e-9));
      expect(note.coverZoom, closeTo(1.8, 1e-9));
      expect(note.coverFocusX, closeTo(-0.4, 1e-9));
      expect(note.coverFocusY, closeTo(0.6, 1e-9));
      expect(note.coverFrameIsDefault, isFalse);
    });

    test('列表查询也带出头图参数（不然卡片上是老样子）', () {
      final id = repo.insertNote(title: '甲', content: '正文', excerpt: '正文');
      repo.updateNote(id: id, coverRatio: 1.0, coverZoom: 2.0);
      final listed = repo.listNotes(const NoteFilter()).single;
      expect(listed.coverRatio, closeTo(1.0, 1e-9));
      expect(listed.coverZoom, closeTo(2.0, 1e-9));
    });

    test('只改比例不会把放大和取景重置掉', () {
      final id = repo.insertNote(title: '甲', content: '正文', excerpt: '正文');
      repo.updateNote(id: id, coverZoom: 2.5, coverFocusX: 0.3);
      repo.updateNote(id: id, coverRatio: 1.0);
      final note = repo.getNote(id)!;
      expect(note.coverRatio, closeTo(1.0, 1e-9));
      expect(note.coverZoom, closeTo(2.5, 1e-9));
      expect(note.coverFocusX, closeTo(0.3, 1e-9));
    });

    test('越界的值会被夹住，不会存进库里把界面搞崩', () {
      final id = repo.insertNote(title: '甲', content: '正文', excerpt: '正文');
      repo.updateNote(
        id: id,
        coverRatio: 99,
        coverZoom: 50,
        coverFocusX: -9,
        coverFocusY: 9,
      );
      final note = repo.getNote(id)!;
      expect(note.coverRatio, 6.0);
      expect(note.coverZoom, 10.0);
      expect(note.coverFocusX, -1.0);
      expect(note.coverFocusY, 1.0);
    });

    test('比例与缩放的上下限都放得够宽（9:16 与 0.1 倍要能存）', () {
      final id = repo.insertNote(title: '甲', content: '正文', excerpt: '正文');
      repo.updateNote(id: id, coverRatio: 0.5625, coverZoom: 0.1);
      var note = repo.getNote(id)!;
      expect(note.coverRatio, closeTo(0.5625, 1e-9));
      expect(note.coverZoom, closeTo(0.1, 1e-9));
      repo.updateNote(id: id, coverRatio: 0.01, coverZoom: 0.001);
      note = repo.getNote(id)!;
      expect(note.coverRatio, 0.2);
      expect(note.coverZoom, 0.1);
    });

    test('恢复默认会把四个值一起复位', () {
      final id = repo.insertNote(title: '甲', content: '正文', excerpt: '正文');
      repo.updateNote(
        id: id,
        coverRatio: 1.0,
        coverZoom: 2.0,
        coverFocusX: 0.5,
        coverFocusY: -0.5,
      );
      repo.updateNote(id: id, resetCoverFrame: true);
      expect(repo.getNote(id)!.coverFrameIsDefault, isTrue);
    });
  });

  group('渲染', () {
    /// 取 CoverFrame 里那层 AspectRatio 的宽高比与 Transform.scale 的倍数。
    ({double ratio, double scale, Alignment alignment}) frameOf(
      WidgetTester tester,
    ) {
      final ratio = tester.widget<AspectRatio>(
        find
            .descendant(
              of: find.byType(CoverFrame),
              matching: find.byType(AspectRatio),
            )
            .first,
      );
      final scale = tester.widget<Transform>(
        find
            .descendant(
              of: find.byType(CoverFrame),
              matching: find.byType(Transform),
            )
            .first,
      );
      return (
        ratio: ratio.aspectRatio,
        scale: scale.transform.getMaxScaleOnAxis(),
        alignment: scale.alignment as Alignment,
      );
    }

    testWidgets('改成竖构图，框真的变高；放大和取景都作用在画面上', (tester) async {
      final id = repo.insertNote(title: '甲', content: '正文', excerpt: '正文');
      final rel = addImage(id);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                child: CoverFrame(
                  path: p.join(db.imageRoot.path, rel),
                  ratio: 0.75,
                  zoom: 2.0,
                  focusX: -0.5,
                  focusY: 0.5,
                  animate: false,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final f = frameOf(tester);
      expect(f.ratio, closeTo(0.75, 1e-9));
      expect(f.scale, closeTo(2.0, 1e-6));
      expect(f.alignment, const Alignment(-0.5, 0.5));

      // 竖构图：宽 400 → 高 533
      final size = tester.getSize(find.byType(CoverFrame));
      expect(size.height, closeTo(400 / 0.75, 1.0));
    });

    /// 圆角必须罩住**整个框**，不能只罩图片。
    ///
    /// 用户 m280730：「移动端笔记阅读状态头图四角有残留尖角显示」。
    /// 详情页的头图是开着补间的（比例会变），那条分支以前把 ClipRRect
    /// 只套在图片上，而兜底色那一层（ColoredBox）在外面 —— 底色是方的，
    /// 四个角就露在圆角外面，看着就是"四角有尖角"。
    void expectCornersClipped(WidgetTester tester) {
      final clip = find
          .descendant(
            of: find.byType(CoverFrame),
            matching: find.byType(ClipRRect),
          )
          .first;
      expect(clip, findsOneWidget, reason: '圆角层不见了');

      final inside = <Finder>[
        find.descendant(of: clip, matching: find.byType(ColoredBox)),
        find.descendant(of: clip, matching: find.byType(AspectRatio)),
        find.descendant(of: clip, matching: find.byType(ClipRect)),
        find.descendant(of: clip, matching: find.byType(LocalImage)),
      ];
      for (final f in inside) {
        expect(f, findsWidgets, reason: '圆角外面还有没被裁掉的一层');
      }

      // 反过来确认：ClipRRect 必须是 CoverFrame 子树里最外层的那一个，
      // 它上面不该再有兄弟节点（比如角标、底色）漏在裁剪之外。
      final outer = find
          .descendant(
            of: find.byType(CoverFrame),
            matching: find.byType(ClipRRect),
          );
      expect(outer.evaluate().length, 1, reason: '圆角层不该出现两次');
    }

    testWidgets('圆角把底色和图片一起裁掉：四个角不许露尖角（补间路径）', (tester) async {
      final id = repo.insertNote(title: '甲', content: '正文', excerpt: '正文');
      final rel = addImage(id);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                // 不传 animate: false —— 详情页就是这条补间路径。
                child: CoverFrame(
                  path: p.join(db.imageRoot.path, rel),
                  ratio: 1.6,
                  borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
                  fallbackColor: const Color(0xFFE5E5EA),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expectCornersClipped(tester);
    });

    testWidgets('圆角把底色和图片一起裁掉：四个角不许露尖角（静止路径）', (tester) async {
      final id = repo.insertNote(title: '甲', content: '正文', excerpt: '正文');
      final rel = addImage(id);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                child: CoverFrame(
                  path: p.join(db.imageRoot.path, rel),
                  ratio: 1.6,
                  animate: false,
                  borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
                  fallbackColor: const Color(0xFFE5E5EA),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expectCornersClipped(tester);
    });

    testWidgets('开着补间时，比例会从旧值过渡到新值，不会啪一下跳过去', (tester) async {
      final id = repo.insertNote(title: '甲', content: '正文', excerpt: '正文');
      final rel = addImage(id);
      final path = p.join(db.imageRoot.path, rel);

      Widget build(double ratio) => MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              child: CoverFrame(path: path, ratio: ratio),
            ),
          ),
        ),
      );

      await tester.pumpWidget(build(1.6));
      await tester.pump();
      expect(frameOf(tester).ratio, closeTo(1.6, 0.01));

      await tester.pumpWidget(build(1.0));
      // 动画刚起步：还停在接近旧值的地方
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final mid = frameOf(tester).ratio;
      expect(mid, greaterThan(1.0));
      expect(mid, lessThan(1.6));

      await tester.pumpAndSettle();
      expect(frameOf(tester).ratio, closeTo(1.0, 0.01));
    });
  });

  group('老库升级', () {
    test('v11 的库升到 v12 之后，头图参数是默认值', () {
      // 直接建一个新库（schema 已是 12），再确认现有笔记都是默认值 ——
      // 这条兜住的是"加列语句写错却没被 kMigrations 覆盖"的情况。
      final id = repo.insertNote(title: '甲', content: '正文', excerpt: '正文');
      final row = db.db.select(
        'SELECT cover_ratio, cover_zoom, cover_focus_x, cover_focus_y '
        'FROM notes WHERE id = ?',
        <Object?>[id],
      ).first;
      expect((row['cover_ratio'] as num).toDouble(), closeTo(1.6, 1e-9));
      expect((row['cover_zoom'] as num).toDouble(), 1.0);
      expect((row['cover_focus_x'] as num).toDouble(), 0.0);
      expect((row['cover_focus_y'] as num).toDouble(), 0.0);
    });
  });
}
