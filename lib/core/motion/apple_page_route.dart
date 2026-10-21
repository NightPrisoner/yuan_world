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
         transitionDuration: fullscreenDialog
             ? AppMotion.sheet
             : AppMotion.page,
         reverseTransitionDuration: fullscreenDialog
             ? AppMotion.sheet
             : AppMotion.page,
         fullscreenDialog: fullscreenDialog,
         pageBuilder: (context, animation, secondaryAnimation) =>
             pageBuilder(context),
         transitionsBuilder: (context, animation, secondaryAnimation, child) =>
             _buildTransition(
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

    // A driven curve has no status listener and follows the same geometric
    // path when an opening transition is reversed halfway through.
    final enter = animation.drive(CurveTween(curve: AppMotion.enter));
    final leave = secondaryAnimation.drive(CurveTween(curve: AppMotion.enter));

    // 新页面进入：右侧滑入，或模态页从底部升起
    final slideIn = fromBottom
        ? Tween<Offset>(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).animate(enter)
        : Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(enter);

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

/// 移动端从阅读态进入编辑态的专用转场。
///
/// 编辑不是进入另一个横向层级：用户仍在同一篇笔记里，只是把阅读表面
/// 换成可编辑表面。因此用轻微缩放 + 淡入表达「原地进入编辑」，避免
/// [ApplePageRoute] 的桌面式右侧推入在竖屏上显得像打开了另一列窗口。
class EditorPageRoute<T> extends PageRouteBuilder<T> {
  EditorPageRoute({required WidgetBuilder pageBuilder, super.settings})
    : super(
        transitionDuration: AppMotion.normal,
        reverseTransitionDuration: AppMotion.normal,
        pageBuilder: (context, animation, secondaryAnimation) =>
            pageBuilder(context),
        transitionsBuilder: (context, animation, secondaryAnimation, child) =>
            _buildTransition(context, animation, child),
      );

  static Widget _buildTransition(
    BuildContext context,
    Animation<double> animation,
    Widget child,
  ) {
    if (AppMotion.reduceMotion(context)) return child;

    final enter = animation.drive(CurveTween(curve: AppMotion.enter));
    final opacity = Tween<double>(begin: 0.0, end: 1.0).animate(enter);
    final scale = Tween<double>(begin: 0.975, end: 1.0).animate(enter);

    return AnimatedBuilder(
      animation: enter,
      child: child,
      builder: (context, page) => Opacity(
        opacity: opacity.value.clamp(0.0, 1.0),
        child: Transform.scale(
          alignment: Alignment.center,
          scale: scale.value,
          child: page,
        ),
      ),
    );
  }
}

/// 窄屏笔记卡片进入正文的专用转场。
///
/// 这条路由和 [ApplePageRoute] 刻意分开：桌面端的正文栏是三栏布局里的
/// 右侧面板，应该从右边推入；移动端是从当前卡片展开成整页，不能复用
/// 横向推入，否则竖屏看起来会像桌面窗口被搬到了手机上。
class CardExpandPageRoute<T> extends PageRouteBuilder<T> {
  CardExpandPageRoute({
    required WidgetBuilder pageBuilder,
    super.settings,
    this.sourceRect,
    this.verticalOnly = false,
    this.sourceRectBuilder,
    this.sourceCoverRectBuilder,
    this.coverKey,
  }) : super(
         transitionDuration: AppMotion.page,
         reverseTransitionDuration: AppMotion.page,
         pageBuilder: (context, animation, secondaryAnimation) =>
             pageBuilder(context),
         transitionsBuilder: (context, animation, secondaryAnimation, child) =>
             _CardExpandTransition(
               animation: animation,
               sourceRect: sourceRect,
               verticalOnly: verticalOnly,
               sourceRectBuilder: sourceRectBuilder,
               sourceCoverRectBuilder: sourceCoverRectBuilder,
               coverKey: coverKey,
               child: child,
             ),
       );

  /// 卡片在 Navigator overlay 坐标系中的位置。为空时退回中心缩放，
  /// 例如从没有实体卡片的入口打开时仍然有合理的转场。
  final Rect? sourceRect;
  final bool verticalOnly;
  final Rect? Function()? sourceRectBuilder;
  final Rect? Function()? sourceCoverRectBuilder;
  final GlobalKey? coverKey;
}

class _CardExpandTransition extends StatefulWidget {
  const _CardExpandTransition({
    required this.animation,
    required this.sourceRect,
    required this.verticalOnly,
    required this.sourceRectBuilder,
    required this.sourceCoverRectBuilder,
    required this.coverKey,
    required this.child,
  });

  final Animation<double> animation;
  final Rect? sourceRect;
  final bool verticalOnly;
  final Rect? Function()? sourceRectBuilder;
  final Rect? Function()? sourceCoverRectBuilder;
  final GlobalKey? coverKey;
  final Widget child;

  @override
  State<_CardExpandTransition> createState() => _CardExpandTransitionState();
}

class _CardExpandTransitionState extends State<_CardExpandTransition> {
  // Match the unchanged cover Hero's default forward AND reverse curves.
  // Keep this object across frames so a mid-flight reversal stays continuous.
  late CurvedAnimation _reveal;
  bool _completedOpening = false;
  Rect? _destinationCover;
  Rect? _sourceCover;
  Rect? _source;

  @override
  void initState() {
    super.initState();
    _bindAnimation();
  }

  void _bindAnimation() {
    _reveal = CurvedAnimation(
      parent: widget.animation,
      curve: Curves.fastOutSlowIn,
      reverseCurve: Curves.fastOutSlowIn.flipped,
    );
    _completedOpening = widget.animation.status == AnimationStatus.completed;
    widget.animation.addStatusListener(_onStatus);
  }

  void _onStatus(AnimationStatus status) {
    // Navigator briefly lays out the destination offstage at value 1 before
    // the first flight. That layout is not a completed opening transition.
    if (status == AnimationStatus.forward) _completedOpening = false;
    if (status == AnimationStatus.completed) _completedOpening = true;
    if (status == AnimationStatus.reverse && _completedOpening) {
      // Return to the card's current position, including changes while reading.
      _source = widget.sourceRectBuilder?.call() ?? _source;
      _sourceCover = widget.sourceCoverRectBuilder?.call() ?? _sourceCover;
    }
  }

  @override
  void didUpdateWidget(covariant _CardExpandTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animation != oldWidget.animation) {
      oldWidget.animation.removeStatusListener(_onStatus);
      _reveal.dispose();
      _bindAnimation();
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onStatus);
    _reveal.dispose();
    super.dispose();
  }

  Rect? _coverRect() {
    final cover = widget.coverKey?.currentContext?.findRenderObject();
    final overlay = Navigator.maybeOf(context)?.overlay?.context
        .findRenderObject();
    if (cover is! RenderBox || overlay is! RenderBox || !cover.hasSize) {
      return null;
    }
    return MatrixUtils.transformRect(
      cover.getTransformTo(overlay),
      Offset.zero & cover.size,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduceMotion(context)) return widget.child;
    _source ??= widget.sourceRectBuilder?.call() ?? widget.sourceRect;
    _sourceCover ??= widget.sourceCoverRectBuilder?.call();

    // The surface stays opaque like the flying cover. Only its boundary grows;
    // an independent fade made the cover look detached from the note beneath it.
    return LayoutBuilder(
      builder: (context, constraints) {
        final fullRect = Offset.zero & constraints.biggest;
        final visibleSource = _source?.intersect(fullRect);
        final begin = visibleSource == null || visibleSource.isEmpty
            ? Rect.fromCenter(
                center: fullRect.center,
                width: fullRect.width * 0.92,
                height: fullRect.height * 0.92,
              )
            : widget.verticalOnly
            ? Rect.fromLTRB(
                0,
                visibleSource.top,
                fullRect.right,
                visibleSource.bottom,
              )
            : visibleSource;
        return AnimatedBuilder(
          animation: _reveal,
          child: RepaintBoundary(child: widget.child),
          builder: (context, page) {
            final progress = _reveal.value;
            var rect = Rect.lerp(begin, fullRect, progress)!;
            final interruptedReturn =
                !_completedOpening &&
                widget.animation.status == AnimationStatus.reverse;
            final coverRect = interruptedReturn ? null : _coverRect();
            if (coverRect != null && coverRect.isFinite) {
              _destinationCover = coverRect;
            }
            final from = _sourceCover;
            final to = _destinationCover;
            if (from != null && to != null) {
              final returning =
                  _completedOpening &&
                  widget.animation.status == AnimationStatus.reverse;
              // Material's existing Hero uses an arc, not Rect.lerp. Include
              // its exact flight bounds so it never floats outside the surface.
              final flight = MaterialRectArcTween(
                begin: returning ? to : from,
                end: returning ? from : to,
              ).transform(returning ? 1 - progress : progress)!;
              rect = rect.expandToInclude(flight).intersect(fullRect);
            }
            final radius = (16 * (1 - progress)).clamp(0.0, 16.0);
            return ClipPath(
              key: const ValueKey('note-expand-surface'),
              clipper: _CardExpandClipper(rect, radius),
              child: page,
            );
          },
        );
      },
    );
  }
}

class _CardExpandClipper extends CustomClipper<Path> {
  const _CardExpandClipper(this.rect, this.radius);

  final Rect rect;
  final double radius;

  @override
  Path getClip(Size size) =>
      Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(radius)));

  @override
  bool shouldReclip(covariant _CardExpandClipper oldClip) =>
      oldClip.rect != rect || oldClip.radius != radius;
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
