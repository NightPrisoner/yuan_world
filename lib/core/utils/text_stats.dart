/// 文本统计与摘要工具。
///
/// 中文没有空格分隔，"词数"需要专门处理：
/// 把每个 CJK 字符算作 1 个词，把连续的拉丁字母/数字串也算作 1 个词。
library;

/// 判断是否为 CJK 字符（中日韩统一表意文字及常见扩展）。
bool isCjk(int codeUnit) {
  return (codeUnit >= 0x4E00 && codeUnit <= 0x9FFF) || // 基本区
      (codeUnit >= 0x3400 && codeUnit <= 0x4DBF) || // 扩展 A
      (codeUnit >= 0xF900 && codeUnit <= 0xFAFF) || // 兼容表意文字
      (codeUnit >= 0x3040 && codeUnit <= 0x30FF) || // 日文假名
      (codeUnit >= 0xAC00 && codeUnit <= 0xD7AF); // 韩文
}

/// 中文标点。Word 把它们**算进字数**，所以这里也要算。
bool isCjkPunctuation(int r) {
  return (r >= 0x3000 && r <= 0x303F) || // 。、《》「」…
      (r >= 0xFF00 && r <= 0xFFEF) ||   // 全角形式：，！？（）
      r == 0x00B7;                       // 间隔号 ·
}

/// 统计字数 —— **对齐 Word 的「字数」**。
///
/// Word 的中文统计规则和"字符数"不是一回事：
///   - 每个 CJK 字（含中文标点）算 1
///   - 连续的拉丁字母/数字算 **1 个词**，不是每个字母算 1
///   - 空白和西文标点不计
///
/// 所以 `hello 世界` 在 Word 里是 **3**（hello 算一个词 + 世界两个字），
/// 而不是 7。之前这里按"字符数（不计空格）"算，和 Word 对不上。
int countChars(String text) {
  var n = 0;
  var inLatinRun = false;

  for (final r in text.runes) {
    if (isCjk(r) || isCjkPunctuation(r)) {
      n++;
      inLatinRun = false;
    } else if (_isLatinOrDigit(r)) {
      if (!inLatinRun) {
        n++;
        inLatinRun = true;
      }
    } else {
      // 空白和西文标点：不计，但要**断开**拉丁词，
      // 否则 `a.b` 会被当成一个词
      inLatinRun = false;
    }
  }
  return n;
}

/// 统计"词数"：CJK 逐字计数 + 拉丁/数字串按空格计词。
///
/// 注意它和 [countChars] 不一样：**这里不算中文标点**。
/// 词数是"多少个字词"，标点不是词。
int countWords(String text) {
  var words = 0;
  var inLatinRun = false;
  for (final r in text.runes) {
    if (isCjk(r)) {
      words++;
      inLatinRun = false;
    } else if (_isLatinOrDigit(r)) {
      if (!inLatinRun) {
        words++;
        inLatinRun = true;
      }
    } else {
      inLatinRun = false;
    }
  }
  return words;
}

bool _isLatinOrDigit(int r) =>
    (r >= 0x30 && r <= 0x39) || // 0-9
    (r >= 0x41 && r <= 0x5A) || // A-Z
    (r >= 0x61 && r <= 0x7A) || // a-z
    (r >= 0xC0 && r <= 0x24F); // 拉丁扩展

