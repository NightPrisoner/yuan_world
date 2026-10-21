/// 带实时 Markdown 样式的编辑控制器。
///
/// 让编辑器「边写边变」：
///   - `**加粗**` 立刻显示为粗体，星号淡出
///   - `# 标题` 立刻变大
///   - `` `代码` `` 立刻变成等宽带底
///   - `- [x] 做完的事` 的文字立刻划掉
///
/// 为什么不做成真正的所见即所得（把语法符号藏起来）：
/// 那需要接管文本布局，会让**光标位置和实际字符对不上**，
/// 中文输入法在组合阶段（候选词还没上屏）会直接错乱。
/// 这里保持普通 TextField、只改渲染样式，输入法行为完全不受影响。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'dart:ui' as ui;

import '../../../core/theme/app_theme.dart';
import 'markdown_styler.dart';
import 'markdown_editing.dart';

class MarkdownEditingController extends TextEditingController {
  MarkdownEditingController({super.text});

  final Set<String> _typingMarks = <String>{};
  int? _runStart;
  int? _runEnd;
  String _runOpen = '';
  String _runClose = '';
  late final TextInputFormatter inputFormatter = _MarkdownInputFormatter(this);

  bool typingMarkActive(String mark) {
    if (!selection.isValid || selection.isCollapsed) return _typingMarks.contains(mark);
    final wanted = switch (mark) {
      '**' => MdKind.bold,
      '*' => MdKind.italic,
      '~~' => MdKind.strike,
      '`' => MdKind.code,
      _ => MdKind.plain,
    };
    var offset = 0;
    var any = false;
    for (final part in _parse(text)) {
      final end = offset + part.text.length;
      if (offset < selection.end && end > selection.start && part.kind != MdKind.marker && part.text.trim().isNotEmpty) {
        final combined = (wanted == MdKind.bold || wanted == MdKind.italic) &&
            (part.kind == MdKind.boldItalic || part.formats.contains(MdKind.boldItalic));
        if (part.kind != wanted && !part.formats.contains(wanted) && !combined) return false;
        any = true;
      }
      offset = end;
    }
    return any;
  }

  void toggleInline(String mark) {
    if (selection.isValid && !selection.isCollapsed) {
      MarkdownEditing.wrap(this, mark);
      _runStart = _runEnd = null;
    } else {
      if (_runEnd != null && selection.isValid && selection.start == _runEnd) {
        selection = TextSelection.collapsed(
          offset: _runEnd! + _runClose.length,
        );
      }
      if (!_typingMarks.remove(mark)) _typingMarks.add(mark);
      _runStart = _runEnd = null;
      notifyListeners();
    }
  }

