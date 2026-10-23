/// 设置页的备份区块：用户得能在界面上看到"到底备成了没有"。
///
/// 这三行的文案看着不起眼，但它们回答的是整个备份功能唯一重要的问题：
/// 上次成功是什么时候、上次为什么没成、备份文件在哪。
library;

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

void main() {
  late Directory root;
  late AppDatabase db;
  late NoteRepository repo;
  late AppState state;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('yw_settings_backup_');
    db = AppDatabase.openAt(root.path);
    repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
  });

  tearDown(() {
    state.dispose();
    db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pumpSettings(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(theme: AppTheme.light(), home: const SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('两个自动备份开关都在，默认都开着', (tester) async {
    await pumpSettings(tester);
    expect(find.text('自动快照'), findsOneWidget);
    expect(find.text('自动完整备份'), findsOneWidget);
    expect(state.backupAutoSnapshot, isTrue);
    expect(state.backupAutoFull, isTrue);
  });

  testWidgets('还没备份过：会说清楚"还没有"，而不是装作没事', (tester) async {
    await pumpSettings(tester);
    expect(find.textContaining('还没有快照'), findsOneWidget);
    expect(find.textContaining('还没有自动完整备份'), findsOneWidget);
  });

  testWidgets('备份成功之后显示最近一次的时间和份数', (tester) async {
    // checkAutoBackup 内部有让出事件循环的 await，widget 测试的假时钟
    // 推不动它 —— 必须放到 runAsync 里用真实时钟跑。
    await tester.runAsync(() => state.checkAutoBackup());
    await pumpSettings(tester);
    expect(find.textContaining('最近一次自动快照'), findsOneWidget);
    expect(find.textContaining('最近一次自动完整备份'), findsOneWidget);
    expect(find.textContaining('上次自动快照没成功'), findsNothing);
    expect(find.textContaining('上次自动完整备份没成功'), findsNothing);
  });

  testWidgets('失败时把原因显示出来，用户能看见自己的备份没成', (tester) async {
    repo.setSetting('backup.lastSnapshotError', 'database is locked: simulated');
    repo.setSetting(
      'backup.lastSnapshotErrorAt',
      DateTime(2026, 10, 21, 9, 30).toIso8601String(),
    );
    await pumpSettings(tester);
    expect(find.textContaining('database is locked'), findsOneWidget);
    expect(find.textContaining('2026-10-21 09:30'), findsOneWidget);
  });

  testWidgets('关掉开关会写进设置，重开页面还是关的', (tester) async {
    await pumpSettings(tester);
    // 点文字不切开关，得点开关本体
    await tester.tap(
      find.descendant(
        of: find.ancestor(
          of: find.text('自动完整备份'),
          matching: find.byType(Row),
        ),
        matching: find.byType(Switch),
      ),
    );
    await tester.pumpAndSettle();
    expect(state.backupAutoFull, isFalse);

    await pumpSettings(tester);
    expect(state.backupAutoFull, isFalse);
  });

  testWidgets('快照与完整备份各占一行开关，目录也各占一行', (tester) async {
    await pumpSettings(tester);
    // 开关和间隔合成同一行
    expect(find.text('自动快照'), findsOneWidget);
    expect(find.text('自动完整备份'), findsOneWidget);
    // 目录各占一行，路径直接写在行里
    expect(find.text('快照存放位置'), findsOneWidget);
    expect(find.text('备份存放位置'), findsOneWidget);
    expect(
      find.textContaining('${Platform.pathSeparator}snapshots'),
      findsWidgets,
    );
    expect(find.textContaining('${Platform.pathSeparator}backups'), findsWidgets);
    // 没改过目录时不出现"自定义"标记
    expect(find.text('自定义'), findsNothing);
  });

  testWidgets('改了备份目录之后：行里显示新路径，并标记为自定义', (tester) async {
    final custom = Directory(
      '${root.path}${Platform.pathSeparator}my_backups',
    )..createSync(recursive: true);
    state.setBackupFullDir(custom.path);
    await pumpSettings(tester);

    expect(find.text(custom.path), findsOneWidget);
    expect(find.text('自定义'), findsOneWidget);
    // 快照那行不受影响
    expect(
      find.textContaining('${Platform.pathSeparator}snapshots'),
      findsWidgets,
    );

    // 菜单里能回默认
    await tester.tap(find.text('备份存放位置'));
    await tester.pumpAndSettle();
    final resetItem = find.descendant(
      of: find.byType(PopupMenuItem<String>),
      matching: find.text('回到默认位置'),
    );
    expect(resetItem, findsOneWidget);
    await tester.tap(resetItem);
    await tester.pumpAndSettle();
    expect(state.backupFullDir, '');
    expect(
      state.backup.fullBackupDir.path,
      state.backup.defaultFullBackupDir.path,
    );
  });
}
