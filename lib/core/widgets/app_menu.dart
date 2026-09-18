/// 自适应菜单：桌面端贴着触发处弹下拉，手机端从底部升面板。
///
/// 为什么要分两套：
///   - **桌面**（Windows/macOS/Linux）：鼠标点在哪儿，菜单就该出现在哪儿。
///     从窗口最底部升起一个面板，视线要跑一整屏，而且和点击位置毫无关联，
///     用户根本建立不起"我点了这个 → 出现了那个"的因果感。
///   - **手机**：底部面板才是对的。拇指天然在屏幕下方，
///     下拉菜单在窄屏上还容易被裁掉。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../motion/app_motion.dart';
import '../theme/app_theme.dart';

/// 菜单的定位信息。
///
/// 优先用 [context]（贴着某个控件弹）；没有就退回 [position]（贴着指针位置）。
/// 右键菜单用后者更自然，按钮触发用前者更稳定。
class AppMenuAnchor {
  const AppMenuAnchor({this.context, this.position});

  final BuildContext? context;
  final Offset? position;

  factory AppMenuAnchor.at(Offset position) => AppMenuAnchor(position: position);
}

/// 一个菜单项。
class AppMenuItem<T> {
  const AppMenuItem({
    required this.value,
    required this.label,
    required this.icon,
    this.color,
    this.destructive = false,
    this.enabled = true,
    this.dividerBefore = false,
  });

  final T value;
  final String label;
  final IconData icon;
  final Color? color;

  /// 破坏性操作（删除这类），用红色并加粗。
  final bool destructive;

  final bool enabled;

  /// 在这一项**之前**画一条分隔线，用来给菜单分组。
  ///
  /// 排序菜单就靠它分成「字段」和「方向」两段 ——
  /// Windows 资源管理器是这么分的，一眼能看出是两组独立的选项。
  final bool dividerBefore;
}

/// 是否该用锚定下拉菜单。
///
/// 桌面系统一律用；手机即使是宽屏平板也用底部面板——那更符合手指的操作习惯。
bool prefersAnchoredMenu(BuildContext context) {
  if (isDesktopPlatform()) return true;
  return MediaQuery.sizeOf(context).width >= 900;
}

/// 是不是桌面系统。
///
/// 桌面和手机在交互上要分两套：菜单弹出位置、拖拽的起手方式都不一样。
/// 手机用长按起拖（直接拖会跟滚动打架），桌面用直接拖。
bool isDesktopPlatform() =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// 上一次弹出菜单的位置。
///
/// 二级菜单（"导出为 → 格式"、"批量操作 → 移动到"）都是在**父菜单已经关闭
/// 之后**才弹的，那时锚点的 BuildContext 早就失效了。这时候该贴着父菜单的
/// 位置弹 —— 用户的手还在那儿。没有这个记录的话，就会退化成"贴着整个页面"
/// 弹到屏幕角落去。
Rect? _lastMenuRect;

/// 弹出菜单。返回被选中项的 value，取消返回 null。
Future<T?> showAppMenu<T>(
  BuildContext context, {
  required List<AppMenuItem<T>> items,
  AppMenuAnchor? anchor,
  String? header,
  String? footerLabel,
  IconData? footerIcon,
  T? footerValue,
}) async {
  if (items.isEmpty && footerValue == null) return null;
  final c = context.colors;

  // 桌面端**一律**用贴着锚点的下拉菜单，绝不用底部面板。
  //
  // 锚点的优先级：显式传入 > 上一次菜单的位置（二级菜单）> 调用处自己。
  if (prefersAnchoredMenu(context)) {
    final explicit = anchor == null ? null : _anchorRect(context, anchor);
    final rect = explicit ?? _lastMenuRect ?? _rectOf(context);
    _lastMenuRect = rect;
    {
      final overlay =
          Overlay.of(context).context.findRenderObject() as RenderBox?;
      if (overlay != null && overlay.hasSize) {
        // 贴着锚点下沿展开；右边界给 0 让菜单自己决定宽度
        final position = RelativeRect.fromLTRB(
          rect.left,
          rect.bottom + 4,
          overlay.size.width - rect.left,
          0,
        );

        return showMenu<T>(
          context: context,
          position: position,
          color: c.secondaryBackground,
          elevation: 12,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
          ),
          items: <PopupMenuEntry<T>>[
            if (header != null)
              PopupMenuItem<T>(
                enabled: false,
                height: 34,
                child: Text(
                  header,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption1.copyWith(
                    color: c.tertiaryLabel,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            for (final it in items) ...[
              if (it.dividerBefore) const PopupMenuDivider(),
              PopupMenuItem<T>(
                value: it.value,
                enabled: it.enabled,
                height: 42,
                child: _MenuRow(item: it),
              ),
            ],
            if (footerValue != null) ...[
              const PopupMenuDivider(),
              PopupMenuItem<T>(
                value: footerValue,
                height: 42,
                child: _MenuRow(
                  item: AppMenuItem<T>(
                    value: footerValue,
                    label: footerLabel ?? '新建…',
                    icon: footerIcon ?? Icons.add_rounded,
                  ),
                ),
              ),
            ],
          ],
        );
      }
    }
  }

  // ── 手机端：底部面板 ──
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: c.secondaryBackground,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (header != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        header,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.headline.copyWith(color: c.label),
                      ),
                    ),
                  ],
                ),
              ),
            const Divider(height: 1),
            for (final it in items) ...[
              if (it.dividerBefore) const Divider(height: 1),
              _SheetRow(
                item: it,
                onTap: it.enabled ? () => Navigator.pop(ctx, it.value) : null,
              ),
            ],
            if (footerValue != null) ...[
              const Divider(height: 1),
              _SheetRow(
                item: AppMenuItem<T>(
                  value: footerValue,
                  label: footerLabel ?? '新建…',
                  icon: footerIcon ?? Icons.add_rounded,
                  color: c.tint,
                ),
                onTap: () => Navigator.pop(ctx, footerValue),
              ),
            ],
            const SizedBox(height: 6),
          ],
        ),
      ),
    ),
  );
}