  TextEditingValue _formatInput(
    TextEditingValue oldValue,
    TextEditingValue next,
  ) {
    if (_runEnd != null &&
        oldValue.selection.isCollapsed &&
        oldValue.selection.start == _runEnd &&
        next.text == oldValue.text.replaceRange(_runEnd!, _runEnd!, '\n') &&
        next.composing.isCollapsed) {
      final at = _runEnd! + _runClose.length;
      oldValue = oldValue.copyWith(
        selection: TextSelection.collapsed(offset: at),
      );
      next = TextEditingValue(
        text: oldValue.text.replaceRange(at, at, '\n'),
        selection: TextSelection.collapsed(offset: at + 1),
      );
    }
    final continued = MarkdownEditing.continueLine(oldValue, next);
    final enter =
        oldValue.selection.isValid &&
        oldValue.selection.isCollapsed &&
        next.text ==
            oldValue.text.replaceRange(
              oldValue.selection.start,
              oldValue.selection.start,
              '\n',
            );
    if (continued.text != next.text || enter) {
      _runStart = _runEnd = null;
      return continued;
    }
    if (_typingMarks.isEmpty ||
        !next.composing.isCollapsed ||
        !next.selection.isCollapsed) {
      return continued;
    }
    var start = 0;
    while (start < oldValue.text.length &&
        start < next.text.length &&
        oldValue.text.codeUnitAt(start) == next.text.codeUnitAt(start)) {
      start++;
    }
    var oldEnd = oldValue.text.length;
    var newEnd = next.text.length;
    while (oldEnd > start &&
        newEnd > start &&
        oldValue.text.codeUnitAt(oldEnd - 1) ==
            next.text.codeUnitAt(newEnd - 1)) {
      oldEnd--;
      newEnd--;
    }
    final committedComposition =
        oldValue.composing.isValid &&
        !oldValue.composing.isCollapsed &&
        oldValue.text == next.text;
    if (committedComposition) {
      start = oldValue.composing.start;
      newEnd = oldValue.composing.end;
      oldEnd = newEnd;
    }
    if (newEnd <= start) {
      if (_runStart != null &&
          _runEnd != null &&
          start >= _runStart! &&
          oldEnd <= _runEnd!) {
        _runEnd = _runEnd! + next.text.length - oldValue.text.length;
        if (_runEnd == _runStart && _runStart! >= _runOpen.length) {
          final from = _runStart! - _runOpen.length;
          final to = _runEnd! + _runClose.length;
          _runStart = _runEnd = null;
          return TextEditingValue(
            text: next.text.replaceRange(from, to, ''),
            selection: TextSelection.collapsed(offset: from),
          );
        }
      }
      return continued;
    }
    final inserted = next.text.substring(start, newEnd);
    if (inserted.contains('\n')) return continued;
    final stars =
        '${_typingMarks.contains('**') ? '**' : ''}${_typingMarks.contains('*') ? '*' : ''}';
    final open =
        '${_typingMarks.contains('~~') ? '~~' : ''}$stars${_typingMarks.contains('`') ? '`' : ''}';
    final close =
        '${_typingMarks.contains('`') ? '`' : ''}$stars${_typingMarks.contains('~~') ? '~~' : ''}';
    if (_runStart != null &&
        _runEnd != null &&
        start >= _runStart! &&
        oldEnd <= _runEnd! &&
        _runOpen == open &&
        _runClose == close &&
        _runEnd! + close.length <= oldValue.text.length &&
        oldValue.text.substring(_runEnd!, _runEnd! + close.length) == close) {
      _runEnd = _runEnd! + next.text.length - oldValue.text.length;
      return continued;
    }
    _runStart = start + open.length;
    _runEnd = _runStart! + inserted.length;
    _runOpen = open;
    _runClose = close;
    return TextEditingValue(
      text: next.text.replaceRange(start, newEnd, '$open$inserted$close'),
      selection: TextSelection.collapsed(offset: _runEnd!),
    );
  }

  /// Use glyph-tight selection boxes instead of Flutter's native `max` width
  /// style, which extends every selected line to the full TextField width.
  static const ui.BoxWidthStyle selectionWidthStyle = ui.BoxWidthStyle.tight;

  // 解析结果按文本缓存：buildTextSpan 每帧会被调用多次，
  // 不缓存的话长文里每次重绘都要跑一遍全部正则。
  String? _segText;
  List<MdSegment>? _segments;

  // 最终 span 也缓存一份，键是「文本 + 基准样式 + 组合区」
  String? _spanKey;
  TextSpan? _span;

  /// 超过这个长度就放弃着色，只求别把输入弄卡。
  static const int _stylingLimit = 100000;

  List<MdSegment> _parse(String t) {
    if (_segText == t && _segments != null) return _segments!;
    _segText = t;
    _segments = MarkdownStyler.parse(t);
    return _segments!;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final base = style ?? const TextStyle();
    final composing =
        (withComposing &&
            !value.composing.isCollapsed &&
            value.isComposingRangeValid)
        ? value.composing
        : null;

    final key =
        '${identityHashCode(base)}|${composing?.start}|'
        '${composing?.end}|${text.length}|$text';
    if (_spanKey == key && _span != null) return _span!;

    final span = _build(context, base, composing);
    _spanKey = key;
    _span = span;
    return span;
  }

