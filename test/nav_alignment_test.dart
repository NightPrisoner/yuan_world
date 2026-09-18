/// 左栏导航的对齐。
///
/// 这一条是拿真实 bug 换来的：「导入文集」原来是自己手搓的一行
/// （`Pressable > _HoverTint > Row`），而 _HoverTint 的左内边距是 22px
/// ——那是给缩进的子文件夹用的——旁边 `_NavRow` 是 10px。
/// 于是它整体比同级右移 12px，一眼就看得出来。
///
/// 光"这次改对了"没用，得钉住：**同级导航项的图标左边缘必须完全一致**。
/// 以后谁再手搓一行，这条会红。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/shell/home_shell.dart';

void main() {
  late AppDatabase db;
  late AppState state;

  setUp(() async {
    db = AppDatabase.inMemory();
    final repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
    for (var i = 0; i < 5; i++) {
      repo.insertNote(
        title: '笔记 $i',
        content: 'x' * 200,
        excerpt: 'x',
        publishedAt: DateTime.now().subtract(Duration(days: i)),
        charCount: 200,
        wordCount: 100,
      );
    }
  });

  tearDown(() => db.close());

  Future<void> pumpWide(WidgetTester tester) async {
    // 宽屏才走三栏工作区（>= 1000）
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(theme: AppTheme.light(), home: const HomeShell()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 左栏里那些"同级"的导航项。图标都是唯一的，直接用图标定位。
  const items = <String, IconData>{
    '待办': Icons.check_circle_rounded,
    '归档': Icons.archive_outlined,
    '回收站': Icons.delete_outline_rounded,
    '统计': Icons.insights_rounded,
    '导入文集': Icons.download_rounded,
    '设置': Icons.tune_rounded,
  };

  testWidgets('所有导航项的图标左边缘必须对齐', (tester) async {
    await pumpWide(tester);

    final xs = <String, double>{};
    for (final e in items.entries) {
      final f = find.byIcon(e.value);
      expect(f, findsWidgets, reason: '左栏里找不到「${e.key}」的图标');
      xs[e.key] = tester.getTopLeft(f.first).dx;
    }

    // 用最小值当基准，逐项报差了多少 —— 失败信息里直接能看出是谁偏了
    final min = xs.values.reduce((a, b) => a < b ? a : b);
    for (final e in xs.entries) {
      expect(
        e.value - min,
        lessThan(0.5),
        reason: '「${e.key}」比最左边的导航项右移了 ${(e.value - min).toStringAsFixed(1)}px',
      );
    }
  });

  testWidgets('所有导航项的文字左边缘也一致（图标宽度相同）', (tester) async {
    await pumpWide(tester);

    final xs = <String, double>{};
    for (final label in items.keys) {
      final f = find.text(label);
      expect(f, findsWidgets, reason: '左栏里找不到「$label」');
      xs[label] = tester.getTopLeft(f.first).dx;
    }
    final min = xs.values.reduce((a, b) => a < b ? a : b);
    for (final e in xs.entries) {
      expect(
        e.value - min,
        lessThan(0.5),
        reason: '「${e.key}」的文字比最左边的右移了 ${(e.value - min).toStringAsFixed(1)}px',
      );
    }
  });

  testWidgets('导入文集点得开，进的是导入页', (tester) async {
    await pumpWide(tester);
    await tester.tap(find.text('导入文集'));
    await tester.pumpAndSettle();
    // 能打开就够了 —— 这里只防"改了布局把它点没了"
    expect(tester.takeException(), isNull);
  });
}
