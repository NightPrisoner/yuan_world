/// 动效系统。
///
/// 参考 Apple HIG 的 Motion 原则实现，关键几条：
///
/// 1. **动效要服务于理解，不是装饰**
///    —— 转场表达层级关系（新页面从右侧推入、返回时原路退回）。
/// 2. **可中断、跟手**
///    —— 用弹簧物理而非固定时长曲线；用户中途反向操作要能立刻响应。
/// 3. **空间一致性**
///    —— 同一个元素跨页面移动时保持位置连续（Hero）。
/// 4. **尊重「减弱动态效果」**
///    —— [AppMotion.reduceMotion] 会在系统开启该选项时把动效降为直接切换。
/// 5. **时长克制**
///    —— 交互反馈 120~200ms，页面转场 350~400ms，超过 500ms 就会觉得拖沓。
library;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

class AppMotion {
  const AppMotion._();

  // ── 时长 ────────────────────────────────────────────────────────────────
  /// 即时反馈：按下高亮、勾选
  static const Duration instant = Duration(milliseconds: 120);

  /// 小范围状态变化：开关、展开
  static const Duration fast = Duration(milliseconds: 200);

  /// 常规过渡：卡片出现、页面内元素切换
  static const Duration normal = Duration(milliseconds: 300);

  /// 页面推入 / 弹出
  static const Duration page = Duration(milliseconds: 380);

  /// 模态面板升起
  static const Duration sheet = Duration(milliseconds: 420);

  // ── 缓动曲线 ────────────────────────────────────────────────────────────

  /// iOS 进入曲线（UIViewAnimationCurveEaseOut 的近似拟合）
  static const Curve enter = Cubic(0.32, 0.72, 0, 1);

  /// iOS 退出曲线
  static const Curve exit = Cubic(0.4, 0, 1, 1);

  /// Material 强调曲线，用于较大幅度的位置移动
  static const Curve emphasized = Cubic(0.2, 0, 0, 1);

  /// 标准缓入缓出
  static const Curve standard = Cubic(0.4, 0, 0.2, 1);

  // ── 弹簧参数 ────────────────────────────────────────────────────────────

  /// 利落、无回弹（大部分界面用这个）
  static SpringDescription get snappy =>
      SpringDescription.withDampingRatio(mass: 1, stiffness: 500, ratio: 1.0);

  /// 轻微回弹（按下、弹窗出现）
  static SpringDescription get bouncy =>
      SpringDescription.withDampingRatio(mass: 1, stiffness: 420, ratio: 0.78);

  /// 强回弹（用于强调、拖拽释放）
  static SpringDescription get elastic =>
      SpringDescription.withDampingRatio(mass: 1, stiffness: 360, ratio: 0.6);

  /// 系统是否开启「减弱动态效果」。
  static bool reduceMotion(BuildContext context) =>
      MediaQuery.maybeOf(context)?.disableAnimations ?? false;

  /// 在减弱动效时退化为零时长。
  static Duration respecting(BuildContext context, Duration d) =>
      reduceMotion(context) ? Duration.zero : d;
}

/// 用真实弹簧物理驱动一个数值的动画容器。
///
/// 与 `AnimatedContainer` 的区别：这里跑的是 [SpringSimulation]，
/// 速度可以在动画中途继承，因此连续操作不会出现「速度突变」的顿挫感。
class SpringAnimatedValue extends StatefulWidget {
  const SpringAnimatedValue({
    super.key,
    required this.value,
    required this.builder,
    this.spring,
    this.velocity = 0,
  });

  final double value;
  final Widget Function(BuildContext context, double value) builder;
  final SpringDescription? spring;
  final double velocity;

  @override
  State<SpringAnimatedValue> createState() => _SpringAnimatedValueState();
}

class _SpringAnimatedValueState extends State<SpringAnimatedValue>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController.unbounded(vsync: this)
    ..value = widget.value;

  @override
  void didUpdateWidget(covariant SpringAnimatedValue old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value) {
      final spring = widget.spring ?? AppMotion.snappy;
      // 继承当前速度，保证连续操作时运动连续
      final current = _c.velocity;
      _c.animateWith(
        SpringSimulation(spring, _c.value, widget.value, current),
      );
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      AnimatedBuilder(
        animation: _c,
        builder: (c, _) => widget.builder(c, _c.value),
      );
}

/// 可按压的容器：按下时轻微缩小 + 降低不透明度 + 触感反馈。
///
/// 这是 iOS 上「按钮有生命感」的关键细节——
/// 反馈必须在 touchDown 时立刻出现，而不是等抬手。
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.scale = 0.97,
    this.opacity = 0.72,
    this.haptic = true,
    this.borderRadius,
    this.behavior = HitTestBehavior.opaque,
  });
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// 右键（或双指点击）。回调带上指针的全局坐标，
  /// 这样菜单可以贴着鼠标弹出，而不是跑到屏幕别处。
  final void Function(Offset globalPosition)? onSecondaryTap;

  final double scale;
  final double opacity;
  final bool haptic;
  final BorderRadius? borderRadius;
  final HitTestBehavior behavior;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  /// 记录右键按下的位置，抬手时用它定位菜单。
  Offset _secondaryAt = Offset.zero;

  void _set(bool v) {
    if (_down == v) return;
    setState(() => _down = v);
    if (v && widget.haptic) {
      // 轻微触感，iOS 上对应 UIImpactFeedbackGenerator(.light)
      HapticFeedback.selectionClick();
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduce = AppMotion.reduceMotion(context);
    final child = widget.child;
    final hasSecondary = widget.onSecondaryTap != null;

    return MouseRegion(
      cursor: widget.onTap != null
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      child: GestureDetector(
        behavior: widget.behavior,
        onTapDown: widget.onTap == null ? null : (_) => _set(true),
        onTapUp: widget.onTap == null ? null : (_) => _set(false),
        onTapCancel: widget.onTap == null ? null : () => _set(false),
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        onSecondaryTapDown:
            hasSecondary ? (d) => _secondaryAt = d.globalPosition : null,
        onSecondaryTap:
            hasSecondary ? () => widget.onSecondaryTap!(_secondaryAt) : null,
        child: AnimatedScale(
          scale: (!reduce && _down) ? widget.scale : 1.0,
          duration: AppMotion.instant,
          curve: AppMotion.enter,
          child: AnimatedOpacity(
            opacity: (!reduce && _down) ? widget.opacity : 1.0,
            duration: AppMotion.instant,
            curve: AppMotion.enter,
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 上下文菜单里的图标按钮（iOS 那种圆形毛玻璃按钮）。
class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.size = 32,
    this.iconSize = 17,
    this.color,
    this.background,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;
  final Color? color;
  final Color? background;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final c = Theme.of(context).extension<AppColors>() ?? AppColors.light;
    Widget btn = Pressable(
      onTap: onTap,
      scale: 0.9,
      borderRadius: BorderRadius.circular(size),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: background ?? c.fill,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: iconSize, color: color ?? c.tint),
      ),
    );
    if (tooltip != null) btn = Tooltip(message: tooltip!, child: btn);
    return btn;
  }
}
