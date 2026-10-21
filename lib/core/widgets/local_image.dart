/// 本地图片的统一入口：**按显示尺寸解码**。
///
/// ## 为什么非做不可
///
/// 这是纯本地图库，图是用户自己塞进来的原始文件。`Image.file` 不加
/// `cacheWidth` 时会把**整张图**解码进内存：一张 1920×1080 的 PNG 是
/// `1920*1080*4 ≈ 8MB`，用户库里就有 9MB 的这种图。列表里一屏十几个
/// 缩略图（每个实际只显示 ~100px），解码出来的却是十几份全尺寸位图 ——
/// 直接顶穿 Flutter 默认 100MB 的图片缓存，于是滚动时反复"解码→驱逐→
/// 再解码"，手感就是"划一下卡一下"。
///
/// ## 为什么不写死一个数字
///
/// 同一张图至少在三处出现：列表缩略图（~96px）、卡片封面（~300px）、
/// 阅读页正文（~900px 甚至全屏）。硬编码一个 cacheWidth 不是糊就是费。
/// 所以这里用 [LayoutBuilder] 拿实际约束，乘设备像素比得到解码宽度 ——
/// **你显示多大就解多大**。
///
/// ## 什么时候不该用
///
/// 会被放大的场景（看图页的 `InteractiveViewer`，最大 5 倍）要原图，
/// 那里直接用 `Image.file` —— 降采样之后再放大就是一坨马赛克。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../motion/app_motion.dart';

/// 解码宽度的取整粒度。
///
/// 不按像素取整的原因：图片缓存是按 (文件, 宽, 高) 建的，宽度差 3px
/// 就是两条缓存。按 64 取整能让"同一个位置前后几次布局"共用一条缓存。
const int _kDecodeBucket = 64;

class LocalImage extends StatelessWidget {
  const LocalImage({
    super.key,
    required this.path,
    this.fit = BoxFit.cover,
    this.fallbackColor,
    this.errorBuilder,
    this.fadeIn = true,
    this.gaplessPlayback = true,
    this.filterQuality = FilterQuality.medium,
    this.decodeScale = 1.0,
    this.maxDecodeWidth,
    this.fullResolution = false,
  });

  /// 图片绝对路径。
  final String path;

  final BoxFit fit;

  /// 文件不存在时的兜底底色（默认透明）。
  final Color? fallbackColor;

  /// 加载失败时显示什么。不给就用 [fallbackColor] 填一块。
  final WidgetBuilder? errorBuilder;

  /// 是否淡入（本地大图解码要几十毫秒，直接"啪"地出现很跳）。
  final bool fadeIn;

  final bool gaplessPlayback;
  final FilterQuality filterQuality;

  /// 解码宽度 = 显示宽度 × 设备像素比 × 这个系数。
  ///
  /// 默认 1.0：显示多大就解多大。将来做"悬停放大"之类再调大。
  final double decodeScale;

  /// 直接指定解码宽度上限（给了就不看 [decodeScale]）。
  ///
  /// 适合"显示尺寸说不清，但我知道不该超过多少"的地方，比如封面横幅。
  final int? maxDecodeWidth;

  /// 要原图（会被放大的场景）。
  final bool fullResolution;

  @override
  Widget build(BuildContext context) {
    final file = File(path);
    if (!file.existsSync()) return _fallback(context);

    if (fullResolution) {
      return Image.file(
        file,
        fit: fit,
        gaplessPlayback: gaplessPlayback,
        filterQuality: filterQuality,
        frameBuilder: _frame,
        errorBuilder: (c, _, _) => _fallback(context),
      );
    }

    if (maxDecodeWidth != null) {
      return _image(file, maxDecodeWidth!, context);
    }

    return LayoutBuilder(
      builder: (context, box) {
        // 宽度没有约束（横向滚动列表之类）时不给 cacheWidth：
        // 猜一个数字反而可能把图解码糊了
        if (!box.hasBoundedWidth) {
          return _image(file, null, context);
        }
        final dpr = MediaQuery.devicePixelRatioOf(context);
        final wanted = box.maxWidth * dpr * decodeScale;
        return _image(file, _bucket(wanted), context);
      },
    );
  }

  /// 向上取整到 [_kDecodeBucket] 的整数倍。
  int _bucket(double wanted) {
    if (wanted <= 0) return _kDecodeBucket;
    return (wanted / _kDecodeBucket).ceil() * _kDecodeBucket;
  }

  Widget _image(File file, int? cacheWidth, BuildContext context) => Image.file(
    file,
    fit: fit,
    cacheWidth: cacheWidth,
    gaplessPlayback: gaplessPlayback,
    filterQuality: filterQuality,
    frameBuilder: _frame,
    errorBuilder: (c, _, _) => _fallback(context),
  );

  /// 淡入。同步命中缓存（`wasSyncLoaded`）时不淡 —— 那会闪一下。
  Widget _frame(
    BuildContext context,
    Widget child,
    int? frame,
    bool wasSyncLoaded,
  ) {
    if (!fadeIn) return child;
    return _LocalImageFade(
      key: ValueKey(path),
      ready: frame != null || wasSyncLoaded,
      synchronous: wasSyncLoaded,
      keepPrevious: gaplessPlayback,
      child: child,
    );
  }

  Widget _fallback(BuildContext context) {
    final custom = errorBuilder;
    if (custom != null) return custom(context);
    return ColoredBox(color: fallbackColor ?? Colors.transparent);
  }
}

/// Image keeps its last decoded frame during a resize. Keep the fade wrapper
/// visible too, otherwise a new cacheWidth hides that retained image.
class _LocalImageFade extends StatefulWidget {
  const _LocalImageFade({
    super.key,
    required this.ready,
    required this.synchronous,
    required this.keepPrevious,
    required this.child,
  });

  final bool ready;
  final bool synchronous;
  final bool keepPrevious;
  final Widget child;

  @override
  State<_LocalImageFade> createState() => _LocalImageFadeState();
}

class _LocalImageFadeState extends State<_LocalImageFade> {
  late bool _hasFrame = widget.ready;

  @override
  void didUpdateWidget(covariant _LocalImageFade oldWidget) {
    super.didUpdateWidget(oldWidget);
    _hasFrame = widget.ready || (widget.keepPrevious && _hasFrame);
  }

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    opacity: _hasFrame ? 1 : 0,
    duration: widget.synchronous
        ? Duration.zero
        : AppMotion.respecting(context, AppMotion.normal),
    curve: AppMotion.enter,
    child: widget.child,
  );
}
