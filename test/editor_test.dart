/// Markdown 编辑操作的测试。
///
/// 这类"光标位置 + 文本变换"的逻辑最容易出细节 bug（选区跑飞、标记叠加、
/// 取消时多删一个字符），而且光看界面很难发现。这里逐条锁住行为。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/features/notes/editor/markdown_controller.dart';
import 'package:yuan_world/features/notes/editor/markdown_editing.dart';
import 'package:yuan_world/features/notes/editor/markdown_styler.dart';

/// 造一个带选区的控制器。
TextEditingController _c(String text, [int? start, int? end]) {
  final controller = TextEditingController(text: text);
  if (start != null) {
    controller.selection = TextSelection(
      baseOffset: start,
      extentOffset: end ?? start,
    );
  }
  return controller;
}

void main() {
  group('行内标记 wrap', () {
    test('选中文字后加粗', () {
      final c = _c('你好世界', 0, 2);
      MarkdownEditing.wrap(c, '**');
      expect(c.text, '**你好**世界');
      // 加粗后仍然选中原文，方便继续叠加其它格式
      expect(c.selection.textInside(c.text), '你好');
      c.dispose();
    });

    test('再次执行同样的操作等于取消加粗', () {
      final c = _c('**你好**世界', 0, 6);
      MarkdownEditing.wrap(c, '**');
      expect(c.text, '你好世界');
      c.dispose();
    });

    test('没选中内容时插入一对标记并把光标放中间', () {
      final c = _c('前缀', 2);
      MarkdownEditing.wrap(c, '**');
      expect(c.text, '前缀****');
      expect(c.selection.baseOffset, 4); // 两个星号之后
      c.dispose();
    });

    test('选区无效时追加到末尾', () {
      final c = TextEditingController(text: '内容');
      // 不设置 selection，模拟刚创建还没聚焦
      MarkdownEditing.wrap(c, '`');
      expect(c.text, '内容``');
      c.dispose();
    });

    test('斜体与删除线使用各自的标记', () {
      final c1 = _c('abc', 0, 3);
      MarkdownEditing.wrap(c1, '*');
      expect(c1.text, '*abc*');
      c1.dispose();

      final c2 = _c('abc', 0, 3);
      MarkdownEditing.wrap(c2, '~~');
      expect(c2.text, '~~abc~~');
      c2.dispose();
    });
  });

  group('行首标记 toggleLinePrefix', () {
    test('给单行加无序列表标记', () {
      final c = _c('买牛奶', 1);
      MarkdownEditing.toggleLinePrefix(c, '- ');
      expect(c.text, '- 买牛奶');
      c.dispose();
    });

    test('再执行一次取消标记', () {
      final c = _c('- 买牛奶', 3);
      MarkdownEditing.toggleLinePrefix(c, '- ');
      expect(c.text, '买牛奶');
      c.dispose();
    });

    test('多行选区会整块加上标记', () {
      // '第一行\n第二行\n第三行' 共 11 个字符
      final c = _c('第一行\n第二行\n第三行', 0, 11);
      MarkdownEditing.toggleLinePrefix(c, '> ');
      expect(c.text, '> 第一行\n> 第二行\n> 第三行');
      c.dispose();
    });

    test('多行里已有标记的行不会被重复加', () {
      // '- 已加过\n没加过' 共 9 个字符
      final c = _c('- 已加过\n没加过', 0, 9);
      MarkdownEditing.toggleLinePrefix(c, '- ');
      expect(c.text, '- 已加过\n- 没加过');
      c.dispose();
    });

    test('待办标记', () {
      final c = _c('写周报', 1);
      MarkdownEditing.toggleLinePrefix(c, '- [ ] ');
      expect(c.text, '- [ ] 写周报');
      c.dispose();
    });

    test('选区在行中间时也能正确识别整行', () {
      // 光标落在「第二行」中间，应该只影响这一行
      final c = _c('第一行\n第二行', 5);
      MarkdownEditing.toggleLinePrefix(c, '- ');
      expect(c.text, '第一行\n- 第二行');
      c.dispose();
    });
  });

  group('标题级别 setHeading', () {
    test('设为一级标题', () {
      final c = _c('标题文字', 1);
      MarkdownEditing.setHeading(c, 1);
      expect(c.text, '# 标题文字');
      c.dispose();
    });

    test('从一级切到三级不会叠加成四个井号', () {
      final c = _c('# 标题文字', 3);
      MarkdownEditing.setHeading(c, 3);
      expect(c.text, '### 标题文字');
      c.dispose();
    });

    test('level 为 0 时去掉标题标记', () {
      final c = _c('### 标题文字', 5);
      MarkdownEditing.setHeading(c, 0);
      expect(c.text, '标题文字');
      c.dispose();
    });
  });

  group('插入独立块与链接', () {
    test('在段落中间插入分割线会补上换行', () {
      final c = _c('上面\n下面', 3);
      MarkdownEditing.insertBlock(c, '---');
      expect(c.text, '上面\n---\n\n下面');
      c.dispose();
    });

    test('选中文字后插入链接，并把 url 占位符选中', () {
      final c = _c('点这里', 0, 3);
      MarkdownEditing.insertLink(c);
      expect(c.text, '[点这里](url)');
      // 占位符 url 应处于选中态，用户直接输入即可替换
      expect(c.selection.textInside(c.text), 'url');
      c.dispose();
    });

    test('没有选中文字时插入链接模板', () {
      final c = _c('前缀', 2);
      MarkdownEditing.insertLink(c);
      expect(c.text, '前缀[](url)');
      c.dispose();
    });
  });

  // ── 实时样式解析 ────────────────────────────────────────────────────────
  group('实时样式解析', () {
    /// 片段拼起来必须和原文一模一样。
    ///
    /// 这不是"顺手一测"：编辑时输入法的组合区用的是**字符下标**，
    /// 一旦片段少字或多字，中文候选阶段的下划线就会画错位置。
    void expectLossless(String text) {
      final joined = MarkdownStyler.parse(text).map((s) => s.text).join();
      expect(joined, text, reason: '片段与原文不一致：$text');
    }

    test('片段拼接必须无损还原原文', () {
      const samples = <String>[
        '',
        '普通一行',
        '**加粗**和*斜体*',
        '# 一级标题',
        '###### 六级标题',
        '- 无序列表\n- 第二项',
        '1. 有序列表',
        '> 引用内容',
        '- [ ] 未完成\n- [x] 已完成',
        '前一行\n\n后一行',
        '```\n代码块\n```',
        '**未闭合的加粗',
        '`行内代码` 与 ~~删除线~~',
        '中文混排 with **English** 和 123',
      ];
      for (final s in samples) {
        expectLossless(s);
      }
    });

    test('加粗拆成 标记-内容-标记 三段', () {
      final segs = MarkdownStyler.parse('前**粗**后');
      expect(segs.map((s) => s.kind).toList(), <MdKind>[
        MdKind.plain,
        MdKind.marker,
        MdKind.bold,
        MdKind.marker,
        MdKind.plain,
      ]);
      expect(segs.map((s) => s.text).join(), '前**粗**后');
    });

    test('加粗优先于斜体，不会把 ** 拆成两个 *', () {
      final segs = MarkdownStyler.parse('**粗体**');
      expect(segs.where((s) => s.kind == MdKind.bold).length, 1);
      expect(segs.where((s) => s.kind == MdKind.italic), isEmpty);
    });

    test('标题按级别给出不同语义', () {
      expect(
        MarkdownStyler.parse('# 一').map((s) => s.kind).toList(),
        <MdKind>[MdKind.marker, MdKind.h1],
      );
      expect(
        MarkdownStyler.parse('### 三').map((s) => s.kind).toList(),
        <MdKind>[MdKind.marker, MdKind.h3],
      );
      // 四级及以下统一归到 h4
      expect(
        MarkdownStyler.parse('##### 五').map((s) => s.kind).toList(),
        <MdKind>[MdKind.marker, MdKind.h4],
      );
    });

    test('已完成的待办会被标成 done（渲染时划掉）', () {
      final done = MarkdownStyler.parse('- [x] 做完了');
      expect(done.map((s) => s.kind).toList(),
          <MdKind>[MdKind.marker, MdKind.done]);

      final todo = MarkdownStyler.parse('- [ ] 还没做');
      expect(todo.map((s) => s.kind).toList(),
          <MdKind>[MdKind.marker, MdKind.plain]);
    });

    test('行内代码与删除线', () {
      expect(
        MarkdownStyler.parse('`x`').map((s) => s.kind).toList(),
        <MdKind>[MdKind.marker, MdKind.code, MdKind.marker],
      );
      expect(
        MarkdownStyler.parse('~~y~~').map((s) => s.kind).toList(),
        <MdKind>[MdKind.marker, MdKind.strike, MdKind.marker],
      );
    });

    test('标题里的加粗保留标题语义而不是降级成 bold', () {
      // 「# **重点**」的正文应该还是标题级别的字号
      final segs = MarkdownStyler.parse('# **重点**');
      expect(segs.any((s) => s.kind == MdKind.h1), isTrue);
      expect(segs.any((s) => s.kind == MdKind.bold), isFalse);
    });

    test('分隔线整行都算分隔线语义', () {
      expect(
        MarkdownStyler.parse('---').map((s) => s.kind).toList(),
        <MdKind>[MdKind.divider],
      );
      // 图片行单独一种语义，渲染时弱化
      expect(
        MarkdownStyler.parse('![](45/1.png)').map((s) => s.kind).toList(),
        <MdKind>[MdKind.image],
      );
    });

    test('引用里的文字带引用语义', () {
      expect(
        MarkdownStyler.parse('> 说的对').map((s) => s.kind).toList(),
        <MdKind>[MdKind.marker, MdKind.quote],
      );
    });

    test('空行不产生多余片段', () {
      final segs = MarkdownStyler.parse('a\n\nb');
      // a、换行、空行（无内容）、换行、b
      expect(segs.map((s) => s.text).join(), 'a\n\nb');
    });
  });

  // ── 渲染样式（所见即所得的关键） ────────────────────────────────────────
  group('编辑控制器渲染', () {
    /// 收集所有带文字的叶子 span
    List<TextSpan> leaves(TextSpan root) {
      final out = <TextSpan>[];
      void walk(InlineSpan s) {
        if (s is TextSpan) {
          if (s.text != null) out.add(s);
          for (final c in s.children ?? const <InlineSpan>[]) {
            walk(c);
          }
        }
      }

      walk(root);
      return out;
    }

    Future<TextSpan> spanOf(
      WidgetTester tester,
      MarkdownEditingController c,
      TextStyle base, {
      bool composing = false,
    }) async {
      late TextSpan span;
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.light(),
        home: Builder(builder: (context) {
          span = c.buildTextSpan(
            context: context,
            style: base,
            withComposing: composing,
          );
          return const SizedBox();
        }),
      ));
      return span;
    }

    testWidgets('语法符号被渲染成透明且近乎零宽（这才叫所见即所得）', (tester) async {
      final c = MarkdownEditingController(text: '普通**加粗**文字');
      const base = TextStyle(fontSize: 17);
      final span = await spanOf(tester, c, base);
      final all = leaves(span);

      // 拼起来必须还是原文（字符没被真的删掉）
      expect(all.map((s) => s.text).join(), '普通**加粗**文字');

      final marks = all.where((s) => s.text == '**').toList();
      expect(marks.length, 2);
      for (final m in marks) {
        expect(m.style!.color, Colors.transparent, reason: '符号必须是透明的');
        expect(m.style!.fontSize! < 1, isTrue, reason: '符号必须近乎零宽');
        // 基准样式 letterSpacing 是负值，小字号下会把符号反向叠到正文上
        expect(m.style!.letterSpacing, 0);
      }
      c.dispose();
    });

    testWidgets('加粗与斜体必须继承基准字号与中文字体回退', (tester) async {
      // 这条对应一个真实出现过的 bug：
      // Flutter 的子 span 样式是「替换」而不是「合并」，
      // 一旦返回裸的 const TextStyle，就会丢掉 fontSize 和 fontFamilyFallback，
      // 中文退回错误字体、字形宽度对不上 —— 表现就是文字互相叠压。
      final c = MarkdownEditingController(text: '**粗** 和 *斜*');
      const base = TextStyle(
        fontSize: 17,
        fontFamilyFallback: <String>['Microsoft YaHei', 'Noto Sans CJK SC'],
      );
      final span = await spanOf(tester, c, base);
      final all = leaves(span);

      final bold = all.firstWhere((s) => s.text == '粗');
      expect(bold.style!.fontWeight, FontWeight.w700);
      expect(bold.style!.fontSize, 17, reason: '不能掉回默认 14');
      expect(bold.style!.fontFamilyFallback, isNotNull,
          reason: '中文回退链必须还在，否则会叠字');

      final italic = all.firstWhere((s) => s.text == '斜');
      expect(italic.style!.fontStyle, FontStyle.italic);
      expect(italic.style!.fontSize, 17);
      expect(italic.style!.fontFamilyFallback, isNotNull);
      c.dispose();
    });

    testWidgets('输入法组合区加下划线，且不打乱字符位置', (tester) async {
      final c = MarkdownEditingController(text: '**你好**');
      c.value = c.value.copyWith(composing: const TextRange(start: 2, end: 4));

      final span = await spanOf(
        tester,
        c,
        const TextStyle(fontSize: 17),
        composing: true,
      );
      final all = leaves(span);

      // 拼起来必须完全等于原文，否则光标与组合区下标会错位
      expect(all.map((s) => s.text).join(), '**你好**');

      final underlined = all
          .where((s) => s.style?.decoration == TextDecoration.underline)
          .toList();
      expect(underlined.length, 1);
      expect(underlined.first.text, '你好');
      c.dispose();
    });
  });
}
