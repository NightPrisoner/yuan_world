/// 阅读页的三处"顺手程度"改动：
///   · 编辑按钮在顶栏（以前在标题下方，长文里想改一句得先往回滚）
///   · 顶栏往下读时让位、往回滑才回来
///   · 点编辑从**当前读到的地方**接着改
///
/// 用户的原话：「编辑笔记按钮放在顶栏」「顶栏在下滑时自动隐藏，
/// 上滑时才显示出来」「点编辑笔记时就在当前停留的位置开始编辑」。
///
/// 这三条都属于"能点、但不顺手"的问题 —— 不会崩、也没报错，
/// 只能靠量位置和数量来钉住。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/notes/editor/note_editor_page.dart';
import 'package:yuan_world/features/notes/note_detail_page.dart';

/// 长到必须滚的正文：20 个带小标题的段落。
String longBody() {
  final b = StringBuffer();
  for (var i = 0; i < 20; i++) {
    b.writeln('## 第 $i 节');
    b.writeln();
    for (var j = 0; j < 6; j++) {
      b.writeln('这是第 $i 节的第 $j 行正文，写长一点才好滚动。');
    }
    b.writeln();
  }
  return b.toString();
}

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
      title: '长文',
      content: longBody(),
      excerpt: '正文',
      publishedAt: DateTime.now(),
    );
  });

  tearDown(() {
    state.dispose();
    db.close();
  });

  Future<void> pumpDetail(WidgetTester tester) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
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

  /// 正文滚动视图（详情页里只有一个 CustomScrollView）。
  ScrollableState bodyScrollable(WidgetTester tester) => tester.state<ScrollableState>(
    find.descendant(
      of: find.byType(CustomScrollView),
      matching: find.byType(Scrollable),
    ).first,
  );

  testWidgets('编辑按钮在顶栏：一进页面就能点到，不用先滚回去', (tester) async {
    await pumpDetail(tester);

    final edit = find.byTooltip('编辑');
    expect(edit, findsOneWidget);
    // 在屏幕顶部区域（顶栏高度范围内），而不是正文标题下方
    expect(tester.getRect(edit).top, lessThan(kToolbarHeight + 60));
    // 顶栏里不该再有第二个"编辑"
    expect(find.text('编辑笔记'), findsNothing);
  });

  testWidgets('往下读时顶栏让位，往回滑又回来', (tester) async {
    await pumpDetail(tester);
    final edit = find.byTooltip('编辑');
    expect(edit, findsOneWidget);
    final before = tester.getRect(edit).top;

    // 往下滚一大段：顶栏整条让位（要么不在树里，要么被推到视口上方）
    final scrollable = bodyScrollable(tester);
    scrollable.position.jumpTo(1200);
    await tester.pumpAndSettle();
    final gone = edit.evaluate().isEmpty || tester.getRect(edit).top < before - 40;
    expect(gone, isTrue, reason: '往下读时顶栏应该让位给正文');

    // 往回滑：顶栏重新出现，编辑按钮又回到顶部
    scrollable.position.jumpTo(900);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 160));
    await tester.pumpAndSettle();
    expect(find.byTooltip('编辑'), findsOneWidget);
    expect(tester.getRect(find.byTooltip('编辑')).top, greaterThanOrEqualTo(0));
  });

  testWidgets('点编辑会带着当前读到的那一行进去', (tester) async {
    await pumpDetail(tester);
    final scrollable = bodyScrollable(tester);
    // 滚到中段（正文很长，这里肯定不是第一行）
    scrollable.position.jumpTo(1500);
    await tester.pumpAndSettle();
    // 顶栏这时是收起来的，往回滑一点把它叫出来再点
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 160));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('编辑'));
    await tester.pumpAndSettle();

    final editor = tester.widget<NoteEditorPage>(find.byType(NoteEditorPage));
    expect(editor.initialLine, isNotNull);
    expect(editor.initialLine!, greaterThan(10));
  });

  testWidgets('停在最开头时，进去也从第一行开始', (tester) async {
    await pumpDetail(tester);
    await tester.tap(find.byTooltip('编辑'));
    await tester.pumpAndSettle();

    final editor = tester.widget<NoteEditorPage>(find.byType(NoteEditorPage));
    expect(editor.initialLine, anyOf(isNull, lessThan(5)));
  });

  testWidgets('三栏嵌入模式下也要把行号交出去（否则桌面端点编辑会跳回开头）', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    int? got;
    var calls = 0;
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: NoteDetailPage(
              noteId: noteId,
              embedded: true,
              // 三栏布局里阅读页不 push 路由，只把行号交出去
              onEditAtLine: (line) {
                got = line;
                calls++;
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final scrollable = bodyScrollable(tester);
    scrollable.position.jumpTo(1500);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 160));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('编辑'));
    await tester.pumpAndSettle();

    expect(calls, 1);
    expect(got, isNotNull);
    expect(got!, greaterThan(10), reason: '嵌入模式必须带上当前读到的行号');
    // 嵌入模式不该 push 新页面
    expect(find.byType(NoteEditorPage), findsNothing);
  });

  testWidgets('编辑按钮是实心强调色的主操作，不是普通圆形图标', (tester) async {
    await pumpDetail(tester);
    final edit = find.byTooltip('编辑');
    final box = tester.widget<Container>(
      find.descendant(of: edit, matching: find.byType(Container)).first,
    );
    final deco = box.decoration! as BoxDecoration;
    final c = AppTheme.light().extension<AppColors>()!;
    // 底色就是强调色（普通图标按钮用的是 c.fill 那种灰底）
    expect(deco.color, c.tint);
    // 比旁边的图标按钮大一圈
    expect(tester.getSize(edit).width, greaterThan(32));
  });
}
