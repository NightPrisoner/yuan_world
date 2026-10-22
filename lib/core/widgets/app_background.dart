import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../theme/app_theme.dart';

/// 界面背景层：一张用户挑的本地图片，铺在所有页面底下。
///
/// 几个刻意的取舍：
///
/// * **不用 `Image.file`**：它会自己管缓存和缩放，但背景图只在切图/改浓度
///   时变一次，用 `FileImage` + `ResizeImage` 交给 Flutter 的图片缓存更省事，
///   而且窗口拉伸时不会每次都重新解码。
/// * **先模糊再铺**：模糊半径给到 0 时直接跳过 `ImageFiltered` —— 全屏
///   高斯模糊是这个 widget 最贵的一步，能省则省。
/// * **浓度走 Opacity 而不是 `Color.withOpacity`**：用户调的是"整张图多浓"，
///   不是"叠一层多黑的膜"，`Opacity` 才是对的语义；代价是一次 saveLayer。
/// * 图片读不出来（被删、权限没了）时静默退化成纯色底，绝不在这里抛。
class AppBackground extends StatelessWidget {
  const AppBackground({
    super.key,
    required this.path,
    required this.opacity,
    required this.blur,
    required this.child,
  });

  final String? path;
  final double opacity;
  final double blur;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final file = path == null ? null : File(path!);
    if (file == null || !file.existsSync() || opacity <= 0.001) {
      return child;
    }

    Widget image = Image(
      // 长边限到 1920：4K 原图铺满全屏时，解码出来的那 3000 万像素对
      // 一张被模糊过的背景图来说纯属浪费内存。
      image: ResizeImage(
        FileImage(file),
        width: 1920,
        policy: ResizeImagePolicy.fit,
      ),
      fit: BoxFit.cover,
      // 图挂了就什么都不画，露出下面的纯色底
      errorBuilder: (_, _, _) => const SizedBox.shrink(),
      gaplessPlayback: true,
    );

    if (blur > 0.5) {
      // 模糊时把图放大一点点，否则边缘会被 blur 啃出一圈透明
      image = ImageFiltered(
        imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Transform.scale(scale: 1.08, child: image),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        Positioned.fill(
          child: IgnorePointer(child: Opacity(opacity: opacity, child: image)),
        ),
        child,
      ],
    );
  }
}

/// 在 `MaterialApp.builder` 里一次性套好：背景图 + 半透明主题。
///
/// 主题要跟着在这里改而不是在 `MaterialApp.theme` 里算，是因为"要不要
/// 半透明"取决于背景图在不在，两处分别判断迟早会不一致。
class AppChrome extends StatelessWidget {
  const AppChrome({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // 用 select 而不是 watch：AppState 在刷新笔记列表时会频繁 notify，
    // 这里只关心"背景图变没变"，跟着一起重建整棵树就白瞎了。
    final settings = context.select<AppState, (String?, double, double)>(
      (s) => (s.themeBackgroundPath, s.themeBackgroundOpacity, s.themeBackgroundBlur),
    );
    final path = settings.$1;
    if (path == null) return child;

    final c = Theme.of(context).extension<AppColors>();
    final dark = c?.isDark ?? false;

    return Theme(
      // 半透明底只给 0.62：再透下去，白色正文压在照片上会花
      data: AppTheme.translucent(Theme.of(context), keep: dark ? 0.72 : 0.62),
      child: AppBackground(
        path: path,
        opacity: settings.$2,
        blur: settings.$3,
        child: child,
      ),
    );
  }
}
