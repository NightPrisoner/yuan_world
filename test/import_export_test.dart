/// txt 导入 + docx 导出的测试。
///
/// 两边各有一个"错了才知道"的坑：
///   - txt 的**编码**：中文 txt 大量是 GBK，按 UTF-8 解就是满屏乱码
///   - docx 的**结构**：少一个 part，Word 就报"文件已损坏"
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/exporter/note_exporter.dart';
import 'package:yuan_world/data/importer/txt_importer.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';

void main() {
  group('txt 解码', () {
    test('UTF-8', () {
      final bytes = Uint8List.fromList(utf8.encode('中文内容'));
      expect(TxtImporter.decodeText(bytes), '中文内容');
    });

    test('带 BOM 的 UTF-8 —— BOM 本身不能留在正文里', () {
      final bytes = Uint8List.fromList(<int>[
        0xEF, 0xBB, 0xBF,
        ...utf8.encode('中文内容'),
      ]);
      expect(TxtImporter.decodeText(bytes), '中文内容');
      expect(TxtImporter.decodeText(bytes).startsWith('\uFEFF'), isFalse);
    });

    test('GBK —— 国内 Windows 上最常见的中文 txt 编码', () {
      // 没有 BOM 且不是合法 UTF-8，必须能嗅探出来
      final bytes = Uint8List.fromList(gbk.encode('中文内容'));
      expect(TxtImporter.decodeText(bytes), '中文内容');
    });

    test('UTF-16 小端（带 BOM）', () {
      final bytes = Uint8List.fromList(<int>[0xFF, 0xFE, 0x2D, 0x4E]);
      expect(TxtImporter.decodeText(bytes), '中');
    });

    test('UTF-16 大端（带 BOM）', () {
      final bytes = Uint8List.fromList(<int>[0xFE, 0xFF, 0x4E, 0x2D]);
      expect(TxtImporter.decodeText(bytes), '中');
    });

    test('纯 ASCII 不受影响', () {
      final bytes = Uint8List.fromList(utf8.encode('hello world'));
      expect(TxtImporter.decodeText(bytes), 'hello world');
    });

    test('空文件不崩', () {
      expect(TxtImporter.decodeText(Uint8List(0)), '');
    });
  });

  group('txt 解析', () {
    ParsedDoc parseOne(String text) {
      final d = TxtImporter.parse(
        Uint8List.fromList(utf8.encode(text)),
        fallbackTitle: '文件名',
      );
      return ParsedDoc(d.title, d.markdown);
    }

    test('第一行当标题，其余当正文，标题不重复', () {
      final r = parseOne('我的标题\n\n正文第一段\n正文第二段');
      expect(r.title, '我的标题');
      expect(r.body, '正文第一段\n正文第二段');
      expect(r.body.contains('我的标题'), isFalse);
    });

    test('开头空行会被跳过', () {
      final r = parseOne('\n\n\n真正的标题\n正文');
      expect(r.title, '真正的标题');
      expect(r.body, '正文');
    });

    test('整篇为空时退回文件名', () {
      final r = parseOne('   \n\n  ');
      expect(r.title, '文件名');
      expect(r.body, '');
    });

    test('超长首行会被截断', () {
      final r = parseOne('${'啊' * 200}\n正文');
      expect(r.title.runes.length, 60);
    });

    test('CRLF 换行被归一化', () {
      final r = parseOne('标题\r\n正文一\r\n正文二');
      expect(r.title, '标题');
      expect(r.body, '正文一\n正文二');
      expect(r.body.contains('\r'), isFalse);
    });
  });

  group('docx 导出 —— 图片与格式', () {
    late AppDatabase db;
    late NoteRepository repo;
    late Directory imgRoot;

    setUp(() {
      db = AppDatabase.inMemory();
      repo = NoteRepository(db);
      imgRoot = Directory.systemTemp.createTempSync('yw_imgs_');
    });
    tearDown(() {
      db.close();
      imgRoot.deleteSync(recursive: true);
    });

    /// 造一张合法的 PNG 头（宽高写在 IHDR 里，导出时会被读出来）。
    void writePng(String rel, {int w = 40, int h = 30}) {
      final f = File('${imgRoot.path}/$rel');
      if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
      f.writeAsBytesSync(<int>[
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0, 0, 0, 13,
        ...utf8.encode('IHDR'),
        (w >> 24) & 0xFF, (w >> 16) & 0xFF, (w >> 8) & 0xFF, w & 0xFF,
        (h >> 24) & 0xFF, (h >> 16) & 0xFF, (h >> 8) & 0xFF, h & 0xFF,
        8, 6, 0, 0, 0,
      ]);
    }

    Archive openDocx(String content) {
      final id = repo.insertNote(title: 'T', content: content, excerpt: '');
      final bytes = NoteExporter.renderDocxBytes(
        repo.getNote(id)!,
        imageRoot: imgRoot.path,
      );
      return ZipDecoder().decodeBytes(bytes);
    }

    String readPart(Archive a, String name) => utf8.decode(
      a.files.firstWhere((f) => f.name == name).content as List<int>,
    );

    test('正文里的图片会真的嵌进 docx', () {
      writePng('7/1.png');
      final a = openDocx('正文\n\n![](7/1.png)');

      final names = a.files.map((f) => f.name).toSet();
      expect(names, contains('word/media/image1.png'), reason: '图片本体必须进包');
      expect(names, contains('word/_rels/document.xml.rels'), reason: '要找得到图片');

      // Content_Types 里要声明 png，否则 Word 不认 media 里的文件
      expect(readPart(a, '[Content_Types].xml'), contains('image/png'));

      // 关系表把 rId 映射到图片
      final rels = readPart(a, 'word/_rels/document.xml.rels');
      expect(rels, contains('media/image1.png'));
      expect(rels, contains('relationships/image'));

      final xml = readPart(a, 'word/document.xml');
      expect(xml, contains('<w:drawing>'));
      expect(xml, contains('r:embed="rIdImg1"'));
      expect(xml.contains('[图片] 7/1.png'), isFalse, reason: '不该退化成占位文字');
    });

    test('docx 里带上真实宽高，不会显示成一条线', () {
      writePng('7/1.png', w: 400, h: 200);
      final xml = readPart(openDocx('![](7/1.png)'), 'word/document.xml');

      // 400x200 按 14cm 宽等比缩放 → 高正好是一半
      expect(xml, contains('cx="5040000"'));
      expect(xml, contains('cy="2520000"'));
    });

    test('图片文件缺失时退化成文字，不让整篇导出失败', () {
      final xml = readPart(openDocx('正文\n\n![](9/不存在.png)'), 'word/document.xml');
      expect(xml, contains('[图片] 9/不存在.png'));
    });

    test('加粗和斜体保留成 Word 的 run 属性', () {
      final xml = readPart(openDocx('这是 **加粗** 和 *斜体*'), 'word/document.xml');

      expect(xml, contains('<w:b/>'), reason: '加粗不能丢');
      expect(xml, contains('<w:i/>'), reason: '斜体不能丢');
      expect(xml, contains('加粗'));
      expect(xml.contains('**'), isFalse, reason: '星号本身不该留在正文里');
    });

    test('行内代码用等宽字体', () {
      expect(readPart(openDocx('看这段 `code`'), 'word/document.xml'),
          contains('Consolas'));
    });

    test('引用块带左边框', () {
      final xml = readPart(openDocx('> 引用内容'), 'word/document.xml');
      expect(xml, contains('<w:pBdr>'));
      expect(xml, contains('引用内容'));
    });

    test('多张图片各自编号，不会互相覆盖', () {
      writePng('7/a.png');
      writePng('7/b.png');
      final a = openDocx('![](7/a.png)\n\n![](7/b.png)');
      final names = a.files.map((f) => f.name).toSet();

      expect(names, contains('word/media/image1.png'));
      expect(names, contains('word/media/image2.png'));
      final xml = readPart(a, 'word/document.xml');
      expect(xml, contains('rIdImg1'));
      expect(xml, contains('rIdImg2'));
    });

    test('同一张图引用两次，两处都要渲染', () {
      writePng('7/a.png');
      final xml = readPart(openDocx('![](7/a.png)\n\n![](7/a.png)'), 'word/document.xml');
      // 不能因为"这张已经收过了"就把第二处吞掉
      expect('<w:drawing>'.allMatches(xml).length, 2);
    });
  });

  group('docx 导出', () {
    late AppDatabase db;
    late NoteRepository repo;

    setUp(() {
      db = AppDatabase.inMemory();
      repo = NoteRepository(db);
    });
    tearDown(() => db.close());

    test('是一个包含必需 part 的 zip', () {
      final id = repo.insertNote(
        title: '标题',
        content: '# 一\n\n正文',
        excerpt: '',
      );
      final bytes = NoteExporter.renderDocxBytes(repo.getNote(id)!);

      // 能解开就说明 zip 结构合法
      final archive = ZipDecoder().decodeBytes(bytes);
      final names = archive.files.map((f) => f.name).toSet();

      // 少任何一个，Word 都会报"文件已损坏"
      expect(names, contains('[Content_Types].xml'));
      expect(names, contains('_rels/.rels'));
      expect(names, contains('word/document.xml'));
    });

    test('正文和标题都进了 document.xml', () {
      final id = repo.insertNote(
        title: '我的标题',
        content: '正文内容',
        excerpt: '',
      );
      final bytes = NoteExporter.renderDocxBytes(repo.getNote(id)!);
      final xml = utf8.decode(
        ZipDecoder().decodeBytes(bytes).files
            .firstWhere((f) => f.name == 'word/document.xml')
            .content as List<int>,
      );

      expect(xml, contains('我的标题'));
      expect(xml, contains('正文内容'));
      expect(xml, contains('<w:document'));
    });

    test('XML 特殊字符被转义', () {
      final id = repo.insertNote(
        title: 'a<b>&"c"',
        content: '正文有 <tag> 和 & 号',
        excerpt: '',
      );
      final bytes = NoteExporter.renderDocxBytes(repo.getNote(id)!);
      final xml = utf8.decode(
        ZipDecoder().decodeBytes(bytes).files
            .firstWhere((f) => f.name == 'word/document.xml')
            .content as List<int>,
      );

      expect(xml, contains('&lt;tag&gt;'));
      expect(xml.contains('<tag>'), isFalse, reason: '未转义的标签会让 Word 判定文件损坏');
    });

    test('控制字符被剔除', () {
      final id = repo.insertNote(
        title: 't',
        content: '正文\u0000里有\u0007控制符',
        excerpt: '',
      );
      final bytes = NoteExporter.renderDocxBytes(repo.getNote(id)!);
      final xml = utf8.decode(
        ZipDecoder().decodeBytes(bytes).files
            .firstWhere((f) => f.name == 'word/document.xml')
            .content as List<int>,
      );
      expect(xml.contains('\u0000'), isFalse);
      expect(xml.contains('\u0007'), isFalse);
    });

    test('导出到目录时 docx 走二进制写入', () {
      final dir = Directory.systemTemp.createTempSync('yw_docx_');
      final id = repo.insertNote(title: '甲', content: '正文', excerpt: '');
      repo.insertNote(title: '乙', content: '正文', excerpt: '');

      final n = NoteExporter.exportToDirectory(
        notes: repo.listNotes(const NoteFilter()),
        format: ExportFormat.docx,
        dir: dir.path,
      );

      expect(n, 2);
      final files = dir.listSync().whereType<File>().toList();
      expect(files.every((f) => f.path.endsWith('.docx')), isTrue);
      // 真正的 zip 以 PK 开头；写成字符串的话这里会挂
      final head = files.first.readAsBytesSync().take(2).toList();
      expect(head, <int>[0x50, 0x4B], reason: 'docx 必须是二进制 zip');
      expect(id, isNotNull);
      dir.deleteSync(recursive: true);
    });
  });
}

/// 测试里用的简单载体，避免依赖 ParsedDocument 的其它字段。
class ParsedDoc {
  const ParsedDoc(this.title, this.body);
  final String title;
  final String body;
}
