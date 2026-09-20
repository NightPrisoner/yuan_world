// 内部链接（双链）的改名不断链 + 选择器测试。
//
// 用户的要求原话：
//   · 内部链接要能"出来个搜索界面，同时也可以翻找"，别用手打标题；
//   · "链接的笔记如果各种改动要保证链接不断，标题改名显示的链接也要同步改，
//     除非笔记删除链接才会失效"。
// ignore_for_file: avoid_print

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/core/utils/wiki_links.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/notes/editor/markdown_editing.dart';
import 'package:yuan_world/features/notes/widgets/note_link_picker.dart';

void main() {
  group('rewriteWikiLinks（改名改写正文里的双链）', () {
    test('普通双链跟着改', () {
      expect(rewriteWikiLinks('看 [[旧标题]] 一下', from: '旧标题', to: '新标题'),
          '看 [[新标题]] 一下');
    });

    test('带别名的保留别名', () {
      expect(
        rewriteWikiLinks('[[旧标题|小名]]', from: '旧标题', to: '新标题'),
        '[[新标题|小名]]',
      );
    });

    test('前缀相同的别误伤（[[旧标题2]] 不动）', () {
      const body = '[[旧标题]] 和 [[旧标题2]] 都要在';
      expect(
        rewriteWikiLinks(body, from: '旧标题', to: '新标题'),
        '[[新标题]] 和 [[旧标题2]] 都要在',
      );
    });

    test('多处出现全改', () {
      expect(
        rewriteWikiLinks('[[旧]] [[旧|x]] [[别的]]', from: '旧', to: '新'),
        '[[新]] [[新|x]] [[别的]]',
      );
    });

    test('没有引用时原样返回', () {
      const body = '一段和双链无关的文字 [[别的]]';
      expect(rewriteWikiLinks(body, from: '旧', to: '新'), body);
    });
  });

  group('仓库层：改标题会自动改写引用它的正文', () {
    late AppDatabase db;
    late NoteRepository repo;

    setUp(() {
      db = AppDatabase.inMemory();
      repo = NoteRepository(db);
    });
    tearDown(() => db.close());

    test('目标改名后：引用正文、显示文字、反链都还是通的', () {
      final target = repo.insertNote(
        title: '旧标题',
        content: '我是被链接的那篇',
        excerpt: '我是被链接的那篇',
        publishedAt: DateTime.now(),
      );
      final referrer = repo.insertNote(
        title: '引用者',
        content: '先看 [[旧标题]]，再看 [[旧标题|小名]]。',
        excerpt: '先看 [[旧标题]]',
        publishedAt: DateTime.now(),
      );

      repo.updateNote(id: target, title: '新标题');

      final body = repo.getNote(referrer)!.content;
      expect(body, contains('[[新标题]]'), reason: '普通双链要跟着改');
      expect(body, contains('[[新标题|小名]]'), reason: '别名保留，但目标要换');
      expect(body, isNot(contains('[[旧标题')), reason: '旧的引用不该留下');
      expect(
        repo.getNote(referrer)!.excerpt,
        contains('[[新标题]]'),
        reason: '摘要里也有链接文字，得一起改',
      );

      // 反链查询按标题现算，所以正文改了它就跟着通了 —— 这就是"链不断"
      final back = repo.backlinksOf(target);
      expect(back.map((n) => n.id), contains(referrer));
      expect(repo.noteIdByTitle('新标题'), target);
      expect(repo.noteIdByTitle('旧标题'), isNull);
    });

    test('标题没变就不动别人（也不多头一次改写）', () {
      final target = repo.insertNote(
        title: '甲',
        content: 'x',
        excerpt: 'x',
        publishedAt: DateTime.now(),
      );
      final other = repo.insertNote(
        title: '乙',
        content: '[[甲]]',
        excerpt: '[[甲]]',
        publishedAt: DateTime.now(),
      );
      repo.updateNote(id: target, title: '甲', content: '改了正文而已');
      expect(repo.getNote(other)!.content, '[[甲]]');
    });
  });

  group('插入到正文（编辑器那一侧）', () {
    test('光标处插入 [[标题]]', () {
      final c = TextEditingController(text: '前面 后面');
      c.selection = const TextSelection.collapsed(offset: 3);
      MarkdownEditing.insertNoteLink(c, '目标笔记');
      expect(c.text, '前面 [[目标笔记]]后面');
      expect(c.selection.baseOffset, 3 + '[[目标笔记]]'.length);
    });

    test('有选中文字时当别名', () {
      final c = TextEditingController(text: '那本《克拉拉》很好看');
      // 2..7 才是「《克拉拉》」——别名的边界按**字**数着算（中文一个字一个
      // offset，书名号也各算一个）
      c.selection = const TextSelection(baseOffset: 2, extentOffset: 7);
      MarkdownEditing.insertNoteLink(c, '克拉拉与太阳');
      expect(c.text, '那本[[克拉拉与太阳|《克拉拉》]]很好看');
    });

    test('标题为空时什么都不做（别插个 [[]] 进去）', () {
      final c = TextEditingController(text: 'abc');
      MarkdownEditing.insertNoteLink(c, '   ');
      expect(c.text, 'abc');
    });
  });

  group('选笔记的界面', () {
    late AppDatabase db;
    late AppState state;

    setUp(() async {
      db = AppDatabase.inMemory();
      final repo = NoteRepository(db);
      state = AppState(db, repo, ImportService(db, repo));
      await state.init();
    });
    tearDown(() => db.close());

    Future<void> pumpPicker(WidgetTester tester) async {
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const NoteLinkPickerPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('列出笔记，搜到之后点一下就把标题带回来', (tester) async {
      state.repo.insertNote(
        title: '阿尔卑斯山',
        content: 'x',
        excerpt: 'x',
        publishedAt: DateTime.now(),
      );
      state.repo.insertNote(
        title: '海边的卡夫卡',
        content: 'x',
        excerpt: 'x',
        publishedAt: DateTime.now(),
      );
      await state.refresh();

      await pumpPicker(tester);
      expect(find.text('阿尔卑斯山'), findsOneWidget);
      expect(find.text('海边的卡夫卡'), findsOneWidget);

      // 搜索：打两个字就只剩一篇（这是"别用手打标题"的关键）
      await tester.enterText(find.byType(TextField), '海边');
      await tester.pumpAndSettle();
      expect(find.text('海边的卡夫卡'), findsOneWidget);
      expect(find.text('阿尔卑斯山'), findsNothing);

      await tester.tap(find.text('海边的卡夫卡'));
      await tester.pumpAndSettle();
      // 页面关掉了（pop 带回选中的笔记）
      expect(find.byType(NoteLinkPickerPage), findsNothing);
    });

    testWidgets('搜不到时明确说"没有匹配的笔记"', (tester) async {
      state.repo.insertNote(
        title: '阿尔卑斯山',
        content: 'x',
        excerpt: 'x',
        publishedAt: DateTime.now(),
      );
      await state.refresh();
      await pumpPicker(tester);

      await tester.enterText(find.byType(TextField), '不存在的东西');
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的笔记'), findsOneWidget);
    });
  });
}
