/// 导出的**媒体引用必须都能落地**：正文里写的每个路径，解压后都要有文件。
///
/// 这是用户连着报了三条的那类问题（「图片和视频的导出都有问题」
/// 「导出 txt 图片和视频没能导出来」「导出 pdf 也有这样的问题」）的
/// 总闸门：
///
///   · 以前 txt 根本不收图片（只有 markdown 收）
///   · 包内条目名用相对 imageRoot 的路径（`7/a.png`），正文却写
///     `images/7/a.png` —— 解压出来链接是断的
///
/// 所以这里不看"函数有没有被调用"，而是**解压后照着正文去取文件**：
/// 取不到就是错的。以后谁再改媒体打包逻辑，这一组会先红。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yuan_world/data/exporter/note_exporter.dart';
import 'package:yuan_world/data/models.dart';

/// 一张合法的 3×2 PNG（PIL 生成的真字节，`pdf` 包能解出来）。
final List<int> kPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x02,
  0x08, 0x02, 0x00, 0x00, 0x00, 0x12, 0x16, 0xF1,
  0x4D, 0x00, 0x00, 0x00, 0x14, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x3C, 0x21, 0x27, 0xC7,
  0x00, 0x06, 0x4C, 0x10, 0x8A, 0x81, 0x81, 0x01,
  0x00, 0x13, 0x2E, 0x01, 0x08, 0xCE, 0x20, 0xB4,
  0x58, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
  0x44, 0xAE, 0x42, 0x60, 0x82,
];

void main() {
  late Directory root;
  late Note sample;

  setUp(() {
    root = Directory.systemTemp.createTempSync('yw_export_media_');
    // 一篇同时带图片和视频的笔记
    Directory(p.join(root.path, 'images', '7')).createSync(recursive: true);
    File(p.join(root.path, 'images', '7', 'a.png')).writeAsBytesSync(kPng);
    File(p.join(root.path, 'images', '7', 'v.mp4'))
        .writeAsBytesSync(List<int>.filled(2048, 3));
    // 正文按导入/插入后的真实写法：带 images/ 前缀
    sample = Note(
      id: 7,
      title: '带媒体的笔记',
      content: '正文\n\n![](images/7/a.png)\n\n![](images/7/v.mp4)\n',
      excerpt: '',
      charCount: 20,
      wordCount: 10,
      imageCount: 1,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Map<String, ArchiveFile> unzip(Uint8List bytes) => <String, ArchiveFile>{
    for (final f in ZipDecoder().decodeBytes(bytes))
      if (f.isFile) f.name: f,
  };

  /// 正文里所有 `![...](路径)` 的路径。
  List<String> refsInDoc(String doc) => <String>[
    for (final m in RegExp(r'!\[[^\]]*\]\(([^)]+)\)').allMatches(doc))
      if (!m.group(1)!.startsWith('http')) m.group(1)!.trim(),
  ];

  group('markdown', () {
    test('正文里每个引用都能在包里找到同名文件', () async {
      final zip = await NoteExporter.zipBytesAsync(
        items: <({List<String> path, Note note})>[
          (path: const <String>[], note: sample),
        ],
        format: ExportFormat.markdown,
        imageRoot: p.join(root.path, 'images'),
      );
      final files = unzip(zip);
      final doc = utf8.decode(files['带媒体的笔记.md']!.content as List<int>);

      final refs = refsInDoc(doc);
      // 媒体统一收进 `<笔记标题>.files/`：包里不该出现 `images/7/` 这种
      // 按 id 建的目录 —— 用户解压出来根本分不清哪张图属于哪篇。
      expect(refs, contains('带媒体的笔记.files/a.png'));
      expect(refs, contains('带媒体的笔记.files/v.mp4'));
      // 真正要保的性质：正文里引用的每一条，包里都得有同名条目，
      // 否则解压出来就是断链（以前 TXT 导出漏图就是这个原因）。
      for (final ref in refs) {
        expect(
          files.keys,
          contains(ref),
          reason: '正文引用了 $ref，包里却没有这个条目：${files.keys}',
        );
      }
    });
  });

  group('纯文本', () {
    test('图片和视频都要跟着进包', () async {
      final zip = await NoteExporter.zipBytesAsync(
        items: <({List<String> path, Note note})>[
          (path: const <String>[], note: sample),
        ],
        format: ExportFormat.text,
        imageRoot: p.join(root.path, 'images'),
      );
      final files = unzip(zip);
      expect(files.keys, contains('带媒体的笔记.files/a.png'));
      expect(files.keys, contains('带媒体的笔记.files/v.mp4'));
    });

    test('txt 正文里也写得出图片和视频两类', () async {
      final zip = await NoteExporter.zipBytesAsync(
        items: <({List<String> path, Note note})>[
          (path: const <String>[], note: sample),
        ],
        format: ExportFormat.text,
        imageRoot: p.join(root.path, 'images'),
      );
      final files = unzip(zip);
      final doc = utf8.decode(files['带媒体的笔记.txt']!.content as List<int>);
      expect(doc, contains('[图片]'));
      expect(doc, contains('[视频]'));
    });
  });

  group('docx', () {
    test('图片内嵌进文档，视频放进同名 .files 目录', () async {
      final zip = await NoteExporter.zipBytesAsync(
        items: <({List<String> path, Note note})>[
          (path: const <String>[], note: sample),
        ],
        format: ExportFormat.docx,
        imageRoot: p.join(root.path, 'images'),
      );
      final files = unzip(zip);
      // docx 本身又是一个 zip：图片要能在它内部找到，不能只是一句「[图片]」。
      final docx = files['带媒体的笔记.docx']!.content as List<int>;
      final inner = <String>{
        for (final f in ZipDecoder().decodeBytes(docx))
          if (f.isFile) f.name,
      };
      expect(
        inner.where((k) => k.startsWith('word/media/')).toList(),
        isNotEmpty,
        reason: 'docx 里没有图片：$inner',
      );
      // 视频跟着走（Word 塞不进去，放同名 .files）
      expect(
        files.keys.where((k) => k.endsWith('v.mp4')).toList(),
        isNotEmpty,
        reason: '视频没进包：${files.keys}',
      );
    });
  });

  group('pdf', () {
    test('正文里的图片真的嵌进了 PDF', () async {
      final zip = await NoteExporter.zipBytesAsync(
        items: <({List<String> path, Note note})>[
          (path: const <String>[], note: sample),
        ],
        format: ExportFormat.pdf,
        imageRoot: p.join(root.path, 'images'),
        pdfFont: await _pdfFont(),
      );
      final files = unzip(zip);
      final pdf = files['带媒体的笔记.pdf']!.content as List<int>;
      expect(pdf.sublist(0, 5), <int>[0x25, 0x50, 0x44, 0x46, 0x2D]); // %PDF-
      final text = latin1.decode(pdf, allowInvalid: true);
      expect(
        text.contains('/Subtype /Image') || text.contains('/Subtype/Image'),
        isTrue,
        reason: 'PDF 里没有图像对象',
      );
    });
  });
}

Future<ByteData> _pdfFont() async {
  final file = File('assets/fonts/NotoSansSC-GBK-Regular.ttf');
  final bytes = file.readAsBytesSync();
  return ByteData.sublistView(bytes);
}
