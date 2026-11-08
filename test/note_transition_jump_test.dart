/// 笔记点开 / 返回这两个转场，首末帧不许跳。
///
/// 用户报的原话是「笔记点开和回去这两个瞬间前后衔接的不好，有一点点
/// 跳变的感觉」。根因不在曲线，而在**头图起飞的第一帧就被压扁了**：
///
/// 详情页的头图以前是 `Hero > Stack > [CoverFrame, 角标]`，而 `Stack`
/// 给非定位子节点的是**松约束**。Hero 飞行时会把目的地子树塞进一个
/// 紧约束盒子里，但这一层 Stack 把紧约束变成了松约束，里面的
/// `AspectRatio` 于是按宽度反算高度 —— 源缩略图是 66×66，框里就变成
/// 66×41，再一路长回去。视觉上就是"先跳一下，再开始飞"。
///
/// 修法是把角标挪到 Hero 外面，让 `CoverFrame` 直接当 Hero 的子节点。
/// 这两条测试钉的就是那个瞬间：起飞第一帧的宽高比必须还是方的。
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
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/shell/home_shell.dart';

/// 一张 3×2 的真 PNG。头图只在文件真的存在时才画，所以测试必须落盘。
const List<int> _png = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x02, //
  0x08, 0x02, 0x00, 0x00, 0x00, 0x40, 0xF0, 0xCF, 0x7A, 0x00, 0x00, 0x00, //
  0x12, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0x60, 0x60, 0x60, 0x60, //
  0x00, 0x00, 0x00, 0x04, 0x00, 0x01, 0x3F, 0x0E, 0x0C, 0x5C, 0x00, 0x00, //
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
];

/// 缩略图边长，跟 `_Thumb(size: 66)` 对齐。
const double _thumbSize = 66;

