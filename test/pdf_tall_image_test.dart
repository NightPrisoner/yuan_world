/// 竖长图（手机截图那种 1080×2400）导出 PDF 不能崩。
///
/// 用户报的是「有图片视频时 pdf 无法导出，显示有一段内容太高，一页放不下」。
/// 根因不在文字，在图片：`pw.ConstrainedBox` 当时只给了 `maxWidth: 400`，
/// 而 `pw.Image.layout` 在高度有界时会把 `constraints.maxHeight` 直接
/// 当成目标高度 —— 400 宽、1080×2400 的图等比算出 ~889pt 高，比 A4 一页
/// 能放的 754pt 还大，`MultiPage` 于是抛 `Widget won't fit into the page`。
///
/// 所以这组测试用的图**特意做成又高又窄**，文字那段保持很短：如果哪天
/// 有人把高度上限又去掉，这里会立刻红。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yuan_world/data/exporter/note_exporter.dart';
import 'package:yuan_world/data/exporter/pdf_exporter.dart';
import 'package:yuan_world/data/models.dart';

/// 一张 9×16 的 PNG（正好是手机截图的形状）。PIL 生成的真字节。
final List<int> kTallPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x10,
  0x08, 0x02, 0x00, 0x00, 0x00, 0x4B, 0x2A, 0xC2,
  0x14, 0x00, 0x00, 0x00, 0x19, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x94, 0xAB, 0x38, 0xC1,
  0x80, 0x03, 0x30, 0xE1, 0x92, 0x60, 0x18, 0x95,
  0xC3, 0x05, 0xE8, 0x1D, 0x66, 0x00, 0x7E, 0xF8,
  0x01, 0x7E, 0x2C, 0x23, 0xC3, 0x63, 0x00, 0x00,
  0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42,
  0x60, 0x82,
];

Future<ByteData> _font() async {
  final bytes = File('assets/fonts/NotoSansSC-GBK-Regular.ttf').readAsBytesSync();
  return ByteData.sublistView(bytes);
}

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('yw_pdf_tall_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Note noteWith(String content) => Note(
    id: 1,
    title: '竖图',
    content: content,
    excerpt: '',
    charCount: content.length,
    wordCount: 0,
    imageCount: 1,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );

  test('一张竖长图（9:16）能导出，不再报「一页放不下」', () async {
    final dir = Directory(p.join(root.path, 'images', '1'))..createSync(recursive: true);
    File(p.join(dir.path, 'shot.png')).writeAsBytesSync(kTallPng);

    final bytes = await PdfExporter.renderBytes(
      noteWith('正文\n\n![](images/1/shot.png)\n\n尾注\n'),
      font: await _font(),
      imageRoot: p.join(root.path, 'images'),
    );
    expect(bytes.sublist(0, 5), <int>[0x25, 0x50, 0x44, 0x46, 0x2D]);
    expect(bytes.length, greaterThan(1000));
  });

  test('连着好几张竖长图也能导出（每张各自受高度限制）', () async {
    final dir = Directory(p.join(root.path, 'images', '1'))..createSync(recursive: true);
    for (var i = 0; i < 4; i++) {
      File(p.join(dir.path, 's$i.png')).writeAsBytesSync(kTallPng);
    }
    final content = StringBuffer('正文\n\n');
    for (var i = 0; i < 4; i++) {
      content.write('![](images/1/s$i.png)\n\n');
    }
    final bytes = await PdfExporter.renderBytes(
      noteWith(content.toString()),
      font: await _font(),
      imageRoot: p.join(root.path, 'images'),
    );
    expect(bytes.sublist(0, 5), <int>[0x25, 0x50, 0x44, 0x46, 0x2D]);
  });

  test('图文混排 + 视频（视频只留一行说明）不会让整篇失败', () async {
    final dir = Directory(p.join(root.path, 'images', '1'))..createSync(recursive: true);
    File(p.join(dir.path, 'shot.png')).writeAsBytesSync(kTallPng);
    File(p.join(dir.path, 'v.mp4')).writeAsBytesSync(List<int>.filled(64, 1));

    final bytes = await PdfExporter.renderBytes(
      noteWith(
        '# 标题\n\n正文一段。\n\n![](images/1/shot.png)\n\n'
        '![](images/1/v.mp4)\n\n- 列表甲\n- 列表乙\n',
      ),
      font: await _font(),
      imageRoot: p.join(root.path, 'images'),
    );
    expect(bytes.sublist(0, 5), <int>[0x25, 0x50, 0x44, 0x46, 0x2D]);
  });

  test('整包导出 PDF 也走得通（不是只有单篇那条路好）', () async {
    final dir = Directory(p.join(root.path, 'images', '1'))..createSync(recursive: true);
    File(p.join(dir.path, 'shot.png')).writeAsBytesSync(kTallPng);

    final zip = await NoteExporter.zipBytesAsync(
      items: <({List<String> path, Note note})>[
        (path: const <String>[], note: noteWith('正文\n\n![](images/1/shot.png)\n')),
      ],
      format: ExportFormat.pdf,
      imageRoot: p.join(root.path, 'images'),
      pdfFont: await _font(),
    );
    expect(zip.length, greaterThan(1000));
  });
}
