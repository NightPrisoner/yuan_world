import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/core/widgets/app_menu.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/notes/editor/markdown_controller.dart';
import 'package:yuan_world/features/notes/editor/markdown_editing.dart';
import 'package:yuan_world/features/notes/editor/markdown_styler.dart';
import 'package:yuan_world/features/notes/editor/note_editor_page.dart';

TextEditingValue edit(
  String text, [
  int? at,
  TextRange composing = TextRange.empty,
]) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: at ?? text.length),
  composing: composing,
);

void input(MarkdownEditingController c, TextEditingValue next) {
  c.value = c.inputFormatter.formatEditUpdate(c.value, next);
}

void main() {
  group('空光标行内格式', () {
    test('连续点击格式不写入空语法，重复点击取消', () {
      final c = MarkdownEditingController();
      c.selection = const TextSelection.collapsed(offset: 0);
      c.toggleInline('**');
      c.toggleInline('*');
      c.toggleInline('~~');
      expect(c.text, '');
      c.toggleInline('*');
      c.toggleInline('~~');
      c.toggleInline('**');
      input(c, edit('普通正文'));
      expect(c.text, '普通正文');
      c.dispose();
    });

    test('加粗模式连续输入保持同一对标记，关闭后输入普通正文', () {
      final c = MarkdownEditingController();
      c.selection = const TextSelection.collapsed(offset: 0);
      c.toggleInline('**');
      input(c, edit('a'));
      expect(c.text, '**a**');
      input(c, edit('**ab**', 4));
      expect(c.text, '**ab**');
      c.toggleInline('**');
      input(c, edit('**ab**普通'));
      expect(c.text, '**ab**普通');
      c.dispose();
    });

    test('空白先选择粗斜体，输入后是规范三颗星', () {
      final c = MarkdownEditingController();
      c.selection = const TextSelection.collapsed(offset: 0);
      c.toggleInline('**');
      c.toggleInline('*');
      input(c, edit('你好'));
      expect(c.text, '***你好***');
      c.dispose();
    });

    test('中文组合输入保持原样，提交后再添加格式', () {
      final c = MarkdownEditingController();
      c.selection = const TextSelection.collapsed(offset: 0);
      c.toggleInline('**');
      input(c, edit('ni', 2, const TextRange(start: 0, end: 2)));
      expect(c.text, 'ni');
      input(c, edit('你', 1, const TextRange(start: 0, end: 1)));
      expect(c.text, '你');
      input(c, edit('你'));
      expect(c.text, '**你**');
      c.dispose();
    });

    test('删除全部新输入内容后不残留四颗星', () {
      final c = MarkdownEditingController();
      c.selection = const TextSelection.collapsed(offset: 0);
      c.toggleInline('**');
      input(c, edit('a'));
      input(c, edit('****', 2));
      expect(c.text, '');
      c.dispose();
    });

    test('加粗输入后回车把闭合标记留在原行', () {
      final c = MarkdownEditingController();
      c.selection = const TextSelection.collapsed(offset: 0);
      c.toggleInline('**');
      input(c, edit('a'));
      input(c, edit('**a\n**', 4));
      expect(c.text, '**a**\n');
      c.dispose();
    });

    test('已经选中的粗斜体正确反映工具栏状态', () {
      final c = MarkdownEditingController(text: '***正文***');
      c.selection = const TextSelection(baseOffset: 3, extentOffset: 5);
      expect(c.typingMarkActive('**'), isTrue);
      expect(c.typingMarkActive('*'), isTrue);
      expect(c.typingMarkActive('~~'), isFalse);
      c.dispose();
    });
  });

  group('列表与段落', () {
    test('粗斜体叠加删除线仍解析样式并隐藏全部符号', () {
      final parts = MarkdownStyler.parse('~~***内容***~~');
      final content = parts.singleWhere((p) => p.text == '内容');
      expect(content.kind, MdKind.boldItalic);
      expect(content.formats, contains(MdKind.strike));
      expect(parts.where((p) => p.kind == MdKind.plain), isEmpty);
    });

    test('代码叠加粗斜体不显示反引号，标题里的斜体保留格式', () {
      final parts = MarkdownStyler.parse('***`内容`***');
      final content = parts.singleWhere((p) => p.text == '内容');
      expect(content.formats, containsAll([MdKind.code, MdKind.boldItalic]));
      expect(parts.where((p) => p.kind == MdKind.plain), isEmpty);
      final heading = MarkdownStyler.parse('# *标题*')
          .singleWhere((p) => p.text == '标题');
      expect(heading.kind, MdKind.h1);
      expect(heading.formats, contains(MdKind.italic));
    });

    test('普通井号文字不会误识别或删除为标题', () {
      final c = TextEditingController(text: '#话题');
      c.selection = const TextSelection.collapsed(offset: 3);
      MarkdownEditing.setHeading(c, 0);
      expect(c.text, '#话题');
      expect(MarkdownStyler.parse(c.text).single.kind, MdKind.plain);
      c.dispose();
    });
    test('多行加粗逐行生效并可再次取消，不包住列表编号', () {
      final c = TextEditingController(text: '1. 甲\n2. 乙');
      c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);
      MarkdownEditing.wrap(c, '**');
      expect(c.text, '1. **甲**\n2. **乙**');
      MarkdownEditing.wrap(c, '**');
      expect(c.text, '1. 甲\n2. 乙');
      c.dispose();
    });
    test('多选有序列表递增，再点一次统一取消', () {
      final c = TextEditingController(text: '甲\n乙\n丙');
      c.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
      MarkdownEditing.toggleLinePrefix(c, '1. ');
      expect(c.text, '1. 甲\n2. 乙\n3. 丙');
      MarkdownEditing.toggleLinePrefix(c, '1. ');
      expect(c.text, '甲\n乙\n丙');
      c.dispose();
    });

    test('转换列表类型不叠加两种行首标记，已完成待办可取消', () {
      final c = TextEditingController(text: '- 甲\n- [x] 乙');
      c.selection = TextSelection(baseOffset: 0, extentOffset: c.text.length);
      MarkdownEditing.toggleLinePrefix(c, '1. ');
      expect(c.text, '1. 甲\n2. 乙');
      MarkdownEditing.toggleLinePrefix(c, '- [ ] ');
      expect(c.text, '- [ ] 甲\n- [ ] 乙');
      c.text = '- [x] 已完成';
      c.selection = const TextSelection.collapsed(offset: 7);
      MarkdownEditing.toggleLinePrefix(c, '- [ ] ');
      expect(c.text, '已完成');
      c.dispose();
    });

    for (final pair in [
      ('- 甲', '- 甲\n- '),
      ('9. 甲', '9. 甲\n10. '),
      ('  - 甲', '  - 甲\n  - '),
      ('- [x] 做完', '- [x] 做完\n- [ ] '),
      ('> 引用', '> 引用\n> '),
    ]) {
      test('回车续写 ${pair.$1}', () {
        final result = MarkdownEditing.continueLine(
          edit(pair.$1),
          edit('${pair.$1}\n'),
        );
        expect(result.text, pair.$2);
        expect(result.selection.start, pair.$2.length);
      });
    }

    for (final empty in ['- ', '2. ', '- [ ] ', '> ']) {
      test('空项回车退出 $empty', () {
        expect(
          MarkdownEditing.continueLine(edit(empty), edit('$empty\n')).text,
          '',
        );
      });
    }

    test('粘贴多行正文不自动添加列表标记', () {
      final next = edit('- 原文\n粘贴甲\n粘贴乙');
      expect(MarkdownEditing.continueLine(edit('- 原文'), next), next);
    });

    test('选区结束于下一行开头不误改下一行，保留选区方向', () {
      final c = TextEditingController(text: '甲\n乙');
      c.selection = const TextSelection(baseOffset: 2, extentOffset: 0);
      MarkdownEditing.toggleLinePrefix(c, '- ');
      expect(c.text, '- 甲\n乙');
      expect(c.selection.baseOffset, greaterThan(c.selection.extentOffset));
      c.dispose();
    });
  });

  group('真实编辑框和工具栏', () {
    late AppDatabase db;
    late AppState state;
    late int id;
    setUp(() async {
      db = AppDatabase.inMemory();
      final repo = NoteRepository(db);
      state = AppState(db, repo, ImportService(db, repo));
      await state.init();
      id = repo.insertNote(title: '测试', content: '', excerpt: '');
    });
    tearDown(() {
      state.dispose();
      db.close();
    });

    Future<Finder> open(
      WidgetTester tester, {
      String text = '',
      bool fullscreen = false,
    }) async {
      state.repo.updateNote(id: id, content: text);
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: NoteEditorPage(
                noteId: id,
                embedded: true,
                fullscreen: fullscreen,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return find.byWidgetPredicate(
        (w) => w is TextField && w.controller is MarkdownEditingController,
      );
    }

    testWidgets('空光标加粗不产生星号，输入后样式落库', (tester) async {
      final body = await open(tester);
      await tester.tap(body);
      await tester.pump();
      await tester.tap(find.byTooltip('加粗'));
      await tester.pump();
      expect((tester.widget<TextField>(body).controller!).text, '');
      await tester.enterText(body, '加粗正文');
      await tester.pump(const Duration(milliseconds: 1300));
      expect(state.repo.getNote(id)!.content, '**加粗正文**');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('标题菜单列出正文和 H1 至 H6 并真正应用', (tester) async {
      final body = await open(tester, text: '标题正文');
      await tester.tap(body);
      await tester.pump();
      await tester.tap(find.byTooltip('设为标题'));
      await tester.pumpAndSettle();
      for (var i = 1; i <= 6; i++) {
        expect(find.text('$i 级标题 · H$i'), findsOneWidget);
      }
      expect(find.text('正文'), findsOneWidget);
      await tester.tap(find.text('4 级标题 · H4'));
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(body).controller!.text, '#### 标题正文');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final fullscreen in [false, true]) {
      testWidgets('编辑菜单紧贴按钮，不沿用其他菜单位置 fullscreen=$fullscreen', (tester) async {
        final body = await open(tester, text: '正文', fullscreen: fullscreen);
        final ctx = tester.element(body);
        final oldMenu = showAppMenu<int>(
          ctx,
          anchor: AppMenuAnchor.at(const Offset(1150, 180)),
          items: const [AppMenuItem(value: 1, label: '其他菜单', icon: Icons.menu)],
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('其他菜单'));
        await tester.pumpAndSettle();
        await oldMenu;
        for (final tooltip in ['设为标题', '插入链接']) {
          final button = tester.getRect(find.byTooltip(tooltip));
          await tester.tap(find.byTooltip(tooltip));
          await tester.pumpAndSettle();
          final entries = tooltip == '设为标题'
              ? find.byType(PopupMenuItem<int>)
              : find.byType(PopupMenuItem<String>);
          final menu = tester.getRect(entries.first);
          expect((menu.left - button.left).abs(), lessThan(40));
          expect(menu.top, greaterThanOrEqualTo(button.bottom - 8));
          await tester.tapAt(const Offset(4, 4));
          await tester.pumpAndSettle();
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('编辑框回车续写序号，空项回车退出', (tester) async {
      final body = await open(tester, text: '1. 第一项');
      await tester.tap(body);
      await tester.pump();
      await tester.enterText(body, '1. 第一项\n');
      await tester.pump();
      expect(tester.widget<TextField>(body).controller!.text, '1. 第一项\n2. ');
      tester.testTextInput.updateEditingValue(edit('1. 第一项\n2. \n'));
      await tester.pump();
      expect(tester.widget<TextField>(body).controller!.text, '1. 第一项\n');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('连续工具栏操作每一步都可撤销重做', (tester) async {
      final body = await open(tester, text: '正文');
      await tester.tap(body);
      await tester.pump();
      tester.widget<TextField>(body).controller!.selection =
          const TextSelection(baseOffset: 0, extentOffset: 2);
      await tester.pump();
      await tester.tap(find.byTooltip('加粗'));
      await tester.pump();
      await tester.tap(find.byTooltip('斜体'));
      await tester.pump();
      expect(tester.widget<TextField>(body).controller!.text, '***正文***');
      await tester.tap(find.byTooltip('撤销'));
      await tester.pump();
      expect(tester.widget<TextField>(body).controller!.text, '**正文**');
      await tester.tap(find.byTooltip('撤销'));
      await tester.pump();
      expect(tester.widget<TextField>(body).controller!.text, '正文');
      await tester.tap(find.byTooltip('重做'));
      await tester.pump();
      expect(tester.widget<TextField>(body).controller!.text, '**正文**');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
