/// Markdown 编辑操作。
///
/// 纯文本变换，不依赖任何 Widget，方便单独测试。
/// 所有函数都遵循同一个约定：**改完之后把选区放在最合理的位置**，
/// 否则用户点一次工具栏光标就跳走了，体验会很差。
library;

import 'package:flutter/widgets.dart';

import '../../../core/utils/markdown_blocks.dart';
import '../../../core/utils/paragraph_indent.dart';

class MarkdownEditing {
  const MarkdownEditing._();

  /// 在选区两端包上标记；若已经包着则去掉（再点一次 = 取消）。
  ///
  /// 空选区不插入语法。编辑器控制器负责接下来输入的格式。
  static void wrap(
    TextEditingController controller,
    String before, [
    String? after,
  ]) {
    final close = after ?? before;
    final text = controller.text;
    final sel = controller.selection;

    if (!sel.isValid || sel.isCollapsed) return;

    final selected = text.substring(sel.start, sel.end);
    if (selected.contains('\n')) {
      final (blockStart, blockEnd) = _lineRange(text, sel.start, sel.end);
      final lines = text.substring(blockStart, blockEnd).split('\n');
      final rewritten = <String>[];
      int? firstStart;
      var lastEnd = sel.end;
      var oldOffset = blockStart;
      var newOffset = blockStart;
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        final prefix = _linePrefixLength(line);
        var from = (sel.start - oldOffset).clamp(prefix, line.length);
        var to = (sel.end - oldOffset).clamp(from, line.length);
        // The outer selection may exclude the first opening delimiter and
        // last closing delimiter while including delimiters on inner lines.
        if (before == '*' || before == '**') {
          final left = _starRunBefore(line, from);
          final trailing = _starRunBefore(line, to);
          if (left > 0 && left == trailing && to == line.length) to -= trailing;
          final leading = _starRunAfter(line, from);
          final right = _starRunAfter(line, to);
          if (leading > 0 && leading == right && from == prefix) {
            from += leading;
          }
        } else {
          if (from >= before.length &&
              line.substring(from - before.length, from) == before &&
              to == line.length &&
              line.endsWith(close)) {
            to -= close.length;
          }
          if (from == prefix &&
              line.substring(from).startsWith(before) &&
              to + close.length <= line.length &&
              line.substring(to, to + close.length) == close) {
            from += before.length;
          }
        }
        if (to == from || line.substring(from, to).trim().isEmpty) {
          rewritten.add(line);
          oldOffset += line.length + 1;
          newOffset += line.length + 1;
          continue;
        }
        final part = TextEditingController(text: line)
          ..selection = TextSelection(baseOffset: from, extentOffset: to);
        wrap(part, before, after);
        firstStart ??= newOffset + part.selection.start;
        lastEnd = newOffset + part.selection.end;
        rewritten.add(part.text);
        oldOffset += line.length + 1;
        newOffset += part.text.length + 1;
        part.dispose();
      }
      final start = firstStart ?? sel.start;
      controller.value = TextEditingValue(
        text: text.replaceRange(blockStart, blockEnd, rewritten.join('\n')),
        selection: TextSelection(
          baseOffset: sel.baseOffset <= sel.extentOffset ? start : lastEnd,
          extentOffset: sel.baseOffset <= sel.extentOffset ? lastEnd : start,
        ),
      );
      return;
    }

    // `*`, `**`, and `***` share the same delimiter character. Toggling
    // against only the exact selected text either strips part of an existing
    // mark or keeps stacking stars when the selection excludes the markers.
    // Treat adjacent star runs as a combined bold/italic state and rewrite
    // them canonically (0, 1, 2, or 3 stars on each side).
    if (before == '*' || before == '**') {
      _toggleAsterisks(controller, text, sel, selected, before.length);
      return;
    }

    final wrapped =
        selected.length >= before.length + close.length &&
        selected.startsWith(before) &&
        selected.endsWith(close);

