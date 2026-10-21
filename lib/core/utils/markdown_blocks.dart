/// Markdown 块级语法的**唯一一份**定义。
///
/// 为什么要有这个文件：编辑器（`MarkdownStyler`）和阅读页（`parseContent`）
/// 以前各写一套正则，两套规则悄悄长歪了 —— 同一行文字在编辑时是分隔线、
/// 读的时候是普通段落；编辑时看不出是代码块、读的时候是灰底等宽字体。
/// 这种"写的时候一个样、读的时候另一个样"是最伤信任的 bug。
///
/// 所以块级识别全部收在这里，两边只做**渲染**上的差别，不再各判各的。
///
/// 范围：只覆盖这个 App 会写出来、会渲染的几种（标题、引用、列表、待办、
/// 分隔线、整行图片、围栏代码块）。不追求完整 CommonMark。
library;

/// 围栏代码块的开口信息。
class MdFence {
  const MdFence(this.marker, this.length);

  /// `` ` `` 或 `~`。
  final String marker;

  /// 围栏长度（最少 3）。
  final int length;
}

class MdHeading {
  const MdHeading(this.level, this.prefix, this.text);

  final int level;

  /// 行首的 `#` 与空格，**原样**保留（编辑器要按原字符数渲染）。
  final String prefix;

  /// 标题正文（可能带行内标记，未解析）。
  final String text;
}

class MdQuote {
  const MdQuote(this.prefix, this.text);
  final String prefix;
  final String text;
}

/// 一个列表/待办行。
class MdListLine {
  const MdListLine({
    required this.prefix,
    required this.text,
    required this.level,
    this.number,
    this.checked,
  });

  final String prefix;
  final String text;

  /// 缩进层级（0 起，最深 4 级）。
  final int level;

  /// 有序列表里写的原始序号。
  final int? number;

  /// 待办的勾选状态；不是待办时为 null。
  final bool? checked;
}

class MdBlockSyntax {
  const MdBlockSyntax._();

  // 缩进约定：标题 / 分隔线 / 引用允许 0~3 个前导空格（CommonMark 也这样）；
  // 4 个空格在本 App 里不是"缩进代码块"，就老老实实当普通段落，
  // 免得"看着是分隔线、读出来是文字"。
  static final RegExp _image = RegExp(r'^\s*!\[[^\]]*\]\(([^)]+)\)\s*$');
  static final RegExp _heading = RegExp(r'^(\s{0,3})(#{1,6})\s+(.*)$');
  static final RegExp _divider = RegExp(r'^\s{0,3}(-{3,}|\*{3,}|_{3,})\s*$');
  static final RegExp _quote = RegExp(r'^(\s{0,3}>\s?)(.*)$');
  static final RegExp _todo = RegExp(r'^(\s*[-*+]\s+\[[ xX]\]\s+)(.*)$');
  static final RegExp _bullet = RegExp(r'^(\s*[-*+]\s+)(.*)$');
  static final RegExp _ordered = RegExp(r'^(\s*\d+\.\s+)(.*)$');
  static final RegExp _fence = RegExp(r'^(\s{0,3})(`{3,}|~{3,})(.*)$');

  /// 整行图片 → 图片路径；不是整行图片返回 null。
  static String? imageLine(String line) {
    final m = _image.firstMatch(line);
    if (m == null) return null;
    final path = m.group(1)!.trim();
    return path.isEmpty ? null : path;
  }

  static MdHeading? headingLine(String line) {
    final m = _heading.firstMatch(line);
    if (m == null) return null;
    final text = m.group(3)!;
    if (text.trim().isEmpty) return null;
    return MdHeading(m.group(2)!.length, '${m.group(1)}${m.group(2)} ', text);
  }

  static bool isDivider(String line) => _divider.hasMatch(line);

  static MdQuote? quoteLine(String line) {
    final m = _quote.firstMatch(line);
    if (m == null) return null;
    return MdQuote(m.group(1)!, m.group(2)!);
  }

  static MdListLine? todoLine(String line) {
    final m = _todo.firstMatch(line);
    if (m == null) return null;
    return MdListLine(
      prefix: m.group(1)!,
      text: m.group(2)!,
      level: _listLevel(m.group(1)!),
      checked: m.group(1)!.toLowerCase().contains('[x]'),
    );
  }

  static MdListLine? bulletLine(String line) {
    final m = _bullet.firstMatch(line);
    if (m == null) return null;
    return MdListLine(
      prefix: m.group(1)!,
      text: m.group(2)!,
      level: _listLevel(m.group(1)!),
    );
  }

  static MdListLine? orderedLine(String line) {
    final m = _ordered.firstMatch(line);
    if (m == null) return null;
    final digits = RegExp(r'\d+').firstMatch(m.group(1)!);
    return MdListLine(
      prefix: m.group(1)!,
      text: m.group(2)!,
      level: _listLevel(m.group(1)!),
      number: digits == null ? null : int.tryParse(digits.group(0)!),
    );
  }

  /// 围栏代码块的开口行；不是开口返回 null。
  static MdFence? fenceStart(String line) {
    final m = _fence.firstMatch(line);
    if (m == null) return null;
    final token = m.group(2)!;
    // 开口行后面只允许跟语言标识（```dart），不能是一整段正文
    return MdFence(token.substring(0, 1), token.length);
  }

  /// 是不是同一条围栏的收尾行。
  static bool isFenceEnd(String line, MdFence fence) {
    final m = _fence.firstMatch(line);
    if (m == null) return false;
    final token = m.group(2)!;
    if (!token.startsWith(fence.marker) || token.length < fence.length) {
      return false;
    }
    return m.group(3)!.trim().isEmpty;
  }

  /// 列表缩进 → 层级。两个空格或一个 Tab 算一级。
  ///
  /// 传进来的 [prefix] 是整段行首标记（`- `、`  - [x] `、`1. `），
  /// 这里只取真正的空白部分算层级。
  static int _listLevel(String prefix) {
    final lead = RegExp(r'^[ \t]*').firstMatch(prefix)?.group(0) ?? '';
    var width = 0;
    for (final r in lead.runes) {
      width += r == 0x09 ? 2 : 1;
    }
    return (width ~/ 2).clamp(0, 4);
  }
}
