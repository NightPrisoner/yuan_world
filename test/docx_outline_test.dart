/// 导出的 docx 里，目录/大纲必须是**真的**能用。
///
/// 以前正文标题虽然写了 `w:pStyle w:val="Heading2"`，但整个包**没有
/// styles.xml** —— 那个样式根本没定义。Word 除了把标题显示成普通文字，
/// 也拿不到大纲级别，于是**侧栏的目录是空的**。用户报的就是这个。
///
/// 所以这里不只是"有 Heading 字样"，而是逐项验证 OOXML 的必需环节：
///   1. 包里有 word/styles.xml
///   2. [Content_Types].xml 里登记了它（不登记 Word 不认）
///   3. document.xml.rels 里有 styles 关系（没图片时以前连 rels 都没有）
///   4. 标题样式带 w:outlineLvl（Word 的导航窗格认的是它，不是字号）
///   5. 正文前的目录是真超链接（w:hyperlink w:anchor），标题上有对应书签
library;

import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/data/exporter/note_exporter.dart';
import 'package:yuan_world/data/models.dart';

Note noteWith(String content) => Note(
  id: 1,
  title: '测试文档',
  content: content,
  excerpt: '',
  charCount: content.length,
  wordCount: 0,
  imageCount: 0,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

/// 把 docx 解开，返回「路径 → 文本」。
///
/// **必须 utf8 解码**：zip 里的 XML 是 UTF-8 字节，用
/// `String.fromCharCodes` 是逐字节当码点，中文全变乱码。
Map<String, String> unzip(List<int> bytes) {
  final out = <String, String>{};
  for (final f in ZipDecoder().decodeBytes(bytes)) {
    if (f.isFile) {
      out[f.name] = utf8.decode(f.content as List<int>, allowMalformed: true);
    }
  }
  return out;
}

void main() {
  const body = '''
# 第一节

正文一。

## 小节 A

正文二。

### 更深一层

正文三。

## 小节 B

正文四。
''';

  late Map<String, String> parts;

  setUpAll(() {
    parts = unzip(NoteExporter.renderDocxBytes(noteWith(body)));
  });

  test('包里有 styles.xml，并且被登记进 Content_Types', () {
    expect(parts.keys, contains('word/styles.xml'));
    expect(parts['[Content_Types].xml'], contains('/word/styles.xml'));
    expect(
      parts['[Content_Types].xml'],
      contains('wordprocessingml.styles+xml'),
    );
  });

  test('document.xml.rels 里有 styles 关系（没有图片时也要有）', () {
    expect(parts.keys, contains('word/_rels/document.xml.rels'));
    expect(
      parts['word/_rels/document.xml.rels'],
      contains('relationships/styles'),
    );
    expect(
      parts['word/_rels/document.xml.rels'],
      contains('Target="styles.xml"'),
    );
  });

  test('Heading1~6 都定义了，而且都带 outlineLvl（导航窗格认这个）', () {
    final styles = parts['word/styles.xml']!;
    for (var lvl = 1; lvl <= 6; lvl++) {
      expect(
        styles,
        contains('w:styleId="Heading$lvl"'),
        reason: 'Heading$lvl 没定义',
      );
      // Word 内置名，引用→目录之类的功能也靠它
      expect(styles, contains('w:name w:val="heading $lvl"'));
    }
    for (var i = 0; i < 6; i++) {
      expect(
        styles,
        contains('<w:outlineLvl w:val="$i"/>'),
        reason: '第 $i 级大纲没写 outlineLvl，Word 侧栏就不会显示它',
      );
    }
    expect(parts['word/styles.xml'], contains('w:styleId="Hyperlink"'));
  });

  test('正文标题用的是 Heading 样式，级别和 Markdown 的 # 对应', () {
    final doc = parts['word/document.xml']!;
    expect(doc, contains('<w:pStyle w:val="Heading1"/>'));
    expect(doc, contains('<w:pStyle w:val="Heading2"/>'));
    expect(doc, contains('<w:pStyle w:val="Heading3"/>'));
    expect(doc, contains('第一节'));
    expect(doc, contains('小节 A'));
  });

  test('每个标题都有书签，正文前的目录是能点的超链接', () {
    final doc = parts['word/document.xml']!;
    // 4 个标题（1 个 H1、2 个 H2、1 个 H3）
    final marks = RegExp(r'<w:bookmarkStart ').allMatches(doc).length;
    expect(marks, 4, reason: '书签数应该等于标题数');
    expect(doc, contains('w:name="ywHead1"'));
    expect(
      RegExp(r'<w:bookmarkEnd ').allMatches(doc).length,
      marks,
      reason: '有开没关会让 Word 判定文件损坏',
    );

    final links = RegExp(r'<w:hyperlink w:anchor="(ywHead\d+)">')
        .allMatches(doc)
        .map((m) => m.group(1))
        .toList();
    expect(links.length, 4, reason: '目录项应该都是超链接');
    expect(links.toSet().length, 4, reason: '锚点不能重复');
    // 每个锚点都要有对应的书签，否则点了跳不过去
    for (final a in links) {
      expect(doc, contains('w:name="$a"'), reason: '$a 没有对应的书签');
    }
  });

  test('没有标题的笔记不生成空目录，也不报错', () {
    final p = unzip(NoteExporter.renderDocxBytes(noteWith('就是一段普通正文。')));
    final doc = p['word/document.xml']!;
    expect(doc, contains('就是一段普通正文。'));
    expect(doc, isNot(contains('<w:hyperlink')));
    expect(doc, isNot(contains('<w:bookmarkStart')));
    // 样式包照样要有
    expect(p.keys, contains('word/styles.xml'));
  });
}
