/// 目录跳转：**跳得准不准**。
///
/// 阅读页和编辑器两边都报过"跳转有点问题"。两者的渲染方式不同，
/// 得分开钉：
///   · 阅读页是按 **block** 渲染的（每个段落一个 widget），下标能直接对上；
///   · 编辑器是按 **分段** 渲染的（图片之间的一大段文字是**一个**输入框），
///     一个标题可能落在"整篇正文"这一个大分段里 —— 只把分段滚进视野，
///     等于永远滚到那一段的开头。
///
/// 所以这条测试特意用**长正文**（几十段、没有图片），
/// 短笔记是测不出这个问题的。
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/notes/editor/note_editor_page.dart';
import 'package:yuan_world/features/notes/note_detail_page.dart';

/// 三个标题 + 每个标题下面十几段：总高度远远超过一屏。
///
/// 特意用**长正文**：短笔记是测不出"跳转不准"的（内容一屏放得下，
/// 滚不滚看起来都对）。
String _paras(String word, int n) =>
    List<String>.generate(n, (i) => '$word$i' * 6).join('\n\n');

final String kLongBody = '# 第一章\n\n${_paras('甲', 12)}\n\n'
    '## 第二章\n\n${_paras('乙', 12)}\n\n'
    '## 第三章\n\n${_paras('丙', 12)}\n\n'
    '## 第四章\n\n${_paras('丁', 12)}';

void main() {
  late AppDatabase db;
  late AppState state;
  late int noteId;

  setUp(() async {
    db = AppDatabase.inMemory();
    final repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
    noteId = repo.insertNote(
      title: '长文',
      content: kLongBody,
      excerpt: '长文',
      publishedAt: DateTime.now(),
    );
  });

  tearDown(() => db.close());

  Future<void> pumpEditor(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 700);
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

  Future<void> pumpReader(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            // 关掉头图之类的干扰，只测正文滚动
            body: NoteDetailPage(noteId: noteId, embedded: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('阅读页', () {
    testWidgets('点最后一个标题，它要出现在视口里', (tester) async {
      await pumpReader(tester);

      await tester.tap(find.byTooltip('目录'));
      await tester.pumpAndSettle();
      expect(find.text('第四章'), findsWidgets);

      await tester.tap(find.text('第四章').last);
      await tester.pumpAndSettle();

      // 标题必须在屏幕里（旧实现点了没反应时它会停在视口外）
      final y = tester.getTopLeft(find.text('第四章').last).dy;
      expect(y, greaterThanOrEqualTo(0));
      expect(y, lessThan(700), reason: '跳过去之后标题要落在视口里');
      // 而且应该落在**上半屏**：只滚到"刚露头"就说明差了一截
      expect(y, lessThan(350), reason: '标题应该落到视口上方附近，而不是刚露个边');
    });

    testWidgets('块高差别很大时（长文夹着极长段落）也要跳得过去', (tester) async {
      // 前半篇塞一个"高得离谱"的块：按比例估算位置会差出好几屏，
      // 目标块根本不会被构建出来 —— 这正是图片多的笔记会遇到的情况
      final id = state.repo.insertNote(
        title: '高低不平',
        content: '# 开头\n\n${List<String>.generate(200, (i) => '一二三四五$i').join('\n\n')}'
            '\n\n## 藏在很后面的标题\n\n结尾一段。',
        excerpt: '高低不平',
        publishedAt: DateTime.now(),
      );
      noteId = id;
      await pumpReader(tester);

      await tester.tap(find.byTooltip('目录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('藏在很后面的标题').last);
      await tester.pumpAndSettle();

      final y = tester.getTopLeft(find.text('藏在很后面的标题').last).dy;
      expect(y, greaterThanOrEqualTo(0));
      expect(y, lessThan(700), reason: '比例估算不准时也必须扫到目标（不能静默失败）');
    });
  });

  group('编辑器', () {
    testWidgets('点最后一个标题后，那一行要真的出现在视口里', (tester) async {
      await pumpEditor(tester);

      await tester.tap(find.byTooltip('目录'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('第三章').last);
      await tester.pumpAndSettle();

      // 直接量"标题那一行在屏幕上的位置"：
      // 编辑器的正文是一个 TextField，标题不是独立 widget，
      // 只能靠 RenderEditable 的排版结果去问。
      final editable = _findRenderEditable(tester);
      final offset = editable.plainText.indexOf('第三章');
      expect(offset, greaterThanOrEqualTo(0), reason: '正文里应该有这个小标题');

      final top = editable
          .localToGlobal(
            editable.getLocalRectForCaret(TextPosition(offset: offset)).topLeft,
          )
          .dy;
      expect(top, greaterThanOrEqualTo(0), reason: '跳过去之后不该还在屏幕外面');
      expect(top, lessThan(600), reason: '标题要落在视口里（旧实现会停在开头，'
          '标题还在一千多像素之外）');
    });
  });
}

/// 在编辑器子树里找正文那个 RenderEditable。
RenderEditable _findRenderEditable(WidgetTester tester) {
  RenderEditable? found;
  void visit(Element e) {
    if (found != null) return;
    final ro = e.renderObject;
    if (ro is RenderEditable && ro.plainText.contains('第三章')) {
      found = ro;
      return;
    }
    e.visitChildren(visit);
  }

  visit(tester.element(find.byType(NoteEditorPage)));
  return found!;
}
