/// Markdown 实时样式解析。
///
/// 把一段 Markdown 切成「带语义的片段」，交给渲染层上色。
/// 抽成纯函数是为了能单独测试——样式逻辑最容易出偏移 bug。
///
/// 设计取向：
///   - **语法符号也算一段**（kind = marker），渲染时用淡色。
///     这样 `**加粗**` 里的星号会"退到背景"，视线自然落在内容上，
///     既保留了所见即所得的观感，又不用真的把符号藏起来
///     （藏起来会让光标位置和实际字符对不上，输入法直接崩）。
///   - 不追求完整 Markdown 语法，只覆盖写作时真正高频的几种。
library;

/// 片段的语义类型。
enum MdKind {
  /// 普通正文
  plain,

  /// 语法符号（**、#、-、> 等）。渲染时会被"藏起来"，实现所见即所得。
  marker,

  /// 整行分隔线 `---`
  divider,

  /// 整行图片 `![](path)`（纯文本编辑框画不出真图，只能弱化显示）
  image,

  h1,
  h2,
  h3,
  h4,
  bold,
  italic,
  code,
  strike,

  /// 引用内容
  quote,

  /// 已完成待办的文字
  done,
}

/// 一个带语义的文本片段。
class MdSegment {
  const MdSegment(this.text, this.kind);

  final String text;
  final MdKind kind;

  @override
  String toString() => '$kind("$text")';
}

class MarkdownStyler {
  const MarkdownStyler._();

  static final _divider = RegExp(r'^\s*(-{3,}|\*{3,}|_{3,})\s*$');
  static final _imageLine = RegExp(r'^\s*!\[[^\]]*\]\([^)]*\)\s*$');
  static final _todo = RegExp(r'^(\s*[-*+]\s+\[[ xX]\]\s*)(.*)$');
  static final _heading = RegExp(r'^(\s*#{1,6}\s*)(.*)$');
  static final _quote = RegExp(r'^(\s*>\s?)(.*)$');
  static final _bullet = RegExp(r'^(\s*[-*+]\s+)(.*)$');
  static final _ordered = RegExp(r'^(\s*\d+\.\s+)(.*)$');

  /// 行内标记：加粗、删除线、行内代码、斜体。
  /// 顺序很重要——`**` 必须排在 `*` 前面，否则加粗会被拆成两段斜体。
  static final _inline = RegExp(r'(\*\*[^*\n]+\*\*|~~[^~\n]+~~|`[^`\n]+`|\*[^*\n]+\*)');

  /// 把整篇文本切成片段列表。
  static List<MdSegment> parse(String text) {
    final out = <MdSegment>[];
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) out.add(const MdSegment('\n', MdKind.plain));
      _parseLine(lines[i], out);
    }
    return out;
  }

  static void _parseLine(String line, List<MdSegment> out) {
    if (line.isEmpty) return;

    // 分隔线：整行都是符号
    if (_divider.hasMatch(line)) {
      out.add(MdSegment(line, MdKind.divider));
      return;
    }

    // 整行图片：编辑框里渲染不出真图，单独给个语义让渲染层弱化它
    if (_imageLine.hasMatch(line)) {
      out.add(MdSegment(line, MdKind.image));
      return;
    }

    // 待办：`- [ ] 事项` / `- [x] 已完成`
    final todo = _todo.firstMatch(line);
    if (todo != null) {
      out.add(MdSegment(todo.group(1)!, MdKind.marker));
      final checked =
          todo.group(1)!.toLowerCase().contains('[x]');
      _parseInline(todo.group(2)!, checked ? MdKind.done : MdKind.plain, out);
      return;
    }

    // 标题
    final heading = _heading.firstMatch(line);
    if (heading != null) {
      out.add(MdSegment(heading.group(1)!, MdKind.marker));
      final level = heading.group(1)!.trim().length;
      final kind = switch (level) {
        1 => MdKind.h1,
        2 => MdKind.h2,
        3 => MdKind.h3,
        _ => MdKind.h4,
      };
      _parseInline(heading.group(2)!, kind, out);
      return;
    }

    // 引用
    final quote = _quote.firstMatch(line);
    if (quote != null) {
      out.add(MdSegment(quote.group(1)!, MdKind.marker));
      _parseInline(quote.group(2)!, MdKind.quote, out);
      return;
    }

    // 无序列表
    final bullet = _bullet.firstMatch(line);
    if (bullet != null) {
      out.add(MdSegment(bullet.group(1)!, MdKind.marker));
      _parseInline(bullet.group(2)!, MdKind.plain, out);
      return;
    }

    // 有序列表
    final ordered = _ordered.firstMatch(line);
    if (ordered != null) {
      out.add(MdSegment(ordered.group(1)!, MdKind.marker));
      _parseInline(ordered.group(2)!, MdKind.plain, out);
      return;
    }

    _parseInline(line, MdKind.plain, out);
  }

  /// 解析行内标记。[fallback] 是这段文字的基准语义（标题/引用/已完成…）。
  ///
  /// 规则：**块级语义优先**。
  /// `# **重点**` 里的加粗不会把标题降级成普通加粗——
  /// 标题本来就已经是粗体，保住字号才是用户想要的。
  /// （MdKind 是单一枚举，表达不了"又大又粗且是链接"这种组合，
  /// 与其硬凑，不如定一条可预期的规则。）
  static void _parseInline(String s, MdKind fallback, List<MdSegment> out) {
    if (s.isEmpty) return;

    // 只有在普通正文里，行内标记才改变语义
    final inline = fallback == MdKind.plain;

    var last = 0;
    for (final m in _inline.allMatches(s)) {
      if (m.start > last) {
        out.add(MdSegment(s.substring(last, m.start), fallback));
      }
      final token = m.group(0)!;
      switch (token.substring(0, 1)) {
        case '`':
          out
            ..add(const MdSegment('`', MdKind.marker))
            ..add(MdSegment(
              token.substring(1, token.length - 1),
              inline ? MdKind.code : fallback,
            ))
            ..add(const MdSegment('`', MdKind.marker));
        case '~':
          out
            ..add(const MdSegment('~~', MdKind.marker))
            ..add(MdSegment(
              token.substring(2, token.length - 2),
              inline ? MdKind.strike : fallback,
            ))
            ..add(const MdSegment('~~', MdKind.marker));
        case '*':
          final doubled = token.startsWith('**');
          final mark = doubled ? '**' : '*';
          out
            ..add(MdSegment(mark, MdKind.marker))
            ..add(MdSegment(
              token.substring(mark.length, token.length - mark.length),
              inline
                  ? (doubled ? MdKind.bold : MdKind.italic)
                  : fallback,
            ))
            ..add(MdSegment(mark, MdKind.marker));
        default:
          out.add(MdSegment(token, fallback));
      }
      last = m.end;
    }

    if (last < s.length) {
      out.add(MdSegment(s.substring(last), fallback));
    }
  }
}
