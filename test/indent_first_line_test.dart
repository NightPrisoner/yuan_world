/// 首行缩进两字 —— **按段落局部生效**。
///
/// 语义按用户的原话定（m280060）：「首行缩进不要对单篇笔记全部生效，
/// 看光标所在的段落或者框选一大片文字那几个段落起作用」。
///
/// 所以它不再是一个"整篇开关"，而是**正文里的字符事实**：
/// 段落第一行行首有没有那两个全角空格。工具栏上的按钮只负责
/// 给光标所在段落（或框选覆盖的那几段）补上 / 摘掉这两个字符。
///
/// 两侧实现不同：
///   · 阅读页：看到行首有 `\u3000\u3000` 就插一个 `WidgetSpan(SizedBox)`
///     当缩进，软换行出来的行自然从 x=0 起（CSS `text-indent` 的效果）。
///   · 编辑器：`TextField` 不能塞 WidgetSpan（会让 `value.text` 与
///     TextPainter 的纯文本索引错开一个字符，光标/选区/输入法全歪），
///     所以那两个全角空格是真的写进正文的。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/core/utils/paragraph_indent.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/notes/editor/markdown_editing.dart';
import 'package:yuan_world/features/notes/editor/note_editor_page.dart';
import 'package:yuan_world/features/notes/widgets/content_view.dart';

/// 两个全角空格，就是"缩进两字"。
const String _pad = kIndentMark;

/// 加零宽连接符之前存下的老数据：行首只有两个全角空格。
const String _legacyPad = '\u3000\u3000';

