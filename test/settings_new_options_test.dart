import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/app_info.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/settings/settings_page.dart';

/// 本轮新增的几个设置项：自动备份节奏、回收站保留天数、主题强调色、
/// 数据目录搬移。都是"改了要真的存下来、下次打开还在"的东西。
void main() {
  late Directory tmp;
  late AppDatabase db;
  late NoteRepository repo;
  late AppState state;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('yw_newopt_');
    db = AppDatabase.openAt(p.join(tmp.path, 'db'));
    repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
    AppInfo.setVersionForTesting('1.0.0+1');
  });

  tearDown(() {
    state.dispose();
    db.close();
    CrashLogGuard.clean();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('自动快照与自动完整备份的间隔', () {
    test('默认是 24 小时 / 7 天', () {
      expect(state.snapshotEveryHours, 24);
      expect(state.fullBackupEveryDays, 7);
    });

    test('改了就写进设置，重开还在', () {
      state.setSnapshotEveryHours(6);
      state.setFullBackupEveryDays(3);
      expect(repo.getSetting('backup.snapshotEveryH'), '6');
      expect(repo.getSetting('backup.fullEveryD'), '3');

      final again = AppState(db, repo, ImportService(db, repo));
      expect(again.snapshotEveryHours, 6);
      expect(again.fullBackupEveryDays, 3);
      again.dispose();
    });

    test('快照间隔可以是 0（只手动），备份间隔最小 1 天、最大 365 天', () {
      state.setSnapshotEveryHours(0);
      expect(state.snapshotEveryHours, 0);
      state.setSnapshotEveryHours(-5);
      expect(state.snapshotEveryHours, 0);
      state.setSnapshotEveryHours(24 * 100);
      expect(state.snapshotEveryHours, 24 * 30);

      state.setFullBackupEveryDays(0);
      expect(state.fullBackupEveryDays, 1);
      state.setFullBackupEveryDays(9999);
      expect(state.fullBackupEveryDays, 365);
    });

    test('存了坏值就当默认，不炸', () {
      repo.setSetting('backup.snapshotEveryH', 'abc');
      repo.setSetting('backup.fullEveryD', '');
      expect(state.snapshotEveryHours, 24);
      expect(state.fullBackupEveryDays, 7);
    });

    test('快照间隔为 0 时，自动检查不会再拍快照', () async {
      state.setSnapshotEveryHours(0);
      await state.checkAutoBackup();
      expect(state.backup.snapshots(), isEmpty);
      expect(state.lastSnapshotAt, isNull);
    });
  });

  group('回收站保留天数', () {
    test('默认 30 天，可以设成 0 = 一直不删', () {
      expect(state.trashRetentionDays, 30);
      state.setTrashRetentionDays(0);
      expect(state.trashRetentionDays, 0);
      state.setTrashRetentionDays(90);
      expect(state.trashRetentionDays, 90);
    });

    test('0 时清理不动手，设成正数才删旧的', () {
      final id = repo.insertNote(title: '老的', content: 'x', excerpt: 'x');
      repo.deleteNote(id);
      // 手动把删除时间挪到 100 天前
      db.db.execute(
        'UPDATE notes SET deleted_at = ? WHERE id = ?',
        [DateTime.now().subtract(const Duration(days: 100)).millisecondsSinceEpoch, id],
      );

      expect(repo.purgeTrashOlderThan(0), 0);
      expect(repo.listTrashedNotes().length, 1);

      expect(repo.purgeTrashOlderThan(30), 1);
      expect(repo.listTrashedNotes(), isEmpty);
    });

    test('设置项写进库，不是内存里的临时值', () {
      state.setTrashRetentionDays(7);
      expect(repo.getSetting('trash.retentionDays'), '7');
      final again = AppState(db, repo, ImportService(db, repo));
      expect(again.trashRetentionDays, 7);
      again.dispose();
    });
  });

  group('主题强调色', () {
    test('默认没有强调色（走系统那套蓝）', () {
      expect(state.themeSeed, isNull);
    });

    test('选一个颜色会存下来，重开还在', () {
      state.setThemeSeed(const Color(0xFF34C759));
      expect(state.themeSeed, const Color(0xFF34C759));
      final again = AppState(db, repo, ImportService(db, repo));
      expect(again.themeSeed, const Color(0xFF34C759));
      again.dispose();
    });

    test('选"默认"会把设置清空', () {
      state.setThemeSeed(const Color(0xFFFF9500));
      state.setThemeSeed(null);
      expect(state.themeSeed, isNull);
      expect(repo.getSetting('theme.seed'), '');
    });

    test('存了坏值当成默认，不炸', () {
      repo.setSetting('theme.seed', 'not-a-color');
      expect(state.themeSeed, isNull);
    });

    test('读了强调色之后，主题的 tint 真的跟着变', () {
      final plain = AppTheme.light();
      final seeded = AppTheme.light(seed: const Color(0xFFFF2D55));
      final a = plain.extension<AppColors>()!;
      final b = seeded.extension<AppColors>()!;
      expect(a.tint, isNot(b.tint));
      // 背景/文字保持系统那套，只换强调色
      expect(a.background, b.background);
      expect(a.label, b.label);
    });
  });

  group('数据目录搬移', () {
    test('搬到别的地方：文件都在，库还能读', () async {
      final noteId = repo.insertNote(
        title: '搬家前写的',
        content: '正文',
        excerpt: '正文',
      );
      final target = p.join(tmp.path, 'moved');
      final moves = <double>[];
      final result = await state.moveDataLocation(
        target,
        onProgress: moves.add,
      );

      expect(result.target, target);
      expect(result.files, greaterThan(0));
      expect(File(p.join(target, 'yuanworld.db')).existsSync(), isTrue);
      expect(moves.last, 1.0);

      // 搬完就地换了连接：还是同一个 repo / state，读得到刚写的笔记
      expect(state.db.rootDir.path, target);
      expect(repo.getNote(noteId)!.title, '搬家前写的');
      expect(Directory(p.join(tmp.path, 'db')).existsSync(), isTrue,
          reason: '原目录不删，留给用户自己决定');
    });

    test('不能搬进自己的子目录', () async {
      await expectLater(
        state.moveDataLocation(p.join(db.rootDir.path, 'inner')),
        throwsA(isA<StateError>()),
      );
    });

    test('目标和当前一样：什么都不做', () async {
      final result = await state.moveDataLocation(db.rootDir.path);
      expect(result.files, 0);
      expect(state.db.rootDir.path, db.rootDir.path);
    });
  });

  group('设置页把这些都摆出来了', () {
    testWidgets('备份区块有间隔输入框，改了会存', (tester) async {
      tester.view.physicalSize = const Size(900, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(theme: AppTheme.light(), home: const SettingsPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('自动快照'), findsOneWidget);
      expect(find.text('自动完整备份'), findsOneWidget);
      expect(find.text('多久拍一次'), findsOneWidget);
      expect(find.text('多久备份一次'), findsOneWidget);

      final field = find.descendant(
        of: find.ancestor(
          of: find.text('多久备份一次'),
          matching: find.byType(Row),
        ).first,
        matching: find.byType(TextField),
      );
      expect(field, findsOneWidget);
      await tester.enterText(field, '3');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(state.fullBackupEveryDays, 3);
    });

    testWidgets('强调色一排色点，点了就换', (tester) async {
      tester.view.physicalSize = const Size(900, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(theme: AppTheme.light(), home: const SettingsPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('强调色'), findsOneWidget);
      // 8 个预设 + 1 个「从色板里挑」自定义
      expect(find.byTooltip('用这个颜色'), findsNWidgets(8));
      expect(find.byTooltip('从色板里挑'), findsOneWidget);
      // 预设里第三个是橙色
      await tester.tap(find.byTooltip('用这个颜色').at(2));
      await tester.pumpAndSettle();
      expect(state.themeSeed, const Color(0xFFFF9500));
    });

    testWidgets('两句旧小字已经不在了', (tester) async {
      tester.view.physicalSize = const Size(900, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(theme: AppTheme.light(), home: const SettingsPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('全部数据都在本机'), findsNothing);
      expect(find.textContaining('备份时直接复制上面两个目录即可'), findsNothing);
    });
  });
}

/// 部分用例会碰诊断目录（设置页里挂着入口），顺手清掉。
class CrashLogGuard {
  static void clean() {}
}
