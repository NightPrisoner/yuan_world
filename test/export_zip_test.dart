/// 批量/文件夹导出：打成压缩包，且**包内保留目录结构**。
///
/// 以前"批量导出"是往用户选的文件夹里撒一堆散文件 —— 文集层级全丢了，
/// 导 200 篇就是 200 个文件平铺在一层，谁也认不出哪篇属于哪个文集。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/data/exporter/note_exporter.dart';
import 'package:yuan_world/data/models.dart';

Note note(int id, String title, {int? collectionId}) => Note(
  id: id,
  title: title,
  content: '# 小节\n\n正文。',
  excerpt: '',
  charCount: 10,
  wordCount: 5,
  imageCount: 0,
  collectionId: collectionId,
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
);

List<String> entries(Uint8List bytes) => <String>[
  for (final f in ZipDecoder().decodeBytes(bytes))
    if (f.isFile) f.name,
];

void main() {
  test('每篇一个 docx，包里能按文集层级找回来', () {
    final zip = NoteExporter.zipBytes(
      items: <({List<String> path, Note note})>[
        (path: <String>['文集', '小小说'], note: note(1, '第一篇')),
        (path: <String>['文集'], note: note(2, '第二篇')),
        (path: <String>[], note: note(3, '没归类的')),
      ],
    );
    final names = entries(zip);
    expect(names.length, 3);
    expect(names, contains('文集/小小说/第一篇.docx'));
    expect(names, contains('文集/第二篇.docx'));
    expect(names, contains('没归类的.docx'));
  });

  test('同名笔记不会互相覆盖', () {
    final zip = NoteExporter.zipBytes(
      items: <({List<String> path, Note note})>[
        (path: <String>[], note: note(1, '无题')),
        (path: <String>[], note: note(2, '无题')),
        (path: <String>[], note: note(3, '无题')),
      ],
    );
    final names = entries(zip);
    expect(names.length, 3, reason: '有同名被覆盖了');
    expect(names.toSet().length, 3);
    expect(names, contains('无题 (2).docx'));
  });

  test('文集名里的非法字符不会伪造出目录层级', () {
    // 名字里带斜杠：不处理的话会凭空多出一层，甚至写到包外面
    final zip = NoteExporter.zipBytes(
      items: <({List<String> path, Note note})>[
        (path: <String>['a/b', 'c:d'], note: note(1, '标题')),
      ],
    );
    final names = entries(zip);
    expect(names.length, 1);
    expect(names.single, 'a_b/c_d/标题.docx');
    expect(names.single.split('/').length, 3, reason: '层级数被改变了');
  });

  test('压缩包名会把非法字符换掉', () {
    expect(NoteExporter.safeZipName('文集/2024'), '文集_2024');
    expect(NoteExporter.safeZipName('   '), '元世界导出');
  });

  test('包里就是能打开的 docx（带 styles.xml）', () {
    final zip = NoteExporter.zipBytes(
      items: <({List<String> path, Note note})>[(path: <String>[], note: note(1, '标题'))],
    );
    final docx = ZipDecoder()
        .decodeBytes(zip)
        .files
        .firstWhere((f) => f.name.endsWith('.docx'));
    final inner = <String, String>{
      for (final f in ZipDecoder().decodeBytes(docx.content as List<int>))
        if (f.isFile) f.name: utf8.decode(f.content as List<int>, allowMalformed: true),
    };
    expect(inner.keys, contains('word/document.xml'));
    expect(inner.keys, contains('word/styles.xml'));
    expect(inner['word/document.xml'], contains('小节'));
  });

  test('markdown 格式导出的是 .md，不是二进制', () {
    final zip = NoteExporter.zipBytes(
      items: <({List<String> path, Note note})>[(path: <String>[], note: note(1, '标题'))],
      format: ExportFormat.markdown,
    );
    final names = entries(zip);
    expect(names.single, '标题.md');
    final content = utf8.decode(
      ZipDecoder().decodeBytes(zip).files.single.content as List<int>,
      allowMalformed: true,
    );
    expect(content, contains('小节'));
  });

  test('空列表给一个合法的空压缩包，不抛', () {
    final zip = NoteExporter.zipBytes(items: const []);
    expect(entries(zip), isEmpty);
  });

  test('同步 zipBytes 不接受 PDF（要走异步版）', () {
    expect(
      () => NoteExporter.zipBytes(
        items: <({List<String> path, Note note})>[
          (path: <String>[], note: note(1, '标题')),
        ],
        format: ExportFormat.pdf,
      ),
      throwsArgumentError,
    );
  });

  test('异步版能把多篇导成 PDF，包内仍是文集层级', () async {
    final font = ByteData.sublistView(
      File('assets/fonts/NotoSansSC-GBK-Regular.ttf').readAsBytesSync(),
    );
    final zip = await NoteExporter.zipBytesAsync(
      items: <({List<String> path, Note note})>[
        (path: <String>['文集'], note: note(1, '第一篇')),
        (path: <String>['文集'], note: note(2, '第二篇')),
      ],
      format: ExportFormat.pdf,
      pdfFont: font,
    );
    final names = entries(zip);
    expect(names.length, 2);
    expect(names, containsAll(<String>['文集/第一篇.pdf', '文集/第二篇.pdf']));
    // 真 PDF：魔数对得上，而且字体被嵌进去了（否则中文会变方框）
    final first = ZipDecoder().decodeBytes(zip).files.first;
    final bytes = first.content as List<int>;
    expect(ascii.decode(bytes.sublist(0, 5)), '%PDF-');
    expect(latin1.decode(bytes), contains('FontFile2'));
  });

  test('异步版导非 PDF 格式，结果和同步版一致', () async {
    final items = <({List<String> path, Note note})>[
      (path: <String>['文集'], note: note(1, '第一篇')),
    ];
    final sync = entries(
      NoteExporter.zipBytes(items: items, format: ExportFormat.markdown),
    );
    final async = entries(
      await NoteExporter.zipBytesAsync(
        items: items,
        format: ExportFormat.markdown,
      ),
    );
    expect(async, sync);
  });

  test('异步版导 PDF 没给字体就报错，不会悄悄退化成别的格式', () async {
    await expectLater(
      NoteExporter.zipBytesAsync(
        items: <({List<String> path, Note note})>[
          (path: <String>[], note: note(1, '标题')),
        ],
        format: ExportFormat.pdf,
      ),
      throwsArgumentError,
    );
  });

  group('带进度与取消的打包', () {
    List<({List<String> path, Note note})> many(int n) =>
        <({List<String> path, Note note})>[
          for (var i = 0; i < n; i++)
            (path: <String>['文集'], note: note(i + 1, '第$i篇')),
        ];

    test('进度从 0 一路涨到 1，中途不会回退', () async {
      final seen = <double>[];
      final zip = await NoteExporter.zipBytesProgressive(
        items: many(6),
        format: ExportFormat.markdown,
        onProgress: seen.add,
      );
      expect(entries(zip).length, 6);
      expect(seen, isNotEmpty, reason: '一次进度都没回调，进度条就是死的');
      expect(seen.last, 1.0, reason: '收尾要落到 1.0，否则进度条永远差一格');
      for (var i = 1; i < seen.length; i++) {
        expect(
          seen[i],
          greaterThanOrEqualTo(seen[i - 1]),
          reason: '进度回退了：$seen',
        );
      }
    });

    test('每处理完一篇就回调一次，不是全干完才报一次', () async {
      final seen = <double>[];
      await NoteExporter.zipBytesProgressive(
        items: many(4),
        format: ExportFormat.markdown,
        onProgress: seen.add,
      );
      // 4 篇 → 至少 4 次逐步推进 + 最后一次兜底 1.0
      expect(seen.length, greaterThanOrEqualTo(4));
      expect(seen.first, closeTo(1 / 4, 1e-9));
    });

    test('取消之后抛 ExportCancelledException，不会返回半个包', () async {
      var calls = 0;
      await expectLater(
        NoteExporter.zipBytesProgressive(
          items: many(5),
          format: ExportFormat.markdown,
          // 第一次问「要不要取消」就说要 —— 也就是刚开工就取消
          isCancelled: () => ++calls > 1,
        ),
        throwsA(isA<ExportCancelledException>()),
      );
    });

    test('取消时一篇都没写，进度也不会报 1.0', () async {
      final seen = <double>[];
      try {
        await NoteExporter.zipBytesProgressive(
          items: many(5),
          format: ExportFormat.markdown,
          onProgress: seen.add,
          isCancelled: () => true,
        );
        fail('应该抛 ExportCancelledException');
      } on ExportCancelledException {
        // 预期
      }
      expect(seen, isEmpty, reason: '刚开工就取消，不该报任何进度');
    });

    test('PDF 带进度也能取消', () async {
      final font = ByteData.sublistView(
        File('assets/fonts/NotoSansSC-GBK-Regular.ttf').readAsBytesSync(),
      );
      var calls = 0;
      await expectLater(
        NoteExporter.zipBytesProgressive(
          items: many(3),
          format: ExportFormat.pdf,
          pdfFont: font,
          isCancelled: () => ++calls > 1,
        ),
        throwsA(isA<ExportCancelledException>()),
      );
    });
  });
}