void main() {
  late AppDatabase db;
  late AppState state;
  late NoteRepository repo;
  late int noteId;

  setUp(() async {
    db = AppDatabase.inMemory();
    repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
    noteId = repo.insertNote(
      title: '缩进测试',
      content: '第一段正文。\n\n第二段正文。',
      excerpt: '正文',
      publishedAt: DateTime.now(),
    );
  });

  tearDown(() {
    state.dispose();
    db.close();
  });

  /// 某一段落（含 needle 的那个）对应的 `RenderParagraph`。
  RenderParagraph paragraphOf(WidgetTester tester, String needle) {
    final para = find
        .ancestor(
          of: find.textContaining(needle),
          matching: find.byType(RichParagraph),
        )
        .first;
    return tester.renderObject<RenderParagraph>(
      find.descendant(of: para, matching: find.byType(RichText)).first,
    );
  }

  /// 段落**文字**第一个字符的左边缘。
  ///
  /// 缩进段落的纯文本 index 0 是 `WidgetSpan` 的占位符（`\uFFFC`），
  /// 量它量到的是占位盒子本身，所以跳过它从 index 1 开始量。
  double firstTextLeft(RenderParagraph p) {
    final plain = p.text.toPlainText();
    final start = plain.isNotEmpty && plain.codeUnitAt(0) == 0xFFFC ? 1 : 0;
    final boxes = p.getBoxesForSelection(
      TextSelection(baseOffset: start, extentOffset: start + 1),
    );
    return boxes.isEmpty ? -1 : boxes.first.left;
  }

  Future<void> pumpReader(WidgetTester tester, String markdown) async {
    tester.view.physicalSize = const Size(430, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ContentViewBox(markdown: markdown, imageRoot: '/nonexistent'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  // ── 阅读页：只认行首那两个字符 ────────────────────────────────────────

  testWidgets('行首带两个全角空格的段落才缩进，没带的不缩进', (tester) async {
    await pumpReader(tester, '$_pad缩进的段落。\n\n没缩进的段落。');

    final indented = paragraphOf(tester, '缩进的段落');
    final plain = paragraphOf(tester, '没缩进的段落');

    expect(
      firstTextLeft(indented),
      greaterThan(20),
      reason: '行首有两个全角空格，就该被两个汉字宽推开',
    );
    expect(
      firstTextLeft(plain),
      lessThan(1.0),
      reason: '没带的段落必须贴左',
    );
  });

  testWidgets('同一篇里逐段生效：一段缩进、一段不缩进，互不影响', (tester) async {
    await pumpReader(
      tester,
      '开头不缩进。\n\n$_pad中间这段缩进。\n\n结尾也不缩进。',
    );

    final first = firstTextLeft(paragraphOf(tester, '开头不缩进'));
    final middle = firstTextLeft(paragraphOf(tester, '中间这段缩进'));
    final last = firstTextLeft(paragraphOf(tester, '结尾也不缩进'));

    expect(first, lessThan(1.0));
    expect(middle, greaterThan(20));
    expect(last, lessThan(1.0));
  });

  testWidgets('首行缩进 ≠ 整段缩进：软换行出来的行仍然顶格', (tester) async {
    final long = List<String>.filled(40, '一二三四五六七八九十').join();
    await pumpReader(tester, '$_pad$long');

    final para = paragraphOf(tester, '一二三四五');
    final firstBoxes = para.getBoxesForSelection(
      const TextSelection(baseOffset: 1, extentOffset: 2),
    );
    expect(firstBoxes, isNotEmpty);
    final firstLineTop = firstBoxes.first.top;
    final firstLineLeft = firstBoxes.first.left;
    expect(firstLineLeft, greaterThan(20));

    final all = para.getBoxesForSelection(
      TextSelection(baseOffset: 1, extentOffset: para.text.toPlainText().length),
    );
    final byLine = <double, double>{};
    for (final b in all) {
      final prev = byLine[b.top];
      if (prev == null || b.left < prev) byLine[b.top] = b.left;
    }
    final laterLines = byLine.entries.where((e) => e.key > firstLineTop + 1);
    expect(laterLines, isNotEmpty, reason: '这段正文应该折成好几行');
    for (final e in laterLines) {
      expect(
        e.value,
        lessThan(firstLineLeft - 10),
        reason: '软换行出来的行必须顶格',
      );
    }
  });

  // ── 编辑器：按光标 / 选区所在段落 ─────────────────────────────────────

  Future<void> pumpEditor(
    WidgetTester tester,
    String content, {
    Size size = const Size(1200, 900),
  }) async {
    repo.updateNote(id: noteId, content: content);
    await state.refresh();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: NoteEditorPage(noteId: noteId),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  TextEditingController bodyController(WidgetTester tester) {
    final field = find
        .byWidgetPredicate(
          (w) => w is TextField && (w.controller?.text ?? '').contains('甲段'),
        )
        .first;
    final widget = tester.widget<TextField>(field);
    widget.focusNode!.requestFocus();
    return widget.controller!;
  }

  Future<void> tapIndent(WidgetTester tester) async {
    await tester.tap(find.byTooltip('首行缩进两字'));
    await tester.pumpAndSettle();
  }

  testWidgets('光标在一段里点缩进：只改这一段，别的段不动', (tester) async {
    await pumpEditor(tester, '甲段落。\n\n乙段落。\n\n丙段落。');
    final ctl = bodyController(tester);
    ctl.selection = TextSelection.collapsed(offset: 2);
    await tester.pump();

    await tapIndent(tester);

    final text = ctl.text;
    expect(text, contains('$_pad甲段落。'), reason: '光标所在段落要补上');
    expect(text, contains('\n\n乙段落。'), reason: '没选中的段落不许动');
    expect(text, contains('\n\n丙段落。'), reason: '没选中的段落不许动');
  });

  // 用户 m280422-1：「光标位置偏移，缩进后光标比之前往前了 2 个字」。
  //
  // 缩进插的是**正文内容**（两个全角空格），光标必须跟着往后挪两格；
  // 以前这里走的是 `_mapSelection`（它的职责是跳过新加的行首语法，
  // 比如点了列表后光标停在文字前而不是 `- ` 后面），于是光标留在了空格前面。
  testWidgets('缩进之后光标跟着往后挪两格，不会停在空格前面', (tester) async {
    await pumpEditor(tester, '甲段落。\n\n乙段落。');
    final ctl = bodyController(tester);
    ctl.selection = TextSelection.collapsed(offset: 2);
    await tester.pump();

    await tapIndent(tester);

    expect(ctl.text, startsWith(_pad));
    // 「甲」原来在 offset 0，现在挪到 `_pad.length`；光标原来指向 offset 2
    // （「段」前），加完缩进应该跟着挪 `_pad.length`，仍然停在同一个字前面。
    expect(ctl.selection.baseOffset, 2 + _pad.length);
    expect(ctl.selection.isCollapsed, isTrue);
  });

  testWidgets('摘掉缩进时光标跟着往前挪两格', (tester) async {
    await pumpEditor(tester, '$_pad甲段落。\n\n乙段落。');
    final ctl = bodyController(tester);
    ctl.selection = TextSelection.collapsed(offset: 4);
    await tester.pump();

    await tapIndent(tester);

    expect(ctl.text, startsWith('甲段落。'));
    expect(ctl.selection.baseOffset, 4 - _pad.length);
  });

  testWidgets('框选时两端都跟着挪，选区仍然盖住同一批字', (tester) async {
    await pumpEditor(tester, '甲段落。\n\n乙段落。\n\n丙段落。');
    final ctl = bodyController(tester);
    // 选中「甲段落。」整段（0..4）。
    ctl.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
    await tester.pump();

    await tapIndent(tester);

    expect(ctl.text, startsWith('$_pad甲段落。'));
    final sel = ctl.selection;
    expect(sel.start, _pad.length);
    expect(sel.end, _pad.length + 4);
    expect(ctl.text.substring(sel.start, sel.end), '甲段落。');
  });

  testWidgets('框选多段：只改被框住的那几段', (tester) async {
    const body = '甲段落。\n\n乙段落。\n\n丙段落。';
    await pumpEditor(tester, body);
    final ctl = bodyController(tester);
    // 从「甲」开头选到「乙」末尾 —— 覆盖前两段，第三段在选区外。
    ctl.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: '甲段落。\n\n乙段落。'.length,
    );
    await tester.pump();

    await tapIndent(tester);

    final text = ctl.text;
    expect(text, contains('$_pad甲段落。'));
    expect(text, contains('$_pad乙段落。'));
    expect(text, contains('\n\n丙段落。'), reason: '第三段不在选区里，不该被改');
  });

  testWidgets('再点一次就把这一段的缩进摘掉', (tester) async {
    await pumpEditor(tester, '$_pad甲段落。\n\n乙段落。');
    final ctl = bodyController(tester);
    ctl.selection = TextSelection.collapsed(offset: _pad.length + 2);
    await tester.pump();

    await tapIndent(tester);

    expect(ctl.text, startsWith('甲段落。'));
    expect(ctl.text, isNot(contains(_pad)));
  });

  testWidgets('按钮高亮跟着光标所在的段落走', (tester) async {
    await pumpEditor(tester, '$_pad甲段落。\n\n乙段落。');
    final ctl = bodyController(tester);

    // 光标落在有缩进的第一段：按钮用"增加缩进"那个图标（= 已缩进）。
    ctl.selection = TextSelection.collapsed(offset: _pad.length + 2);
    await tester.pump();
    await tester.pump();
    expect(
      find.descendant(
        of: find.byTooltip('首行缩进两字'),
        matching: find.byIcon(Icons.format_indent_increase_rounded),
      ),
      findsOneWidget,
    );

    // 光标挪到没有缩进的第二段：图标换成"减少缩进"。
    ctl.selection = TextSelection.collapsed(offset: ctl.text.length - 2);
    await tester.pump();
    await tester.pump();
    expect(
      find.descendant(
        of: find.byTooltip('首行缩进两字'),
        matching: find.byIcon(Icons.format_indent_decrease_rounded),
      ),
      findsOneWidget,
    );
  });

  // ── 回车续写：跟着光标所在段落 ────────────────────────────────────────

  TextEditingValue enterAfter(String before) {
    return MarkdownEditing.continueLine(
      TextEditingValue(
        text: before,
        selection: TextSelection.collapsed(offset: before.length),
      ),
      TextEditingValue(
        text: '$before\n',
        selection: TextSelection.collapsed(offset: before.length + 1),
      ),
      indent: before.startsWith(_pad) ? _pad : '',
    );
  }

  test('回车：光标在带缩进的段落里，新行也补两个全角空格', () {
    expect(enterAfter('$_pad第一段').text, '$_pad第一段\n$_pad');
  });

  test('回车：光标在没缩进的段落里，一个空格都不补', () {
    expect(enterAfter('第一段').text, '第一段\n');
  });

  test('回车：标题 / 分隔线 / 围栏 / 整行图片不补缩进', () {
    for (final line in <String>['# 标题', '---', '```', '![](images/1/a.png)']) {
      expect(
        enterAfter(line).text,
        '$line\n',
        reason: '$line 不该被缩进',
      );
    }
  });

  test('回车：列表与引用的续写语义优先，缩进不叠加', () {
    expect(enterAfter('- 列表').text, '- 列表\n- ');
    expect(enterAfter('> 引用').text, '> 引用\n> ');
  });

  // ── 语法层：哪些行算"能缩进的段落" ───────────────────────────────────

  test('toggleIndentFirstLine 跳过标题、分隔线、围栏与整行图片', () {
    final ctl = TextEditingController(
      text: '段落一。\n# 标题\n---\n```\ncode();\n```\n![](images/1/a.png)',
    );
    ctl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: ctl.text.length,
    );

    MarkdownEditing.toggleIndentFirstLine(ctl);

    expect(ctl.text, contains('$_pad段落一。'));
    expect(ctl.text, contains('\n# 标题'));
    expect(ctl.text, contains('\n---'));
    expect(ctl.text, contains('\n```\ncode();\n```'), reason: '围栏里的代码不许动');
    expect(ctl.text, contains('\n![](images/1/a.png)'));
  });

  test('围栏中间的行也不算段落，不会被补缩进', () {
    final ctl = TextEditingController(text: '```\ncode();\n```\n段落。');
    ctl.selection = TextSelection(
      baseOffset: 0,
      extentOffset: ctl.text.length,
    );

    MarkdownEditing.toggleIndentFirstLine(ctl);

    expect(ctl.text, '```\ncode();\n```\n$_pad段落。');
  });

  test('lineHasIndent 看光标所在段落；光标停在空行上时往前找', () {
    final ctl = TextEditingController(text: '$_pad甲\n乙');
    ctl.selection = const TextSelection.collapsed(offset: 2);
    expect(MarkdownEditing.lineHasIndent(ctl), isTrue);

    ctl.selection = TextSelection.collapsed(offset: ctl.text.length - 1);
    expect(MarkdownEditing.lineHasIndent(ctl), isFalse);

    // 光标停在空行上：它夹在两段之间，该不该缩进要参照上面最近的非空行
    // （用户在段落后连按两次回车时，第二行就是这种情况）。
    final blank = TextEditingController(text: '$_pad甲\n\n乙');
    blank.selection = const TextSelection.collapsed(offset: 4);
    expect(MarkdownEditing.lineHasIndent(blank), isTrue);

    final blank2 = TextEditingController(text: '甲\n\n乙');
    blank2.selection = const TextSelection.collapsed(offset: 2);
    expect(MarkdownEditing.lineHasIndent(blank2), isFalse);
  });

  // ── 排满断行：缩进不能孤零零留在第一行 ────────────────────────────────
  //
  // 用户 m280512：「缩进后你就一直打字到屏幕边缘，然后这一行字突然变到第二行
  // （顶格），第一行一个字都没，然后再打几个字快到屏幕边缘时又变正常了」。
  //
  // 根因：`\u3000` 是可断行空白（Unicode 行断行类 BA），两个全角空格与后面的
  // 文字之间允许断行，行排满时断点正好落在空格后 —— 于是第一行只剩缩进、
  // 正文全跑到第二行顶格。修法是在 pad 末尾粘一个零宽的 U+2060（WORD JOINER），
  // 把「缩进」和「紧跟的第一个字」粘成一个不许断的整体。

  /// 用 TextPainter 直接排一段文字，返回每一视觉行的宽度。
  ///
  /// 不经过 TextField：这条要的是「断行点落在哪儿」，用渲染器本体量最直接，
  /// 也避免被输入框的 hint / composing 干扰。
  List<double> lineWidths(String text, {double width = 376}) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: const TextStyle(fontSize: 17)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: width);
    final boxes = painter.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: text.length),
    );
    final byTop = <double, double>{};
    for (final b in boxes) {
      final prev = byTop[b.top];
      if (prev == null || b.right - b.left > prev) {
        byTop[b.top] = b.right - b.left;
      }
    }
    painter.dispose();
    final rows = byTop.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return <double>[for (final e in rows) e.value];
  }

  test('缩进的行一直打到排满，第一行始终有字，不会只剩缩进', () {
    // 用户 m280512：「缩进后你就一直打字到屏幕边缘，然后这一行字突然变到
    // 第二行（顶格），第一行一个字都没」。
    //
    // 根因：`\u3000` 是可断行空白（UAX #14 里属 BA 类），两个全角空格与后面
    // 的拉丁字符之间允许断行 —— 行排满时断点正好落在空格后，第一行只剩缩进。
    // 修法是 pad 末尾粘一个零宽的 U+2060（WORD JOINER），把缩进和紧跟的第一个字
    // 粘成不许断的整体。
    for (var n = 10; n <= 60; n++) {
      final rows = lineWidths('$kIndentMark${'1' * n}');
      expect(rows, isNotEmpty);
      expect(
        rows.first,
        greaterThan(40),
        reason: '打 $n 个字时第一行只剩 ${rows.first.toStringAsFixed(1)} 宽（只有缩进）',
      );
    }
  });

  test('对照：不带零宽连接符时确实会断在缩进后面（这条钉住根因）', () {
    // 老数据是纯 `\u3000\u3000`，渲染器照样允许在它后面断行 —— 所以这条
    // 必须能测出「第一行只剩缩进」，否则上面那条测试是假的。
    var sawBarePad = false;
    for (var n = 10; n <= 60; n++) {
      final rows = lineWidths('$kIndentPad${'1' * n}');
      if (rows.isNotEmpty && rows.first < 40) sawBarePad = true;
    }
    expect(sawBarePad, isTrue, reason: '没测出断行就说明这条对照失效了');
  });

  test('老数据（行首只有两个全角空格、没有零宽连接符）也要认得出来', () {
    expect(hasIndentMark('$_legacyPad甲段落。'), isTrue);
    expect(stripIndentMark('$_legacyPad甲段落。'), '甲段落。');
    expect(hasIndentMark('$_pad甲段落。'), isTrue);
    expect(stripIndentMark('$_pad甲段落。'), '甲段落。');
    expect(hasIndentMark('甲段落。'), isFalse);
  });

  testWidgets('老数据的缩进能被一键摘掉', (tester) async {
    await pumpEditor(tester, '$_legacyPad甲段落。\n\n乙段落。');
    final ctl = bodyController(tester);
    ctl.selection = TextSelection.collapsed(offset: _legacyPad.length + 2);
    await tester.pump();

    await tapIndent(tester);

    expect(ctl.text, startsWith('甲段落。'));
    expect(ctl.text, contains('\n\n乙段落。'));
  });

  // ── 工具栏 ────────────────────────────────────────────────────────────

  testWidgets('工具栏分成两行，窄窗口下两行都在树里', (tester) async {
    repo.updateNote(id: noteId, content: '甲段落。');
    await state.refresh();
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: NoteEditorPage(noteId: noteId),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('加粗'), findsOneWidget);
    expect(find.byTooltip('插入视频'), findsOneWidget);
    final rows = tester.widgetList<ListView>(
      find.byWidgetPredicate(
        (w) => w is ListView && w.scrollDirection == Axis.horizontal,
      ),
    );
    expect(rows.length, greaterThanOrEqualTo(2));
  });
}
