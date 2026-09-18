// 演示数据：往待办清单里灌几条示例，方便看界面效果 / 做演示。
//
// 用法：
//   dart run tool/seed_todos.dart            # 追加示例待办
//   dart run tool/seed_todos.dart --clear    # 先清空再追加
//
// 注意：请先关闭正在运行的「元世界」，避免两个连接同时写库。
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/repositories/todo_repository.dart';

Future<void> main(List<String> args) async {
  final root = _defaultDbRoot();
  final db = AppDatabase.openAt(root);
  final repo = TodoRepository(db);

  if (args.contains('--clear')) {
    db.db.execute('DELETE FROM todos');
    print('已清空待办');
  }

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  // (内容, 截止天数偏移, 优先级)
  const items = <(String, int?, int)>[
    ('把「元世界」的统计页图表再打磨一轮', 1, 3),
    ('给待办加上截止时间提醒', 3, 2),
    ('整理 B 站文集的图片附件，去掉重复的', null, 1),
    ('研究一下 FTS5 的中文分词能不能再准一点', null, 0),
    ('读《克拉拉与太阳》', 7, 0),
    ('把长文排行的条形图换成可点击跳转', null, 0),
  ];

  for (final (content, dueOffset, priority) in items) {
    repo.add(
      content,
      dueAt: dueOffset == null ? null : today.add(Duration(days: dueOffset)),
      priority: priority,
    );
  }

  // 造两条"已完成"的，好让已完成折叠区有内容
  final doneA = repo.add('搭好 Flutter 双端构建环境', priority: 0);
  final doneB = repo.add('写完 docx 解析器', priority: 0);
  repo.setDone(doneA, true);
  repo.setDone(doneB, true);

  final c = repo.counts();
  print('待办：未完成 ${c.open}，已完成 ${c.done}，逾期 ${c.overdue}');
  print('数据库：$root');
  db.close();
}

String _defaultDbRoot() {
  final appData = Platform.environment['APPDATA'];
  if (appData == null || appData.isEmpty) return Directory.current.path;
  return '$appData${Platform.pathSeparator}com.yuanworld'
      '${Platform.pathSeparator}yuan_world';
}
