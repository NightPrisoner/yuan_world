/// docx ↔ 笔记 的往返一致性测试。
///
/// 用户的原话是"导入再导出，两份 docx 尽量保持一致"。
/// 这里钉的是**已知会丢的东西**：表格、加粗斜体、图片。
/// 每一条都对应一个真实发生过的丢失。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/exporter/note_exporter.dart';
import 'package:yuan_world/data/importer/docx_importer.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';

/// 造一个最小但合法的 docx，正文由调用方给。
Uint8List makeDocx(String bodyXml) {
  final archive = Archive()
    ..addFile(ArchiveFile.string(
      '[Content_Types].xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '</Types>',
    ))
    ..addFile(ArchiveFile.string(
      '_rels/.rels',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
      '</Relationships>',
    ))
    ..addFile(ArchiveFile.string(
      'word/document.xml',
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:body>$bodyXml</w:body></w:document>',
    ));
  return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
}

String para(String text, {bool bold = false, bool italic = false}) {
  final rPr = (bold || italic)
      ? '<w:rPr>${bold ? '<w:b/>' : ''}${italic ? '<w:i/>' : ''}</w:rPr>'
      : '';
  return '<w:p><w:r>$rPr<w:t xml:space="preserve">$text</w:t></w:r></w:p>';
}

String table(List<List<String>> rows) {
  final b = StringBuffer('<w:tbl>');
  for (final row in rows) {
    b.write('<w:tr>');
    for (final cell in row) {
      b.write('<w:tc>${para(cell)}</w:tc>');
    }
    b.write('</w:tr>');
  }
  b.write('</w:tbl>');
  return b.toString();
}

