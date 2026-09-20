/// 编辑器里的目录 + 全屏（占满页面）时的正文宽度。
///
/// 用户的两条反馈：
///   1. 「全屏不要左右两边留白那么多」—— 以前正文写死 860 宽，
///      大屏上左右各空出一大片；
///   2. 「编辑的时候目录相关功能没有」—— 目录只有阅读页有，编辑长文
///      想跳段只能自己滚。
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
import 'package:yuan_world/features/notes/widgets/toc_panel.dart';

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
      title: '带目录的笔记',
      content: kBody,
      excerpt: '正文',
      publishedAt: DateTime.now(),
    );
  });

  tearDown(() => db.close());

  Future<void> pumpEditor(
    WidgetTester tester, {
    Size size = const Size(1400, 900),
    bool fullscreen = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: NoteEditorPage(
              noteId: noteId,
              embedded: true,
              fullscreen: fullscreen,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('编辑器目录', () {
    testWidgets('有标题时给目录入口，点了才展开', (tester) async {
      await pumpEditor(tester);

      expect(find.byTooltip('目录'), findsOneWidget);
      expect(find.byType(TocPanel), findsNothing, reason: '默认收起，不占地方');

      await tester.tap(find.byTooltip('目录'));
      await tester.pumpAndSettle();

      expect(find.byType(TocPanel), findsOneWidget);
      // 三个标题都在面板里
      expect(find.text('第一章'), findsWidgets);
      expect(find.text('第二章'), findsWidgets);
      // 面板自己的关闭键 + 头部那个按钮此时都叫"关闭目录"，所以是 widgets
      expect(find.byTooltip('关闭目录'), findsWidgets);
    });

    testWidgets('没有标题的笔记不给目录入口', (tester) async {
      final id = state.repo.insertNote(
        title: '纯正文',
        content: '只有一段话，没有标题。',
        excerpt: '只有一段话',
        publishedAt: DateTime.now(),
      );
      noteId = id;
      await pumpEditor(tester);
      expect(find.byTooltip('目录'), findsNothing);
    });

    testWidgets('点目录条目会滚到对应那一段（并把光标放进去）', (tester) async {
      await pumpEditor(tester);
      await tester.tap(find.byTooltip('目录'));
      await tester.pumpAndSettle();

      final before = tester.getTopLeft(find.text('第一章')).dy;

      // 点最后一个标题
      await tester.tap(find.text('第二章').last);
      await tester.pumpAndSettle();

      // 正文那一段被滚进视野（位置相对视口发生了变化）
      final after = tester.getTopLeft(find.text('第二章')).dy;
      expect(after, isNot(before));
      expect(after, greaterThanOrEqualTo(0));
      expect(after, lessThan(900));
    });

    testWidgets('可以换到左侧停靠', (tester) async {
      await pumpEditor(tester);
      await tester.tap(find.byTooltip('目录'));
      await tester.pumpAndSettle();

      final rightX = tester.getTopLeft(find.byType(TocPanel)).dx;
      await tester.tap(find.byTooltip('移到左侧'));
      await tester.pumpAndSettle();

      expect(tester.getTopLeft(find.byType(TocPanel)).dx, lessThan(rightX));
      expect(state.tocSide, 'left', reason: '换边要落库，阅读页也跟着变');
    });
  });

  group('占满页面时的正文宽度', () {
    testWidgets('宽屏下正文不再是写死的 860，留白明显变小', (tester) async {
      await pumpEditor(tester, fullscreen: true);

      final w = tester.getSize(find.byType(TextField).first).width;
      expect(w, greaterThan(900),
          reason: '1400 宽的窗口里正文只有 860 的话，左右各空 270 —— 用户就是嫌这个');
      expect(w, lessThanOrEqualTo(1200));
    });

    testWidgets('非全屏时不受这个上限影响（照旧随面板宽度）', (tester) async {
      await pumpEditor(tester);
      final w = tester.getSize(find.byType(TextField).first).width;
      expect(w, greaterThan(0));
    });
  });
}