/// 从 Markdown 正文推导标题。
///
/// 优先级：
///   1. 第一个 Markdown 标题行（`# xxx`）—— 最明确
///   2. 第一行真正的文字（跳过空行 / 图片行 / 分隔线）
///   3. [fallback]
///
/// 为什么必须跳过图片行：有些 Word 文档开篇就是一张图，
/// 直接取"第一条非空行"会把 `![](45/1.png)` 当成标题，
/// 界面上看起来就像乱码。
String deriveTitleFromMarkdown(String markdown, {String fallback = '未命名'}) {
  // 1) 优先用显式标题行
  for (final raw in markdown.split('\n')) {
    final m = RegExp(r'^\s{0,3}#{1,6}\s+(.+)$').firstMatch(raw);
    if (m != null) {
      final t = _cleanInline(m.group(1)!);
      if (t.isNotEmpty) return _clamp(t);
    }
  }

  // 2) 退而求其次：第一行有内容的文字
  for (final raw in markdown.split('\n')) {
    final line = raw.trim();
    if (line.isEmpty) continue;
    if (RegExp(r'^!\[[^\]]*\]\([^)]*\)$').hasMatch(line)) continue;
    if (RegExp(r'^(-{3,}|\*{3,}|_{3,})$').hasMatch(line)) continue;
    final t = _cleanInline(line);
    if (t.isNotEmpty) return _clamp(t);
  }

  return fallback;
}

String _cleanInline(String s) => s
    .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
    .replaceAll(RegExp(r'\*\*|__|[*_`>~\[\]]'), '')
    .trim();

String _clamp(String t) => t.length > 40 ? '${t.substring(0, 40)}…' : t;

/// 判断一个标题是否是"坏标题"（图片占位符、纯符号、空）。
///
/// 用于修复历史数据：早期版本的导入器会把图片行当成标题。
bool isBadTitle(String title) {
  final t = title.trim();
  if (t.isEmpty) return true;
  if (RegExp(r'^!\[[^\]]*\]\([^)]*\)$').hasMatch(t)) return true;
  // 去掉 Markdown 符号后没有实际文字
  final stripped = t.replaceAll(RegExp(r'[!\[\]\(\)\*_`#>\-~]'), '').trim();
  return stripped.isEmpty;
}

/// 取正文里的第一张图片路径。没有就返回 null。
///
/// 头图的默认值就是它：用户不用特意去设，写了图自然就有头图。
/// 返回的是相对图片根目录的路径（如 `45/1.png`）。
String? firstImageOf(String markdown) {
  final m = RegExp(r'!\[[^\]]*\]\(([^)]+)\)').firstMatch(markdown);
  if (m == null) return null;
  final path = m.group(1)!.trim();
  if (path.isEmpty || path.startsWith('http')) return null;
  // 导入阶段的占位路径带 images/ 前缀，落盘并改写后不带，统一剥掉
  return path.startsWith('images/') ? path.substring('images/'.length) : path;
}

/// 从正文生成列表预览摘要：去掉 Markdown 标记与图片语法，压缩空白。
String makeExcerpt(String markdown, {int maxLength = 120}) {
  var s = markdown
      // 图片整行去掉
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
      // 链接保留文字
      .replaceAllMapped(RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1) ?? '')
      // 标题、引用、列表符号
      .replaceAll(RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true), '')
      .replaceAll(RegExp(r'^\s{0,3}>\s?', multiLine: true), '')
      .replaceAll(RegExp(r'^\s{0,3}[-*+]\s+', multiLine: true), '')
      .replaceAll(RegExp(r'^\s{0,3}\d+\.\s+', multiLine: true), '')
      // 强调标记
      .replaceAll(RegExp(r'\*\*|__|\*|_|`'), '')
      // 分隔线
      .replaceAll(RegExp(r'^\s{0,3}(-{3,}|\*{3,})\s*$', multiLine: true), '');

  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (s.length <= maxLength) return s;
  return '${s.substring(0, maxLength)}…';
}

/// 去掉一段文字里的行内 Markdown 标记（`**`、`*`、`_`、`~~`、`` ` ``）。
///
/// 用在"只想要纯文字"的地方：导出目录、纯文本导出、标题。
/// 放在这里而不是 toc.dart：导出器和正文渲染都要用它，
/// 它们不该为了一个剥标记的小函数去依赖「目录」模块。
String stripInline(String s) => s
    .replaceAll(RegExp(r'\*\*|__|~~'), '')
    .replaceAll(RegExp(r'[*`_]'), '')
    .trim();

