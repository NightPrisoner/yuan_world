// 批量导入命令行工具。
//
// 用途：不启动图形界面，直接把一个目录下的 .docx 全部导入「元世界」的数据库。
// 适合首次灌入大量文集（比在界面里点选文件夹快，也便于脚本化/重复执行）。
//
// 用法：
//   dart run tool/import_cli.dart "E:\deepseek work\B站专栏文集"
//
// 数据库位置默认取 Windows 的应用数据目录：
//   %APPDATA%\com.yuanworld\yuan_world
// 也可以用 --db 指定其它目录（比如想导入到一份测试库里）。
//
// 注意：导入前请先关闭正在运行的「元世界」，避免两个连接同时写同一个库。
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.contains('-h') || args.contains('--help')) {
    print('用法: dart run tool/import_cli.dart <文集目录> [--db <数据库目录>]');
    return;
  }

  final sourceDir = args.first;
  final dbFlag = args.indexOf('--db');
  final dbRoot = dbFlag >= 0 && dbFlag + 1 < args.length
      ? args[dbFlag + 1]
      : _defaultDbRoot();

  if (!Directory(sourceDir).existsSync()) {
    print('目录不存在: $sourceDir');
    exitCode = 1;
    return;
  }

  print('来源目录 : $sourceDir');
  print('数据库   : $dbRoot');
  print('');

  final files = ImportService.collectDocx(sourceDir);
  if (files.isEmpty) {
    print('该目录下没有找到 .docx 文件。');
    return;
  }

  final totalMb =
      files.fold<int>(0, (s, f) => s + f.lengthSync()) / 1024 / 1024;
  print('发现 ${files.length} 个 .docx，合计 ${totalMb.toStringAsFixed(1)} MB');
  print('开始导入…\n');

  final db = AppDatabase.openAt(dbRoot);
  final repo = NoteRepository(db);
  final importer = ImportService(db, repo);

  final sw = Stopwatch()..start();
  var lastShown = -1;

  final summary = await importer.importDocx(
    files,
    onProgress: (stage, done, total, label) {
      // 每完成一个文件打一行，避免刷屏
      if (done != lastShown) {
        lastShown = done;
        final pct = (done / total * 100).toStringAsFixed(0).padLeft(3);
        final name = label.length > 46 ? '${label.substring(0, 43)}...' : label;
        print('  [$pct%] $done/$total  ${_stageName(stage)}  $name');
      }
    },
  );

  sw.stop();
  print('\n${'─' * 60}');
  print('导入完成，用时 ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} 秒');
  print('  ${summary.report}');
  if (summary.errors.isNotEmpty) {
    print('\n失败明细：');
    for (final e in summary.errors.take(30)) {
      print('  - $e');
    }
  }

  // 汇总一下库里的现状，确认真的写进去了
  final o = repo.overview();
  print('\n数据库现状：');
  print('  笔记      ${o.noteCount} 篇');
  print('  总字数    ${o.totalChars}');
  print('  图片      ${o.imageCount} 张');
  print('  文集      ${o.collectionCount} 个');
  print('  标签      ${o.tagCount} 个');
  if (o.firstAt != null && o.lastAt != null) {
    print('  时间跨度  ${_d(o.firstAt!)} ~ ${_d(o.lastAt!)}');
  }
  print('\n各文集分布：');
  for (final c in repo.collectionDistribution()) {
    print('  ${c.name.padRight(12)} ${c.count.toString().padLeft(3)} 篇   '
        '${c.chars.toString().padLeft(8)} 字');
  }

  db.close();
}

String _stageName(ImportStage s) => switch (s) {
  ImportStage.reading => '读取',
  ImportStage.parsing => '解析',
  ImportStage.saving => '入库',
  ImportStage.done => '完成',
};

String _d(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Windows 上 Flutter 的 getApplicationSupportDirectory() 会落到
/// %APPDATA%\<org>\<app>，这里手工复现，好让 CLI 不依赖 Flutter 插件。
String _defaultDbRoot() {
  final appData = Platform.environment['APPDATA'];
  if (appData == null || appData.isEmpty) {
    return Directory.current.path;
  }
  return '$appData${Platform.pathSeparator}com.yuanworld'
      '${Platform.pathSeparator}yuan_world';
}