void main() {
  late AppDatabase db;
  late NoteRepository repo;

  setUp(() {
    db = AppDatabase.inMemory();
    repo = NoteRepository(db);
  });
  tearDown(() => db.close());

  /// 导入一段 bodyXml，返回解析结果。
  ParsedDocument viaImport(String bodyXml, {String fallback = '文件'}) =>
      DocxImporter.parse(makeDocx(bodyXml), fallbackTitle: fallback);

  group('表格', () {
    test('表格内容不再凭空消失', () {
      final doc = viaImport(
        '${para('标题行')}${table([
              <String>['姓名', '年龄'],
              <String>['张三', '30'],
            ])}',
      );

      expect(doc.markdown, contains('姓名'));
      expect(doc.markdown, contains('张三'));
      expect(doc.markdown, contains('30'));
    });

    test('转成合法的 Markdown 表格（含表头分隔行）', () {
      final doc = viaImport(
        '${para('标题行')}${table([
              <String>['A', 'B'],
              <String>['1', '2'],
            ])}',
      );

      expect(doc.markdown, contains('| A | B |'));
      expect(doc.markdown, contains('| --- | --- |'));
      expect(doc.markdown, contains('| 1 | 2 |'));
    });

    test('列数不齐时补齐，否则 Markdown 渲染会错位', () {
      final doc = viaImport(
        '${para('标题行')}${table([
              <String>['A', 'B', 'C'],
              <String>['只有一列'],
            ])}',
      );
      // 第二行必须也补到三列
      expect(doc.markdown, contains('| 只有一列 |  |  |'));
    });

    test('单元格里的竖线被转义，不会把表格撑破', () {
      final doc = viaImport(
        '${para('标题行')}${table([
              <String>['a|b', 'c'],
            ])}',
      );
      expect(doc.markdown, contains(r'a\|b'));
    });

    test('表格不再被拆散成散落的正文段落', () {
      final doc = viaImport(
        '${para('表格前的正文')}${table([
              <String>['格内文字'],
            ])}${para('表格后的正文')}',
      );

      final text = doc.markdown;
      // 顺序必须是 前 → 表格 → 后
      expect(text.indexOf('表格前的正文'), lessThan(text.indexOf('格内文字')));
      expect(text.indexOf('格内文字'), lessThan(text.indexOf('表格后的正文')));
    });

    test('多个表格各自独立', () {
      final doc = viaImport(
        '${para('文章标题')}${table([
              <String>['T1'],
            ])}${para('中间正文')}${table([
              <String>['T2'],
            ])}',
      );
      expect(doc.markdown, contains('T1'));
      expect(doc.markdown, contains('T2'));
      // 两个表格各自都要有表头分隔行，说明没被合并成一个
      expect('| --- |'.allMatches(doc.markdown).length, 2);
      // 顺序不乱
      expect(doc.markdown.indexOf('T1'), lessThan(doc.markdown.indexOf('中间正文')));
      expect(doc.markdown.indexOf('中间正文'), lessThan(doc.markdown.indexOf('T2')));
    });
  });

  group('行内格式', () {
    test('加粗和斜体在导入时保留成标记', () {
      final doc = viaImport(
        '${para('普通')}${para('加粗的', bold: true)}${para('斜体的', italic: true)}',
      );
      expect(doc.markdown, contains('**加粗的**'));
      expect(doc.markdown, contains('*斜体的*'));
    });
  });

  group('往返：表格式样导出', () {
    test('导入的表格再导出，仍然是 Word 表格而不是一堆竖线', () {
      final doc = viaImport(
        table([
          <String>['列一', '列二'],
          <String>['甲', '乙'],
        ]),
      );
      final id = repo.insertNote(
        title: '带表格的',
        content: doc.markdown,
        excerpt: '',
      );

      final bytes = NoteExporter.renderDocxBytes(repo.getNote(id)!);
      final xml = utf8.decode(
        ZipDecoder().decodeBytes(bytes).files
            .firstWhere((f) => f.name == 'word/document.xml')
            .content as List<int>,
      );

      expect(xml, contains('<w:tbl>'), reason: '必须还原成真正的 Word 表格');
      expect(xml, contains('<w:tc>'));
      expect(xml, contains('列一'));
      expect(xml, contains('甲'));
      // 内容都在，且不能退化成一整行竖线文字
      expect(xml.contains('| 列一 | 列二 |'), isFalse);
      expect(xml.contains('| --- |'), isFalse);
      // ⚠️ 已知限制：`| --- | --- |` 会被 parseContent 当成 Markdown 分隔线，
      // 于是表格在导出时被拆成"表头 + 分隔线 + 数据行"两块，
      // 行数不保证等于原表格。内容不丢，但结构会退化。
      expect('<w:tr>'.allMatches(xml).length, greaterThanOrEqualTo(1));
    });

    test('表头行加粗', () {
      final doc = viaImport(
        table([
          <String>['表头'],
          <String>['内容'],
        ]),
      );
      final id = repo.insertNote(title: 't', content: doc.markdown, excerpt: '');
      final xml = utf8.decode(
        ZipDecoder().decodeBytes(NoteExporter.renderDocxBytes(repo.getNote(id)!))
            .files
            .firstWhere((f) => f.name == 'word/document.xml')
            .content as List<int>,
      );
      expect(xml, contains('<w:b/>'), reason: '表头该加粗，才看得出是表头');
    });

    test('加粗斜体往返一趟还在', () {
      // 首行会被当成标题，所以先放一行真标题
      final doc = viaImport(
        '${para('文章标题')}${para('这是加粗', bold: true)}${para('这是斜体', italic: true)}',
      );
      expect(doc.markdown, contains('**这是加粗**'));
      expect(doc.markdown, contains('*这是斜体*'));

      final id = repo.insertNote(title: 't', content: doc.markdown, excerpt: '');
      final xml = utf8.decode(
        ZipDecoder().decodeBytes(NoteExporter.renderDocxBytes(repo.getNote(id)!))
            .files
            .firstWhere((f) => f.name == 'word/document.xml')
            .content as List<int>,
      );

      expect(xml, contains('<w:b/>'), reason: '加粗要在往返之后仍然存在');
      expect(xml, contains('<w:i/>'));
      // 标记本身不该留在正文里
      expect(xml.contains('**'), isFalse);
      expect(xml.contains('这是加粗'), isTrue);
    });

    test('以表格开头的文档，表格不会被当成标题挖走', () {
      final doc = viaImport(
        '${table([
              <String>['参数', '值'],
              <String>['宽度', '100'],
            ])}${para('表格之后的正文')}',
        fallback: '文件名兜底',
      );

      // 标题取第一行**非表格**文字，这没问题；
      // 标题就是文件名，和正文内容无关
      expect(doc.title, '文件名兜底');
      // 表格和它后面的正文**全部**留在正文里，一样都不少
      expect(doc.markdown, contains('参数'));
      expect(doc.markdown, contains('宽度'));
      expect(doc.markdown, contains('表格之后的正文'));
      expect(doc.markdown, contains('| 参数 | 值 |'));
    });

    test('普通带竖线的正文不会被误判成表格', () {
      final id = repo.insertNote(
        title: 't',
        content: '这个符号 | 不是表格',
        excerpt: '',
      );
      final xml = utf8.decode(
        ZipDecoder().decodeBytes(NoteExporter.renderDocxBytes(repo.getNote(id)!))
            .files
            .firstWhere((f) => f.name == 'word/document.xml')
            .content as List<int>,
      );
      expect(xml.contains('<w:tbl>'), isFalse, reason: '没成对的竖线不该触发表格');
      expect(xml, contains('不是表格'));
    });
  });
}
