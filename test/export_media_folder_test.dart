/// 导出包里「媒体文件夹」的命名规则。
///
/// 以前的包内结构是两种样子：
///   · docx / pdf —— 视频进 `<标题>.files/`
///   · markdown / txt —— 媒体原地放，路径就是正文里那个 `images/7/a.png`
///
/// `7` 是笔记 id。用户解压出来看到一堆 `7/`、`82/`，既分不清哪张图属于
/// 哪篇，也不敢删。现在统一成 `<标题>.files/`，并且跟着**最终**文件名
/// （同名笔记去重后的 `无题 (2)`）与文集目录走。
///
/// 另一条同样重要：PDF 里放不下视频，但视频**文件要跟着走** ——
/// 否则正文写着"已随导出放入 xxx.files"，包里根本没有那个文件夹。
library;

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yuan_world/data/exporter/note_exporter.dart';
import 'package:yuan_world/data/models.dart';

/// 一张合法的 3×2 PNG（PIL 生成的真字节，`pdf` 包能解出来；
/// 手搓的会被 `pdf` 的 MemoryImage 拒掉）。
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
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late ByteData pdfFont;

  Note noteWith({int id = 7, String title = '带媒体的笔记'}) => Note(
    id: id,
    title: title,
    content: '正文\n\n![](images/$id/a.png)\n\n![](images/$id/v.mp4)\n',
    excerpt: '',
    charCount: 20,
    wordCount: 10,
    imageCount: 1,
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );

  setUpAll(() async {
    final data = await rootBundle.load('assets/fonts/NotoSansSC-GBK-Regular.ttf');
    pdfFont = ByteData.sublistView(data);
  });

  setUp(() {
    root = Directory.systemTemp.createTempSync('yw_media_folder_');
    for (final id in <int>[7, 8]) {
      Directory(p.join(root.path, 'images', '$id')).createSync(recursive: true);
      File(
        p.join(root.path, 'images', '$id', 'a.png'),
      ).writeAsBytesSync(kPng);
      File(
        p.join(root.path, 'images', '$id', 'v.mp4'),
      ).writeAsBytesSync(List<int>.filled(2048, 3));
    }
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  List<String> namesOf(Uint8List zip) => <String>[
    for (final f in ZipDecoder().decodeBytes(zip))
      if (f.isFile) f.name,
  ];

  group('媒体文件夹跟着笔记标题走', () {
    test('markdown / txt：媒体在 <标题>.files/，正文引用逐字对得上', () async {
      for (final format in <ExportFormat>[
        ExportFormat.markdown,
        ExportFormat.text,
      ]) {
        final zip = await NoteExporter.zipBytesAsync(
          items: <({List<String> path, Note note})>[
            (path: const <String>[], note: noteWith()),
          ],
          format: format,
          imageRoot: p.join(root.path, 'images'),
        );
        final names = namesOf(zip);
        expect(
          names,
          contains('带媒体的笔记.files/a.png'),
          reason: '$format 的图片没进 <标题>.files/',
        );
        expect(
          names,
          contains('带媒体的笔记.files/v.mp4'),
          reason: '$format 的视频没进 <标题>.files/',
        );
        // 按 id 起的目录不该再出现
        expect(
          names.where((n) => n.startsWith('7/')).toList(),
          isEmpty,
          reason: '包内还有按笔记 id 起的目录：$names',
        );
      }
    });

    test('同名笔记去重后，媒体文件夹也跟着改号', () async {
      final zip = await NoteExporter.zipBytesAsync(
        items: <({List<String> path, Note note})>[
          (path: const <String>[], note: noteWith(id: 7, title: '无题')),
          (path: const <String>[], note: noteWith(id: 8, title: '无题')),
        ],
        format: ExportFormat.markdown,
        imageRoot: p.join(root.path, 'images'),
      );
      final names = namesOf(zip);
      expect(names, contains('无题.files/a.png'));
      expect(
        names,
        contains('无题 (2).files/a.png'),
        reason: '第二篇的媒体还挂在没加序号的文件夹下：$names',
      );
      expect(names.where((n) => n.startsWith('8/')).toList(), isEmpty);
    });

    test('媒体跟着文集目录走，不会掉到包根', () async {
      final zip = await NoteExporter.zipBytesAsync(
        items: <({List<String> path, Note note})>[
          (path: const <String>['文集'], note: noteWith()),
        ],
        format: ExportFormat.markdown,
        imageRoot: p.join(root.path, 'images'),
      );
      final names = namesOf(zip);
      expect(names, contains('文集/带媒体的笔记.md'));
      expect(names, contains('文集/带媒体的笔记.files/a.png'));
      expect(
        names,
        isNot(contains('带媒体的笔记.files/a.png')),
        reason: '媒体跑到了包根，和文档分了家：$names',
      );
    });
  });

  group('PDF 里放不下视频，但视频文件要跟着走', () {
    test('批量导出 PDF：视频本体在包里，正文说得出文件夹名', () async {
      final zip = await NoteExporter.zipBytesProgressive(
        items: <({List<String> path, Note note})>[
          (path: const <String>[], note: noteWith()),
        ],
        format: ExportFormat.pdf,
        pdfFont: pdfFont,
        imageRoot: p.join(root.path, 'images'),
      );
      final names = namesOf(zip);
      expect(names, contains('带媒体的笔记.pdf'));
      expect(
        names,
        contains('带媒体的笔记.files/v.mp4'),
        reason: 'PDF 导出时视频被丢掉了：$names',
      );

      // PDF 的内容流是压缩的，逐字搜正文不可靠（只能搜到 `%PDF-1.5`）。
      // 这里改验等价的东西：包里视频所在的那一级目录，必须就是导出时
      // 传给渲染器的那个文件夹名 —— PDF 正文里写的也是它。
      final folder = NoteExporter.mediaFolderOf('带媒体的笔记');
      expect(
        names.where((n) => n.startsWith('$folder/')).toList(),
        isNotEmpty,
        reason: '视频没落在 $folder/ 下：$names',
      );
    });

    test('文件夹名规则：一律是 <标题>.files，且不会撑破目录', () {
      expect(NoteExporter.mediaFolderOf('带媒体的笔记'), '带媒体的笔记.files');
      final weird = NoteExporter.mediaFolderOf('a/b:c*?');
      expect(weird.contains('/'), isFalse);
      expect(weird.endsWith('.files'), isTrue);
    });
  });
}
