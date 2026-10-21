import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/motion/app_motion.dart';
import 'package:yuan_world/core/motion/apple_page_route.dart';
import 'package:yuan_world/core/motion/folder_tree_motion.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/core/widgets/local_image.dart';
import 'package:yuan_world/core/widgets/todo_check.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/collections/manage_collections_page.dart';
import 'package:yuan_world/features/notes/notes_page.dart';
import 'package:yuan_world/features/notes/editor/note_editor_page.dart';
import 'package:yuan_world/features/notes/note_detail_page.dart';
import 'package:yuan_world/features/notes/widgets/content_view.dart';
import 'package:yuan_world/features/notes/widgets/note_card.dart';
import 'package:yuan_world/features/notes/widgets/toc_panel.dart';
import 'package:yuan_world/features/shell/home_shell.dart';
import 'package:yuan_world/features/todos/todos_page.dart';

void main() {
  late AppDatabase db;
  late AppState state;
  setUp(() async {
    db = AppDatabase.inMemory();
    final repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
  });
  tearDown(() => db.close());

  Future<void> host(
    WidgetTester tester,
    Widget home, {
    Size size = const Size(430, 900),
    bool reduce = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: reduce),
            child: child!,
          ),
          home: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  int note() => state.repo.insertNote(
    title: '动画测试笔记',
    content: '# 标题\n\n正文',
    excerpt: '正文',
  );

  double pageOpacity(WidgetTester tester, Type type) => tester
      .widget<Opacity>(
        find
            .ancestor(of: find.byType(type), matching: find.byType(Opacity))
            .first,
      )
      .opacity;

  testWidgets('手机标签快速切换继承透明度和位置，不闪回动画起点', (tester) async {
    await state.refresh();
    await host(tester, const HomeShell());
    final initial = tester.state(find.byType(NotesPage));
    await tester.tap(find.text('待办').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 65));
    final before = pageOpacity(tester, TodosPage);
    final pos = tester.getTopLeft(find.byType(TodosPage));
    expect(before, inExclusiveRange(0, 1));
    await tester.tap(find.text('设置').last);
    await tester.pump();
    expect(pageOpacity(tester, TodosPage), closeTo(before, 0.001));
    expect(tester.getTopLeft(find.byType(TodosPage)), pos);
    await tester.pump(const Duration(milliseconds: 45));
    await tester.tap(find.text('笔记').last);
    await tester.pump();
    expect(pageOpacity(tester, NotesPage), greaterThan(0));
    await tester.pumpAndSettle();
    expect(pageOpacity(tester, NotesPage), 1);
    expect(identical(tester.state(find.byType(NotesPage)), initial), isTrue);
    expect(find.byType(TodosPage), findsNothing);
  });

  for (final desktop in [false, true]) {
    testWidgets('两棵文件夹连续收起互不取消 desktop=$desktop', (tester) async {
      final a = state.repo.createCollection('父甲')!;
      final b = state.repo.createCollection('父乙')!;
      state.repo.createCollection('子甲', parentId: a);
      state.repo.createCollection('子乙', parentId: b);
      await state.refresh();
      await host(
        tester,
        desktop ? const HomeShell() : const ManageCollectionsPage(),
        size: desktop ? const Size(1400, 900) : const Size(430, 900),
      );
      Finder toggle(String label) {
        final row = find
            .ancestor(of: find.text(label), matching: find.byType(Row))
            .evaluate()
            .firstWhere(
              (e) => find
                  .descendant(
                    of: find.byWidget(e.widget),
                    matching: find.byIcon(Icons.chevron_right_rounded),
                  )
                  .evaluate()
                  .isNotEmpty,
            );
        return find.descendant(
          of: find.byWidget(row.widget),
          matching: find.byIcon(Icons.chevron_right_rounded),
        );
      }

      await tester.tap(toggle('父甲'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(toggle('父乙'));
      await tester.pumpAndSettle();
      expect(find.text('子甲'), findsNothing);
      expect(find.text('子乙'), findsNothing);
      await tester.tap(toggle('父甲'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(toggle('父甲'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      await tester.tap(toggle('父甲'));
      await tester.pumpAndSettle();
      expect(find.text('子甲'), findsOneWidget);
      expect(find.text('子乙'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('文件夹显示行调整动画顺序不会重置透明度', (tester) async {
    const row = SizedBox(key: ValueKey('row'), width: 100, height: 40);
    Widget view(int? order, bool exiting) => MaterialApp(
      home: FolderTreeReveal(order: order, exiting: exiting, child: row),
    );
    await tester.pumpWidget(view(null, false));
    await tester.pumpWidget(view(2, false));
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1);
    await tester.pumpWidget(view(0, true));
    await tester.pump(const Duration(milliseconds: 75));
    final before = tester.widget<Opacity>(find.byType(Opacity)).opacity;
    await tester.pumpWidget(view(0, false));
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, before);
    await tester.pumpAndSettle();
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 1);
  });

  testWidgets('文件夹收起同步收纳行高，相邻内容不会最后一帧跳动', (tester) async {
    Widget view(bool exiting) => MaterialApp(
      home: Column(
        children: [
          FolderTreeReveal(
            order: exiting ? 0 : null,
            exiting: exiting,
            child: const SizedBox(width: 100, height: 100),
          ),
          const SizedBox(key: ValueKey('next-row'), width: 100, height: 20),
        ],
      ),
    );
    await tester.pumpWidget(view(false));
    final before = tester.getTopLeft(find.byKey(const ValueKey('next-row'))).dy;
    await tester.pumpWidget(view(true));
    await tester.pump(const Duration(milliseconds: 80));
    final during = tester.getTopLeft(find.byKey(const ValueKey('next-row'))).dy;
    expect(during, inExclusiveRange(0, before));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(const ValueKey('next-row'))).dy, 0);
  });

  for (final editing in [false, true]) {
    testWidgets('手机目录开合保留正文，遮罩和内容一起过渡 editing=$editing', (tester) async {
      final id = note();
      await host(
        tester,
        editing ? NoteEditorPage(noteId: id) : NoteDetailPage(noteId: id),
      );
      final originalState = tester.state(
        editing ? find.byType(NoteEditorPage) : find.byType(NoteDetailPage),
      );
      await tester.tap(find.byTooltip('目录'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 65));
      final panel = find.byType(TocPanel);
      expect(tester.getSize(panel).width, state.tocWidth);
      final motionWidth = tester.getSize(find.byType(TocMotion)).width;
      expect(motionWidth, inExclusiveRange(0, state.tocWidth));
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭目录').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 65));
      expect(panel, findsOneWidget);
      await tester.pumpAndSettle();
      expect(panel, findsNothing);
      expect(
        identical(
          originalState,
          tester.state(
            editing ? find.byType(NoteEditorPage) : find.byType(NoteDetailPage),
          ),
        ),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final grid in [false, true]) {
    testWidgets('手机笔记卡片按视图选择展开方向 grid=$grid', (tester) async {
      note();
      state.setGridMode(grid);
      await state.refresh();
      await host(tester, const HomeShell());
      await tester.tap(find.byType(NoteCard).first);
      await tester.pumpAndSettle();
      final route = ModalRoute.of(
        tester.element(find.byType(NoteDetailPage)),
      ) as CardExpandPageRoute<void>;
      expect(route.verticalOnly, !grid);
      expect(route.sourceRect, isNotNull);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('detail-pane')), findsNothing);
    });
  }

  testWidgets('卡片转场以 Navigator 实际尺寸为边界，反向连续且能到达四边', (tester) async {
    final animation = AnimationController(
      vsync: tester,
      duration: AppMotion.page,
      value: 0.4,
    );
    addTearDown(animation.dispose);
    final route = CardExpandPageRoute<void>(
      sourceRect: const Rect.fromLTWH(40, 90, 160, 100),
      pageBuilder: (_) => const SizedBox(),
    );
    late BuildContext ctx;
    await host(
      tester,
      Center(
        child: SizedBox(
          width: 310,
          height: 440,
          child: Builder(
            builder: (context) {
              ctx = context;
              return route.transitionsBuilder(
                context,
                animation,
                const AlwaysStoppedAnimation(0),
                const ColoredBox(color: Colors.blue),
              );
            },
          ),
        ),
      ),
    );
    Rect clipRect() {
      final clip = tester.widget<ClipPath>(find.byType(ClipPath).first);
      return clip.clipper!.getClip(const Size(310, 440)).getBounds();
    }

    final before = clipRect();
    animation.reverse();
    await tester.pump();
    expect(clipRect(), before);
    animation.value = 1;
    await tester.pump();
    expect(clipRect(), const Rect.fromLTWH(0, 0, 310, 440));
    expect(AppMotion.reduceMotion(ctx), isFalse);
    route.dispose();
  });

  testWidgets('手机进入编辑保持原地，返回途中没有横向位移', (tester) async {
    final id = note();
    await host(tester, NoteDetailPage(noteId: id));
    await tester.tap(find.byTooltip('编辑'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 90));
    final editor = find.byType(NoteEditorPage);
    final route = ModalRoute.of(tester.element(editor));
    expect(route, isA<EditorPageRoute<void>>());
    expect(
      find.ancestor(of: editor, matching: find.byType(SlideTransition)),
      findsNothing,
    );
    Navigator.of(tester.element(editor)).pop();
    await tester.pumpAndSettle();
    expect(find.byType(NoteDetailPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('看图拖动未到关闭距离会连续回位，不立即跳回', (tester) async {
    await host(tester, const ImageViewer(images: ['missing.png']));
    final viewer = tester.widget<GestureDetector>(
      find
          .ancestor(
            of: find.byType(Stack).first,
            matching: find.byType(GestureDetector),
          )
          .first,
    );
    viewer.onVerticalDragStart!(DragStartDetails());
    viewer.onVerticalDragUpdate!(
      DragUpdateDetails(
        delta: const Offset(0, 75),
        primaryDelta: 75,
        globalPosition: Offset.zero,
      ),
    );
    await tester.pump();
    double offset() => tester
        .widget<Transform>(
          find.byKey(const ValueKey('image-viewer-drag-surface')),
        )
        .transform
        .storage[13];
    expect(offset(), 75);
    viewer.onVerticalDragEnd!(DragEndDetails(primaryVelocity: 0));
    await tester.pump();
    expect(offset(), 75);
    await tester.pump(const Duration(milliseconds: 50));
    expect(offset(), inExclusiveRange(0, 75));
    viewer.onVerticalDragStart!(DragStartDetails());
    final current = offset();
    viewer.onVerticalDragUpdate!(
      DragUpdateDetails(
        delta: const Offset(0, 8),
        primaryDelta: 8,
        globalPosition: Offset.zero,
      ),
    );
    await tester.pump();
    expect(offset(), closeTo(current + 8, 0.01));
    viewer.onVerticalDragCancel!();
    await tester.pumpAndSettle();
    expect(offset(), 0);
  });

  testWidgets('看图单指下拉能驱动预览回位而非被缩放组件吞掉', (tester) async {
    await host(tester, const ImageViewer(images: ['missing.png']));
    final gesture = await tester.startGesture(const Offset(215, 400));
    await gesture.moveBy(const Offset(0, 35));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 25));
    await tester.pump();
    final transform = tester.widget<Transform>(
      find.byKey(const ValueKey('image-viewer-drag-surface')),
    );
    expect(transform.transform.storage[13], greaterThan(0));
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('桌面收起侧栏第一帧分隔宽度不跳变，编辑器保持原实例', (tester) async {
    note();
    await state.refresh();
    await host(tester, const HomeShell(), size: const Size(1400, 900));
    await tester.tap(find.text('动画测试笔记').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑'));
    await tester.pumpAndSettle();
    final editorState = tester.state(find.byType(NoteEditorPage));
    final list = find.byKey(const ValueKey('list-column'));
    final before = tester.getTopLeft(list).dx;
    await tester.tap(find.text('收起侧栏'));
    await tester.pump();
    expect(tester.getTopLeft(list).dx, closeTo(before, 0.01));
    await tester.pumpAndSettle();
    expect(
      identical(tester.state(find.byType(NoteEditorPage)), editorState),
      isTrue,
    );
    await tester.tap(find.byTooltip('占满页面'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('退出占满页面'));
    await tester.pumpAndSettle();
    expect(
      identical(tester.state(find.byType(NoteEditorPage)), editorState),
      isTrue,
    );
  });

  testWidgets('减少动画时勾选、按压、看图控件立即落到最终状态', (tester) async {
    bool checked = false;
    await host(
      tester,
      StatefulBuilder(
        builder: (context, set) => Scaffold(
          body: TodoCheck(
            checked: checked,
            onChanged: (value) => set(() => checked = value),
          ),
        ),
      ),
      reduce: true,
    );
    await tester.tap(find.byType(TodoCheck));
    await tester.pump();
    final paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(TodoCheck),
        matching: find.byType(CustomPaint),
      ),
    );
    expect((paint.painter as dynamic).progress, 1);
    expect(tester.hasRunningAnimations, isFalse);
    await host(
      tester,
      const ImageViewer(images: ['missing.png']),
      reduce: true,
    );
    final opacity = tester.widget<AnimatedOpacity>(
      find.byType(AnimatedOpacity).first,
    );
    expect(opacity.duration, Duration.zero);
  });

  testWidgets('减少动画的图片加载不额外播放淡入', (tester) async {
    final dir = Directory.systemTemp.createTempSync('yw_motion_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/picture.png')..writeAsBytesSync([1, 2]);
    await host(
      tester,
      SizedBox(width: 120, height: 120, child: LocalImage(path: file.path)),
      reduce: true,
    );
    final frame = tester.widget<Image>(find.byType(Image)).frameBuilder!;
    final widget = frame(
      tester.element(find.byType(Image)),
      const SizedBox(),
      0,
      false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: widget,
        ),
      ),
    );
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).duration,
      Duration.zero,
    );
  });

  testWidgets('图片尺寸变化重新解码期间保持旧图可见', (tester) async {
    final dir = Directory.systemTemp.createTempSync('yw_motion_resize_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/image.png')..writeAsBytesSync([1, 2]);
    await host(tester, LocalImage(path: file.path));
    final context = tester.element(find.byType(Image));
    final frame = tester.widget<Image>(find.byType(Image)).frameBuilder!;
    Widget surface(int? index, bool sync) =>
        MaterialApp(home: frame(context, const SizedBox(), index, sync));
    await tester.pumpWidget(surface(0, true));
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );
    await tester.pumpWidget(surface(null, false));
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );
    await tester.pumpWidget(surface(0, false));
    expect(
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity)).opacity,
      1,
    );
  });
}
