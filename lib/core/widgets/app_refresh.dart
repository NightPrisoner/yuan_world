/// 自定义下拉刷新。
///
/// 没有用 Material 的 `RefreshIndicator`，原因有两个：
///   1. 它的外观（圆形箭头 + 底色圆盘）是 Material 语言，跟整套 Apple 风格不搭；
///   2. 它只接受一个普通 child，没法参与 Sliver 布局。
///
/// 改用 `CupertinoSliverRefreshControl`，它是 Sliver，
/// 而且允许用 `builder` 完全自绘指示器——正是我们要的效果：
///   - 下拉过程中画一段圆环，进度跟手（拉多长画多长）
///   - 越过阈值后圆环转为持续旋转
///   - 松手回弹走弹性物理，不是生硬的线性
library;

import 'dart:math' as math;

import 'package:flutter/cupertino.dart';

import '../motion/app_motion.dart';
import '../theme/app_theme.dart';

class AppRefresh {
  const AppRefresh._();

  /// 直接放进 `CustomScrollView.slivers` 里。
  ///
  /// 注意：宿主滚动视图必须使用 [BouncingScrollPhysics]，
  /// 否则在 Android 上不会产生 overscroll，下拉刷新永远不会触发。
  static Widget sliver({required Future<void> Function() onRefresh}) {
    return CupertinoSliverRefreshControl(
      onRefresh: onRefresh,
      refreshTriggerPullDistance: 92,
      refreshIndicatorExtent: 56,
      builder: (
        context,
        mode,
        pulledExtent,
        refreshTriggerPullDistance,
        refreshIndicatorExtent,
      ) {
        final t = (pulledExtent / refreshTriggerPullDistance).clamp(0.0, 1.0);
        final spinning = mode == RefreshIndicatorMode.refresh ||
            mode == RefreshIndicatorMode.armed;
        // 指示器随下拉淡入，避免一冒头就很突兀
        final opacity = switch (mode) {
          RefreshIndicatorMode.inactive => 0.0,
          RefreshIndicatorMode.drag => t,
          _ => 1.0,
        };
        return Center(
          child: Opacity(
            opacity: opacity,
            child: _RefreshRing(progress: t, spinning: spinning),
          ),
        );
      },
    );
  }
}

class _RefreshRing extends StatefulWidget {
  const _RefreshRing({required this.progress, required this.spinning});

  final double progress;
  final bool spinning;

  @override
  State<_RefreshRing> createState() => _RefreshRingState();
}

class _RefreshRingState extends State<_RefreshRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    if (widget.spinning) _spin.repeat();
  }

  @override
  void didUpdateWidget(covariant _RefreshRing old) {
    super.didUpdateWidget(old);
    if (widget.spinning && !_spin.isAnimating) {
      _spin.repeat();
    } else if (!widget.spinning && _spin.isAnimating) {
      _spin.stop();
      _spin.value = 0;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      width: 26,
      height: 26,
      child: AnimatedBuilder(
        animation: _spin,
        builder: (context, _) => CustomPaint(
          painter: _RingPainter(
            progress: widget.progress,
            spin: _spin.value,
            color: c.tint,
            track: c.fill,
            spinning: widget.spinning,
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.progress,
    required this.spin,
    required this.color,
    required this.track,
    required this.spinning,
  });

  final double progress;
  final double spin;
  final Color color;
  final Color track;
  final bool spinning;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 2.5;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = track;
    canvas.drawCircle(center, radius, trackPaint);

    // 转圈时扫过 3/4 圆，跟手时按下拉比例画
    final sweep = spinning ? math.pi * 1.5 : math.pi * 2 * progress;
    final start = spinning ? spin * math.pi * 2 : -math.pi / 2;

    final arcPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawArc(rect, start, sweep, false, arcPaint);
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.progress != progress ||
      old.spin != spin ||
      old.color != color ||
      old.spinning != spinning;
}

/// 统一的「空状态」区块，带一点入场动效。
class EmptyHint extends StatelessWidget {
  const EmptyHint({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 48),
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: 1),
          duration: AppMotion.normal,
          curve: AppMotion.enter,
          builder: (context, t, child) => Opacity(
            opacity: t,
            child: Transform.translate(offset: Offset(0, (1 - t) * 10), child: child),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  color: c.fill,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Icon(icon, size: 30, color: c.tertiaryLabel),
              ),
              const SizedBox(height: 18),
              Text(title, style: AppText.title3.copyWith(color: c.label)),
              if (subtitle != null) ...[
                const SizedBox(height: 7),
                Text(
                  subtitle!,
                  textAlign: TextAlign.center,
                  style: AppText.footnote.copyWith(
                    color: c.secondaryLabel,
                    height: 1.6,
                  ),
                ),
              ],
              if (action != null) ...[const SizedBox(height: 22), action!],
            ],
          ),
        ),
      ),
    );
  }
}