    final adjacent =
        !wrapped &&
        sel.start >= before.length &&
        sel.end + close.length <= text.length &&
        text.substring(sel.start - before.length, sel.start) == before &&
        text.substring(sel.end, sel.end + close.length) == close;

    final content = wrapped
        ? selected.substring(before.length, selected.length - close.length)
        : selected;
    final replaceStart = adjacent ? sel.start - before.length : sel.start;
    final replaceEnd = adjacent ? sel.end + close.length : sel.end;
    final replacement = wrapped || adjacent
        ? content
        : '$before$selected$close';
    final newText = text.replaceRange(replaceStart, replaceEnd, replacement);

    // 选区保持在「文字本身」上，而不是把标记也框进来：
    // 这样用户可以接着点斜体/删除线继续叠加，不会把 ** 也包进去。
    final contentStart = wrapped
        ? sel.start
        : (adjacent ? replaceStart : sel.start + before.length);

    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection(
        baseOffset: contentStart,
        extentOffset: contentStart + content.length,
      ),
    );
  }

  static void _toggleAsterisks(
    TextEditingController controller,
    String text,
    TextSelection selection,
    String selected,
    int toggleMarkLength,
  ) {
    var content = selected;
    var replaceStart = selection.start;
    var replaceEnd = selection.end;
    var existingCount = 0;

    final leading =
        selected.length - selected.replaceFirst(RegExp(r'^\*+'), '').length;
    final trailing =
        selected.length - selected.replaceFirst(RegExp(r'\*+$'), '').length;
    if (leading > 0 &&
        leading == trailing &&
        selected.length > leading + trailing) {
      // The user's selection includes the markdown markers.
      existingCount = leading;
      content = selected.substring(leading, selected.length - trailing);
    } else {
      final leftCount = _starRunBefore(text, selection.start);
      final rightCount = _starRunAfter(text, selection.end);
      if (leftCount > 0 && leftCount == rightCount) {
        // Toolbar formatting leaves the selection on the content, outside its
        // markers, so the next click must inspect the surrounding text.
        existingCount = leftCount;
        replaceStart -= leftCount;
        replaceEnd += rightCount;
      }
    }

    final hasBold = existingCount >= 2;
    final hasItalic = existingCount.isOdd;
    final nextBold = toggleMarkLength == 2 ? !hasBold : hasBold;
    final nextItalic = toggleMarkLength == 1 ? !hasItalic : hasItalic;
    final nextCount = (nextBold ? 2 : 0) + (nextItalic ? 1 : 0);
    final marks = '*' * nextCount;
    final replacement = '$marks$content$marks';
    final newText = text.replaceRange(replaceStart, replaceEnd, replacement);
    final contentStart = replaceStart + nextCount;

    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection(
        baseOffset: contentStart,
        extentOffset: contentStart + content.length,
      ),
    );
  }

  static int _starRunBefore(String text, int offset) {
    var count = 0;
    for (var i = offset - 1; i >= 0 && text[i] == '*'; i--) {
      count++;
    }
    return count;
  }

  static int _starRunAfter(String text, int offset) {
    var count = 0;
    for (var i = offset; i < text.length && text[i] == '*'; i++) {
      count++;
    }
    return count;
  }

  /// 给选区覆盖的每一行加/去行首标记（`- `、`> `、`- [ ] ` 等）。
  ///
  /// 若所有行都已经带该标记，则视为"再点一次取消"，统一去掉。
  static void toggleLinePrefix(
    TextEditingController controller,
    String prefix,
  ) {
    final text = controller.text;
    final sel = _effectiveSelection(controller);
    final (lineStart, lineEnd) = _lineRange(text, sel.start, sel.end);

    final block = text.substring(lineStart, lineEnd);
    final lines = block.split('\n');
    final listPrefix = RegExp(r'^(\s*)(?:[-*+]\s+(?:\[[ xX]\]\s+)?|\d+\.\s+)');
    final requested = prefix == '1. '
        ? RegExp(r'^\s*\d+\.\s+')
        : prefix == '- '
        ? RegExp(r'^\s*[-*+]\s+(?!\[[ xX]\])')
        : prefix == '- [ ] '
        ? RegExp(r'^\s*[-*+]\s+\[[ xX]\]\s+')
        : null;
    final allHave = lines.every(
      (l) => requested?.hasMatch(l) ?? l.trimLeft().startsWith(prefix),
    );

    final newLines = <String>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (requested != null) {
        final match = listPrefix.firstMatch(line);
        final indent = match?.group(1) ?? RegExp(r'^\s*').stringMatch(line)!;
        final content = match == null
            ? line.substring(indent.length)
            : line.substring(match.end);
        final marker = prefix == '1. ' ? '${i + 1}. ' : prefix;
        newLines.add('$indent${allHave ? '' : marker}$content');
        continue;
      }
      if (allHave) {
        final idx = line.indexOf(prefix);
        newLines.add(
          idx < 0
              ? line
              : line.substring(0, idx) + line.substring(idx + prefix.length),
        );
      } else {
        newLines.add(
          line.trimLeft().startsWith(prefix) ? line : '$prefix$line',
        );
      }
    }

    final newBlock = newLines.join('\n');
    _applyRange(controller, text, lineStart, lineEnd, newBlock, selection: sel);
  }

  /// 首行缩进两字：只作用于**选区覆盖的那几个段落**。
  ///
  /// 语义照 Word 定（用户 m272125「每个段落的第一行缩进 2 格，和 word 里
  /// docx 的效果一样」+ m280060「看光标所在的段落或者框选一大片文字那几个
  /// 段落起作用」+ m280341「仿照 word 改」）：
  ///
  ///   · **一个硬回车行 = 一个段落**。Word 里 Enter 插的是段落标记（`<w:p>`），
  ///     每按一次就起一段并继承段落格式；只有 Shift+Enter 的软换行
  ///     （`<w:br/>`）留在段内、不缩进。
  ///   · 所以每个非空行都是它那一段的第一行，都该缩进；软换行折出来的行
  ///     连字符都不是，当然不缩进。
  ///
  /// Word 那边缩进是段落属性（`w:ind/@w:firstLineChars`，单位「字符」= 当前
  /// 字号下一个汉字的宽，200 就是两字），排版时把首行起点右移，正文里一个字
  /// 都不多。我们存的是纯 markdown，没有段落属性可放，`TextField` 又塞不了
  /// `WidgetSpan`（会让 `value.text` 与 TextPainter 的纯文本索引错开一个字符，
  /// 光标/选区/输入法全歪，见 flutter#12255 / #161014）—— 所以用两个全角空格
  /// 当段首标记，只在段首那一行有。
  ///
  /// 若选区里的段落**全都**已经缩进了，就统一摘掉（再点一次取消）。
  static void toggleIndentFirstLine(TextEditingController controller) {
    const pad = kIndentMark;
    final text = controller.text;
    final sel = _effectiveSelection(controller);
    final lines = text.split('\n');

    // 每一行在全文里的起始偏移，用来把光标/选区换算成行号。
    final starts = <int>[];
    var offset = 0;
    for (final line in lines) {
      starts.add(offset);
      offset += line.length + 1;
    }

    int lineOf(int pos) {
      final p = pos.clamp(0, text.length);
      for (var i = lines.length - 1; i >= 0; i--) {
        if (p >= starts[i]) return i;
      }
      return 0;
    }

    final first = lineOf(sel.start);
    final last = lineOf(sel.end);

    /// 这些行不参与缩进：空行没有"第一行"，标题/分隔线/整行图片本身是块，
    /// 围栏里的代码更要原样保留。
    bool eligible(int i) {
      final line = lines[i];
      if (line.trim().isEmpty) return false;
      if (MdBlockSyntax.headingLine(line) != null ||
          MdBlockSyntax.isDivider(line) ||
          MdBlockSyntax.imageLine(line) != null) {
        return false;
      }
      // 围栏：整块（含开口与收尾）都不动
      MdFence? fence;
      for (var j = 0; j < lines.length; j++) {
        final l = lines[j];
        if (fence != null) {
          if (MdBlockSyntax.isFenceEnd(l, fence)) {
            fence = null;
            if (j == i) return false;
            continue;
          }
          if (j == i) return false;
          continue;
        }
        final opening = MdBlockSyntax.fenceStart(l);
        if (opening != null) {
          fence = opening;
          if (j == i) return false;
          continue;
        }
        if (j == i) return true;
      }
      return false;
    }

    final targets = <int>[
      for (var i = first; i <= last && i < lines.length; i++)
        if (eligible(i)) i,
    ];
    if (targets.isEmpty) return;
    // 判"有没有缩进"只看两个全角空格（[hasIndentMark]），不看后面那个零宽
    // 连接符：加它之前存下的老笔记行首只有两个空格，也得照样认得出来、
    // 照样能摘掉，否则升级一次旧笔记的缩进就再也关不掉了。
    final allHave = targets.every((i) => hasIndentMark(lines[i]));
    // 每行被加了还是摘了 pad —— 光标要靠它自己挪，不能交给 _mapSelection：
    // 那套映射的职责是"跳过新加的行首语法"（点了列表后光标停在文字前、
    // 而不是停在 `- ` 后面），可全角空格是**正文内容**，光标得跟着往后挪两格，
    // 否则加完缩进光标就落在原来那个字上，看起来"往前跳了两个字"。
    final delta = List<int>.filled(lines.length, 0);
    for (final i in targets) {
      if (allHave) {
        final before = lines[i].length;
        lines[i] = stripIndentMark(lines[i]);
        delta[i] = lines[i].length - before;
      } else if (!hasIndentMark(lines[i])) {
        lines[i] = '$pad${lines[i]}';
        delta[i] = pad.length;
      }
    }
    final newText = lines.join('\n');
    if (newText == text) return;
    // 只在整篇范围内替换受影响的几行，选区按行号映射回去。
    final rangeStart = starts[first];
    final rangeEnd = last + 1 < starts.length
        ? starts[last + 1] - 1
        : text.length;
    final newBlock = lines.sublist(first, last + 1).join('\n');

    int shift(int offset) {
      final p = offset.clamp(0, text.length);
      final line = lineOf(p);
      var total = 0;
      for (var i = 0; i < line; i++) {
        total += delta[i];
      }
      // 光标在这一行里（含行首）：pad 是插在行首的，所以整行都跟着挪。
      return p + total + delta[line];
    }

    final nextSelection = TextSelection(
      baseOffset: shift(sel.start).clamp(0, newText.length),
      extentOffset: shift(sel.end).clamp(0, newText.length),
    );
    _applyRange(
      controller,
      text,
      rangeStart,
      rangeEnd,
      newBlock,
      selection: nextSelection,
      remap: false,
    );
  }

  /// 光标所在**段落**有没有缩进。
  ///
  /// 工具栏按钮的高亮、以及回车续写都用它。
  ///
  /// **光标在空行上时要往前找最近的非空行**：空行本身不是段落，它夹在两段
  /// 之间；在空行上敲回车得到的是下一段的第一行，该不该缩进要参照上一段。
  /// 以前这里只看当前行，于是「在有缩进的段落后面回车得到空行、再回车」
  /// 时新行就不缩进了，正文里出现"前几行缩进、后面突然顶格"的阶梯
  /// （用户截图里那个现象）。
  static bool lineHasIndent(TextEditingController controller) {
    final text = controller.text;
    final sel = _effectiveSelection(controller);
    final caret = sel.start.clamp(0, text.length);
    final lines = text.split('\n');

    final starts = <int>[];
    var offset = 0;
    for (final line in lines) {
      starts.add(offset);
      offset += line.length + 1;
    }
    var i = lines.length - 1;
    for (var k = lines.length - 1; k >= 0; k--) {
      if (caret >= starts[k]) {
        i = k;
        break;
      }
    }
    while (i >= 0 && lines[i].trim().isEmpty) {
      i--;
    }
    if (i < 0) return false;
    return hasIndentMark(lines[i]);
  }

  /// 设置标题级别。`level = 0` 表示取消标题。
  ///
  /// 会先清掉已有的 `#`，避免出现 `####` 这种叠加。
  static void setHeading(TextEditingController controller, int level) {
    level = level.clamp(0, 6);
    final text = controller.text;
    final sel = _effectiveSelection(controller);
    final (lineStart, lineEnd) = _lineRange(text, sel.start, sel.end);

    final block = text.substring(lineStart, lineEnd);
    final lines = block.split('\n');
    final newLines = <String>[];
    for (final line in lines) {
      final stripped = line.replaceFirst(RegExp(r'^\s*#{1,6}\s+'), '');
      newLines.add(level <= 0 ? stripped : '${'#' * level} $stripped');
    }

    final newBlock = newLines.join('\n');
    _applyRange(controller, text, lineStart, lineEnd, newBlock, selection: sel);
  }

  /// 在当前光标处另起一段插入内容（分割线、代码块这类独立块）。
  static void insertBlock(TextEditingController controller, String block) {
    final text = controller.text;
    final sel = _effectiveSelection(controller);
    final at = sel.end;

    final needsLeading = at > 0 && !text.substring(0, at).endsWith('\n');
    final needsTrailing =
        at < text.length && !text.substring(at).startsWith('\n');

    final inserted =
        '${needsLeading ? '\n' : ''}$block${needsTrailing ? '\n' : ''}\n';
    final newText = text.replaceRange(at, at, inserted);
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: at + inserted.length),
    );
  }

  /// 插入链接：选中文字作为链接文本，没选就插入模板并选中占位符。
  static void insertLink(TextEditingController controller) {
    final sel = controller.selection;
    if (sel.isValid && !sel.isCollapsed) {
      final selected = controller.text.substring(sel.start, sel.end);
      final replacement = '[$selected](url)';
      final text = controller.text.replaceRange(
        sel.start,
        sel.end,
        replacement,
      );
      // 通过替换长度计算占位符位置，不用 indexOf：选区前面可能已经有
      // 一个相同的 `](url)`，否则连续插入链接会选错 URL。
      final urlStart = sel.start + 1 + selected.length + 2;
      controller.value = TextEditingValue(
        text: text,
        selection: TextSelection(
          baseOffset: urlStart,
          extentOffset: urlStart + 3,
        ),
      );
      return;
    }
    final at = sel.isValid ? sel.start : controller.text.length;
    const snippet = '[链接文字](url)';
    controller.value = TextEditingValue(
      text: controller.text.replaceRange(at, at, snippet),
      selection: TextSelection(baseOffset: at + 1, extentOffset: at + 5),
    );
  }

  /// 插入**内部链接**（指向另一篇笔记的双链）。
  ///
  /// 有选中文字时把它当别名（`[[标题|选中文字]]`）—— 用户选了一段话再插链接，
  /// 想保留那段话当显示文字是常态；没选就插 `[[标题]]`，光标落在后面。
  ///
  /// 标题由调用方从"选笔记"页面带回来，**不需要用户手打** ——
  /// 手打标题又慢又容易错，错了还只是"点了没反应"。
  static void insertNoteLink(TextEditingController controller, String title) {
    final t = title.trim();
    if (t.isEmpty) return;
    final sel = controller.selection;
    final text = controller.text;

    if (sel.isValid && !sel.isCollapsed) {
      final alias = text.substring(sel.start, sel.end).trim();
      final snippet = alias.isEmpty ? '[[$t]]' : '[[$t|$alias]]';
      controller.value = TextEditingValue(
        text: text.replaceRange(sel.start, sel.end, snippet),
        selection: TextSelection.collapsed(offset: sel.start + snippet.length),
      );
      return;
    }

    final at = sel.isValid ? sel.start : text.length;
    final snippet = '[[$t]]';
    controller.value = TextEditingValue(
      text: text.replaceRange(at, at, snippet),
      selection: TextSelection.collapsed(offset: at + snippet.length),
    );
  }

  // ── 内部工具 ────────────────────────────────────────────────────────────

  static TextSelection _effectiveSelection(TextEditingController controller) {
    final sel = controller.selection;
    if (sel.isValid) return sel;
    return TextSelection.collapsed(offset: controller.text.length);
  }

  /// 找出 [start, end] 覆盖到的完整行范围（含行尾换行符之前）。
  static (int, int) _lineRange(String text, int start, int end) {
    final lineStart = start <= 0 ? 0 : (text.lastIndexOf('\n', start - 1) + 1);
    // A selection ending at the next line's start excludes that next line.
    final last = end > start && end > 0 && text[end - 1] == '\n'
        ? end - 1
        : end;
    var lineEnd = text.indexOf('\n', last);
    if (lineEnd < 0) lineEnd = text.length;
    return (lineStart, lineEnd);
  }

  /// Continue a list/quote only for a single committed Enter edit. Pasting
  /// multiline text and IME composition must not receive automatic prefixes.
  /// 光标是不是落在围栏代码块里面（从头扫一遍数开口/收尾）。
  ///
  /// 代码块里的每一行都该原样保留，不能因为开了「首行缩进」就往前塞两个
  /// 全角空格 —— 那会把代码缩进改坏，而且复制出去还带着看不见的字符。
  static bool _insideFence(String text, int at) {
    MdFence? open;
    var pos = 0;
    for (final line in text.split('\n')) {
      if (pos > at) break;
      if (open == null) {
        final start = MdBlockSyntax.fenceStart(line);
        if (start != null) open = start;
      } else if (MdBlockSyntax.isFenceEnd(line, open)) {
        open = null;
      }
      pos += line.length + 1;
    }
    return open != null;
  }

  static TextEditingValue continueLine(
    TextEditingValue oldValue,
    TextEditingValue next, {
    String indent = '',
  }) {
    if (!oldValue.selection.isValid ||
        !oldValue.selection.isCollapsed ||
        !next.selection.isValid ||
        !next.selection.isCollapsed ||
        !next.composing.isCollapsed) {
      return next;
    }
    final at = oldValue.selection.start;
    if (next.text != oldValue.text.replaceRange(at, at, '\n') ||
        next.selection.start != at + 1) {
      return next;
    }
    final start = at == 0 ? 0 : oldValue.text.lastIndexOf('\n', at - 1) + 1;
    final endIndex = oldValue.text.indexOf('\n', at);
    final end = endIndex < 0 ? oldValue.text.length : endIndex;
    final line = oldValue.text.substring(start, end);
    final match = RegExp(
      r'^(\s*)(?:(\d+)\.\s+|([-*+])\s+(?:\[([ xX])\]\s+)?|(>)\s?)(.*)$',
    ).firstMatch(line);
    if (match == null) {
      // 普通段落：敲回车 = 开一个新段落，所以新行的行首要补两个全角空格。
      //
      // 这里的关键是**分清"段落"和"行"**：硬回车（Enter）切出来的是段落，
      // 一行排满之后的软换行只是折行，不是段落。Word 里也是这个规矩 ——
      // 每按一次 Enter 起一段、段首都缩进；段内排满换行不缩进。
      //
      // 所以判据不是"这一行有没有字"，而是"这次回车有没有开出新段落"：
      // 只要是硬回车，光标右边的内容（可能是空的）就是新段落的开头。
      //
      // 为什么用字符而不是布局缩进：`TextField` 外层的 Padding 是整段的，
      // 续行会跟着一起右移；WidgetSpan 插在开头会让 `value.text` 与
      // TextPainter 的纯文本索引错开一个字符，光标/选区/输入法全歪
      // （Flutter 至今没有 text-indent，flutter#12255 / #161014）。
      if (indent.isEmpty) return next;
      // 刚从标题 / 分隔线 / 围栏 / 整行图片上回车，别急着缩进：这些行的
      // 下一行多半还是同类块（尤其围栏里的代码），补两个空格只会碍事。
      if (MdBlockSyntax.headingLine(line) != null ||
          MdBlockSyntax.isDivider(line) ||
          MdBlockSyntax.fenceStart(line) != null ||
          MdBlockSyntax.imageLine(line) != null) {
        return next;
      }
      // 光标在围栏代码块里面：整块都不该有首行缩进。
      if (_insideFence(oldValue.text, at)) return next;
      return TextEditingValue(
        text: next.text.replaceRange(at + 1, at + 1, indent),
        selection: TextSelection.collapsed(offset: at + 1 + indent.length),
      );
    }
    if (at < start + match.start + line.length - match.group(6)!.length) {
      return next;
    }
    if (match.group(6)!.trim().isEmpty) {
      final indent = match.group(1)!;
      return TextEditingValue(
        text: oldValue.text.replaceRange(start, end, indent),
        selection: TextSelection.collapsed(offset: start + indent.length),
      );
    }
    final marker = match.group(2) != null
        ? '${(int.tryParse(match.group(2)!) ?? 0) + 1}. '
        : match.group(3) != null
        ? '${match.group(3)} ${match.group(4) != null ? '[ ] ' : ''}'
        : '> ';
    final prefix = '${match.group(1)}$marker';
    return TextEditingValue(
      text: next.text.replaceRange(at + 1, at + 1, prefix),
      selection: TextSelection.collapsed(offset: at + 1 + prefix.length),
    );
  }

  static void _applyRange(
    TextEditingController controller,
    String text,
    int start,
    int end,
    String replacement, {
    TextSelection? selection,
    bool remap = true,
  }) {
    final newText = text.replaceRange(start, end, replacement);
    final nextSelection = selection == null
        ? TextSelection(
            baseOffset: start,
            extentOffset: start + replacement.length,
          )
        : remap
        ? _mapSelection(text.substring(start, end), replacement, selection, start)
        : selection;
    controller.value = TextEditingValue(
      text: newText,
      selection: nextSelection,
    );
  }

  /// 把块级操作前的选区映射回正文内容，排除新加的 `# `、`- `、`> ` 等
  /// 行首语法。这样先点「列表」再点「加粗」时，加粗的是文字而不是语法符号。
  static TextSelection _mapSelection(
    String oldBlock,
    String newBlock,
    TextSelection selection,
    int blockStart,
  ) {
    int map(int offset) {
      final relative = (offset - blockStart).clamp(0, oldBlock.length);
      final oldLines = oldBlock.split('\n');
      final newLines = newBlock.split('\n');
      var oldStart = 0;
      var newStart = 0;

      for (var i = 0; i < oldLines.length; i++) {
        final oldLine = oldLines[i];
        final newLine = newLines[i < newLines.length ? i : newLines.length - 1];
        final oldEnd = oldStart + oldLine.length;
        if (relative <= oldEnd || i == oldLines.length - 1) {
          final oldPrefix = _linePrefixLength(oldLine);
          final newPrefix = _linePrefixLength(newLine);
          final column = relative - oldStart;
          if (column < oldPrefix) {
            return blockStart + newStart + column.clamp(0, newPrefix);
          }
          final contentColumn = column - oldPrefix;
          return blockStart +
              newStart +
              (newPrefix + contentColumn).clamp(newPrefix, newLine.length);
        }
        oldStart += oldLine.length + 1;
        newStart += newLine.length + 1;
      }
      return blockStart + newBlock.length;
    }

    return TextSelection(
      baseOffset: map(selection.baseOffset),
      extentOffset: map(selection.extentOffset),
      affinity: selection.affinity,
      isDirectional: selection.isDirectional,
    );
  }

  static int _linePrefixLength(String line) {
    final match = RegExp(
      r'^\s*(?:#{1,6}\s+|[-*+]\s+(?:\[[ xX]\]\s+)?|\d+\.\s+|>\s?)',
    ).firstMatch(line);
    return match?.group(0)?.length ?? 0;
  }
}
