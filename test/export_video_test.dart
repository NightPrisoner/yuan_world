/// 导出里的**视频**：不能再被当成图片，也不能凭空消失。
///
/// 背景（用户报的两个 bug）：
///   1. 文件夹导出出来的 docx **一个字都没有** —— 因为取笔记时走了
///      不含 `content` 列的轻量查询；
///   2. 笔记里的视频导出后**不见了** —— 数据库里视频块和图片块是同一个
///      `ContentBlockType.image`（界面靠扩展名区分），导出器不分青红皂白
///      把 mp4 当图片塞进 `word/media`，Word 里就是个红叉。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yuan_world/data/exporter/note_exporter.dart';
import 'package:yuan_world/data/models.dart';

Note videoNote({int id = 1, String title = '带视频的笔记'}) => Note(
  id: id,
  title: title,
  content: '开场白。\n\n![](7/clip.mp4)\n\n![](7/shot.png)\n\n结尾。',
  excerpt: '',
  charCount: 30,
  wordCount: 10,
  imageCount: 1,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

/// 一个最小的合法 PNG（1×1），给"图片仍然要嵌进去"那条断言用。
final Uint8List kPng = base64.decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8DwHwAFAAH/'
  'q842iQAAAABJRU5ErkJggg==',
);

ArchiveFile? findFile(Archive a, String name) {
  for (final f in a) {
    if (f.name == name) return f;
  }
  return null;
}

