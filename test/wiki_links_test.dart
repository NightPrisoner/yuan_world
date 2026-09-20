/// `[[双链]]`：解析 + 反向链接。
///
/// 两个独立的关注点放一起测：
///   · **解析**是纯函数（`core/utils/wiki_links.dart`），边界情况最多；
///   · **反向链接**是查询（`NoteRepository.backlinksOf`），口径必须和
///     列表/标签/统计一致（回收站、归档、隐私空间）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/core/utils/wiki_links.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/notes/note_detail_page.dart';

void main() {
  group('解析 [[双链]]', () {
    test('基本的双链', () {
      final links = parseWikiLinks('见 [[克拉拉与太阳]] 那篇');
      expect(links.length, 1);
      expect(links.first.target, '克拉拉与太阳');
      expect(links.first.label, '克拉拉与太阳');
      expect(links.first.start, 2);
    });

    test('[[标题|显示名]]：目标是标题，显示的是别名', () {
      final links = parseWikiLinks('见 [[克拉拉与太阳|那本书]]');
      expect(links.first.target, '克拉拉与太阳');
      expect(links.first.label, '那本书');
    });

    test('标题两边的空格不算（手滑打出来的）', () {
      expect(parseWikiLinks('[[ 读书笔记 ]]').first.target, '读书笔记');
    });

    test('一篇里多处，按出现顺序', () {
      final links = parseWikiLinks('[[甲]] 和 [[乙]] 还有 [[甲|又一个]]');
      expect(links.map((l) => l.target).toList(), <String>['甲', '乙', '甲']);
    });

    test('空标题忽略：它指不到任何东西', () {
      expect(parseWikiLinks('[[]]'), isEmpty);
      expect(parseWikiLinks('[[   ]]'), isEmpty);
      expect(parseWikiLinks('[[|只有别名]]'), isEmpty);
    });

    test('不跨行：跨行的方括号不是双链', () {
      expect(parseWikiLinks('[[甲\n乙]]'), isEmpty);
    });

    test('普通 markdown 链接不受影响', () {
      expect(parseWikiLinks('[文字](https://x.com)'), isEmpty);
    });

    test('去重后的目标列表供查询用', () {
      expect(wikiTargetsIn('[[甲]] [[乙]] [[甲|别名]]'), <String>['甲', '乙']);
    });
  });

  group('反向链接', () {
    late AppDatabase db;
    late NoteRepository repo;

    setUp(() {
      db = AppDatabase.inMemory();
      repo = NoteRepository(db);
    });

    tearDown(() => db.close());

    int add(String title, {String content = '正文'}) => repo.insertNote(
          title: title,
          content: content,
          excerpt: content,
          publishedAt: DateTime.now(),
          charCount: content.length,
        );

    test('谁写了 [[标题]] 谁就是被引用方', () {
      final target = add('克拉拉与太阳');
      final a = add('读书笔记', content: '刚看完 [[克拉拉与太阳]]，很好');
      add('无关的笔记', content: '什么都没链');

      final back = repo.backlinksOf(target);
      expect(back.map((n) => n.id), <int>[a]);
    });

    test('[[标题|别名]] 也算', () {
      final target = add('克拉拉与太阳');
      add('读书笔记', content: '刚看完 [[克拉拉与太阳|那本书]]');
      expect(repo.backlinksOf(target).length, 1);
    });

    test('标题是别人前缀时不算误命中（LIKE 粗筛之后要复核）', () {
      final target = add('读书');
      add('链到别的', content: '看 [[读书笔记]] 那篇');
      expect(repo.backlinksOf(target), isEmpty,
          reason: '`[[读书` 会被 LIKE 命中，但它链的是《读书笔记》');
    });

    test('不算自己', () {
      final id = add('自恋', content: '我这篇提到了 [[自恋]]');
      expect(repo.backlinksOf(id), isEmpty);
    });

    test('回收站里的不算（口径和列表一致）', () {
      final target = add('目标');
      final a = add('引用者', content: '[[目标]]');
      repo.deleteNote(a);
      expect(repo.backlinksOf(target), isEmpty);

      repo.restoreNotes(<int>[a]);
      expect(repo.backlinksOf(target).length, 1, reason: '恢复之后应该回来');
    });

    test('归档的不算', () {
      final target = add('目标');
      final a = add('引用者', content: '[[目标]]');
      repo.setArchived(a, true);
      expect(repo.backlinksOf(target), isEmpty);
    });

    test('隐私空间：隐藏的引用者在普通空间看不到，进隐私空间才看得到', () {
      final target = add('目标');
      final a = add('引用者', content: '[[目标]]');
      repo.setNoteHidden(a, true);

      expect(repo.backlinksOf(target), isEmpty);
      expect(repo.backlinksOf(target, hiddenOnly: true).length, 1);
    });

    test('按标题找笔记：找到了给 id，找不到给 null', () {
      final id = add('克拉拉与太阳');
      expect(repo.noteIdByTitle('克拉拉与太阳'), id);
      expect(repo.noteIdByTitle('不存在'), isNull);
      expect(repo.noteIdByTitle('   '), isNull);
    });

    test('同名笔记取最近改过的那篇', () {
      final first = add('同名');
      final second = repo.insertNote(
        title: '同名',
        content: '第二篇',
        excerpt: '',
        publishedAt: DateTime.now(),
        charCount: 3,
        updatedAt: DateTime.now().add(const Duration(minutes: 5)),
      );
      expect(repo.noteIdByTitle('同名'), second);
      expect(repo.noteIdByTitle('同名'), isNot(first));
    });
  });

  group('阅读页', () {
    late AppDatabase db;
    late NoteRepository repo;
    late AppState state;

    setUp(() async {
      db = AppDatabase.inMemory();
      repo = NoteRepository(db);
      state = AppState(db, repo, ImportService(db, repo));
      await state.init();
    });

    tearDown(() => db.close());

    int add(String title, {String content = '正文'}) => repo.insertNote(
          title: title,
          content: content,
          excerpt: content,
          publishedAt: DateTime.now(),
          charCount: content.length,
        );

    Future<void> pumpReader(WidgetTester tester, int noteId) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: NoteDetailPage(noteId: noteId),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('正文末尾列出「被引用」，点一下打开那篇', (tester) async {
      final target = add('克拉拉与太阳');
      add('读书笔记', content: '刚看完 [[克拉拉与太阳]]');

      await pumpReader(tester, target);
      expect(find.text('被引用 1'), findsOneWidget);
      expect(find.text('读书笔记'), findsOneWidget);

      await tester.tap(find.text('读书笔记'));
      await tester.pumpAndSettle();
      // 新路由上应该显示那篇的正文
      expect(find.textContaining('刚看完'), findsWidgets);
    });

    testWidgets('没有人引用时不显示这一栏（别占地方）', (tester) async {
      final id = add('孤零零');
      await pumpReader(tester, id);
      expect(find.textContaining('被引用'), findsNothing);
    });

    testWidgets('正文里的 [[…]] 渲染成链接文字，方括号不露出来', (tester) async {
      add('克拉拉与太阳');
      final id = add('读书笔记', content: '刚看完 [[克拉拉与太阳|那本书]]');

      await pumpReader(tester, id);
      // 显示的应该是别名，原文的方括号和竖线都不该出现在屏幕上
      expect(find.textContaining('[[克拉拉与太阳'), findsNothing);
      expect(find.textContaining('那本书'), findsWidgets);
    });
  });
}
