/// 目录侧栏（阅读页和**编辑器**共用同一个）。
///
/// 以前只有阅读页有目录，编辑的时候没有任何目录相关功能 —— 长文写到一半
/// 想跳回某一段只能自己滚。同一个东西做两遍必然会长歪，所以抽出来共用。
///
/// 它是**停靠**在正文旁边的（对齐 Word 的导航窗格），不是浮在内容上的外挂件：
/// 正文该多宽就多宽，目录不遮字；位置可左右切换，宽度可拖。
library;

import 'package:flutter/material.dart';

import '../../../core/motion/app_motion.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/toc.dart';

class TocPanel extends StatelessWidget {
  const TocPanel({
    super.key,
    required this.entries,
    required this.minLevel,
    required this.width,
    required this.side,
    required this.onTap,
    required this.onFlipSide,
    required this.onClose,
  });

  final List<TocEntry> entries;
  final int minLevel;
  final double width;

  /// `left` | `right`
  final String side;

  final void Function(TocEntry entry) onTap;
  final VoidCallback onFlipSide;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return Container(
      width: width,
      decoration: BoxDecoration(
        color: c.groupedBackground,
        // 只在与正文相邻的那一侧画分隔线，看起来才像"窗格"而不是"卡片"
        border: Border(
          right: side == 'left'
              ? BorderSide(color: c.separator, width: 0.5)
              : BorderSide.none,
          left: side == 'right'
              ? BorderSide(color: c.separator, width: 0.5)
              : BorderSide.none,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 8),
            child: Row(
              children: [
                Icon(Icons.toc_rounded, size: 15, color: c.secondaryLabel),
                const SizedBox(width: 7),
                Text(
                  '目录',
                  style: AppText.footnote.copyWith(
                    color: c.label,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Pressable(
                  onTap: onFlipSide,
                  scale: 0.86,
                  child: Tooltip(
                    message: side == 'left' ? '移到右侧' : '移到左侧',
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        side == 'left'
                            ? Icons.keyboard_double_arrow_right_rounded
                            : Icons.keyboard_double_arrow_left_rounded,
                        size: 16,
                        color: c.tertiaryLabel,
                      ),
                    ),
                  ),
                ),
                Pressable(
                  onTap: onClose,
                  scale: 0.86,
                  child: Tooltip(
                    message: '关闭目录',
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.close_rounded,
                          size: 15, color: c.tertiaryLabel),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: c.separator),
          Flexible(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 6),
              shrinkWrap: true,
              itemCount: entries.length,
              itemBuilder: (context, i) {
                final e = entries[i];
                return Pressable(
                  onTap: () => onTap(e),
                  scale: 0.99,
                  haptic: false,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      14 + e.depthOf(minLevel) * 13.0,
                      6,
                      12,
                      6,
                    ),
                    child: Text(
                      e.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.footnote.copyWith(
                        color: e.level == minLevel ? c.label : c.secondaryLabel,
                        fontWeight: e.level == minLevel
                            ? FontWeight.w600
                            : FontWeight.w400,
                        height: 1.4,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 目录栏与正文之间的拖拽分隔条（宽度可调）。
///
/// 命中区域 8px、视觉只有 0.5px —— 1px 的线鼠标根本抓不住；
/// 悬停/拖动时才亮起来并变粗，平时不抢戏。
class TocResizer extends StatefulWidget {
  const TocResizer({super.key, required this.onDrag, this.onEnd});

  final void Function(double dx) onDrag;
  final VoidCallback? onEnd;

  @override
  State<TocResizer> createState() => _TocResizerState();
}

class _TocResizerState extends State<TocResizer> {
  bool _hover = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final active = _hover || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
        onHorizontalDragEnd: (_) {
          setState(() => _dragging = false);
          widget.onEnd?.call();
        },
        onHorizontalDragCancel: () {
          setState(() => _dragging = false);
          widget.onEnd?.call();
        },
        child: SizedBox(
          width: 8,
          child: Align(
            child: AnimatedContainer(
              duration: AppMotion.instant,
              width: active ? 2 : 0.5,
              height: double.infinity,
              color: active ? c.tint : c.separator,
            ),
          ),
        ),
      ),
    );
  }
}
