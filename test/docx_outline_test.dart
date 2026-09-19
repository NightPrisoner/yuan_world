/// 导出的 docx 里，大纲必须是**真的**能用。
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
///
/// **正文里不再写目录**（用户明确要求：导出的文档要和笔记长得一样，
/// 第一行就该是正文）。导航靠上面的样式走 Word 自己的导航窗格。
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

  test('正文里不写目录（用户要求导出即所见），导航靠 Word 自己的窗格', () {
    final doc = parts['word/document.xml']!;
    // 目录项是超链接 + 书签；两者都不该出现在正文里了
    expect(
      RegExp(r'<w:hyperlink').allMatches(doc).length,
      0,
      reason: '正文里不该再有目录链接',
    );
    expect(
      RegExp(r'<w:bookmarkStart ').allMatches(doc).length,
      0,
      reason: '书签是给那份目录用的，目录没了书签也没用',
    );
    // 但标题必须仍是 Heading 样式（导航窗格认的是它，不是书签）
    expect(doc, contains('<w:pStyle w:val="Heading1"/>'));
    expect(doc, contains('<w:pStyle w:val="Heading2"/>'));
    // 正文第一行就是标题，第二块就是正文
    expect(doc.indexOf('第一节'), lessThan(doc.indexOf('正文一')));
  });

  test('没有标题的笔记照样导出，不报错', () {
    final p = unzip(NoteExporter.renderDocxBytes(noteWith('就是一段普通正文。')));
    final doc = p['word/document.xml']!;
    expect(doc, contains('就是一段普通正文。'));
    expect(doc, isNot(contains('<w:hyperlink')));
    // 样式包照样要有
    expect(p.keys, contains('word/styles.xml'));
  });
}
