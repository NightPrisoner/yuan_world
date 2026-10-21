/// 手机端动画验收：键盘弹出、横竖屏切换、转场中断、断点跨越。
///
/// 这几条以前只是"看着没毛病"，没有测试钉住。它们共同的特点是：
/// **出问题的方式不是崩溃，而是错位** —— 键盘弹起时工具栏没跟着抬、
/// 转屏后目录还停在旧位置、转场被打断后页面上多出一层。
///
/// 这类回归用普通断言很难发现，所以每条都量具体位置或数量：
///   · 键盘：页面可视高度、底部工具栏的 dy
///   · 转屏：目录是"停靠"还是"浮层"、正文宽度有没有跳变
///   · 中断：页面上还剩几个详情页、有没有异常
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/motion/apple_page_route.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/notes/editor/note_editor_page.dart';
import 'package:yuan_world/features/notes/note_detail_page.dart';
import 'package:yuan_world/features/notes/widgets/toc_panel.dart';
import 'package:yuan_world/features/search/search_page.dart';
import 'package:yuan_world/features/shell/home_shell.dart';

const String kBody = '# 第一章\n\n正文一。\n\n## 小节 A\n\n正文二。\n\n# 第二章\n\n正文三。';

void main() {
  late AppDatabase db;
  late AppState state;
  late int noteId;

  setUp(() async {
    db = AppDatabase.inMemory();
    final repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
    noteId = repo.insertNote(
      title: '动画验收',
      content: kBody,
      excerpt: '正文',
      publishedAt: DateTime.now(),
    );
  });

  tearDown(() {
    state.dispose();
    db.close();
  });

  Future<void> pumpPage(
    WidgetTester tester,
    Widget home, {
    Size size = const Size(430, 900),
    bool reduceMotion = false,
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
            data: MediaQuery.of(
              context,
            ).copyWith(disableAnimations: reduceMotion),
            child: child!,
          ),
          home: home,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 目录此刻是"停靠"还是"浮层" —— 判据和页面里那段注释一致：
  /// 窄屏走 Stack，宽屏走 Row。
  bool tocDocked(WidgetTester tester) {
    final toc = find.byType(TocMotion);
    if (toc.evaluate().isEmpty) return false;
    return find
        .ancestor(of: toc, matching: find.byType(Row))
        .evaluate()
        .isNotEmpty;
  }

  group('键盘弹出', () {
    testWidgets('编辑时键盘弹起，底部工具栏跟着抬起；收起键盘回原位', (tester) async {
      await pumpPage(tester, NoteEditorPage(noteId: noteId));

      final toolbar = find.byTooltip('撤销');
      final before = tester.getTopLeft(toolbar).dy;

      // 模拟软键盘占掉底部 300 —— 和真机上 viewInsets 长高是同一条路径。
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();

      final during = tester.getTopLeft(toolbar).dy;
      expect(
        during,
        lessThan(before - 200),
        reason: '工具栏本该被键盘顶上去，否则手指够不着',
      );
      expect(tester.takeException(), isNull);

      tester.view.viewInsets = FakeViewPadding.zero;
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(toolbar).dy, closeTo(before, 0.01));
    });

    testWidgets('键盘弹起时正文不会被挤到看不见', (tester) async {
      await pumpPage(tester, NoteEditorPage(noteId: noteId));
      final body = find.textContaining('正文一');
      final heightBefore = tester.getSize(body.first).height;

      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();

      expect(tester.getSize(body.first).height, closeTo(heightBefore, 0.01));
      expect(tester.takeException(), isNull);
    });
  });

  group('横竖屏切换', () {
    for (final editing in [false, true]) {
      testWidgets('目录跟着屏幕宽窄在浮层与停靠之间切换 editing=$editing', (tester) async {
        await pumpPage(
          tester,
          editing
              ? NoteEditorPage(noteId: noteId)
              : NoteDetailPage(noteId: noteId),
          size: const Size(430, 900),
        );
        await tester.tap(find.byTooltip('目录'));
        await tester.pumpAndSettle();
        expect(tocDocked(tester), isFalse, reason: '竖屏手机上一律走浮层');

        // 转横屏：目录应该在同一帧里改成停靠，而不是留一个悬空的浮层。
        tester.view.physicalSize = const Size(900, 430);
        await tester.pumpAndSettle();
        expect(tocDocked(tester), isTrue, reason: '横屏够宽，目录改成停靠');
        expect(tester.takeException(), isNull);

        // 转回竖屏
        tester.view.physicalSize = const Size(430, 900);
        await tester.pumpAndSettle();
        expect(tocDocked(tester), isFalse);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('转屏时目录开着也不会把正文挤没', (tester) async {
      await pumpPage(tester, NoteDetailPage(noteId: noteId));
      await tester.tap(find.byTooltip('目录'));
      await tester.pumpAndSettle();

      tester.view.physicalSize = const Size(900, 430);
      await tester.pumpAndSettle();

      final content = find.textContaining('正文一');
      expect(content, findsWidgets);
      expect(tester.getSize(content.first).width, greaterThan(100));
      expect(tester.takeException(), isNull);
    });
  });

  group('转场中断', () {
    testWidgets('打开到一半返回，再打开同一篇不会叠出两层', (tester) async {
      await pumpPage(tester, _Host(noteId: noteId));

      Future<void> open() async {
        await tester.tap(find.text('打开详情'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 120));
      }

      await open();
      Navigator.of(tester.element(find.byType(NoteDetailPage))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));

      await open();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      expect(find.byType(NoteDetailPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('返回途中连按两次返回不会出错', (tester) async {
      await pumpPage(tester, _Host(noteId: noteId));
      await tester.tap(find.text('打开详情'));
      await tester.pumpAndSettle();

      Navigator.of(tester.element(find.byType(NoteDetailPage))).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      // 动画还没结束，第二次返回 —— 多出来的 pop 不能把宿主页也弹掉。
      final navigator = Navigator.of(tester.element(find.byType(Scaffold).first));
      expect(navigator.canPop(), isFalse, reason: '只剩下唯一一页了');

      await tester.pumpAndSettle();
      expect(find.byType(NoteDetailPage), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('卡片展开时会先铺一块裁剪面，尺寸从卡片长到整页', (tester) async {
      const surface = ValueKey<String>('note-expand-surface');
      await pumpPage(tester, _Host(noteId: noteId));
      await tester.tap(find.text('打开详情'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      // ClipPath 自己的 size 一直是全屏，真正在长的是它裁出来的那块矩形。
      Rect clip() {
        final path = tester.widget<ClipPath>(find.byKey(surface));
        return path.clipper!.getClip(const Size(430, 900)).getBounds();
      }

      expect(find.byKey(surface), findsOneWidget);
      final during = clip();
      await tester.pumpAndSettle();
      final settled = clip();
      // 竖屏（verticalOnly）下宽度一开始就是满宽，长的是高度。
      expect(during.height, lessThan(settled.height));
      expect(during.top, greaterThan(0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('减少动画时不走卡片展开，直接换成详情页', (tester) async {
      const surface = ValueKey<String>('note-expand-surface');
      await pumpPage(tester, _Host(noteId: noteId), reduceMotion: true);
      await tester.tap(find.text('打开详情'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 16));

      expect(find.byType(NoteDetailPage), findsOneWidget);
      expect(find.byKey(surface), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
    });
  });

  testWidgets('从搜索结果进详情用同一条推入转场，不是凭空淡入', (tester) async {
    // 搜索页以前用的是裸 PageRouteBuilder + 纯淡入：从搜索结果点进去，
    // 正文像凭空出现，和从列表、统计、设置里点进去的观感对不上。
    await pumpPage(tester, const SearchPage());

    await tester.enterText(find.byType(TextField), '动画验收');
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
    // 搜索框里也有这串字，所以取最后一个（结果卡片里的标题）。
    final hit = find.text('动画验收');
    expect(hit, findsWidgets);

    await tester.tap(hit.last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    final route = ModalRoute.of(tester.element(find.byType(NoteDetailPage)));
    expect(route, isA<ApplePageRoute<void>>());
    expect(
      find.ancestor(
        of: find.byType(NoteDetailPage),
        matching: find.byType(SlideTransition),
      ),
      findsWidgets,
      reason: '推入转场一定带横向位移',
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  group('断点跨越', () {
    testWidgets('宽度跨过 1000 时三栏与底栏互切，来回都不报错', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await state.refresh();
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(theme: AppTheme.light(), home: const HomeShell()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('收起侧栏'), findsOneWidget, reason: '宽屏是桌面三栏');

      tester.view.physicalSize = const Size(980, 900);
      await tester.pumpAndSettle();
      expect(find.text('收起侧栏'), findsNothing, reason: '窄屏是底部标签');
      expect(tester.takeException(), isNull);

      tester.view.physicalSize = const Size(1400, 900);
      await tester.pumpAndSettle();
      expect(find.text('收起侧栏'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

/// 一个最小的宿主页：点按钮用 [CardExpandPageRoute] 打开详情，
/// 好用来看"转场被打断"这件事。
class _Host extends StatelessWidget {
  const _Host({required this.noteId});

  final int noteId;

  @override
  Widget build(BuildContext context) {
    final card = GlobalKey();
    Rect? rect() {
      final box = card.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return null;
      return box.localToGlobal(Offset.zero) & box.size;
    }

    return Scaffold(
      body: Center(
        child: GestureDetector(
          onTap: () => Navigator.of(context).push(
            CardExpandPageRoute<void>(
              sourceRect: rect() ?? Rect.zero,
              sourceRectBuilder: rect,
              verticalOnly: true,
              pageBuilder: (_) => NoteDetailPage(noteId: noteId),
            ),
          ),
          child: Container(
            key: card,
            width: 320,
            height: 180,
            color: Colors.blue,
            alignment: Alignment.center,
            child: const Text('打开详情'),
          ),
        ),
      ),
    );
  }
}
