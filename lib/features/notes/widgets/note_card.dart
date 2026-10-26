/// 笔记卡片：列表态与瀑布流态两种形态。
///
/// 视觉参考小米笔记的卡片（标题 / 摘要 / 时间 / 右侧缩略图），
/// 但排版与圆角、按压反馈按 Apple 的观感做：
/// - 卡片圆角 16，按压缩放 0.98
/// - 元信息用次要色，字号 12，不抢正文
/// - 截图渐显 + 从模糊到清晰的过渡，避免图片"跳"出来
library;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../../core/motion/app_motion.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_menu.dart';
import '../../../core/widgets/local_image.dart';
import '../../../data/models.dart';

class NoteCard extends StatefulWidget {
  const NoteCard({
    super.key,
    required this.note,
    required this.imageRoot,
    required this.onTap,
    required this.onLongPress,
    this.onSecondaryTap,
    this.onMore,
    this.compact = false,
    this.enableHero = true,
    this.displayTime,
  });
  final Note note;
  final String imageRoot;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// 右键菜单（桌面端主要入口），带上指针位置以便菜单贴着鼠标弹
  final void Function(AppMenuAnchor anchor)? onSecondaryTap;

  /// 悬停时出现的 ⋯ 按钮，带上按钮自身的 context 以便菜单贴着它弹
  final void Function(AppMenuAnchor anchor)? onMore;

  /// true = 瀑布流卡片；false = 横向列表行。
  final bool compact;

  /// 卡片上显示哪个时间。由**当前排序字段**决定 ——
  /// 按创建日期排就该显示创建时间，否则用户会觉得顺序不对。
  /// 为空时退回笔记自己的默认时间。
  final DateTime? displayTime;

  /// 三栏布局里列表和详情在同一个路由，Hero tag 会撞车，所以那边要关掉。
  final bool enableHero;

  @override
  State<NoteCard> createState() => _NoteCardState();
}

class _NoteCardState extends State<NoteCard> {
  bool _hover = false;

  Note get note => widget.note;
  String get imageRoot => widget.imageRoot;

  /// 这张卡片真的该显示的头图（相对路径）。
  ///
  /// 用 [displayCover] 而不是 `effectiveCover`：`__none__`（用户明确不要
  /// 头图）是个非空串，只看 isNotEmpty 会把它当路径去拼文件名；另外它还会
  /// 排掉**文件已经不在**的路径 —— 否则卡片顶上会留一条空荡荡的灰条。
  String? get _cover => displayCover(note.coverImage, imageRoot);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hasCover = _cover != null;

    return MouseRegion(
      onEnter: (_) {
        if (!_hover) setState(() => _hover = true);
      },
      onExit: (_) {
        if (_hover) setState(() => _hover = false);
      },
      child: Pressable(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onSecondaryTap: widget.onSecondaryTap == null
            ? null
            : (pos) => widget.onSecondaryTap!(AppMenuAnchor.at(pos)),
        scale: 0.98,
        child: Stack(
          children: [
            Container(
              decoration: BoxDecoration(
                color: c.secondaryBackground,
                borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
                border: Border.all(
                  color: c.isDark
                      ? c.separator.withValues(alpha: 0.5)
                      : const Color(0x14000000),
                  width: 0.5,
                ),
                boxShadow: c.isDark
                    ? null
                    : const <BoxShadow>[
                        BoxShadow(
                          color: Color(0x0A000000),
                          blurRadius: 12,
                          offset: Offset(0, 2),
                        ),
                      ],
              ),
              clipBehavior: Clip.antiAlias,
              child: widget.compact
                  ? _buildGrid(context, hasCover, c)
                  : _buildRow(context, hasCover, c),
            ),
            // 悬停时右上角浮出 ⋯ 按钮：
            // 长按/右键都有"要猜"的成本，这个按钮是唯一一眼能看到的入口。
            if (widget.onMore != null && _hover)
              Positioned(
                top: 4,
                right: 4,
                child: Builder(
                  builder: (btnCtx) => _MoreButton(
                    onTap: () => widget.onMore!(AppMenuAnchor(context: btnCtx)),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── 列表行 ──────────────────────────────────────────────────────────────

  Widget _buildRow(BuildContext context, bool hasCover, AppColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 13, 12, 13),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _titleRow(c),
                if (note.excerpt.isNotEmpty) ...[
                  const SizedBox(height: 5),
                  Text(
                    note.excerpt,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.footnote.copyWith(
                      color: c.secondaryLabel,
                      height: 1.5,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                _metaRow(c),
              ],
            ),
          ),
          if (hasCover) ...[
            const SizedBox(width: 12),
            _maybeHero(
              _Thumb(
                path: p.join(imageRoot, _cover!),
                size: 66,
                fadeIn: !widget.enableHero,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── 瀑布流卡片 ──────────────────────────────────────────────────────────

  Widget _buildGrid(BuildContext context, bool hasCover, AppColors c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasCover)
          _maybeHero(
            _Cover(
              path: p.join(imageRoot, _cover!),
              color: c.fill,
              fadeIn: !widget.enableHero,
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(13, 11, 13, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _titleRow(c, maxLines: 2),
              if (note.excerpt.isNotEmpty) ...[
                const SizedBox(height: 5),
                Text(
                  note.excerpt,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.footnote.copyWith(
                    color: c.secondaryLabel,
                    height: 1.55,
                  ),
                ),
              ],
              const SizedBox(height: 9),
              _metaRow(c),
            ],
          ),
        ),
      ],
    );
  }

  // ── 公共片断 ────────────────────────────────────────────────────────────

  /// Hero：让缩略图在列表 → 详情之间连续飞行，而不是"消失再出现"。
  /// 三栏布局里两边同处一个路由，必须关掉，否则 tag 冲突。
  Widget _maybeHero(Widget child) {
    if (!widget.enableHero) return child;
    return Hero(tag: 'note-cover-${note.id}', child: child);
  }

  Widget _titleRow(AppColors c, {int maxLines = 1}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (note.isPinned) ...[
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 5),
            child: Icon(Icons.push_pin, size: 13, color: c.tint),
          ),
        ],
        Expanded(
          child: Text(
            note.title.isEmpty ? '无标题笔记' : note.title,
            maxLines: maxLines,
            overflow: TextOverflow.ellipsis,
            style: AppText.callout.copyWith(
              color: note.title.isEmpty ? c.tertiaryLabel : c.label,
              fontWeight: FontWeight.w600,
              height: 1.35,
            ),
          ),
        ),
        if (note.isFavorite)
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 1),
            child: Icon(Icons.star_rounded, size: 15, color: c.palette[7]),
          ),
      ],
    );
  }

  Widget _metaRow(AppColors c) {
    final parts = <String>[
      formatRelative(widget.displayTime ?? note.displayTime),
      if (note.collectionName != null && note.collectionName!.isNotEmpty)
        note.collectionName!,
      if (note.charCount > 0) '${_fmtNum(note.charCount)} 字',
    ];
    return Row(
      children: [
        if (note.collectionColor != null) ...[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: Color(note.collectionColor!),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 5),
        ],
        Expanded(
          child: Text(
            parts.join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption1.copyWith(color: c.tertiaryLabel),
          ),
        ),
        if (note.imageCount > 0) ...[
          Icon(Icons.image_outlined, size: 12, color: c.tertiaryLabel),
          const SizedBox(width: 3),
          Text(
            '${note.imageCount}',
            style: AppText.caption1.copyWith(color: c.tertiaryLabel),
          ),
        ],
      ],
    );
  }

