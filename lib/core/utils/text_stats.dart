/// 文本统计与摘要工具。
///
/// 中文没有空格分隔，"词数"需要专门处理：
/// 把每个 CJK 字符算作 1 个词，把连续的拉丁字母/数字串也算作 1 个词。
library;

import 'markdown_blocks.dart';

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
      (r >= 0xFF00 && r <= 0xFFEF) || // 全角形式：，！？（）
      r == 0x00B7; // 间隔号 ·
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

/// 正文里出现的所有图片路径，按出现顺序。
///
/// 返回的是相对图片根目录的路径（如 `45/1.png`），外链（http）不算。
/// 抽出来是因为「取第一张当默认头图」和「删掉一张之后该换成哪张」
/// 需要同一套解析 —— 两处各写一条正则会慢慢长歪。
List<String> imagePathsIn(String markdown) {
  final out = <String>[];
  for (final m in RegExp(r'!\[[^\]]*\]\(([^)]+)\)').allMatches(markdown)) {
    var path = m.group(1)!.trim();
    // Markdown 允许 `![说明](a.png "标题")`，标题不属于路径
    final quoteAt = path.indexOf(RegExp('''\\s+["']'''));
    if (quoteAt > 0) path = path.substring(0, quoteAt).trim();
    if (path.isEmpty || path.startsWith('http')) continue;
    // 导入阶段的占位路径带 images/ 前缀，落盘并改写后不带，统一剥掉
    if (path.startsWith('images/')) path = path.substring('images/'.length);
    if (path.isEmpty) continue;
    out.add(path);
  }
  return out;
}

/// 取正文里的第一张图片路径。没有就返回 null。
///
/// 头图的默认值就是它：用户不用特意去设，写了图自然就有头图。
String? firstImageOf(String markdown) {
  final all = imagePathsIn(markdown);
  return all.isEmpty ? null : all.first;
}

/// 从正文生成列表预览摘要：去掉 Markdown 标记与图片语法，压缩空白。
String makeExcerpt(String markdown, {int maxLength = 120}) {
  var s = markdown
      // 图片整行去掉
      .replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '')
      // 链接保留文字
      .replaceAllMapped(
        RegExp(r'\[([^\]]*)\]\([^)]*\)'),
        (m) => m.group(1) ?? '',
      )
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
    this.listNumber,
    this.isTodo = false,
    this.checked = false,
  });

  final ContentBlockType type;
  final String text;
  final int level;
  final int? listNumber;
  final bool isTodo;
  final bool checked;
}

enum ContentBlockType {
  heading,
  paragraph,
  quote,
  bullet,
  ordered,
  code,
  image,
  divider,
}

/// 把正文（Markdown）拆成渲染用的块序列。
///
/// **块级识别统一走 [MdBlockSyntax]**，编辑器那边也用它 ——
/// 以前两边各写一套正则，长歪之后出现了"编辑时是分隔线、读出来是普通
/// 段落"这种灵异现象。现在规则只定义一次，两边只在**渲染**上有差别。
List<ContentBlock> parseContent(String markdown) {
  final blocks = <ContentBlock>[];
  final lines = markdown.split('\n');
  final buffer = <String>[];

  void flush() {
    if (buffer.isEmpty) return;
    blocks.add(
      ContentBlock(
        type: ContentBlockType.paragraph,
        text: buffer.join('\n').trim(),
      ),
    );
    buffer.clear();
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trimRight();

    if (line.trim().isEmpty) {
      flush();
      continue;
    }

    final img = MdBlockSyntax.imageLine(line);
    if (img != null) {
      flush();
      blocks.add(ContentBlock(type: ContentBlockType.image, text: img));
      continue;
    }

    final fence = MdBlockSyntax.fenceStart(line);
    if (fence != null) {
      flush();
      // 围栏代码块是**多行**的：一直吃到收尾围栏为止。
      // 以前每一行都单独成一个 code 块，围栏里的内容全被拆散、
      // 第一行还只剩下语言标识 —— 阅读页里根本看不出是代码。
      final body = <String>[];
      for (i++; i < lines.length; i++) {
        if (MdBlockSyntax.isFenceEnd(lines[i], fence)) break;
        body.add(lines[i]);
      }
      // 没写收尾的围栏：就当到文末为止都是代码（和大多数渲染器一致）
      final code = body.join('\n');
      // 空围栏（还在输入中，或者只有一对 ```）不渲染成空灰块 ——
      // 编辑器那边这时也只看到一行被藏起来的符号，两边保持一致。
      if (code.trim().isEmpty) continue;
      blocks.add(ContentBlock(type: ContentBlockType.code, text: code));
      continue;
    }

    final h = MdBlockSyntax.headingLine(line);
    if (h != null) {
      flush();
      blocks.add(
        ContentBlock(
          type: ContentBlockType.heading,
          text: h.text.trim(),
          level: h.level,
        ),
      );
      continue;
    }

    if (MdBlockSyntax.isDivider(line)) {
      flush();
      blocks.add(const ContentBlock(type: ContentBlockType.divider, text: ''));
      continue;
    }

    final quote = MdBlockSyntax.quoteLine(line);
    if (quote != null) {
      flush();
      blocks.add(
        ContentBlock(
          type: ContentBlockType.quote,
          text: quote.text.trim(),
        ),
      );
      continue;
    }

    final todo = MdBlockSyntax.todoLine(line);
    if (todo != null) {
      flush();
      blocks.add(
        ContentBlock(
          type: ContentBlockType.bullet,
          text: todo.text.trim(),
          level: todo.level,
          isTodo: true,
          checked: todo.checked ?? false,
        ),
      );
      continue;
    }

    // 缩进决定列表的层级：2 个空格（或一个 Tab）算一级。
    // 以前正则只认 0~3 个空格，**4 个空格缩进的子项会掉进普通段落**，
    // 导出成 docx 时那一项就变成了没头没尾的一行文字。
    final bullet = MdBlockSyntax.bulletLine(line);
    if (bullet != null) {
      flush();
      blocks.add(
        ContentBlock(
          type: ContentBlockType.bullet,
          text: bullet.text.trim(),
          level: bullet.level,
        ),
      );
      continue;
    }

    final ordered = MdBlockSyntax.orderedLine(line);
    if (ordered != null) {
      flush();
      blocks.add(
        ContentBlock(
          type: ContentBlockType.ordered,
          text: ordered.text.trim(),
          level: ordered.level,
          listNumber: ordered.number,
        ),
      );
      continue;
    }

    buffer.add(line);
  }
  flush();
  return blocks;
}
