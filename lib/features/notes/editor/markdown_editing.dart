/// Markdown 编辑操作。
///
/// 纯文本变换，不依赖任何 Widget，方便单独测试。
/// 所有函数都遵循同一个约定：**改完之后把选区放在最合理的位置**，
/// 否则用户点一次工具栏光标就跳走了，体验会很差。
library;

import 'package:flutter/widgets.dart';

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
  static TextEditingValue continueLine(
    TextEditingValue oldValue,
    TextEditingValue next,
  ) {
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
    if (match == null ||
        at < start + match.start + line.length - match.group(6)!.length) {
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
  }) {
    final newText = text.replaceRange(start, end, replacement);
    final nextSelection = selection == null
        ? TextSelection(
            baseOffset: start,
            extentOffset: start + replacement.length,
          )
        : _mapSelection(
            text.substring(start, end),
            replacement,
            selection,
            start,
          );
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
