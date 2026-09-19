/// 导出格式要和笔记本身一致，以及"时间戳跟随笔记"。
///
/// 用户的三条原话：
///   · 「笔记导出后目录不需要出现在正文上面」→ 见 export_test.dart
///   · 「导出文档的创建时间和修改时间跟随笔记」
///   · 「导出文档格式和笔记里的保持一致，也可以说导入文档什么样导出文档也什么样」
///
/// 这里钉的就是第二条和第三条里**容易被改坏**的部分：
/// 有序列表的编号、嵌套层级、段落里的软换行、删除线、可真点的超链接。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/data/exporter/note_exporter.dart';
import 'package:yuan_world/data/exporter/note_times.dart';
import 'package:yuan_world/data/models.dart';

Note noteOf(String content, {String title = '测试'}) => Note(
  id: 1,
  title: title,
  content: content,
  excerpt: '',
  charCount: content.length,
  wordCount: 0,
  imageCount: 0,
  createdAt: DateTime(2024, 3, 5, 8, 30, 15),
  updatedAt: DateTime(2025, 11, 20, 22, 45, 5),
);

Map<String, String> unzipParts(List<int> bytes) {
  final out = <String, String>{};
  for (final f in ZipDecoder().decodeBytes(bytes)) {
    if (f.isFile) {
      out[f.name] = utf8.decode(f.content as List<int>, allowMalformed: true);
    }
  }
  return out;
}

String docxOf(String content) =>
    unzipParts(NoteExporter.renderDocxBytes(noteOf(content)))['word/document.xml']!;

