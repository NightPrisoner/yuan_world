/// 文章目录：从正文里抽出标题结构。
///
/// 抽成纯函数是为了能直接测——目录最容易出的问题是
/// 「点进去跳错位置」，而那种错只有测过才放心。
library;

import 'text_stats.dart';

/// 目录里的一条。
class TocEntry {
  const TocEntry({
    required this.blockIndex,
    required this.level,
    required this.text,
  });

  /// 它在 [parseContent] 结果里的下标。
  ///
  /// 存下标而不是行号：渲染是按 block 走的，跳转要用的是同一个坐标，
  /// 换算成行号再换回来只会引入误差。
  final int blockIndex;

  /// 1..6，对应 `#` 的个数。
  final int level;

  final String text;

  /// 相对最浅一级的缩进层级，用于展示。
  int depthOf(int minLevel) => (level - minLevel).clamp(0, 5);
}

/// 去掉标题里的行内标记。
///
/// 正文渲染时 `**重点**` 会真的变粗，但目录是纯文本列表，
/// 留着星号只会显得脏。
String stripInlineMarkers(String s) => s
    .replaceAll(RegExp(r'\*\*|__|~~'), '')
    .replaceAll(RegExp(r'[*`_]'), '')
    .trim();

/// 抽出全部标题。没有标题就返回空列表。
List<TocEntry> extractToc(String markdown) {
  final blocks = parseContent(markdown);
  final out = <TocEntry>[];

  for (var i = 0; i < blocks.length; i++) {
    final b = blocks[i];
    if (b.type != ContentBlockType.heading) continue;
    final text = stripInlineMarkers(b.text);
    if (text.isEmpty) continue;
    out.add(TocEntry(blockIndex: i, level: b.level, text: text));
  }
  return out;
}

/// 目录里最浅的一级，用来算缩进。
int minTocLevel(List<TocEntry> entries) => entries.isEmpty
    ? 1
    : entries.map((e) => e.level).reduce((a, b) => a < b ? a : b);
