/// DOCX 导入的格式还原测试。
///
/// 重点：**列表层级、有序/无序、首行缩进**。
/// 这三样以前全丢——所有列表都被拍平成一级无序。
///
/// 有序还是无序写在 `word/numbering.xml` 里，光看 `document.xml` 分不出来，
/// 所以这里必须造一个带 numbering.xml 的样本，否则测不到真实路径。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/data/importer/docx_importer.dart';

/// 造一个最小 docx。
///
/// [numbering] 为空时不写 numbering.xml —— 顺便验证缺文件时不会崩。
String _docx({
  required String bodyXml,
  String? numbering,
  int tables = 0,
}) {
  final archive = Archive()
    ..addFile(ArchiveFile.string('[Content_Types].xml',
        '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>'));

  final tableXml = List.generate(tables, (i) => '<w:tbl><w:tr><w:tc>'
      '<w:p><w:r><w:t>表格$i</w:t></w:r></w:p>'
      '</w:tc></w:tr></w:tbl>').join();

  // 头部必须留一行给标题：导入器会把第一行当标题、并从正文里剔掉。
  // 不留的话第一个测试段落会被吃掉，测试就会莫名其妙地失败。
  const titleLine = '<w:p><w:r><w:t>样本标题</w:t></w:r></w:p>';

  archive.addFile(ArchiveFile.string(
    'word/document.xml',
    '<?xml version="1.0" encoding="UTF-8"?>'
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
    '<w:body>$titleLine$bodyXml$tableXml</w:body></w:document>',
  ));

  if (numbering != null) {
    archive.addFile(ArchiveFile.string(
      'word/numbering.xml',
      '<?xml version="1.0" encoding="UTF-8"?>'
      '<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '$numbering</w:numbering>',
    ));
  }
  return base64.encode(ZipEncoder().encodeBytes(archive));
}

Uint8List _bytes(String b64) => base64.decode(b64);

/// 一个列表段落。
String _li(String text, {required int numId, required int ilvl}) =>
    '<w:p><w:pPr><w:numPr>'
    '<w:ilvl w:val="$ilvl"/><w:numId w:val="$numId"/>'
    '</w:numPr></w:pPr>'
    '<w:r><w:t>$text</w:t></w:r></w:p>';

String _p(String text, {String? firstLineChars}) {
  final ind = firstLineChars == null
      ? ''
      : '<w:ind w:firstLineChars="$firstLineChars"/>';
  return '<w:p><w:pPr>$ind</w:pPr><w:r><w:t>$text</w:t></w:r></w:p>';
}

/// numId=1 是无序，numId=2 是有序（decimal）。
const String _numbering = '''
<w:abstractNum w:abstractNumId="10">
  <w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl>
  <w:lvl w:ilvl="1"><w:numFmt w:val="bullet"/></w:lvl>
  <w:lvl w:ilvl="2"><w:numFmt w:val="bullet"/></w:lvl>
</w:abstractNum>
<w:abstractNum w:abstractNumId="20">
  <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl>
  <w:lvl w:ilvl="1"><w:numFmt w:val="chineseCounting"/></w:lvl>
</w:abstractNum>
<w:num w:numId="1"><w:abstractNumId w:val="10"/></w:num>
<w:num w:numId="2"><w:abstractNumId w:val="20"/></w:num>
''';

List<String> _lines(ParsedDocument d) =>
    d.markdown.split('\n').where((l) => l.trim().isNotEmpty).toList();

void main() {
  group('列表层级', () {
    test('嵌套列表不再被拍平成一级', () {
      final doc = DocxImporter.parse(
        _bytes(_docx(
          numbering: _numbering,
          bodyXml: _p('标题段') +
              _li('一级项', numId: 1, ilvl: 0) +
              _li('二级项', numId: 1, ilvl: 1) +
              _li('三级项', numId: 1, ilvl: 2),
        )),
        fallbackTitle: '测试',
      );

      final lines = _lines(doc);
      expect(lines, contains('- 一级项'));
      expect(lines, contains('  - 二级项'), reason: '二级要缩进两个空格');
      expect(lines, contains('    - 三级项'), reason: '三级要缩进四个空格');
    });

    test('有序列表用 1. 而不是 -', () {
      final doc = DocxImporter.parse(
        _bytes(_docx(
          numbering: _numbering,
          bodyXml: _li('第一', numId: 2, ilvl: 0) + _li('第二', numId: 2, ilvl: 0),
        )),
        fallbackTitle: '测试',
      );

      final lines = _lines(doc);
      expect(lines.where((l) => l.startsWith('1. ')).length, 2);
      expect(lines.any((l) => l.startsWith('- ')), isFalse);
    });

    test('中文章节编号也算有序', () {
      final doc = DocxImporter.parse(
        _bytes(_docx(
          numbering: _numbering,
          bodyXml: _li('甲', numId: 2, ilvl: 1),
        )),
        fallbackTitle: '测试',
      );
      expect(_lines(doc), contains('  1. 甲'));
    });

    test('没有 numbering.xml 时退化成无序，不会崩', () {
      final doc = DocxImporter.parse(
        _bytes(_docx(bodyXml: _li('孤零零', numId: 9, ilvl: 0))),
        fallbackTitle: '测试',
      );
      expect(_lines(doc), contains('- 孤零零'));
    });

    test('层级过深会被夹住，不会把正文推到屏幕外', () {
      final doc = DocxImporter.parse(
        _bytes(_docx(
          numbering: _numbering,
          bodyXml: _li('很深', numId: 1, ilvl: 12),
        )),
        fallbackTitle: '测试',
      );
      final line = _lines(doc).firstWhere((l) => l.contains('很深'));
      expect(line.length - line.trimLeft().length, lessThanOrEqualTo(10));
    });
  });

  group('标题', () {
    test('Heading 样式转成对应数量的 #', () {
      String h(int n, String t) =>
          '<w:p><w:pPr><w:pStyle w:val="Heading$n"/></w:pPr>'
          '<w:r><w:t>$t</w:t></w:r></w:p>';

      final doc = DocxImporter.parse(
        _bytes(_docx(bodyXml: h(1, '一') + h(2, '二') + h(3, '三'))),
        fallbackTitle: '测试',
      );
      final lines = _lines(doc);
      expect(lines, contains('# 一'));
      expect(lines, contains('## 二'));
      expect(lines, contains('### 三'));
    });
  });

  group('首行缩进', () {
    test('firstLineChars=200 折算成两个全角空格', () {
      final doc = DocxImporter.parse(
        _bytes(_docx(bodyXml: _p('缩进两格', firstLineChars: '200'))),
        fallbackTitle: '测试',
      );
      final line = _lines(doc).firstWhere((l) => l.contains('缩进两格'));
      expect(line.startsWith('　　'), isTrue, reason: '应该是两个全角空格');
    });

    test('没有缩进就不加空格', () {
      final doc = DocxImporter.parse(
        _bytes(_docx(bodyXml: _p('顶格写'))),
        fallbackTitle: '测试',
      );
      final line = _lines(doc).firstWhere((l) => l.contains('顶格写'));
      expect(line, '顶格写');
    });
  });

  group('表格', () {
    test('表格数量会被统计出来', () {
      final doc = DocxImporter.parse(
        _bytes(_docx(bodyXml: _p('正文'), tables: 3)),
        fallbackTitle: '测试',
      );
      expect(doc.tableCount, 3);
    });

    test('没有表格时是 0', () {
      final doc = DocxImporter.parse(
        _bytes(_docx(bodyXml: _p('正文'))),
        fallbackTitle: '测试',
      );
      expect(doc.tableCount, 0);
    });
  });
}