  TextSpan _build(BuildContext context, TextStyle base, TextRange? composing) {
    if (text.length > _stylingLimit) {
      return TextSpan(style: base, text: text);
    }

    final c = context.colors;
    final segments = _parse(text);

    final children = <TextSpan>[];
    var offset = 0;

    for (final seg in segments) {
      final start = offset;
      final end = offset + seg.text.length;
      offset = end;

      final segStyle = _styleForSegment(seg, base, c);
      // Block markers are rendered with same-length glyphs so the visual text
      // stays close to reading mode without changing cursor offsets.
      final displayText = _displayText(seg);

      if (composing == null ||
          end <= composing.start ||
          start >= composing.end) {
        children.add(TextSpan(text: displayText, style: segStyle));
        continue;
      }

      // 与输入法组合区有重叠：切开，重叠的那段加下划线。
      // 这一步不能省——中文候选阶段没有下划线，用户会以为没输入进去。
      final cutA = (composing.start - start).clamp(0, seg.text.length);
      final cutB = (composing.end - start).clamp(0, seg.text.length);
      if (cutA > 0) {
        children.add(
          TextSpan(text: displayText.substring(0, cutA), style: segStyle),
        );
      }
      if (cutB > cutA) {
        children.add(
          TextSpan(
            text: displayText.substring(cutA, cutB),
            style: (segStyle ?? base).merge(
              const TextStyle(decoration: TextDecoration.underline),
            ),
          ),
        );
      }
      if (cutB < seg.text.length) {
        children.add(
          TextSpan(text: displayText.substring(cutB), style: segStyle),
        );
      }
    }

    return TextSpan(style: base, children: children);
  }

  TextStyle? _styleForSegment(MdSegment seg, TextStyle base, AppColors c) {
    if (seg.kind == MdKind.marker && _isBlockMarker(seg.text)) {
      return base.copyWith(
        color: c.tint,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      );
    }
    var result = _styleFor(seg.kind, base, c);
    if (seg.kind == MdKind.marker) return result;
    if (seg.formats.contains(MdKind.code)) {
      result = (result ?? base).copyWith(
        fontFamily: 'Consolas',
        backgroundColor: c.fill,
      );
    }
    if (seg.formats.contains(MdKind.bold) ||
        seg.formats.contains(MdKind.boldItalic)) {
      result = (result ?? base).copyWith(fontWeight: FontWeight.w700);
    }
    if (seg.formats.contains(MdKind.italic) ||
        seg.formats.contains(MdKind.boldItalic)) {
      result = (result ?? base).copyWith(fontStyle: FontStyle.italic);
    }
    if (seg.kind != MdKind.marker && seg.formats.contains(MdKind.strike)) {
      return (result ?? base).copyWith(decoration: TextDecoration.lineThrough);
    }
    return result;
  }

  bool _isBlockMarker(String text) =>
      RegExp(r'^\s*>\s?$').hasMatch(text) ||
      RegExp(r'^\s*[-*+]\s+\[[ xX]\]\s+$').hasMatch(text) ||
      RegExp(r'^\s*[-*+]\s+$').hasMatch(text) ||
      RegExp(r'^\s*\d+\.\s+$').hasMatch(text);

  String _displayText(MdSegment seg) {
    if (seg.kind == MdKind.divider) {
      // Box-drawing glyphs look like the reader's horizontal divider while
      // keeping exactly one UTF-16 code unit per source character.
      return seg.text.replaceAll(RegExp(r'[-*_]'), '─');
    }
    if (seg.kind != MdKind.marker) return seg.text;

    final text = seg.text;
    if (RegExp(r'^\s*>\s?$').hasMatch(text)) {
      return text.replaceFirst('>', '│');
    }
    if (RegExp(r'^\s*[-*+]\s+$').hasMatch(text)) {
      return text.replaceFirst(RegExp(r'[-*+]'), '•');
    }
    final todo = RegExp(r'^(\s*)[-*+]\s+\[([ xX])\]\s+$').firstMatch(text);
    if (todo != null) {
      final prefix = todo.group(1)!;
      final icon = todo.group(2)!.toLowerCase() == 'x' ? '☑' : '☐';
      // Preserve the original marker's UTF-16 length for caret/selection math.
      return prefix + icon + (' ' * (text.length - prefix.length - 1));
    }
    return text;
  }

