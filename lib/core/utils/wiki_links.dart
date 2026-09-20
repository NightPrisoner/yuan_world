/// `[[双链]]` 的解析。
///
/// ## 为什么是"解析"而不是"建表"
///
/// 双链的本质是"正文里写了一个别的笔记的标题"。做成 `note_links` 表当然
/// 更"正规"，但要在**每个写入路径**（编辑保存、导入、批量改标题）都维护
/// 一张派生表 —— 漏一处，链接就悄悄错位，而且错得没人知道。这个库是
/// 本地 SQLite、几百到几千篇笔记，`content LIKE '%[[标题]]%'` 是常数级
/// 的扫描，代价远小于"派生表不同步"的风险。
///
/// 所以：**正文是唯一真源**，反向链接在读取时现算（见
/// `NoteRepository.backlinksOf`）。哪天笔记量真到了 LIKE 撑不住，
/// 再谈建表 + 在写入路径统一维护。
library;

/// 正文里的一处 `[[…]]`。
class WikiLink {
  const WikiLink({required this.target, required this.label, required this.start});

  /// 目标笔记的标题。
  final String target;

  /// 显示出来的文字。`[[标题|显示名]]` 时是显示名，否则等于标题。
  final String label;

  /// 在正文里的起始下标（用于测试和精确定位）。
  final int start;

  @override
  String toString() => 'WikiLink($target @$start)';
}

/// `[[标题]]`：方括号里的第一个 `|` 后面是显示名（可选）。
///
/// 不允许嵌套方括号、不允许跨行 —— 标题里本来也不该有这些。
final RegExp kWikiLinkPattern = RegExp(r'\[\[([^\[\]\n]+)\]\]');

/// 找出正文里所有的双链。
///
/// 空标题（`[[]]` / `[[  ]]`）直接忽略：它指不到任何东西，
/// 渲染成一个"点了没反应的链接"比不认更糟。
List<WikiLink> parseWikiLinks(String text) {
  final out = <WikiLink>[];
  for (final m in kWikiLinkPattern.allMatches(text)) {
    final raw = m.group(1)!;
    final bar = raw.indexOf('|');
    final target = (bar < 0 ? raw : raw.substring(0, bar)).trim();
    if (target.isEmpty) continue;
    final label = (bar < 0 ? raw : raw.substring(bar + 1)).trim();
    out.add(WikiLink(
      target: target,
      label: label.isEmpty ? target : label,
      start: m.start,
    ));
  }
  return out;
}

/// 正文里出现过的所有目标标题（去重、保持出现顺序）。
///
/// 反向链接查询用它：一篇笔记的标题可能有 `[[标题]]` 和 `[[标题|换个说法]]`
/// 两种写法，去重之后只需查一次。
List<String> wikiTargetsIn(String text) {
  final seen = <String>{};
  final out = <String>[];
  for (final l in parseWikiLinks(text)) {
    if (seen.add(l.target)) out.add(l.target);
  }
  return out;
}
