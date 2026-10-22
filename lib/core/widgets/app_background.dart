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
/// * **这里不碰透明度。** 以前这里是 `Opacity(opacity: 用户调的浓度, 图片)`，
///   同时外面那层半透明主题也在遮 —— 两层叠起来只剩 0.5 × 0.38 ≈ 19% 的
///   光透出来，用户看到的就是"怎么调都像隔了层纱"。浓度现在完全交给
///   页面底色的不透明度去表达（见 [AppChrome]），图片本身该多亮就多亮。
/// * 图片读不出来（被删、权限没了）时静默退化成纯色底，绝不在这里抛。
class AppBackground extends StatelessWidget {
  const AppBackground({
    super.key,
    required this.path,
    required this.blur,
    required this.child,
  });

  final String? path;
  final double blur;
  final Widget child;

  /// 浓度到页面底色保留量的换算：用户把浓度拉满时，底色只剩这么多。
  ///
  /// 0.22 是下限 —— 再透下去，白色正文压在照片的亮处就看不见了。
  static const double minKeep = 0.22;

  /// 浓度 0~1 对应页面底色保留 1~[minKeep]。
  static double keepFor(double strength) =>
      (1 - (1 - minKeep) * strength).clamp(minKeep, 1.0);

  @override
  Widget build(BuildContext context) {
    final file = path == null ? null : File(path!);
    if (file == null || !file.existsSync()) {
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
        Positioned.fill(child: IgnorePointer(child: image)),
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
    // 浓度拉到 0 就是"不要这张图"，连半透明底也一起收掉
    if (path == null || settings.$2 <= 0.001) return child;

    final c = Theme.of(context).extension<AppColors>();
    final dark = c?.isDark ?? false;

    // 浓度只在这一层体现：浓度越高，页面底色留得越少，图越清楚。
    // 深色主题下底色是纯黑，同样的 keep 会显得更闷，所以让它多透一点。
    final keep = AppBackground.keepFor(settings.$2) * (dark ? 0.82 : 1.0);

    return Theme(
      data: AppTheme.translucent(Theme.of(context), keep: keep),
      child: AppBackground(
        path: path,
        blur: settings.$3,
        child: child,
      ),
    );
  }
}
