/// 统计页的**多文件夹选择**。
///
/// 这里盯的是"选了两个文件夹，界面有没有说实话"——
/// 之前按钮上永远写「全部文件夹」、副标题一个字不提，
/// 用户勾完两个文件夹却看不出自己筛了东西。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/stats/stats_page.dart';

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

  /// 三个文件夹，各几篇笔记。
  ///
  /// 走 `state.createCollection` 而不是 `state.repo.createCollection` ——
  /// 后者不会刷新 AppState 缓存的列表，筛选项里会是空的。
  Future<void> seed() async {
    final now = DateTime.now();
    for (final name in <String>['文集甲', '文集乙', '文集丙']) {
      final cid = await state.createCollection(name);
      for (var i = 0; i < 6; i++) {
        final at = DateTime(now.year, now.month - i, 10);
        state.repo.insertNote(
          title: '$name 第 $i 篇',
          content: 'x' * (400 + i * 300),
          excerpt: '深夜写作的时候最有感觉',
          publishedAt: at,
          collectionId: cid,
          charCount: 400 + i * 300,
          wordCount: 120 + i * 40,
        );
      }
    }
  }

  Future<void> pumpStats(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1300, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(theme: AppTheme.light(), home: const StatsPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 打开筛选对话框 → 点「全选」→ 确定。
  Future<void> selectAllFolders(WidgetTester tester) async {
    await tester.tap(find.text('全部文件夹'));
    await tester.pumpAndSettle();
    expect(find.text('选择文件夹'), findsOneWidget);
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
  }

  testWidgets('没筛选时按钮写「全部文件夹」', (tester) async {
    await seed();
    await pumpStats(tester);
    expect(find.text('全部文件夹'), findsOneWidget);
    expect(find.textContaining('· 对比'), findsNothing);
  });

  testWidgets('全选之后按钮不再谎称「全部」', (tester) async {
    await seed();
    await pumpStats(tester);
    await selectAllFolders(tester);

    // 三个文件夹全选 —— 按钮要说清楚选了几个
    expect(find.text('已选 3 个文件夹'), findsOneWidget);
    expect(find.text('全部文件夹'), findsNothing);
  });

  testWidgets('副标题会写出对比了几个文件夹', (tester) async {
    await seed();
    await pumpStats(tester);
    await selectAllFolders(tester);

    // 「对比 N 个文件夹」必须出现在筛选按钮之外的摘要行里
    expect(find.textContaining('· 对比 3 个文件夹'), findsOneWidget);
  });

  testWidgets('只选一个文件夹时显示它的名字', (tester) async {
    await seed();
    await pumpStats(tester);

    await tester.tap(find.text('全部文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文集乙').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.text('文集乙'), findsWidgets);
    expect(find.text('全部文件夹'), findsNothing);
    expect(find.textContaining('只看「文集乙」'), findsOneWidget);
  });

  testWidgets('选完文件夹后趋势图能渲染出多条序列，不报错', (tester) async {
    await seed();
    await pumpStats(tester);
    await selectAllFolders(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('发布趋势'), findsOneWidget);
    // 多序列会带图例
    expect(find.text('文集甲'), findsWidgets);
  });

  testWidgets('筛选状态会写进设置，重开页面还在', (tester) async {
    await seed();
    await pumpStats(tester);
    await selectAllFolders(tester);

    expect(state.repo.getSetting('stats.collectionIds'), isNotEmpty);
    expect(state.repo.getSetting('stats.collectionIds'), contains(','));
  });

  /// 概览卡片里某个数字（第一行是标签，第二行才是值）。
  String statValue(WidgetTester tester, String key) {
    final texts = tester
        .widgetList<Text>(
          find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text)),
        )
        .map((t) => t.data)
        .whereType<String>()
        .toList();
    return texts.length < 2 ? '' : texts[1];
  }

  /// 打开筛选 → 只勾一个 → 确定。
  Future<void> pickOnly(WidgetTester tester, String name) async {
    await tester.tap(find.text('全部文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部（不筛选）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(name).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
  }

  testWidgets('改文件夹筛选，概览**当场**就变（不是等下次进页面）', (tester) async {
    await seed();
    await pumpStats(tester);

    // 三个文件夹各 6 篇 = 18 篇
    expect(statValue(tester, 'ov-notes'), '18');

    await pickOnly(tester, '文集乙');

    // 这条盯的就是用户报的那个 bug：_reload() 漏了 _overview，
    // 图表全跟着筛选变了，概览还挂着 18
    expect(statValue(tester, 'ov-notes'), '6');
    expect(find.textContaining('只看「文集乙」'), findsOneWidget);
  });

  testWidgets('概览的总字数也跟着筛选走', (tester) async {
    await seed();
    await pumpStats(tester);
    final all = statValue(tester, 'ov-chars');
    expect(all, isNotEmpty);

    await pickOnly(tester, '文集丙');

    expect(statValue(tester, 'ov-chars'), isNot(all));
    expect(statValue(tester, 'ov-notes'), '6');
  });

  testWidgets('取消筛选后概览恢复成全库', (tester) async {
    await seed();
    await pumpStats(tester);

    await pickOnly(tester, '文集甲');
    expect(statValue(tester, 'ov-notes'), '6');

    await tester.tap(find.text('文集甲').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部（不筛选）'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(statValue(tester, 'ov-notes'), '18');
  });
}