/// 把正文（Markdown）拆成「段落 + 图片」的结构，供自定义渲染使用。
///
/// 之所以不直接用 flutter_markdown，是因为我们要在图文混排上做
/// 苹果风格的圆角图片、淡入动效，以及图片点击预览。
class ContentBlock {
  const ContentBlock({
    required this.type,
    required this.text,
    this.level = 0,
  });

  final ContentBlockType type;
  final String text;
  final int level;
}

enum ContentBlockType { heading, paragraph, quote, bullet, ordered, code, image, divider }

/// 列表项的缩进 → 层级（0 起，最深 4 级）。
///
/// 制表符按 2 个空格算；`~/ 2` 是"两个空格一级"这个约定，
/// 和 Word/编辑器里按 Tab 缩进的观感一致。
int _listLevel(String indent) {
  var width = 0;
  for (final r in indent.runes) {
    width += r == 0x09 ? 2 : 1;
  }
  return (width ~/ 2).clamp(0, 4);
}

List<ContentBlock> parseContent(String markdown) {
  final blocks = <ContentBlock>[];
  final lines = markdown.split('\n');
  final buffer = <String>[];

  void flush() {
    if (buffer.isEmpty) return;
    blocks.add(ContentBlock(type: ContentBlockType.paragraph, text: buffer.join('\n').trim()));
    buffer.clear();
  }

  for (final raw in lines) {
    final line = raw.trimRight();

    if (line.trim().isEmpty) {
      flush();
      continue;
    }

    final img = RegExp(r'^!\[[^\]]*\]\(([^)]+)\)\s*$').firstMatch(line.trim());
    if (img != null) {
      flush();
      blocks.add(ContentBlock(type: ContentBlockType.image, text: img.group(1)!));
      continue;
    }

    final h = RegExp(r'^(#{1,6})\s+(.*)$').firstMatch(line);
    if (h != null) {
      flush();
      blocks.add(ContentBlock(
        type: ContentBlockType.heading,
        text: h.group(2)!.trim(),
        level: h.group(1)!.length,
      ));
      continue;
    }

    if (RegExp(r'^\s{0,3}(-{3,}|\*{3,}|_{3,})\s*$').hasMatch(line)) {
      flush();
      blocks.add(const ContentBlock(type: ContentBlockType.divider, text: ''));
      continue;
    }

    final quote = RegExp(r'^\s{0,3}>\s?(.*)$').firstMatch(line);
    if (quote != null) {
      flush();
      blocks.add(ContentBlock(type: ContentBlockType.quote, text: quote.group(1)!.trim()));
      continue;
    }

    // 缩进决定列表的层级：2 个空格（或一个 Tab）算一级。
    // 以前正则只认 0~3 个空格，**4 个空格缩进的子项会掉进普通段落**，
    // 导出成 docx 时那一项就变成了没头没尾的一行文字。
    final bullet = RegExp(r'^(\s*)[-*+]\s+(.*)$').firstMatch(line);
    if (bullet != null) {
      flush();
      blocks.add(ContentBlock(
        type: ContentBlockType.bullet,
        text: bullet.group(2)!.trim(),
        level: _listLevel(bullet.group(1)!),
      ));
      continue;
    }

    final ordered = RegExp(r'^(\s*)\d+\.\s+(.*)$').firstMatch(line);
    if (ordered != null) {
      flush();
      blocks.add(ContentBlock(
        type: ContentBlockType.ordered,
        text: ordered.group(2)!.trim(),
        level: _listLevel(ordered.group(1)!),
      ));
      continue;
    }

    if (line.trimLeft().startsWith('```')) {
      flush();
      blocks.add(ContentBlock(type: ContentBlockType.code, text: line.replaceAll('`', '').trim()));
      continue;
    }

    buffer.add(line);
  }
  flush();
  return blocks;
}