  /// 把语义映射成样式。
  ///
  /// ⚠️ **所有样式都必须从 [base] 派生（copyWith）**，不能返回裸的
  /// `const TextStyle(...)`。
  ///
  /// 原因：Flutter 的 `TextSpan` 子节点样式**不与父节点合并**，而是直接替换。
  /// 一旦返回裸样式，就会同时丢掉 `fontSize` 和 `fontFamilyFallback`，
  /// 中文会退回错误的字体、字形宽度对不上，表现就是**文字互相叠压**。
  /// 这个 bug 真出现过，代价是用户看到的界面直接烂掉。
  TextStyle? _styleFor(MdKind kind, TextStyle base, AppColors c) {
    final size = base.fontSize ?? 17;
    return switch (kind) {
      // 返回 null = 用基准样式，避免每次都 copyWith 产生新对象
      MdKind.plain => null,

      // 语法符号：透明 + 极小字号 = 视觉上"消失"。
      // 不能真的从文本里删掉——光标位置和输入法都依赖真实字符。
      // letterSpacing 必须显式清零：基准样式是 -0.41，
      // 在 0.1 的字号下负间距会让字符反向重叠。
      MdKind.marker => base.copyWith(
        color: Colors.transparent,
        fontSize: 0.1,
        letterSpacing: 0,
        decoration: TextDecoration.none,
      ),
      // 分隔线和图片行没有"内容"可显示，保留淡淡的原样，
      // 至少让人知道这一行有东西（纯文本编辑框画不出真正的图片）
      MdKind.divider => base.copyWith(
        color: c.separator,
        fontSize: size * 0.7,
        letterSpacing: 0,
        height: 0.8,
      ),
      MdKind.image => base.copyWith(
        color: c.quaternaryLabel,
        fontSize: size * 0.8,
      ),

      MdKind.h1 => base.copyWith(
        fontSize: size * 1.55,
        fontWeight: FontWeight.w700,
        height: 1.5,
      ),
      MdKind.h2 => base.copyWith(
        fontSize: size * 1.3,
        fontWeight: FontWeight.w700,
        height: 1.45,
      ),
      MdKind.h3 => base.copyWith(
        fontSize: size * 1.15,
        fontWeight: FontWeight.w600,
        height: 1.4,
      ),
      MdKind.h4 => base.copyWith(fontWeight: FontWeight.w600),
      MdKind.bold => base.copyWith(fontWeight: FontWeight.w700),
      MdKind.italic => base.copyWith(fontStyle: FontStyle.italic),
      MdKind.boldItalic => base.copyWith(
        fontWeight: FontWeight.w700,
        fontStyle: FontStyle.italic,
      ),
      MdKind.code => base.copyWith(
        fontFamily: 'Consolas',
        backgroundColor: c.fill,
        color: c.label,
      ),
      MdKind.strike => base.copyWith(decoration: TextDecoration.lineThrough),
      MdKind.link => base.copyWith(
        color: c.tint,
        decoration: TextDecoration.underline,
        decorationColor: c.tint.withValues(alpha: 0.45),
      ),
      MdKind.quote => base.copyWith(
        color: c.secondaryLabel,
        fontStyle: FontStyle.italic,
      ),
      MdKind.done => base.copyWith(
        color: c.tertiaryLabel,
        decoration: TextDecoration.lineThrough,
      ),
    };
  }
}

class _MarkdownInputFormatter extends TextInputFormatter {
  _MarkdownInputFormatter(this.controller);
  final MarkdownEditingController controller;
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => controller._formatInput(oldValue, newValue);
}
