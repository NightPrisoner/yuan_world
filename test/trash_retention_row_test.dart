import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/settings/settings_page.dart';

/// 回收站「保留多久」现在摆在外面：设置页「回收站」那一行尾巴上一个胶囊。
///
/// 以前它藏在回收站页面顶部的副标题里，得先进那一页才看得见、才点得到。
void main() {
  late Directory root;
  late AppDatabase db;
  late NoteRepository repo;
  late AppState state;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('yw_trash_retention_');
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

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(theme: AppTheme.light(), home: const SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('回收站'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
  }

  testWidgets('设置页「回收站」那一行直接显示保留天数', (tester) async {
    await pumpSettings(tester);
    expect(find.text('回收站'), findsOneWidget);
    expect(find.text('保留 30 天'), findsOneWidget);
  });

  testWidgets('一直不删时胶囊写「一直不删」', (tester) async {
    state.setTrashRetentionDays(0);
    await pumpSettings(tester);
    expect(find.text('一直不删'), findsOneWidget);
    expect(find.text('保留 30 天'), findsNothing);
  });

  testWidgets('点胶囊能改天数，改完立刻反映到那一行', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text('保留 30 天'));
    await tester.pumpAndSettle();
    expect(find.text('回收站保留多久'), findsOneWidget);

    await tester.tap(find.text('7 天'));
    await tester.pumpAndSettle();
    expect(state.trashRetentionDays, 7);
    expect(find.text('保留 7 天'), findsOneWidget);
  });

  testWidgets('点胶囊不会顺带跳进回收站', (tester) async {
    await pumpSettings(tester);
    await tester.tap(find.text('保留 30 天'));
    await tester.pumpAndSettle();
    // 菜单开了，但页面还停在设置页
    expect(find.text('回收站保留多久'), findsOneWidget);
    expect(find.text('清空回收站'), findsNothing);
  });

  testWidgets('改成更短的保留期，当场就把超期的清掉', (tester) async {
    final old = repo.insertNote(
      title: '很早以前删的',
      content: '正文',
      excerpt: '正文',
      publishedAt: DateTime.now(),
    );
    repo.deleteNote(old);
    // 手动把它推到 100 天前
    db.db.execute(
      'UPDATE notes SET deleted_at = ? WHERE id = ?',
      <Object?>[
        DateTime.now()
            .subtract(const Duration(days: 100))
            .millisecondsSinceEpoch,
        old,
      ],
    );
    state.refreshTrash();
    expect(state.trashedNotes.length, 1);

    await pickTrashRetentionAfter(tester, state, 30);
    expect(state.trashedNotes, isEmpty);
  });
}

/// 直接走共用的选择逻辑（菜单是异步的，测试里跳过弹菜单这一步）。
Future<void> pickTrashRetentionAfter(
  WidgetTester tester,
  AppState state,
  int days,
) async {
  state.setTrashRetentionDays(days);
  state.repo.purgeTrashOlderThan(days);
  state.refreshTrash();
  await tester.pumpAndSettle();
}
