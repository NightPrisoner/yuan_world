/// 搜索页要能「说实话」：总数是查库数出来的、能翻页、编辑完返回会重查。
///
/// 修之前这里是三个连在一起的问题：
///  1. `repo.search(q, limit: 200)`，页面却拿返回长度当总数 —— 超 200 条
///     就是个假数字；
///  2. 没有分页，第 201 条起永远看不到；
///  3. `if (query == _lastQuery) return;` 拦着不让重查，从详情返回后
///     列表还是进详情之前那份。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/search/search_page.dart';

void main() {
  late AppDatabase db;
  late NoteRepository repo;
  late AppState state;

  setUp(() async {
    db = AppDatabase.inMemory();
    repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
  });

  tearDown(() async {
    state.dispose();
    db.close();
  });

  int add(String title, {String content = ''}) => repo.insertNote(
    title: title,
    content: content,
    excerpt: content,
    publishedAt: DateTime.now(),
  );

  Future<void> pumpSearch(WidgetTester tester) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(theme: AppTheme.light(), home: const SearchPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 在搜索框里输入并等防抖跑完。
  Future<void> type(WidgetTester tester, String q) async {
    await tester.enterText(find.byType(TextField), q);
    await tester.pump(const Duration(milliseconds: 220));
    await tester.pumpAndSettle();
  }

  group('总数是真的', () {
    test('countNotes 与列表条数对得上（同一套筛选条件）', () {
      for (var i = 0; i < 45; i++) {
        add('会议纪要 $i', content: '会议记录第 $i 篇');
      }
      final filter = NoteFilter(query: '会议');
      expect(repo.countNotes(filter), 45);
      expect(repo.listNotes(filter, limit: 45).length, 45);
    });

    test('searchPage 一页最多给 limit 条，总数不受 limit 影响', () {
      for (var i = 0; i < 80; i++) {
        add('旅行日记 $i', content: '旅行记录 $i');
      }
      final first = repo.searchPage('旅行', limit: 30);
      expect(first.notes.length, 30);
      expect(first.total, 80);

      final third = repo.searchPage('旅行', limit: 30, offset: 60);
      expect(third.notes.length, 20);
      expect(third.total, 80);
      // 不同页之间不重复
      final firstIds = first.notes.map((n) => n.id).toSet();
      expect(third.notes.any((n) => firstIds.contains(n.id)), isFalse);
    });

    test('筛选条件也计入总数（归档的不算）', () {
      final a = add('会议纪要', content: '会议');
      add('会议纪要二', content: '会议');
      repo.setArchived(a, true);
      expect(repo.countNotes(const NoteFilter(query: '会议')), 1);
      expect(repo.countNotes(const NoteFilter(query: '会议', archivedOnly: true)), 1);
    });

    testWidgets('超过一页时，页面写的是库里真实总数', (tester) async {
      for (var i = 0; i < 45; i++) {
        add('会议纪要 $i', content: '会议记录第 $i 篇');
      }
      await pumpSearch(tester);
      await type(tester, '会议');

      expect(find.textContaining('找到 45 篇'), findsOneWidget);
      expect(find.textContaining('已显示 30 篇'), findsOneWidget);
    });

    testWidgets('刚好一页时不多显示「已显示 N 篇」', (tester) async {
      for (var i = 0; i < 3; i++) {
        add('读书笔记 $i', content: '读书 $i');
      }
      await pumpSearch(tester);
      await type(tester, '读书');

      expect(find.text('找到 3 篇'), findsOneWidget);
      expect(find.textContaining('已显示'), findsNothing);
    });
  });

  group('翻页', () {
    testWidgets('滚到底自动取下一页，结果不丢也不重', (tester) async {
      for (var i = 0; i < 45; i++) {
        add('会议纪要 $i', content: '会议记录第 $i 篇');
      }
      await pumpSearch(tester);
      await type(tester, '会议');

      expect(find.textContaining('已显示 30 篇'), findsOneWidget);

      // 往下滚到触发加载（每次 -4000，分两次保证一定到底）
      await tester.drag(find.byType(ListView), const Offset(0, -4000));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -4000));
      await tester.pumpAndSettle();

      // 滚回顶部再读标题 —— ListView.builder 会把滚出屏幕的第 0 项回收掉，
      // 停在底部时那一行根本不在树里。
      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, 5000));
      await tester.pumpAndSettle();

      // 45 条全部到齐，标题不再显示「已显示」
      expect(find.textContaining('找到 45 篇'), findsOneWidget);
      expect(find.textContaining('已显示'), findsNothing);
    });

    testWidgets('只有一页时不出现「继续往下滚动加载更多」', (tester) async {
      for (var i = 0; i < 3; i++) {
        add('读书笔记 $i', content: '读书 $i');
      }
      await pumpSearch(tester);
      await type(tester, '读书');

      expect(find.text('找到 3 篇'), findsOneWidget);
      expect(find.textContaining('继续往下滚动'), findsNothing);
    });
  });

  group('编辑完返回要重搜', () {
    testWidgets('在详情里改了正文，返回后结果跟着变', (tester) async {
      final hit = add('甲', content: '这里有火车');
      add('乙', content: '只有汽车');

      await pumpSearch(tester);
      await type(tester, '火车');
      expect(find.text('甲'), findsOneWidget);
      expect(find.textContaining('找到 1 篇'), findsOneWidget);

      // 进详情
      await tester.tap(find.text('甲'));
      await tester.pumpAndSettle();

      // 直接在库里改掉正文（等价于在详情里编辑并保存），再返回
      repo.updateNote(
        id: hit,
        content: '这里既没有，也没有别的',
        excerpt: '这里既没有，也没有别的',
      );
      await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
      await tester.pumpAndSettle();

      // 返回后必须重查：这篇已经不含「火车」了
      expect(find.text('没有找到结果'), findsOneWidget);
    });

    testWidgets('返回后即使没改动也会重查（不会因为 _lastQuery 卡住）', (tester) async {
      add('丙', content: '一个关于知识管理的长文');
      await pumpSearch(tester);
      await type(tester, '知识管理');
      expect(find.text('丙'), findsOneWidget);

      await tester.tap(find.text('丙'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
      await tester.pumpAndSettle();

      // 结果还在，说明重查跑过且没有把查询词弄丢
      expect(find.text('丙'), findsOneWidget);
      expect(find.textContaining('找到 1 篇'), findsOneWidget);
    });
  });
}


