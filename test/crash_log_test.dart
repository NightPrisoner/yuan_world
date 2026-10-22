/// 崩溃日志与诊断信息。
///
/// 开源软件「崩了」的 issue 只靠一句描述没法查，所以这里钉三件事：
///   · 错误真的会落到磁盘上，且能按时间读回来；
///   · 日志不会无限涨（有保留上限）；
///   · 诊断文本里带够定位问题的信息（版本、系统、库大小、最近的错误）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/app_info.dart';
import 'package:yuan_world/core/diagnostics/crash_log.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/settings/diagnostics_sheet.dart';
import 'package:yuan_world/features/settings/settings_page.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('yw_crashlog_');
    CrashLog.resetForTesting();
    AppInfo.setVersionForTesting('1.2.3+45');
  });

  tearDown(() {
    CrashLog.resetForTesting();
    AppInfo.resetForTesting();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('崩溃日志落盘', () {
    test('记一条错误就多一份日志，内容里带版本与堆栈', () {
      CrashLog.install(root);

      CrashLog.record(
        StateError('模拟的崩溃'),
        StackTrace.fromString(
          '#0      aaa (a.dart:1:1)\n#1      bbb (b.dart:2:2)',
        ),
        kind: 'test',
        extra: '点开某篇笔记时',
      );

      final files = CrashLog.files();
      expect(files, hasLength(1));
      final text = files.single.readAsStringSync();
      expect(text, contains('模拟的崩溃'));
      expect(text, contains('1.2.3+45'));
      expect(text, contains('a.dart:1:1'));
      expect(text, contains('点开某篇笔记时'));
    });

    test('同一天的多条错误追加进同一个文件，而不是覆盖', () {
      CrashLog.install(root);
      CrashLog.record(StateError('第一条'), StackTrace.empty);
      CrashLog.record(StateError('第二条'), StackTrace.empty);

      expect(CrashLog.files(), hasLength(1));
      final text = CrashLog.files().single.readAsStringSync();
      expect(text, contains('第一条'));
      expect(text, contains('第二条'));
    });

    test('日志只保留最近 N 份，超出的自动删掉', () {
      final dir = Directory(p.join(root.path, 'logs'))
        ..createSync(recursive: true);
      CrashLog.attachForTesting(dir);

      // 造一堆过期的日志文件（文件名决定新旧）
      for (var i = 0; i < kCrashLogKeep + 5; i++) {
        File(
          p.join(dir.path, 'log-2020${i.toString().padLeft(2, '0')}.txt'),
        ).writeAsStringSync('旧日志 $i');
      }
      expect(
        dir.listSync().whereType<File>().length,
        kCrashLogKeep + 5,
        reason: '前置条件：文件确实造出来了',
      );

      // 记一条，触发轮转
      CrashLog.record(StateError('触发轮转'), StackTrace.empty);

      final names = CrashLog.files().map((f) => p.basename(f.path)).toList();
      expect(names.length, lessThanOrEqualTo(kCrashLogKeep + 1));
      // 最旧的那几个必须被删掉，最新的一定还在
      expect(names, isNot(contains('log-202000.txt')));
      expect(names.first, startsWith('log-202'));
    });

    test('清空之后一份都不剩', () {
      CrashLog.install(root);
      CrashLog.record(StateError('要清掉的'), StackTrace.empty);
      expect(CrashLog.files(), isNotEmpty);

      CrashLog.clear();
      expect(CrashLog.files(), isEmpty);
      expect(CrashLog.totalBytes(), 0);
    });

    test('日志目录建不出来时不抛异常，只是没有文件', () {
      // 把 logs 这个名字占成一个普通文件，createSync 就会失败
      File(p.join(root.path, 'logs')).writeAsStringSync('占位');
      expect(() => CrashLog.install(root), returnsNormally);
      expect(() => CrashLog.record(StateError('没目录也要能记'), null),
          returnsNormally);
      expect(CrashLog.files(), isEmpty);
    });
  });

  group('诊断文本', () {
    test('没有错误时明确写"没有记录到错误"，不说空白', () {
      CrashLog.install(root);
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final repo = NoteRepository(db);
      final state = AppState(db, repo, ImportService(db, repo));

      final text = buildDiagnosticsText(
        state: state,
        version: '1.2.3+45',
        platformOverride: 'windows',
        now: DateTime(2026, 10, 22, 19, 5),
      );

      expect(text, contains('元世界诊断信息'));
      expect(text, contains('版本：1.2.3+45'));
      expect(text, contains('系统：windows'));
      expect(text, contains('2026-10-22 19:05'));
      expect(text, contains('没有记录到错误'));
    });

    test('有错误时把最近的错误带进文本', () async {
      CrashLog.install(root);
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final repo = NoteRepository(db);
      final state = AppState(db, repo, ImportService(db, repo));
      await state.init();

      CrashLog.record(StateError('导出时炸了'), StackTrace.empty, kind: 'io');

      final text = buildDiagnosticsText(
        state: state,
        version: '1.2.3+45',
        platformOverride: 'android',
      );

      expect(text, contains('最近的错误'));
      expect(text, contains('导出时炸了'));
      expect(text, contains('类型：io'));
    });
  });

  group('设置页入口', () {
    testWidgets('「导出诊断信息」打开弹窗，里面有可复制的文本', (tester) async {
      CrashLog.install(root);
      tester.view.physicalSize = const Size(900, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final repo = NoteRepository(db);
      final state = AppState(db, repo, ImportService(db, repo));
      await state.init();

      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const SettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('导出诊断信息…'));
      await tester.pumpAndSettle();

      expect(find.text('诊断信息'), findsOneWidget);
      expect(find.textContaining('元世界诊断信息'), findsOneWidget);
      expect(find.text('复制'), findsOneWidget);
      expect(find.textContaining('不会自动上传'), findsOneWidget);
    });
  });
}
