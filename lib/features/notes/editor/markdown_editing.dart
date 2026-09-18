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
  /// 没有选中内容时，插入一对空标记并把光标放到中间，方便直接输入。
  static void wrap(
    TextEditingController controller,
    String before, [
    String? after,
  ]) {
    final close = after ?? before;
    final text = controller.text;
    final sel = controller.selection;

    if (!sel.isValid) {
      // 没有有效选区时，追加到末尾
      final at = text.length;
      final inserted = '$before$close';
      controller.value = TextEditingValue(
        text: '$text$inserted',
        selection: TextSelection.collapsed(offset: at + before.length),
      );
      return;
    }

    if (sel.isCollapsed) {
      final at = sel.start;
      final newText = text.replaceRange(at, at, '$before$close');
      controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: at + before.length),
      );
      return;
    }

    final selected = text.substring(sel.start, sel.end);
    final wrapped = selected.length >= before.length + close.length &&
        selected.startsWith(before) &&
        selected.endsWith(close);

    final newText = wrapped
        ? text.replaceRange(
            sel.start,
            sel.end,
            selected.substring(before.length, selected.length - close.length),
          )
        : text.replaceRange(sel.start, sel.end, '$before$selected$close');

    // 选区保持在「文字本身」上，而不是把标记也框进来：
    // 这样用户可以接着点斜体/删除线继续叠加，不会把 ** 也包进去。
    final contentStart = wrapped ? sel.start : sel.start + before.length;
    final contentLength =
        wrapped ? selected.length - before.length - close.length : selected.length;

    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection(
        baseOffset: contentStart,
        extentOffset: contentStart + contentLength,
      ),
    );
  }

  /// 给选区覆盖的每一行加/去行首标记（`- `、`> `、`- [ ] ` 等）。
  ///
  /// 若所有行都已经带该标记，则视为"再点一次取消"，统一去掉。
  static void toggleLinePrefix(TextEditingController controller, String prefix) {
    final text = controller.text;
    final sel = _effectiveSelection(controller);
    final (lineStart, lineEnd) = _lineRange(text, sel.start, sel.end);

    final block = text.substring(lineStart, lineEnd);
    final lines = block.split('\n');
    final allHave = lines.every((l) => l.trimLeft().startsWith(prefix));

    final newLines = <String>[];
    for (final line in lines) {
      if (allHave) {
        final idx = line.indexOf(prefix);
        newLines.add(idx < 0 ? line : line.substring(0, idx) + line.substring(idx + prefix.length));
      } else {
        newLines.add(line.trimLeft().startsWith(prefix) ? line : '$prefix$line');
      }
    }

    final newBlock = newLines.join('\n');
    _applyRange(controller, text, lineStart, lineEnd, newBlock);
  }

  /// 设置标题级别。`level = 0` 表示取消标题。
  ///
  /// 会先清掉已有的 `#`，避免出现 `####` 这种叠加。
  static void setHeading(TextEditingController controller, int level) {
    final text = controller.text;
    final sel = _effectiveSelection(controller);
    final (lineStart, lineEnd) = _lineRange(text, sel.start, sel.end);

    final block = text.substring(lineStart, lineEnd);
    final lines = block.split('\n');
    final newLines = <String>[];
    for (final line in lines) {
      final stripped = line.replaceFirst(RegExp(r'^\s*#{1,6}\s*'), '');
      newLines.add(level <= 0 ? stripped : '${'#' * level} $stripped');
    }

    final newBlock = newLines.join('\n');
    _applyRange(controller, text, lineStart, lineEnd, newBlock);
  }

  /// 在当前光标处另起一段插入内容（分割线、代码块这类独立块）。
  static void insertBlock(TextEditingController controller, String block) {
    final text = controller.text;
    final sel = _effectiveSelection(controller);
    final at = sel.end;

    final needsLeading = at > 0 && !text.substring(0, at).endsWith('\n');
    final needsTrailing = at < text.length && !text.substring(at).startsWith('\n');

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
      wrap(controller, '[', '](url)');
      // 把 url 占位符选中，用户直接输入即可
      final text = controller.text;
      final urlStart = text.indexOf('](url)', sel.start);
      if (urlStart >= 0) {
        controller.value = TextEditingValue(
          text: text,
          selection: TextSelection(
            baseOffset: urlStart + 2,
            extentOffset: urlStart + 5,
          ),
        );
      }
      // 保留 selected 变量语义（避免 lint 提示未使用）
      assert(selected.isNotEmpty);
      return;
    }
    wrap(controller, '[', '](url)');
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
    var lineEnd = text.indexOf('\n', end);
    if (lineEnd < 0) lineEnd = text.length;
    return (lineStart, lineEnd);
  }

  static void _applyRange(
    TextEditingController controller,
    String text,
    int start,
    int end,
    String replacement,
  ) {
    final newText = text.replaceRange(start, end, replacement);
    controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection(
        baseOffset: start,
        extentOffset: start + replacement.length,
      ),
    );
  }
}
