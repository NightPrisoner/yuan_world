/// 待办用的圆形勾选框。
///
/// 动效细节（这是"丝滑"的关键，全部走弹簧而不是固定时长曲线）：
///   - 未选中：细描边空心圆
///   - 勾选瞬间：圆从空心填充为主题色，同时对勾号做一个带过冲的弹出
///   - 取消勾选：反向播放，勾号先"缩回去"再清空圆
///   - 全程叠一层很轻的缩放脉冲，让点击有"实体反馈"
library;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../motion/app_motion.dart';
import '../theme/app_theme.dart';

class TodoCheck extends StatefulWidget {
  const TodoCheck({
    super.key,
    required this.checked,
    required this.onChanged,
    this.size = 24,
    this.color,
  });

  final bool checked;
  final ValueChanged<bool> onChanged;
  final double size;
  final Color? color;

  @override
  State<TodoCheck> createState() => _TodoCheckState();
}

class _TodoCheckState extends State<TodoCheck> with TickerProviderStateMixin {
  /// 勾号绘制进度（0 → 1 画完）。走弹簧，落笔有"啪"的一下的手感。
  late final AnimationController _mark = AnimationController.unbounded(
    vsync: this,
  )..value = widget.checked ? 1 : 0;

  /// 点按脉冲。
  ///
  /// 这里**不是**"推到 1 再拉回 0"，而是给弹簧一个初速度让它自己荡回来：
  /// `SpringSimulation(spring, 1, 1, v)` 起点终点都是 1，光靠初速度
  /// 冲出去、再自己收回来 —— 这才是"弹一下"的物理写法。
  /// 之前是 `forward().then(reverse)` 两段固定时长，收尾是硬的。
  late final AnimationController _pulse = AnimationController.unbounded(
    vsync: this,
  )..value = 1;
  late final Listenable _ticker = Listenable.merge([_mark, _pulse]);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduceMotion(context)) {
      _mark.value = widget.checked ? 1 : 0;
      _pulse.value = 1;
    }
  }

  @override
  void didUpdateWidget(covariant TodoCheck old) {
    super.didUpdateWidget(old);
    if (widget.checked != old.checked) {
      if (AppMotion.reduceMotion(context)) {
        _mark.value = widget.checked ? 1 : 0;
        _pulse.value = 1;
        return;
      }
      if (widget.checked) {
        // 正的初速度 → 先胀出去再荡回来
        _pulse
          ..value = 1
          ..animateWith(SpringSimulation(AppMotion.bouncy, 1, 1, 4.2));
        _mark.animateWith(
          SpringSimulation(AppMotion.bouncy, _mark.value, 1, 0),
        );
      } else {
        _mark.animateWith(
          SpringSimulation(AppMotion.snappy, _mark.value, 0, 0),
        );
      }
    }
  }

  @override
  void dispose() {
    _mark.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tint = widget.color ?? c.tint;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => widget.onChanged(!widget.checked),
      child: SizedBox(
        width: widget.size + 12,
        height: widget.size + 12,
        child: Center(
          child: AnimatedBuilder(
            animation: _ticker,
            builder: (context, _) {
              // 脉冲：弹簧会荡到 1 以上再收回来，直接当倍率用就行。
              // 夹一下范围：弹簧过冲不受控，别让它在极端情况下把圆撑爆。
              final pulse = (1 + 0.12 * (_pulse.value - 1)).clamp(0.85, 1.22);
              return Transform.scale(
                scale: pulse,
                child: CustomPaint(
                  size: Size.square(widget.size + 4),
                  painter: _CheckPainter(
                    // 弹簧会冲过 1，画的时候夹住 —— 让它"冲"但不画出界
                    progress: _mark.value.clamp(0.0, 1.0),
                    tint: tint,
                    border: c.tertiaryLabel,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CheckPainter extends CustomPainter {
  _CheckPainter({
    required this.progress,
    required this.tint,
    required this.border,
  });

  /// 0 = 未勾选，1 = 完全勾选
  final double progress;
  final Color tint;
  final Color border;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2 - 1.5;

    // 圆环：随进度从描边过渡到实心
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..color = Color.lerp(border, tint, progress)!;
    canvas.drawCircle(center, radius, ringPaint);

    if (progress > 0) {
      final fill = Paint()
        ..style = PaintingStyle.fill
        ..color = tint.withValues(alpha: progress);
      canvas.drawCircle(center, radius, fill);

      // 勾号：两段线，前半段先画，后半段后画，形成"写出来"的感觉
      final checkPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.1
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.white.withValues(alpha: progress);

      final w = size.width;
      final h = size.height;
      final p1 = Offset(w * 0.28, h * 0.52);
      final p2 = Offset(w * 0.44, h * 0.68);
      final p3 = Offset(w * 0.73, h * 0.34);

      // 用两段进度控制笔迹生长
      final firstLeg = Curves.easeOut.transform(
        (progress / 0.45).clamp(0.0, 1.0),
      );
      final secondLeg = Curves.easeOut.transform(
        ((progress - 0.45) / 0.55).clamp(0.0, 1.0),
      );

      final path = Path()..moveTo(p1.dx, p1.dy);
      path.lineTo(
        p1.dx + (p2.dx - p1.dx) * firstLeg,
        p1.dy + (p2.dy - p1.dy) * firstLeg,
      );
      if (secondLeg > 0) {
        path.lineTo(
          p2.dx + (p3.dx - p2.dx) * secondLeg,
          p2.dy + (p3.dy - p2.dy) * secondLeg,
        );
      }
      canvas.drawPath(path, checkPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _CheckPainter old) =>
      old.progress != progress || old.tint != tint || old.border != border;
}

/// 会「画」出来的删除线：完成时从左到右划过文字。
class AnimatedStrikethrough extends StatelessWidget {
  const AnimatedStrikethrough({
    super.key,
    required this.done,
    required this.child,
  });

  final bool done;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Stack(
      children: [
        child,
        Positioned.fill(
          child: TweenAnimationBuilder<double>(
            tween: Tween<double>(begin: 0, end: done ? 1 : 0),
            duration: AppMotion.respecting(context, AppMotion.fast),
            curve: AppMotion.enter,
            builder: (context, t, _) => CustomPaint(
              painter: _StrikePainter(progress: t, color: c.secondaryLabel),
            ),
          ),
        ),
      ],
    );
  }
}

class _StrikePainter extends CustomPainter {
  _StrikePainter({required this.progress, required this.color});
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    final y = size.height / 2;
    canvas.drawLine(Offset(0, y), Offset(size.width * progress, y), paint);
  }

  @override
  bool shouldRepaint(covariant _StrikePainter old) =>
      old.progress != progress || old.color != color;
}
