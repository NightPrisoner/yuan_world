/// 批量/文件夹导出：打成压缩包，且**包内保留目录结构**。
///
/// 以前"批量导出"是往用户选的文件夹里撒一堆散文件 —— 文集层级全丢了，
/// 导 200 篇就是 200 个文件平铺在一层，谁也认不出哪篇属于哪个文集。
library;

import 'dart:convert';
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
}