void main() {
  late AppDatabase db;
  late NoteRepository repo;
  late AppState state;

  setUp(() async {
    db = AppDatabase.inMemory();
    repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
    for (var i = 0; i < 3; i++) {
      final id = repo.insertNote(
        title: '笔记 $i',
        content: '正文 $i',
        excerpt: '正文',
        publishedAt: DateTime.now().subtract(Duration(minutes: i)),
      );
      final dir = Directory(p.join(db.imageRoot.path, '$id'))
        ..createSync(recursive: true);
      File(p.join(dir.path, 'c.png')).writeAsBytesSync(_png);
      repo.updateNote(id: id, coverImage: '$id/c.png');
    }
    await state.refresh();
  });

  tearDown(() {
    state.dispose();
    db.close();
  });

  Future<void> pumpList(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(theme: AppTheme.light(), home: const HomeShell()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 树里每一张头图（Hero 飞行时，飞行的那份也会带同一个 key）。
  List<Rect> coverRects(WidgetTester tester) {
    final out = <Rect>[];
    for (final e in find
        .byKey(const ValueKey<String>('detail-cover'))
        .evaluate()) {
      final box = e.renderObject;
      if (box is RenderBox && box.hasSize) {
        out.add(box.localToGlobal(Offset.zero) & box.size);
      }
    }
    return out;
  }

  testWidgets('点开笔记的第一帧，头图没有被压扁', (tester) async {
    await pumpList(tester);

    // 静止时列表缩略图是 66×66，先记下这个"起飞点"。
    final cardCover = tester.getRect(
      find.byType(Image).first,
    );
    expect(cardCover.width, closeTo(_thumbSize, 0.5));
    expect(cardCover.height, closeTo(_thumbSize, 0.5));

    await tester.tap(find.text('笔记 0').first);

    // 起飞第一帧：头图必须还是那个 66×66 的方框。
    //
    // 修之前这一帧读到的是 66×41 —— 高度被 Stack 的松约束按宽度反算掉了。
    // 之后几帧开始沿弧线飞，矩形本来就会逐渐变形（66×66 → 350×219），
    // 所以"方形"这条只对第一帧成立，后续只要求别被压扁。
    await tester.pump(const Duration(milliseconds: 10));
    for (final r in coverRects(tester)) {
      expect(
        r.width / r.height,
        closeTo(1.0, 0.12),
        reason: '起飞第一帧头图应该还是方形缩略图：$r',
      );
    }

    // 往后每一帧都不许塌下去。
    //
    // 阈值给到 0.85 而不是贴着 1.0：弧线飞行途中矩形会轻微收缩（实测
    // 59.3 / 66），那是 `MaterialRectArcTween` 的正常表现，不是 bug。
    // 真正要拦的是修之前那种一帧掉到 41（0.63）的塌陷。
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 10));
      for (final r in coverRects(tester)) {
        expect(
          r.height,
          greaterThan(_thumbSize * 0.85),
          reason: '头图在起飞途中被压扁了：$r',
        );
      }
    }

    // 落定后回到笔记自己的比例（默认 16:10）。
    await tester.pumpAndSettle();
    final settled = coverRects(tester).single;
    expect(settled.width / settled.height, closeTo(1.6, 0.02));
  });

  /// 裁剪面里那层淡入的不透明度。
  ///
  /// 这层在整段动画里**必须一直存在**：一旦在淡到 1.0 时被整段拿掉，
  /// 下面的页面子树就会 deactivate 再重建，图片跟着重新解码 ——
  /// 表现就是"第一次点开会闪一下，第二次（已缓存）就没事"。
  double surfaceOpacity(WidgetTester tester) {
    final fade = find.byKey(const ValueKey<String>('note-expand-fade'));
    return tester.widget<Opacity>(fade.first).opacity;
  }

  testWidgets('点开的头几十毫秒，裁剪面里的正文是淡入的', (tester) async {
    await pumpList(tester);
    await tester.tap(find.text('笔记 0').first);

    // 这是"卡片瞬间变成正文再扩散"的另一半原因：裁剪面在 progress = 0
    // 时正好是卡片大小，里面却是整页内容。不淡入的话第一帧就把正文塞进
    // 那片小区域；淡入之后露出来的是下层还在绘制的列表页（真卡片），
    // 于是看到的是"卡片原地不动、正文显影出来"。
    //
    // 先 pump 一帧让路由挂上去，再往后推 10ms —— 第一帧转场还没开始跑。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    expect(
      surfaceOpacity(tester),
      lessThan(0.4),
      reason: '开头这一帧正文必须基本透明，否则就是"内容挤进卡片"',
    );

    // 中途逐步显影。
    await tester.pump(const Duration(milliseconds: 60));
    final mid = surfaceOpacity(tester);
    expect(mid, greaterThan(0.1));
    expect(mid, lessThan(0.9));

    // 动画走完必须完全不透明，不能留下半透明的正文。
    await tester.pumpAndSettle();
    expect(surfaceOpacity(tester), 1.0);
  });

  testWidgets('返回时正文也是淡出的，不是"啪"地换回卡片', (tester) async {
    await pumpList(tester);
    await tester.tap(find.text('笔记 0').first);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded).first);

    // 反向动画刚起步时正文仍然接近不透明。
    await tester.pump(const Duration(milliseconds: 20));
    expect(surfaceOpacity(tester), greaterThan(0.6));

    // 临近结尾必须已经淡掉，这样最后一帧换回卡片时看不出接缝。
    var lowest = 1.0;
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 24));
      final o = surfaceOpacity(tester);
      if (o < lowest) lowest = o;
    }
    expect(
      lowest,
      lessThan(0.2),
      reason: '返回末段正文要淡到几乎看不见，才不会在最后一帧突然换内容',
    );
  });

  testWidgets('整段转场里淡入层始终在树上，不会中途被拆掉重挂', (tester) async {
    await pumpList(tester);
    await tester.tap(find.text('笔记 0').first);

    // 先 pump 一帧把路由挂上去，否则第 0 帧转场树还没建出来。
    await tester.pump();

    // 每一帧都要求这层 Opacity 存在。拆掉它的那一刻，下面的页面子树会
    // 被重新挂载，图片重新解码 —— 用户看到的就是"第一次点开闪一下"。
    for (var i = 0; i < 18; i++) {
      await tester.pump(const Duration(milliseconds: 24));
      expect(
        find.byKey(const ValueKey<String>('note-expand-fade')),
        findsOneWidget,
        reason: '转场第 ${i * 24}ms 淡入层不见了，页面子树会被重建',
      );
    }

    // 返回方向同理。只查动画还在跑的那一段 —— 动画结束后路由整个被销毁，
    // 这层自然也不在了，那不是"中途被拆掉"。
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded).first);
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 24));
      expect(
        find.byKey(const ValueKey<String>('note-expand-fade')),
        findsOneWidget,
        reason: '返回第 ${i * 24}ms 淡入层不见了，页面子树会被重建',
      );
    }
  });

  testWidgets('返回列表的最后一帧，头图回到方形缩略图', (tester) async {
    await pumpList(tester);
    await tester.tap(find.text('笔记 0').first);
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded).first);

    // 反向动画全程：头图只许连续缩小，不许在某一帧突然变形。
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 24));
      for (final r in coverRects(tester)) {
        expect(
          r.height,
          greaterThan(_thumbSize * 0.9),
          reason: '返回途中头图被压扁了：$r',
        );
      }
    }

    await tester.pumpAndSettle();
    // 回到列表后，那张缩略图又是 66×66。
    final back = tester.getRect(find.byType(Image).first);
    expect(back.width, closeTo(_thumbSize, 0.5));
    expect(back.height, closeTo(_thumbSize, 0.5));
  });
}
