/// 编辑态与阅读态的**一致性验收**。
///
/// 这里不测"某个样式长什么样"，而是测一条更狠的规则：
/// **同一段 Markdown，编辑时被认成什么块、读的时候就必须被认成什么块。**
///
/// 之所以单独拉一条测试线：这两个解析器以前各写一套正则，长歪过
/// 一次——` ``` ` 围栏在阅读页被拆成三行、在编辑页毫无样式；
/// `    ---` 在编辑页是分隔线、阅读页是普通段落。这类 bug 不会让程序崩，
/// 但会让人不敢相信自己写进去的东西。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/core/utils/markdown_blocks.dart';
import 'package:yuan_world/core/utils/text_stats.dart';
import 'package:yuan_world/features/notes/editor/markdown_styler.dart';

/// 把阅读页的块类型折成编辑器的语义类别，好做一一对应。
String _readerKind(ContentBlock b) => switch (b.type) {
  ContentBlockType.heading => 'heading',
  ContentBlockType.quote => 'quote',
  ContentBlockType.bullet || ContentBlockType.ordered => 'list',
  ContentBlockType.code => 'code',
  ContentBlockType.image => 'image',
  ContentBlockType.divider => 'divider',
  ContentBlockType.paragraph => 'paragraph',
};

/// 把编辑器的片段折成同一套语义类别。
///
/// 关键点：`marker` 不参与语义判断（它就是被藏起来的语法符号）。
/// 但**列表是个例外**：列表行在编辑器里就是「一个 marker 前缀 + 普通文字」，
/// 没有单独的 `list` 语义，所以必须回头看一眼前缀长什么样。
String _editorKind(List<MdSegment> segs) {
  final visible = segs.where((s) => s.text != '\n').toList();
  final real = visible.where((s) => s.kind != MdKind.marker).toList();
  if (real.isEmpty) return 'empty';

  switch (real.first.kind) {
    case MdKind.h1 || MdKind.h2 || MdKind.h3 || MdKind.h4:
      return 'heading';
    case MdKind.quote:
      return 'quote';
    case MdKind.divider:
      return 'divider';
    case MdKind.image:
      return 'image';
    case MdKind.code:
      return 'code';
    case _:
      break;
  }

  final listMarker = RegExp(r'^\s*([-*+]|\d+\.)\s+\S|^\s*([-*+]|\d+\.)\s+$');
  final isList = visible.any(
    (s) => s.kind == MdKind.marker && listMarker.hasMatch(s.text),
  );
  return isList ? 'list' : 'paragraph';
}

/// 编辑器可见文字（去掉 marker、去掉换行分隔符）。
String _editorVisible(List<MdSegment> segs) => segs
    .where((s) => s.kind != MdKind.marker && s.text != '\n')
    .map((s) => s.text)
    .join();

