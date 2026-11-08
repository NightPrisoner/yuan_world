import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/data/exporter/pdf_exporter.dart';
import 'package:yuan_world/data/models.dart';

/// 真实字体：PDF 必须内嵌中文字形，所以测试也得用真的那一份。
Future<ByteData> loadFont() async {
  final bytes =
      File('assets/fonts/NotoSansSC-GBK-Regular.ttf').readAsBytesSync();
  return ByteData.sublistView(bytes);
}

Note note({
  String title = '测试笔记',
  required String content,
  DateTime? createdAt,
}) {
  final t = createdAt ?? DateTime(2026, 3, 1, 9, 30);
  return Note(
    id: 1,
    title: title,
    content: content,
    excerpt: '',
    createdAt: t,
    updatedAt: t,
    charCount: content.length,
  );
}

void main() {
  test('纯中文正文能导出，且是合法 PDF', () async {
    final font = await loadFont();
    final bytes = await PdfExporter.renderBytes(
      note(content: '第一段中文。\n\n第二段还有中文，标点：，。！？「」'),
      font: font,
    );
    expect(bytes.length, greaterThan(1000));
    // %PDF- 魔数
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    // 字体被嵌进去了（子集化的 Type0 字体）
    final text = String.fromCharCodes(bytes.where((b) => b > 8 && b < 127));
    expect(text.contains('FontFile2'), isTrue);
  });

  test('各种块级元素都能过', () async {
    final font = await loadFont();
    final bytes = await PdfExporter.renderBytes(
      note(
        content: [
          '# 一级标题',
          '',
          '## 二级标题',
          '',
          '正文有 **粗体**、~~删除线~~、*斜体*、`行内代码`。',
          '',
          '> 引用一行',
          '',
          '- 无序项',
          '- [ ] 待办',
          '- [x] 已办',
          '',
          '1. 有序项',
          '',
          '```',
          'code here',
          '```',
          '',
          '---',
        ].join('\n'),
      ),
      font: font,
    );
    expect(bytes.length, greaterThan(1000));
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test('emoji 和字体里没有的符号不会让导出失败', () async {
    final font = await loadFont();
    // 这几类在内嵌的 GBK 子集里都没有；不清理的话 pdf 包会直接抛
    // "Missing glyph for character ..."
    final bytes = await PdfExporter.renderBytes(
      note(content: '开心 😂🎉 星星 ✧❤ 组合 é 空格\u00a0结束'),
      font: font,
    );
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test('长文会分页，页数大于 1', () async {
    final font = await loadFont();
    final long = List.generate(120, (i) => '第 $i 段正文，写点东西凑长度。').join('\n\n');
    final bytes = await PdfExporter.renderBytes(
      note(content: long),
      font: font,
    );
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    // 统计 /Type /Page 出现次数（粗略）
    final s = String.fromCharCodes(bytes.where((b) => b > 8 && b < 127));
    final pages = RegExp(r'/Type\s*/Page[^s]').allMatches(s).length;
    expect(pages, greaterThan(1));
  });

  test('视频块留一行说明，图片不存在就跳过', () async {
    final font = await loadFont();
    final bytes = await PdfExporter.renderBytes(
      note(content: '![视频](videos/a.mp4)\n\n![图](nope.png)\n\n收尾'),
      font: font,
    );
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test('一整段超长正文（单段落几万字）也能导出，不会卡死', () async {
    // 用户报的正是这个：长文点导出没反应。
    // 根因是段落整块塞进一个 pw.Text / pw.RichText，而它们默认
    // overflow: visible ⇒ 不是 SpanningWidget ⇒ 高度超过一页就抛
    // "Widget won't fit into the page as its height ... exceed a page height"。
    final font = await loadFont();
    final oneParagraph = List.generate(
      900,
      (i) => '这是第 $i 句，用来把单独一段撑到远超一页的高度。',
    ).join();
    final bytes = await PdfExporter.renderBytes(
      note(content: oneParagraph),
      font: font,
    );
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
    final s = String.fromCharCodes(bytes.where((b) => b > 8 && b < 127));
    final pages = RegExp(r'/Type\s*/Page[^s]').allMatches(s).length;
    expect(pages, greaterThan(3));
  });

  test('超长引用、超长代码块、超长列表项都不抛异常', () async {
    final font = await loadFont();
    final long = List.generate(700, (i) => '第 $i 行内容需要足够长以撑满整页空间。').join(' ');
    final bytes = await PdfExporter.renderBytes(
      note(
        content: '> $long\n\n```\n$long\n```\n\n- $long\n\n1. $long\n\n收尾',
      ),
      font: font,
    );
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });
}