  static String _fmtNum(int n) {
    if (n >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}

/// 卡片右上角的「更多操作」按钮。
class _MoreButton extends StatelessWidget {
  const _MoreButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Pressable(
      onTap: onTap,
      scale: 0.88,
      child: Container(
        width: 26,
        height: 26,
        decoration: BoxDecoration(
          color: c.secondaryBackground.withValues(alpha: 0.92),
          shape: BoxShape.circle,
          border: Border.all(
            color: c.isDark ? c.separator : const Color(0x14000000),
            width: 0.5,
          ),
        ),
        child: Icon(
          Icons.more_horiz_rounded,
          size: 16,
          color: c.secondaryLabel,
        ),
      ),
    );
  }
}

/// 圆角缩略图，带从模糊到清晰的渐显。
class _Thumb extends StatelessWidget {
  const _Thumb({required this.path, required this.size, this.fadeIn = true});
  final String path;
  final double size;
  final bool fadeIn;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
      child: SizedBox(
        width: size,
        height: size,
        child: _LocalImage(path: path, color: c.fill, fadeIn: fadeIn),
      ),
    );
  }
}

/// 卡片顶部封面图。
class _Cover extends StatelessWidget {
  const _Cover({required this.path, required this.color, this.fadeIn = true});
  final String path;
  final Color color;
  final bool fadeIn;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 16 / 10,
      child: _LocalImage(path: path, color: color, fadeIn: fadeIn),
    );
  }
}

/// 本地图片加载：带淡入 + 失败兜底。
///
/// 用 [LocalImage] 而不是裸 `Image.file`：同一个组件在列表里当 96px 的
/// 缩略图、在卡片里当 300px 的封面，解码尺寸得跟着显示尺寸走 ——
/// 不然一张 9MB 的图会被整张解码进内存（见 local_image.dart 的说明）。
class _LocalImage extends StatelessWidget {
  const _LocalImage({
    required this.path,
    required this.color,
    this.fadeIn = true,
  });
  final String path;
  final Color color;
  final bool fadeIn;

  @override
  Widget build(BuildContext context) {
    return LocalImage(
      path: path,
      fit: BoxFit.cover,
      fallbackColor: color,
      fadeIn: fadeIn,
      errorBuilder: (context) => ColoredBox(
        color: color,
        child: const Center(child: Icon(Icons.broken_image_outlined, size: 18)),
      ),
    );
  }
}

/// 相对时间：刚刚 / 5 分钟前 / 昨天 / 09-12 / 2023-09-12
String formatRelative(DateTime t) {
  final now = DateTime.now();
  final diff = now.difference(t);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24 && now.day == t.day) return '${diff.inHours} 小时前';

  final yesterday = now.subtract(const Duration(days: 1));
  if (t.year == yesterday.year &&
      t.month == yesterday.month &&
      t.day == yesterday.day) {
    return '昨天';
  }
  if (t.year == now.year) {
    return '${_pad2(t.month)}-${_pad2(t.day)}';
  }
  return '${t.year}-${_pad2(t.month)}-${_pad2(t.day)}';
}

String _pad2(int v) => v.toString().padLeft(2, '0');