void main() {
  group('块级识别：编辑态与阅读态必须一致', () {
    test('一份覆盖全部块类型的语料', () {
      // (原文, 期望语义)。期望值写死，两边**同时**被钉在这张表上。
      const corpus = <(String, String)>[
        ('# 标题', 'heading'),
        ('## 标题', 'heading'),
        ('###### 六级', 'heading'),
        ('####### 七级不是标题', 'paragraph'),
        ('#不是标题', 'paragraph'),
        ('   ### 缩进三格仍是标题', 'heading'),
        ('    # 四格缩进不是标题', 'paragraph'),
        ('---', 'divider'),
        ('***', 'divider'),
        ('___', 'divider'),
        ('    ---', 'paragraph'),
        ('- - -', 'list'),
        ('> 引用', 'quote'),
        ('   > 缩进引用', 'quote'),
        ('    > 四格不是引用', 'paragraph'),
        ('- 列表', 'list'),
        ('1. 有序', 'list'),
        ('  - 嵌套', 'list'),
        ('    - 四格嵌套', 'list'),
        ('- [ ] 待办', 'list'),
        ('- [x] 待办', 'list'),
        ('![图片](a.png)', 'image'),
        ('```\nx\n```', 'code'),
        ('~~~\nx\n~~~', 'code'),
        ('3.5 元', 'paragraph'),
        ('普通正文', 'paragraph'),
      ];

      for (final (input, expected) in corpus) {
        final blocks = parseContent(input);
        final segs = MarkdownStyler.parse(input);
        expect(
          blocks.length,
          1,
          reason: '阅读页应把「$input」切成恰好一块，实际切成 ${blocks.length} 块',
        );
        expect(
          _readerKind(blocks.single),
          expected,
          reason: '阅读页把「$input」认成了别的块',
        );
        expect(
          _editorKind(segs),
          expected,
          reason: '编辑页把「$input」认成了别的块',
        );
      }
    });

    test('可见文字也一致：编辑时看到的字，读出来还是那些字', () {
      const cases = [
        '# 标题文字',
        '> 引用文字',
        '- 列表文字',
        '1. 有序文字',
        '- [ ] 待办文字',
        '- [x] 已完成文字',
        '   - 缩进列表文字',
      ];

      for (final input in cases) {
        final block = parseContent(input).single;
        final segs = MarkdownStyler.parse(input);
        expect(
          _editorVisible(segs),
          block.text,
          reason: '「$input」在编辑器和阅读页显示的文字不一样',
        );
      }
    });
  });

  group('围栏代码块：不能再被拆散', () {
    const source = '```dart\nfinal a = 1;\nprint(a);\n```';

    test('阅读页把整块收成一个 code 块，围栏行不进正文', () {
      final blocks = parseContent(source);
      expect(blocks.length, 1);
      expect(blocks.single.type, ContentBlockType.code);
      expect(blocks.single.text, 'final a = 1;\nprint(a);');
    });

    test('编辑页把围栏符号收进 marker，中间每行都是 code 语义', () {
      final segs = MarkdownStyler.parse(source);
      final kinds = segs
          .where((s) => s.text != '\n')
          .map((s) => s.kind)
          .toList();
      expect(kinds.first, MdKind.marker, reason: '开口围栏应当只是淡色符号');
      expect(kinds.last, MdKind.marker, reason: '收尾围栏应当只是淡色符号');
      expect(
        kinds.where((k) => k == MdKind.code).length,
        2,
        reason: '两行代码都应当是 code 语义',
      );
    });

    test('没写收尾的围栏一直算代码到文末', () {
      final blocks = parseContent('```\nabc\ndef');
      expect(blocks.length, 1);
      expect(blocks.single.type, ContentBlockType.code);
      expect(blocks.single.text, 'abc\ndef');
    });

    test('围栏里的 # 和 --- 不会被当成标题或分隔线吃掉', () {
      final blocks = parseContent('```\n# 这是注释\n--- 这是减号\n```');
      expect(blocks.length, 1);
      expect(blocks.single.type, ContentBlockType.code);
      expect(blocks.single.text, '# 这是注释\n--- 这是减号');
    });

    test('波浪线围栏也能收口，且不会和反引号混用', () {
      expect(parseContent('~~~\nx\n~~~').single.type, ContentBlockType.code);
      // 反引号开的围栏，用波浪线收不掉，于是吃到文末
      final unterminated = parseContent('```\nx\n~~~');
      expect(unterminated.single.type, ContentBlockType.code);
      expect(unterminated.single.text, 'x\n~~~');
    });

    test('收尾围栏可以比开口长，但不能比开口短', () {
      // CommonMark：收尾至少要和开口一样长。``` 开的，```` 收得住。
      final longClose = parseContent('```\na\n````\nb');
      expect(longClose.first.type, ContentBlockType.code);
      expect(longClose.first.text, 'a');
      expect(longClose[1].type, ContentBlockType.paragraph);
      expect(longClose[1].text, 'b');

      // ```` 开的，``` 收不住 → 一直吃到文末
      final shortClose = parseContent('````\na\n```\nb');
      expect(shortClose.length, 1);
      expect(shortClose.single.type, ContentBlockType.code);
      expect(shortClose.single.text, 'a\n```\nb');
    });
  });

  group('行内标记：块内也能认', () {
    test('引用、标题、列表里的加粗，两边都能识别', () {
      for (final input in ['> **重点**', '# **重点**', '- **重点**']) {
        // 阅读页：行内解析在 RichParagraph 里，块 text 保留原样标记
        final block = parseContent(input).single;
        expect(block.text, contains('**重点**'));
        // 编辑页：必须产出 bold 格式，而不是把星号当正文
        final segs = MarkdownStyler.parse(input);
        final bolded = segs.where(
          (s) => s.formats.contains(MdKind.bold) || s.kind == MdKind.bold,
        );
        expect(bolded, isNotEmpty, reason: '「$input」的加粗没被识别');
        expect(
          segs.any((s) => s.kind == MdKind.marker && s.text.contains('**')),
          isTrue,
          reason: '「$input」的星号应当是藏起来的符号',
        );
      }
    });

    test('链接、行内代码、删除线也一样', () {
      for (final input in [
        '> [某处](https://a.com)',
        '> `code`',
        '> ~~删掉~~',
        '- [ ] [某处](https://a.com)',
      ]) {
        final segs = MarkdownStyler.parse(input);
        final visible = _editorVisible(segs);
        expect(visible, isNot(contains('](')), reason: '「$input」的链接语法露出来了');
        expect(visible, isNot(contains('~~')), reason: '「$input」的删除线语法露出来了');
        expect(visible, isNot(contains('`')), reason: '「$input」的反引号露出来了');
      }
    });
  });

  group('共享语法层本身', () {
    test('缩进层级：两个空格一级，Tab 算两个空格', () {
      expect(MdBlockSyntax.bulletLine('- a')!.level, 0);
      expect(MdBlockSyntax.bulletLine('  - a')!.level, 1);
      expect(MdBlockSyntax.bulletLine('    - a')!.level, 2);
      expect(MdBlockSyntax.bulletLine('\t- a')!.level, 1);
      // 再深也不会超过 4 级，不然渲染时会把文字挤出屏幕
      expect(MdBlockSyntax.bulletLine('            - a')!.level, 4);
    });

    test('有序列表保留原序号，不从 1 重排', () {
      expect(MdBlockSyntax.orderedLine('3. 第三步')!.number, 3);
      expect(MdBlockSyntax.orderedLine('12. 第十二步')!.number, 12);
    });

    test('前缀原样保留，编辑器要靠它的字符数算光标位置', () {
      final line = MdBlockSyntax.todoLine('  - [x] 做完了')!;
      expect(line.prefix, '  - [x] ');
      expect(line.text, '做完了');
      expect(line.checked, isTrue);
      expect(line.level, 1);
    });

    test('标题正文为空时不算标题（只是几个井号）', () {
      expect(MdBlockSyntax.headingLine('#'), isNull);
      expect(MdBlockSyntax.headingLine('#   '), isNull);
      expect(MdBlockSyntax.headingLine('# x'), isNotNull);
    });

    test('整行图片必须独占一行，行内图片不当块', () {
      expect(MdBlockSyntax.imageLine('![a](x.png)'), 'x.png');
      expect(MdBlockSyntax.imageLine('  前![a](x.png)'), isNull);
      expect(MdBlockSyntax.imageLine('![a](x.png) 后'), isNull);
    });
  });
}
