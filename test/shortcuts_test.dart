/// 快捷键。
///
/// 这一组盯的是三件事：
///   1. **定义本身是自洽的** —— id 不重、按键不撞（两条快捷键绑同一个键，
///      后绑的会静默盖掉前一个，用户按了只出来一个，很难查）；
///   2. 显示用的键名对（帮助面板里写 `Ctrl+N`，实际就得真能按 Ctrl+N）；
///   3. 真的按下去**有反应**：Ctrl+F 进搜索框、Ctrl+3 到待办、
///      Ctrl+/ 弹一览、Ctrl+N 建笔记、编辑器里 Ctrl+S 立刻落库。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/shortcuts/app_shortcuts.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/notes/editor/note_editor_page.dart';
import 'package:yuan_world/features/shell/home_shell.dart';

void main() {
  group('定义自洽', () {
    test('id 不重复', () {
      final ids = kAppShortcuts.map((s) => s.id).toList();
      expect(ids.toSet().length, ids.length, reason: '有重复的快捷键 id：$ids');
    });

    test('同一个按键不会绑两个动作', () {
      final seen = <String, String>{};
      for (final s in kAppShortcuts) {
        for (final a in s.activators) {
          final key = describeShortcut(a);
          final prev = seen[key];
          expect(prev, isNull,
              reason: '$key 同时被「$prev」和「${s.label}」占用 —— '
                  '后绑的那个会静默盖掉前一个');
          seen[key] = s.label;
        }
      }
    });

    test('每条都有名字、分组、至少一个按键', () {
      for (final s in kAppShortcuts) {
        expect(s.label, isNotEmpty);
        expect(s.group, isNotEmpty);
        expect(s.activators, isNotEmpty);
      }
    });

    test('都带一个 macOS 的 ⌘ 变体（除了 Esc）', () {
      for (final s in kAppShortcuts) {
        if (s.id == AppShortcutIds.exitFullscreen) continue;
        expect(
          s.activators.any((a) => a is SingleActivator && a.meta),
          isTrue,
          reason: '「${s.label}」没有 ⌘ 变体，Mac 上按不出来',
        );
      }
    });

    test('bindShortcuts 把两个变体都绑上', () {
      final map = bindShortcuts(<String, VoidCallback>{
        AppShortcutIds.newNote: () {},
      });
      expect(map.length, 2);
      expect(map.keys.map(describeShortcut).toSet(), {'Ctrl+N', '⌘+N'});
    });
  });

  group('键名怎么写给人看', () {
    String show(String id) =>
        describeShortcut(shortcutById(id)!.activators.first);

    test('Ctrl+N / Ctrl+F / Ctrl+1', () {
      expect(show(AppShortcutIds.newNote), 'Ctrl+N');
      expect(show(AppShortcutIds.search), 'Ctrl+F');
      expect(show(AppShortcutIds.todos), 'Ctrl+3');
    });

    test('斜杠就写 /，不写 Slash', () {
      expect(show(AppShortcutIds.help), 'Ctrl+/');
    });

    test('Esc 不带 Ctrl', () {
      expect(show(AppShortcutIds.exitFullscreen), 'Esc');
    });

    test('Shift 组合按 Ctrl+Shift+X 的顺序写', () {
      expect(
        describeShortcut(
          const SingleActivator(LogicalKeyboardKey.keyF, control: true, shift: true),
        ),
        'Ctrl+Shift+F',
      );
    });
  });

  group('按下去真的有反应', () {
    late AppDatabase db;
    late AppState state;

    setUp(() async {
      db = AppDatabase.inMemory();
      final repo = NoteRepository(db);
      state = AppState(db, repo, ImportService(db, repo));
      await state.init();
      for (var i = 0; i < 3; i++) {
        repo.insertNote(
          title: '笔记 $i',
          content: '正文 $i',
          excerpt: '正文',
          publishedAt: DateTime.now().subtract(Duration(days: i)),
          charCount: 3,
        );
      }
      await state.refresh();
    });

    tearDown(() => db.close());

    Future<void> pumpWide(WidgetTester tester) async {
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

    /// 按住 Ctrl 敲一个键（真实按键路径，不直接调方法）。
    Future<void> pressCtrl(WidgetTester tester, LogicalKeyboardKey key) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(key);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
    }

    /// 搜索框有没有焦点。**看 EditableText 的节点**，不看 TextField.focusNode
    /// —— TextField 自己会兜一个内部节点，读 widget 上的那个永远是 null。
    bool searchFocused(WidgetTester tester) {
      final et = tester.widget<EditableText>(find.byType(EditableText));
      return et.focusNode.hasFocus;
    }

    testWidgets('Ctrl+F 把光标送进搜索框', (tester) async {
      await pumpWide(tester);
      await pressCtrl(tester, LogicalKeyboardKey.keyF);
      expect(searchFocused(tester), isTrue,
          reason: 'Ctrl+F 之后光标必须落在搜索框里，否则等于没按');
    });

    testWidgets('在搜索框里打字时 Ctrl+F 仍然好使（不会被输入框吃掉）', (tester) async {
      await pumpWide(tester);
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '笔记');
      await tester.pumpAndSettle();

      // 焦点先移走，再按 Ctrl+F：应当回到搜索框
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await pressCtrl(tester, LogicalKeyboardKey.keyF);
      expect(searchFocused(tester), isTrue);
    });

    testWidgets('Ctrl+3 切到待办', (tester) async {
      await pumpWide(tester);
      // 笔记区中栏的标志：那行「共 N 篇 · …」统计
      expect(find.textContaining(' 篇 · '), findsOneWidget);

      await pressCtrl(tester, LogicalKeyboardKey.digit3);
      // 待办区：中栏换成待办列表，那行统计没了
      expect(find.textContaining(' 篇 · '), findsNothing);
      expect(find.textContaining('待办'), findsWidgets);
    });

    testWidgets('Ctrl+1 从待办回到全部笔记', (tester) async {
      await pumpWide(tester);
      await pressCtrl(tester, LogicalKeyboardKey.digit3);
      expect(find.textContaining(' 篇 · '), findsNothing);
      await pressCtrl(tester, LogicalKeyboardKey.digit1);
      expect(find.textContaining(' 篇 · '), findsOneWidget);
    });

    testWidgets('Ctrl+/ 弹出快捷键一览，内容来自定义表', (tester) async {
      await pumpWide(tester);
      await pressCtrl(tester, LogicalKeyboardKey.slash);

      expect(find.text('快捷键'), findsOneWidget);
      // 抽查两条：动作名和键名都要在
      expect(find.text('新建笔记'), findsOneWidget);
      expect(find.text('Ctrl+N'), findsWidgets);
      expect(find.text('切换分区'), findsOneWidget);
    });

    testWidgets('Ctrl+N 新建一篇笔记', (tester) async {
      await pumpWide(tester);
      final before = state.notes.length;
      await pressCtrl(tester, LogicalKeyboardKey.keyN);
      await tester.pumpAndSettle();
      expect(state.notes.length, before + 1);
    });
  });

  group('编辑器里的 Ctrl+S', () {
    late AppDatabase db;
    late AppState state;
    late int noteId;

    setUp(() async {
      db = AppDatabase.inMemory();
      final repo = NoteRepository(db);
      state = AppState(db, repo, ImportService(db, repo));
      await state.init();
      noteId = repo.insertNote(
        title: '原标题',
        content: '原内容',
        excerpt: '原内容',
        publishedAt: DateTime.now(),
        charCount: 3,
      );
      await state.refresh();
    });

    tearDown(() => db.close());

    Future<void> pumpEditor(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: NoteEditorPage(noteId: noteId, embedded: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('改了内容按 Ctrl+S：立刻落库，不等 1.2 秒的自动保存', (tester) async {
      await pumpEditor(tester);

      await tester.enterText(find.byType(TextField).first, '改过的标题');
      await tester.pump(); // 只过一帧，远不到自动保存的 1200ms

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(state.repo.getNote(noteId)!.title, '改过的标题',
          reason: 'Ctrl+S 必须马上写库');
      expect(find.text('已保存'), findsOneWidget);
    });

    testWidgets('没改动就按 Ctrl+S：说"没有改动"，不假装保存', (tester) async {
      await pumpEditor(tester);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('没有改动'), findsOneWidget);
    });
  });
}
