/// Apple 风格的页面转场。
///
/// 与系统默认转场的区别：
/// 1. 被推入的新页面从右侧滑入（Offset(1,0) → 0）
/// 2. 旧页面同时向左位移 28%、轻微缩小并压暗，形成明确的层次纵深
/// 3. 模态页（`fullscreenDialog: true`）从底部升起
/// 4. 全程尊重系统的「减弱动态效果」开关
///
/// 之所以不用 `CupertinoPageRoute`：它假设了 iOS 的手势与阴影模型，
/// 在桌面端表现怪异；而我们要 Windows 与 Android 观感完全一致。
library;

// fullscreenDialog 需要参与转场时长的计算，无法改用 super parameter
// ignore_for_file: use_super_parameters

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_motion.dart';

class ApplePageRoute<T> extends PageRouteBuilder<T> {
  ApplePageRoute({
    required WidgetBuilder pageBuilder,
    super.settings,
    bool fullscreenDialog = false,
  }) : super(
         transitionDuration:
             fullscreenDialog ? AppMotion.sheet : AppMotion.page,
         reverseTransitionDuration:
             fullscreenDialog ? AppMotion.sheet : AppMotion.page,
         fullscreenDialog: fullscreenDialog,
         pageBuilder: (context, animation, secondaryAnimation) =>
             pageBuilder(context),
         transitionsBuilder:
             (context, animation, secondaryAnimation, child) => _buildTransition(
               context,
               animation,
               secondaryAnimation,
               child,
               fullscreenDialog,
             ),
       );

  static Widget _buildTransition(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
    bool fromBottom,
  ) {
    if (AppMotion.reduceMotion(context)) return child;

    final enter = CurvedAnimation(
      parent: animation,
      curve: AppMotion.enter,
      reverseCurve: AppMotion.exit,
    );
    final leave = CurvedAnimation(
      parent: secondaryAnimation,
      curve: AppMotion.enter,
      reverseCurve: AppMotion.exit,
    );

    // 新页面进入：右侧滑入，或模态页从底部升起
    final slideIn = fromBottom
        ? Tween<Offset>(begin: const Offset(0, 1), end: Offset.zero)
              .animate(enter)
        : Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
              .animate(enter);

    Widget page = SlideTransition(position: slideIn, child: child);

    if (fromBottom) return page;

    // 旧页面退场：左移 + 缩小 + 压暗
    final slideOut = Tween<Offset>(
      begin: Offset.zero,
      end: const Offset(-0.28, 0),
    ).animate(leave);
    final scaleOut = Tween<double>(begin: 1.0, end: 0.96).animate(leave);
    final dim = Tween<double>(begin: 0, end: 0.14).animate(leave);

    page = AnimatedBuilder(
      animation: leave,
      builder: (context, inner) => Stack(
        children: [
          Transform.scale(scale: scaleOut.value, child: inner),
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: dim.value),
              ),
            ),
          ),
        ],
      ),
      child: page,
    );

    return SlideTransition(position: slideOut, child: page);
  }
}

/// 模态面板的标准外观：顶部抓手 + 圆角 + 拖拽下拉关闭。
class SheetGrabber extends StatelessWidget {
  const SheetGrabber({super.key, this.onDragDown});

  final VoidCallback? onDragDown;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      onVerticalDragEnd: (d) {
        if ((d.primaryVelocity ?? 0) > 320) onDragDown?.call();
      },
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: 22,
        child: Center(
          child: Container(
            width: 36,
            height: 5,
            decoration: BoxDecoration(
              color: c.tertiaryLabel,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
        ),
      ),
    );
  }
}
