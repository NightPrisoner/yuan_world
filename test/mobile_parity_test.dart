/// 手机端和桌面端的功能对齐。
///
/// 起因：桌面左栏有一批"视图/系统入口"（回收站、归档…），而手机是
/// 底部四个标签 + 设置页。之前 `TrashPage` 只被 `desktop_workspace` 引用，
/// `archivedOnly` 也只有桌面在设 —— 于是在手机上：
///   · 删掉的笔记**永远找不回来**；
///   · 长按「归档」之后那篇笔记直接消失，**看不到也取消不了**。
///
/// 这一组把两条路钉住：设置页里的「回收站」、筛选条里的「归档」。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/settings/settings_page.dart';
import 'package:yuan_world/features/shell/home_shell.dart';
import 'package:yuan_world/features/trash/trash_page.dart';

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

  int add(String title) => state.repo.insertNote(
        title: title,
        content: '正文',
        excerpt: '正文',
        publishedAt: DateTime.now(),
        charCount: 2,
      );

  /// 窄屏 → 走手机的底部标签那套（不是三栏工作区）
  Future<void> pumpPhone(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(theme: AppTheme.light(), home: home),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('筛选条里的「归档」：点开只看归档，再点回来', (tester) async {
    add('正常的');
    final archived = add('归档的');
    state.repo.setArchived(archived, true);
    await state.refresh();
    await pumpPhone(tester, const HomeShell());

    // 默认看不到归档的
    expect(find.text('正常的'), findsOneWidget);
    expect(find.text('归档的'), findsNothing);

    await tester.tap(find.text('归档'));
    await tester.pumpAndSettle();
    expect(state.filter.archivedOnly, isTrue);
    expect(find.text('归档的'), findsOneWidget);
    expect(find.text('正常的'), findsNothing);

    await tester.tap(find.text('归档'));
    await tester.pumpAndSettle();
    expect(state.filter.archivedOnly, isFalse);
    expect(find.text('正常的'), findsOneWidget);
  });

  testWidgets('设置页里的「回收站」：能看到数量、点得进去', (tester) async {
    final id = add('要删的');
    state.repo.deleteNote(id);
    // 回收站的列表是**单独缓存**的（refresh() 不带它，省一次全表查询），
    // 界面上的删除流程会自己调 refreshTrash()，这里直接打仓库就得补一下
    state.refreshTrash();
    await state.refresh();
    await pumpPhone(tester, const SettingsPage());

    expect(find.text('回收站'), findsOneWidget);
    expect(find.textContaining('1 篇'), findsWidgets, reason: '要显示里面有几篇');

    await tester.tap(find.text('回收站'));
    await tester.pumpAndSettle();
    expect(find.byType(TrashPage), findsOneWidget, reason: '手机上必须能进回收站');
  });

  testWidgets('回收站空了也要能进（不是隐藏入口）', (tester) async {
    await state.refresh();
    await pumpPhone(tester, const SettingsPage());
    expect(find.text('回收站'), findsOneWidget);
    expect(find.text('空的'), findsOneWidget);
  });
}