void main() {
  group('docx 列表是真列表', () {
    test('有无序列表的编号定义，且被登记进包', () {
      final parts = unzipParts(
        NoteExporter.renderDocxBytes(noteOf('- 甲\n- 乙')),
      );
      expect(parts.keys, contains('word/numbering.xml'));
      expect(parts['[Content_Types].xml'], contains('/word/numbering.xml'));
      expect(
        parts['word/_rels/document.xml.rels'],
        contains('Target="numbering.xml"'),
        reason: '不登记关系，Word 不会去读它',
      );
      final numbering = parts['word/numbering.xml']!;
      expect(numbering, contains('w:numFmt w:val="bullet"'));
      expect(numbering, contains('w:numFmt w:val="decimal"'));
    });

    test('项目符号用 w:numPr，而不是手打的「·」', () {
      final doc = docxOf('- 甲\n- 乙');
      expect(doc, contains('<w:numId w:val="1"/>'));
      expect(doc.contains('·'), isFalse, reason: '符号该由 Word 画，不该写进正文');
    });

    test('有序列表带编号（以前编号直接丢失）', () {
      final doc = docxOf('1. 第一步\n2. 第二步\n3. 第三步');
      expect(doc, contains('<w:numId w:val="2"/>'));
      expect(doc, contains('第一步'));
      expect(doc, contains('第三步'));
    });

    test('缩进的子项带层级 ilvl', () {
      final doc = docxOf('- 父项\n  - 子项\n    - 孙项');
      expect(doc, contains('<w:ilvl w:val="0"/>'));
      expect(doc, contains('<w:ilvl w:val="1"/>'));
      expect(doc, contains('<w:ilvl w:val="2"/>'));
    });

    test('4 个空格缩进的子项也算列表，不掉进普通段落', () {
      final doc = docxOf('- 父项\n    - 深一层');
      expect(doc, contains('<w:ilvl w:val="2"/>'));
      expect(doc, isNot(contains('<w:ind w:left="240"/>')));
    });

    test('空格数不规则的缩进也能分层（Tab 算两级）', () {
      final html = NoteExporter.render(
        noteOf('- 甲\n\t- 乙'),
        ExportFormat.html,
      );
      // Tab → 2 空格宽度 → 1 级；HTML 里靠嵌套 ul 表达
      expect(html, contains('<ul>'));
    });
  });

  group('docx 行内格式', () {
    test('删除线导出成 w:strike', () {
      expect(docxOf('这~~删掉了~~的话'), contains('<w:strike/>'));
    });

    test('标记链接导出成可真点的超链接，地址写进 rels', () {
      final parts = unzipParts(
        NoteExporter.renderDocxBytes(noteOf('看 [官网](https://example.com/a) 吧')),
      );
      final doc = parts['word/document.xml']!;
      final rels = parts['word/_rels/document.xml.rels']!;
      expect(doc, contains('<w:hyperlink r:id="rIdLink1">'));
      expect(doc, contains('官网'));
      expect(rels, contains('Target="https://example.com/a"'));
      expect(rels, contains('TargetMode="External"'),
          reason: '外链必须标 External，否则 Word 会当成包内文件');
    });

    test('裸网址也是可点的', () {
      final parts = unzipParts(
        NoteExporter.renderDocxBytes(noteOf('见 https://example.com/b')),
      );
      expect(parts['word/document.xml'], contains('<w:hyperlink'));
      expect(parts['word/_rels/document.xml.rels'],
          contains('https://example.com/b'));
    });

    test('段落里的软换行变成 w:br，而不是被 Word 吞掉', () {
      final doc = docxOf('第一行\n第二行');
      expect(doc, contains('<w:br/>'));
      expect(doc, contains('第一行'));
      expect(doc, contains('第二行'));
    });
  });

  group('HTML 与纯文本也保持一致', () {
    test('列表是 ul/ol，连续的项合进同一个列表', () {
      final html = NoteExporter.render(
        noteOf('- 甲\n- 乙\n\n中间一段\n\n1. 一\n2. 二'),
        ExportFormat.html,
      );
      expect(html, contains('<ul>'));
      expect(html, contains('<li>甲</li>'));
      expect(html, contains('<li>乙</li>'));
      expect(html, contains('</ul>'));
      expect(html, contains('<ol>'));
      expect(html, contains('<li>一</li>'));
      expect(html.contains('<li>· '), isFalse);
    });

    test('删除线是 del', () {
      final html = NoteExporter.render(noteOf('~~不要了~~'), ExportFormat.html);
      expect(html, contains('<del>不要了</del>'));
    });

    test('纯文本保留有序列表的序号', () {
      final txt = NoteExporter.render(
        noteOf('1. 第一步\n2. 第二步\n3. 第三步'),
        ExportFormat.text,
      );
      expect(txt, contains('1. 第一步'));
      expect(txt, contains('2. 第二步'));
      expect(txt, contains('3. 第三步'));
    });

    test('纯文本的项目符号带缩进层级', () {
      final txt = NoteExporter.render(
        noteOf('- 甲\n  - 乙'),
        ExportFormat.text,
      );
      expect(txt, contains('  · 甲'));
      expect(txt, contains('    · 乙'));
    });
  });

  group('时间戳跟随笔记', () {
    test('W3CDTF 串按 UTC 输出', () {
      expect(
        w3cDate(DateTime.utc(2024, 3, 5, 8, 30, 15)),
        '2024-03-05T08:30:15Z',
      );
    });

    test('docx 的 core.xml 写的是笔记的创建/修改时间', () {
      final parts = unzipParts(
        NoteExporter.renderDocxBytes(noteOf('正文')),
      );
      final core = parts['docProps/core.xml']!;
      expect(core, contains('<dcterms:created'));
      expect(core, contains('2024-03-05T'));
      expect(core, contains('2025-11-20T'));
      expect(parts['[Content_Types].xml'], contains('/docProps/core.xml'));
      expect(parts['_rels/.rels'], contains('docProps/core.xml'));
    });

    test('压缩包里每个条目带笔记的修改时间', () {
      final note = noteOf('正文');
      final zip = NoteExporter.zipBytes(
        items: <({List<String> path, Note note})>[
          (path: <String>[], note: note),
        ],
      );
      final entry = ZipDecoder()
          .decodeBytes(zip)
          .files
          .firstWhere((f) => f.name.endsWith('.docx'));
      // archive 的编解码单位不一致：写进去是纪元秒，读出来是 DOS 打包值，
      // 所以这里按 DOS 布局拆开对年月日时分
      final t = parseDosTime(entry.lastModTime);
      final want = note.updatedAt;
      expect(t.year, want.year);
      expect(t.month, want.month);
      expect(t.day, want.day);
      expect(t.hour, want.hour);
      expect(t.minute, want.minute);
    });

    test('纪元秒就是 Unix 时间戳', () {
      expect(epochSecondsOf(DateTime.fromMillisecondsSinceEpoch(1700000000000)),
          1700000000);
    });

    test('落盘时文件的修改时间改成笔记的修改时间', () {
      final dir = Directory.systemTemp.createTempSync('yw_times_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final note = noteOf('正文');
      final n = NoteExporter.exportToDirectory(
        notes: <Note>[note],
        format: ExportFormat.markdown,
        dir: dir.path,
      );
      expect(n, 1);
      final written = File('${dir.path}${Platform.pathSeparator}测试.md');
      expect(written.existsSync(), isTrue);
      final mtime = written.lastModifiedSync();
      // 秒级精度足够（文件系统可能截断毫秒）
      expect(
        mtime.difference(note.updatedAt).inSeconds.abs() <= 2,
        isTrue,
        reason: '文件时间是 $mtime，期望接近 ${note.updatedAt}',
      );
    });

    test('applyNoteTimes 对不存在的文件不抛异常', () {
      expect(
        () => applyNoteTimes(
          '${Directory.systemTemp.path}${Platform.pathSeparator}没有这个文件.bin',
          created: DateTime(2024),
          modified: DateTime(2024),
        ),
        returnsNormally,
      );
    });
  });
}
