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

import '../../../core/theme/app_theme.dart';
import 'markdown_styler.dart';

class MarkdownEditingController extends TextEditingController {
  MarkdownEditingController({super.text});

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
        (withComposing && !value.composing.isCollapsed && value.isComposingRangeValid)
            ? value.composing
            : null;

    final key = '${identityHashCode(base)}|${composing?.start}|'
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

      final segStyle = _styleFor(seg.kind, base, c);

      if (composing == null || end <= composing.start || start >= composing.end) {
        children.add(TextSpan(text: seg.text, style: segStyle));
        continue;
      }

      // 与输入法组合区有重叠：切开，重叠的那段加下划线。
      // 这一步不能省——中文候选阶段没有下划线，用户会以为没输入进去。
      final cutA = (composing.start - start).clamp(0, seg.text.length);
      final cutB = (composing.end - start).clamp(0, seg.text.length);
      if (cutA > 0) {
        children.add(TextSpan(text: seg.text.substring(0, cutA), style: segStyle));
      }
      if (cutB > cutA) {
        children.add(TextSpan(
          text: seg.text.substring(cutA, cutB),
          style: (segStyle ?? base)
              .merge(const TextStyle(decoration: TextDecoration.underline)),
        ));
      }
      if (cutB < seg.text.length) {
        children.add(TextSpan(text: seg.text.substring(cutB), style: segStyle));
      }
    }

    return TextSpan(style: base, children: children);
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
          color: c.quaternaryLabel,
          fontSize: size * 0.7,
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
      MdKind.code => base.copyWith(
          fontFamily: 'Consolas',
          backgroundColor: c.fill,
          color: c.label,
        ),
      MdKind.strike => base.copyWith(decoration: TextDecoration.lineThrough),
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
