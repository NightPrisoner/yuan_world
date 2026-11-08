/// 头图的显示框。
///
/// 头图以前是写死的「16:10 + 居中裁切」：竖构图（手机拍的）被裁掉一大半，
/// 长图只剩中间一条，人像的脸经常正好切在边上。现在比例、放大倍数、
/// 取景位置都存在笔记行上（`cover_ratio` / `cover_zoom` /
/// `cover_focus_x` / `cover_focus_y`），这个组件负责把它们变成画面。
///
/// 三件事分开管，互不干扰：
///   - **比例** 决定框多高（[ratio]）
///   - **放大** 决定往图里推多深（[zoom]，1 = 刚好填满）
///   - **取景** 决定裁掉的是哪一边（[focusX] / [focusY]，-1…1）
///
/// 放大和取景同时作用在 [BoxFit.cover] 的对齐上：`cover` 总会裁掉溢出
/// 的那一边，对齐点就是"从图片的哪个位置开始裁"。
library;

import 'package:flutter/material.dart';

import '../../../core/motion/app_motion.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/local_image.dart';

class CoverFrame extends StatelessWidget {
  const CoverFrame({
    super.key,
    required this.path,
    required this.ratio,
    this.zoom = 1,
    this.focusX = 0,
    this.focusY = 0,
    this.fallbackColor,
    this.borderRadius,
    this.fadeIn = false,
    this.animate = true,
    this.decodeWidth,
    this.decodeScale = 1.0,
  });

  /// 图片绝对路径。
  final String path;

  /// 显示框的宽高比（宽 / 高）。
  final double ratio;

  /// 放大倍数，0.3…4，1 = 刚好填满。
  ///
  /// 允许小于 1：把整张图缩进框里，四周露出底色 —— 拍的是竖构图、
  /// 想整张看全，或者想让图在一段留白里"落"下来，都要靠它。
  final double zoom;

  /// 取景中心，-1…1。
  final double focusX;
  final double focusY;

  final Color? fallbackColor;

  /// 圆角；null 表示直角（外面自己裁）。
  final BorderRadius? borderRadius;

  final bool fadeIn;

  /// 参数变化时是否补间。编辑面板里要开着（拖滑块时是连续的），
  /// 列表里关掉（每次滚动都插值一遍白费电）。
  final bool animate;

  /// 解码宽度上限，透传给 LocalImage。
  final int? decodeWidth;

  /// 解码宽度相对显示宽度的倍数（[decodeWidth] 为空时才生效）。
  ///
  /// 这里还会**再乘上 [zoom]**：放大 2 倍就是把一张按框宽解码的位图拉到
  /// 两倍大，源像素不够，看着就是糊的。以前没乘，所以"编辑里预览还行、
  /// 瀑布流里一放大就糊"。
  ///
  /// 但**不能**钉死一个绝对值：Hero 起飞那一帧框只有 66 宽，钉死成
  /// 1600 就要在那一帧去解一张大图，首次打开必然空几帧（"闪一下"）。
  /// 交给 LocalImage 按当前宽度算，起飞时解小的、落定后解大的，
  /// 配合 gaplessPlayback 换图时旧帧还在，看不出接缝。
  final double decodeScale;

  @override
  Widget build(BuildContext context) {
    final duration = animate
        ? AppMotion.respecting(context, AppMotion.fast)
        : Duration.zero;

    if (duration == Duration.zero) return _frame(ratio, _image());

    // 比例也要补间：直接换 AspectRatio 会"啪"地跳一下，六档之间来回切
    // 的时候尤其明显。
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: ratio),
      duration: duration,
      curve: AppMotion.enter,
      builder: (context, r, child) => _frame(r, child!),
      child: _image(),
    );
  }

  /// 把「框 + 底色 + 缩放 + 图片」装起来，圆角一律裁在**最外层**。
  ///
  /// 圆角必须罩住整个框，不能只裁图片：底色（[fallbackColor]）和图片
  /// 放大到框外被 [ClipRect] 切掉的部分都在框里，只裁图片的话四个角会
  /// 露出底色的直角 —— 移动端阅读页头图那圈"残留尖角"就是这么来的。
  Widget _frame(double r, Widget image) {
    Widget frame = AspectRatio(
      aspectRatio: r,
      child: ClipRect(
        // 缩到 1 以下时图会比框小，四周露出来的地方要有底色 ——
        // 否则在深色页面里就是一块透明的洞。
        child: ColoredBox(
          color: fallbackColor ?? Colors.transparent,
          child: Transform.scale(
            scale: zoom,
            // 放大以取景点为轴，否则一放大画面就往中心跑，用户刚调好的
            // 位置白调了。
            alignment: Alignment(focusX, focusY),
            child: image,
          ),
        ),
      ),
    );

    final radius = borderRadius;
    if (radius == null) return frame;
    return ClipRRect(borderRadius: radius, child: frame);
  }

  Widget _image() {
    return LocalImage(
      path: path,
      // cover：填满框，多出来的裁掉。这正是"取景"能生效的前提。
      fit: BoxFit.cover,
      alignment: Alignment(focusX, focusY),
      fallbackColor: fallbackColor,
      fadeIn: fadeIn,
      maxDecodeWidth: decodeWidth,
      // 放大之后画面是"位图被拉大"，源像素必须跟着放大走，
      // 否则 2 倍的图就是 2 倍的模糊。
      decodeScale: decodeScale * zoom.clamp(1.0, 4.0),
    );
  }
}

/// 列表行里的方形缩略图。
///
/// 它是**同一张头图的另一个呈现**，不是另一张图：比例、放大、取景都跟
/// 头图一致，只是外面套一个方框裁掉多余部分。
///
/// 为什么不用裸 [LocalImage]：以前列表行画的是原图等比缩进 66×66 的方框，
/// 而瀑布流画的是用户设好的比例/取景 —— 同一篇笔记在两种视图下看着像
/// 两张不同的图，用户调完头图只有瀑布流变了，列表没变。
class NoteCoverThumb extends StatelessWidget {
  const NoteCoverThumb({
    super.key,
    required this.path,
    required this.size,
    this.ratio = 1,
    this.zoom = 1,
    this.focusX = 0,
    this.focusY = 0,
    this.color,
    this.fadeIn = true,
  });

  final String path;
  final double size;
  final double ratio;
  final double zoom;
  final double focusX;
  final double focusY;
  final Color? color;
  final bool fadeIn;

  @override
  Widget build(BuildContext context) {
    // 缩略图始终是方块：宽高比由外面的 [size] 决定，这里只需要把
    // 头图的那套取景参数喂给 CoverFrame。
    return SizedBox(
      width: size,
      height: size,
      child: CoverFrame(
        path: path,
        ratio: 1,
        zoom: zoom,
        focusX: focusX,
        focusY: focusY,
        fallbackColor: color,
        fadeIn: fadeIn,
        animate: false,
        borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
      ),
    );
  }
}