String entryText(Archive a, String name) {
  final f = findFile(a, name);
  if (f == null) return '';
  return utf8.decode(f.content as List<int>, allowMalformed: true);
}

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('yw_export_video');
    Directory(p.join(root.path, '7')).createSync(recursive: true);
    // 假的 mp4：内容不重要，重要的是**扩展名**决定它是不是视频
    File(p.join(root.path, '7', 'clip.mp4'))
        .writeAsBytesSync(List<int>.filled(2048, 7));
    File(p.join(root.path, '7', 'shot.png')).writeAsBytesSync(kPng);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('docx 里不再把 mp4 当图片塞进 word/media', () {
    final bytes = NoteExporter.renderDocxBytes(
      videoNote(),
      imageRoot: root.path,
    );
    final a = ZipDecoder().decodeBytes(bytes);
    expect(findFile(a, 'word/media/image1.png'), isNotNull,
        reason: '真图片还是要嵌进去');
    final media = <String>[
      for (final f in a)
        if (f.name.startsWith('word/media/')) f.name,
    ];
    expect(media.length, 1, reason: 'mp4 被当成图片塞进来了: $media');
  });

  test('docx 正文里留得下视频的痕迹，且写明了去哪找', () {
    final bytes = NoteExporter.renderDocxBytes(
      videoNote(),
      imageRoot: root.path,
    );
    final xml = entryText(ZipDecoder().decodeBytes(bytes), 'word/document.xml');
    expect(xml, contains('clip.mp4'), reason: '视频文件名必须看得见');
    expect(xml, contains('.files'), reason: '要告诉用户视频放在哪个文件夹');
    expect(xml, contains('带视频的笔记.files'));
  });

  test('压缩包里视频文件跟着走，docx 说的目录和实际一致', () {
    final zip = NoteExporter.zipBytes(
      items: <({List<String> path, Note note})>[
        (path: <String>['文集'], note: videoNote()),
      ],
      imageRoot: root.path,
    );
    final a = ZipDecoder().decodeBytes(zip);
    final names = <String>[
      for (final f in a)
        if (f.isFile) f.name,
    ];
    expect(names, contains('文集/带视频的笔记.docx'));
    expect(names, contains('文集/带视频的笔记.files/clip.mp4'));
    // 正文点名的目录必须是包里真有的那个。docx 在包里面，要再解一层
    final docx = ZipDecoder().decodeBytes(
      findFile(a, '文集/带视频的笔记.docx')!.content as List<int>,
    );
    final xml = entryText(docx, 'word/document.xml');
    expect(xml, contains('带视频的笔记.files'));
    expect(findFile(a, '文集/带视频的笔记.files/clip.mp4')!.size, 2048);
  });

  test('同名笔记加序号后，视频目录也跟着改（否则正文指向不存在的目录）', () {
    final zip = NoteExporter.zipBytes(
      items: <({List<String> path, Note note})>[
        (path: <String>[], note: videoNote(id: 1, title: '无题')),
        (path: <String>[], note: videoNote(id: 2, title: '无题')),
      ],
      imageRoot: root.path,
    );
    final names = <String>[
      for (final f in ZipDecoder().decodeBytes(zip))
        if (f.isFile) f.name,
    ];
    expect(names, contains('无题 (2).docx'));
    expect(names, contains('无题 (2).files/clip.mp4'),
        reason: '视频目录名没跟着去重后的文件名走');
  });

  test('markdown 导出：视频用原始相对路径，解压后链接不断', () {
    final zip = NoteExporter.zipBytes(
      items: <({List<String> path, Note note})>[
        (path: <String>[], note: videoNote()),
      ],
      format: ExportFormat.markdown,
      imageRoot: root.path,
    );
    final names = <String>[
      for (final f in ZipDecoder().decodeBytes(zip))
        if (f.isFile) f.name,
    ];
    expect(names, contains('带视频的笔记.md'));
    expect(names, contains('7/clip.mp4'));
    final md = entryText(ZipDecoder().decodeBytes(zip), '带视频的笔记.md');
    expect(md, contains('![](7/clip.mp4)'));
  });

  test('markdown 正文不写 .files 目录名（那是 docx 的约定）', () {
    final zip = NoteExporter.zipBytes(
      items: <({List<String> path, Note note})>[
        (path: <String>[], note: videoNote()),
      ],
      format: ExportFormat.markdown,
      imageRoot: root.path,
    );
    final md = entryText(ZipDecoder().decodeBytes(zip), '带视频的笔记.md');
    expect(md, isNot(contains('.files')));
  });

  test('HTML 里视频走 <video>，不做 base64 内联', () {
    final html = NoteExporter.render(
      videoNote(),
      ExportFormat.html,
      imageRoot: root.path,
    );
    expect(html, contains('<video'));
    expect(html, contains('src="7/clip.mp4"'));
    // 图片仍然是内联的 data URI
    expect(html, contains('data:image/png;base64,'));
  });

  test('纯文本里区分 [视频] 和 [图片]', () {
    final txt = NoteExporter.render(videoNote(), ExportFormat.text);
    expect(txt, contains('[视频] 7/clip.mp4'));
    expect(txt, contains('[图片] 7/shot.png'));
  });

  test('视频文件不在了也不至于让整篇导出失败', () {
    File(p.join(root.path, '7', 'clip.mp4')).deleteSync();
    final zip = NoteExporter.zipBytes(
      items: <({List<String> path, Note note})>[
        (path: <String>[], note: videoNote()),
      ],
      imageRoot: root.path,
    );
    final names = <String>[
      for (final f in ZipDecoder().decodeBytes(zip))
        if (f.isFile) f.name,
    ];
    expect(names, contains('带视频的笔记.docx'));
    expect(names.where((n) => n.endsWith('.mp4')), isEmpty);
  });

  test('单篇导出：视频被拷到 docx 旁边的 .files 目录里', () {
    final docxPath = p.join(root.path, 'out', '我的笔记.docx');
    Directory(p.dirname(docxPath)).createSync(recursive: true);
    File(docxPath).writeAsBytesSync(<int>[1, 2, 3]);

    final copied = NoteExporter.copyVideosNextTo(
      docxPath,
      videoNote(),
      imageRoot: root.path,
    );
    expect(copied, 1);
    expect(
      File(p.join(root.path, 'out', '我的笔记.files', 'clip.mp4')).existsSync(),
      isTrue,
    );
  });

  test('单篇导出：没有视频时不凭空建目录', () {
    final docxPath = p.join(root.path, 'out2', '没视频.docx');
    Directory(p.dirname(docxPath)).createSync(recursive: true);
    final plain = Note(
      id: 9,
      title: '没视频',
      content: '只有文字。',
      excerpt: '',
      charCount: 4,
      wordCount: 4,
      imageCount: 0,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
    expect(NoteExporter.copyVideosNextTo(docxPath, plain, imageRoot: root.path), 0);
    expect(Directory(p.join(root.path, 'out2', '没视频.files')).existsSync(),
        isFalse);
  });

  test('超大视频不硬塞进包，正文如实说明（不能谎称已放入文件夹）', () {
    final zip = NoteExporter.zipBytes(
      items: <({List<String> path, Note note})>[
        (path: <String>[], note: videoNote()),
      ],
      imageRoot: root.path,
      // 把上限压到 1 字节，等价于"这个视频超大"
      maxVideoBytes: 1,
    );
    final a = ZipDecoder().decodeBytes(zip);
    final names = <String>[
      for (final f in a)
        if (f.isFile) f.name,
    ];
    expect(names, contains('带视频的笔记.docx'));
    expect(names.where((n) => n.endsWith('.mp4')), isEmpty);

    final docx = ZipDecoder().decodeBytes(
      findFile(a, '带视频的笔记.docx')!.content as List<int>,
    );
    final xml = entryText(docx, 'word/document.xml');
    expect(xml, contains('未随导出打包'));
    expect(xml, isNot(contains('已随导出放入')),
        reason: '文件明明没在包里，不能说已放入');
  });

  test('videoRelsOf 去重且保持出现顺序', () {
    final n = videoNote();
    final note = Note(
      id: n.id,
      title: n.title,
      content: '![](a.mp4)\n\n![](b.png)\n\n![](a.mp4)',
      excerpt: '',
      charCount: 0,
      wordCount: 0,
      imageCount: 0,
      createdAt: n.createdAt,
      updatedAt: n.updatedAt,
    );
    expect(NoteExporter.videoRelsOf(note), <String>['a.mp4']);
  });
}