/// 没给锚点时的兜底：用**调用处自己**的位置。
///
/// 调用 `showAppMenu` 的地方大多是一个按钮或一个 State 的 context，
/// 它的 RenderBox 就是天然锚点。实在拿不到（比如挂在没有尺寸的节点上），
/// 就贴着屏幕顶部中间弹 —— **无论如何不能退回底部面板**。
Rect _rectOf(BuildContext context) {
  final box = context.findRenderObject();
  if (box is RenderBox && box.hasSize && box.size.width > 0) {
    final rect = box.localToGlobal(Offset.zero) & box.size;
    // 按钮、图标这种小控件，它的矩形就是天然锚点。
    if (rect.width <= 480 && rect.height <= 140) return rect;
    // 整个页面这种大块头**不能**当锚点：用它的底边会把菜单推到屏幕最下面
    // （用户看到的就是"菜单跑到右下角去了"）。取中上部一个点。
    return Rect.fromLTWH(rect.left + rect.width * 0.5, rect.top + 72, 1, 1);
  }

  final overlay = Overlay.maybeOf(context)?.context.findRenderObject();
  final size = overlay is RenderBox && overlay.hasSize
      ? overlay.size
      : MediaQuery.sizeOf(context);
  return Rect.fromLTWH(size.width * 0.35, size.height * 0.15, 1, 1);
}

/// 算出锚点的全局矩形。
Rect? _anchorRect(BuildContext context, AppMenuAnchor anchor) {
  final ac = anchor.context;
  if (ac != null && ac.mounted) {
    final box = ac.findRenderObject();
    if (box is RenderBox && box.hasSize) {
      return box.localToGlobal(Offset.zero) & box.size;
    }
  }
  final pos = anchor.position;
  if (pos != null) return Rect.fromLTWH(pos.dx, pos.dy, 1, 1);
  return null;
}

class _MenuRow<T> extends StatelessWidget {
  const _MenuRow({required this.item});
  final AppMenuItem<T> item;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final base = item.destructive ? c.destructive : c.label;
    final color = item.enabled ? (item.color ?? base) : c.quaternaryLabel;
    return Row(
      children: [
        Icon(item.icon, size: 17, color: color),
        const SizedBox(width: 11),
        Expanded(
          child: Text(
            item.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.callout.copyWith(
              color: color,
              fontWeight: item.destructive ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ],
    );
  }
}

class _SheetRow<T> extends StatelessWidget {
  const _SheetRow({required this.item, required this.onTap});
  final AppMenuItem<T> item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final base = item.destructive ? c.destructive : c.label;
    final color = item.enabled ? (item.color ?? base) : c.quaternaryLabel;
    return Pressable(
      onTap: onTap,
      scale: 0.99,
      opacity: 0.6,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 15),
        child: Row(
          children: [
            Icon(item.icon, size: 19, color: color),
            const SizedBox(width: 13),
            Text(
              item.label,
              style: AppText.callout.copyWith(
                color: color,
                fontWeight: item.destructive ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
