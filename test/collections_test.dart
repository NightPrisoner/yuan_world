/// 文件夹（文集）管理页的测试。
///
/// 这个入口在手机上才有（宽屏走左栏的 + 和 ⋯），所以单独测一遍，
/// 免得只有桌面端被覆盖到。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/collections/manage_collections_page.dart';

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

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(500, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const ManageCollectionsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('空状态给出引导与新建按钮', (tester) async {
    await pumpPage(tester);

    expect(find.text('还没有文件夹'), findsOneWidget);
    expect(find.text('新建文件夹'), findsWidgets);
  });

  testWidgets('列出文集并显示笔记数', (tester) async {
    final id = state.repo.createCollection('杂碎记')!;
    state.repo.insertNote(
      title: 'A',
      content: '',
      excerpt: '',
      collectionId: id,
    );
    state.repo.insertNote(
      title: 'B',
      content: '',
      excerpt: '',
      collectionId: id,
    );
    await state.refresh();
    await pumpPage(tester);

    expect(find.text('杂碎记'), findsOneWidget);
    expect(find.text('2 篇笔记'), findsOneWidget);
  });

  testWidgets('有子文件夹时可以像桌面端一样收起和展开', (tester) async {
    final parent = state.repo.createCollection('父文件夹')!;
    state.repo.createCollection('子文件夹', parentId: parent);
    await state.refresh();
    await pumpPage(tester);

    expect(find.text('父文件夹'), findsOneWidget);
    expect(find.text('子文件夹'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right_rounded), findsOneWidget);

    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await tester.pumpAndSettle();
    expect(find.text('子文件夹'), findsNothing);

    await tester.tap(find.byIcon(Icons.chevron_right_rounded));
    await tester.pumpAndSettle();
    expect(find.text('子文件夹'), findsOneWidget);
  });

  testWidgets('文件夹更多菜单支持桌面端同款置顶操作', (tester) async {
    final id = state.repo.createCollection('可置顶')!;
    await state.refresh();
    await pumpPage(tester);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('置顶'), findsOneWidget);
    await tester.tap(find.text('置顶'));
    await tester.pumpAndSettle();

    expect(state.collections.firstWhere((c) => c.id == id).isPinned, isTrue);
    expect(find.byIcon(Icons.push_pin_rounded), findsOneWidget);

    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('取消置顶'), findsOneWidget);
  });

  testWidgets('点条目打开编辑面板，可以改名', (tester) async {
    state.repo.createCollection('旧名');
    await state.refresh();
    await pumpPage(tester);

    await tester.tap(find.text('旧名'));
    await tester.pumpAndSettle();

    expect(find.text('编辑文集'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, '新名');
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(state.collections.first.name, '新名');
  });

  testWidgets('顶部 + 可以新建', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byTooltip('新建文件夹'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '创建出来的');
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建'));
    await tester.pumpAndSettle();

    expect(state.collections.length, 1);
    expect(find.text('创建出来的'), findsOneWidget);
  });

  testWidgets('左滑删除会先弹确认框', (tester) async {
    final id = state.repo.createCollection('要删的')!;
    state.repo.insertNote(
      title: '里面的',
      content: '',
      excerpt: '',
      collectionId: id,
    );
    await state.refresh();
    await pumpPage(tester);

    await tester.drag(find.text('要删的'), const Offset(-500, 0));
    await tester.pumpAndSettle();

    expect(find.text('删除「要删的」？'), findsOneWidget);
    // 提示里要讲清楚：进回收站，不是直接没了
    expect(find.textContaining('回收站'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();

    expect(state.collections, isEmpty);
    // 笔记跟着文件夹一起进回收站，不是变成未分类
    expect(state.overview?.noteCount, 0);
    expect(state.trashedNotes.length, 1);
    // 但数据还在库里，能恢复
    expect(state.repo.getNote(1), isNotNull);
  });
}
