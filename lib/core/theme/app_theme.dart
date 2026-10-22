/// 「元世界」视觉主题。
///
/// 设计语言参考 Apple Human Interface Guidelines：
/// - 语义化颜色（label / secondaryLabel / separator ...），自动适配深浅色
/// - 系统色板（systemBlue 等），而不是随手调的品牌色
/// - iOS 字号阶梯（largeTitle 34 → caption2 11）
/// - 统一圆角与留白，营造「连续圆角」的柔和观感
///
/// 中文排版说明：不引入字体文件（避免包体和授权问题），
/// 而是通过 [kCjkFallback] 给出各平台的中文字体回退链，
/// 保证 Windows / Android 上中文都不糊、行高一致。
library;

import 'package:flutter/material.dart';

/// 各平台可用的中文字体回退链，按优先级排列。
const List<String> kCjkFallback = <String>[
  // macOS / iOS
  'PingFang SC',
  'Hiragino Sans GB',
  // Windows
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  // Android / Linux
  'Noto Sans CJK SC',
  'Source Han Sans SC',
  'Noto Sans SC',
  'Droid Sans Fallback',
];

/// 主题扩展：承载 HIG 的语义化颜色。
@immutable
class AppColors extends ThemeExtension<AppColors> {
  const AppColors({
    required this.brightness,
    required this.label,
    required this.secondaryLabel,
    required this.tertiaryLabel,
    required this.quaternaryLabel,
    required this.background,
    required this.secondaryBackground,
    required this.tertiaryBackground,
    required this.groupedBackground,
    required this.separator,
    required this.fill,
    required this.tint,
    required this.destructive,
    required this.palette,
  });

  final Brightness brightness;
  final Color label;
  final Color secondaryLabel;
  final Color tertiaryLabel;
  final Color quaternaryLabel;

  /// 最底层背景（列表页）
  final Color background;

  /// 卡片 / 分组行背景
  final Color secondaryBackground;

  /// 比二级再高一层（弹出层、输入框）
  final Color tertiaryBackground;

  /// 分组列表的整体底色（iOS 设置页那种灰底）
  final Color groupedBackground;

  final Color separator;

  /// 填充色（搜索框、未选中态）
  final Color fill;

  /// 强调色
  final Color tint;

  final Color destructive;

  /// 用于文集 / 图表的多彩配色
  final List<Color> palette;

  bool get isDark => brightness == Brightness.dark;

  static const AppColors light = AppColors(
    brightness: Brightness.light,
    label: Color(0xFF000000),
    secondaryLabel: Color(0x993C3C43),
    tertiaryLabel: Color(0x4D3C3C43),
    quaternaryLabel: Color(0x2E3C3C43),
    background: Color(0xFFFFFFFF),
    secondaryBackground: Color(0xFFFFFFFF),
    tertiaryBackground: Color(0xFFF2F2F7),
    groupedBackground: Color(0xFFF2F2F7),
    separator: Color(0x4A3C3C43),
    fill: Color(0x1F767680),
    tint: Color(0xFF007AFF),
    destructive: Color(0xFFFF3B30),
    palette: <Color>[
      Color(0xFF007AFF),
      Color(0xFF34C759),
      Color(0xFFFF9500),
      Color(0xFFFF2D55),
      Color(0xFFAF52DE),
      Color(0xFF5856D6),
      Color(0xFF00C7BE),
      Color(0xFFFFCC00),
      Color(0xFF5AC8FA),
      Color(0xFFFF6482),
    ],
  );

  static const AppColors dark = AppColors(
    brightness: Brightness.dark,
    label: Color(0xFFFFFFFF),
    secondaryLabel: Color(0x99EBEBF5),
    tertiaryLabel: Color(0x4DEBEBF5),
    quaternaryLabel: Color(0x2EEBEBF5),
    background: Color(0xFF000000),
    secondaryBackground: Color(0xFF1C1C1E),
    tertiaryBackground: Color(0xFF2C2C2E),
    groupedBackground: Color(0xFF000000),
    separator: Color(0x99545458),
    fill: Color(0x1F767680),
    tint: Color(0xFF0A84FF),
    destructive: Color(0xFFFF453A),
    palette: <Color>[
      Color(0xFF0A84FF),
      Color(0xFF30D158),
      Color(0xFFFF9F0A),
      Color(0xFFFF375F),
      Color(0xFFBF5AF2),
      Color(0xFF5E5CE6),
      Color(0xFF40C8E0),
      Color(0xFFFFD60A),
      Color(0xFF64D2FF),
      Color(0xFFFF7A93),
    ],
  );

  /// 用自定义种子色派生出整套颜色。
  ///
  /// 换的是强调色、配色轮，以及**几层底色的色相**：纯白/纯黑铺满全屏
  /// 时，用户挑个绿色也只有按钮和小图标变色，看着"好像没变"。所以
  /// 列表底、分组底、输入框这些大面积的浅色会往种子色那边偏一点。
  ///
  /// 幅度是刻意压很小的（4%~12%）：中性底是"读得下去"的地基，让用户
  /// 挑的粉色直接刷满背景，长文会糊成一片。要更明显的视觉效果走
  /// 「界面背景图」那条路，那条由用户显式调浓度。
  ///
  /// [seed] 为空时返回 [light] / [dark] 原样。
  static AppColors fromSeed({
    required Brightness brightness,
    Color? seed,
  }) {
    final base = brightness == Brightness.dark ? dark : light;
    if (seed == null) return base;

    // 用 HCT（Material 3 的 ColorScheme.fromSeed 背后那套）算出来的
    // 强调色比直接把用户选的色丢上去更稳：选中/未选中、深底/浅底都还能
    // 拉开对比。这里只取它的 primary，其余颜色仍用我们自己的。
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    );
    final accent = scheme.primary;

    // 配色轮：以强调色为首，后面几个按色相旋转，保证彼此拉得开。
    final hsl = HSLColor.fromColor(accent);
    final rotated = <Color>[
      accent,
      for (final deg in <double>[130, 35, -35, 265, 220, 180, 60, 300, 320])
        hsl.withHue((hsl.hue + deg) % 360).toColor(),
    ];

    return base.copyWith(
      tint: accent,
      palette: rotated,
      groupedBackground: _tintSurface(base.groupedBackground, hsl, base.isDark),
      tertiaryBackground:
          _tintSurface(base.tertiaryBackground, hsl, base.isDark),
      fill: _tintSurface(base.fill, hsl, base.isDark),
    );
  }

  /// 把一块底色往 [accent] 的**色相**推，但亮度不许掉。
  ///
  /// 以前这里是 `Color.lerp(base, accent, 0.07)` —— 直接往强调色里混。
  /// 混出来的是"更暗的那个颜色"：浅色主题里 `#F2F2F7` 往深蓝靠就变成灰，
  /// 用户挑个紫/红，整个界面跟着暗一档，观感是"换了个色但变脏了"。
  ///
  /// 这里换到 HSL 空间只动色相和饱和度，**亮度原样保留**：
  /// 浅色底还是那么亮，只是色相偏过去了一点点，能看出"换色了"却不发暗。
  ///
  /// 深色主题的底色是纯黑（亮度 0），纯黑在任何色相下都还是黑，永远看不出
  /// 变化；所以深色下给一个极小的下限亮度，让底色带一点点色相。
  static Color _tintSurface(Color base, HSLColor accent, bool isDark) {
    final b = HSLColor.fromColor(base);
    final amount = isDark ? 0.34 : 0.30;
    // 色相沿圆周取近的一侧，别为了 350°→10° 绕一整圈把中间颜色全扫一遍
    var delta = (accent.hue - b.hue) % 360;
    if (delta > 180) delta -= 360;
    final hue = (b.hue + delta * amount) % 360;
    final sat = (b.saturation + (accent.saturation - b.saturation) * amount)
        .clamp(0.0, 1.0);
    final light = isDark
        ? (b.lightness > 0.055 ? b.lightness : 0.055)
        : b.lightness;
    return b
        .withHue(hue)
        .withSaturation(sat)
        .withLightness(light)
        .toColor()
        .withValues(alpha: base.a);
  }


  @override
  AppColors copyWith({
    Brightness? brightness,
    Color? label,
    Color? secondaryLabel,
    Color? tertiaryLabel,
    Color? quaternaryLabel,
    Color? background,
    Color? secondaryBackground,
    Color? tertiaryBackground,
    Color? groupedBackground,
    Color? separator,
    Color? fill,
    Color? tint,
    Color? destructive,
    List<Color>? palette,
  }) => AppColors(
    brightness: brightness ?? this.brightness,
    label: label ?? this.label,
    secondaryLabel: secondaryLabel ?? this.secondaryLabel,
    tertiaryLabel: tertiaryLabel ?? this.tertiaryLabel,
    quaternaryLabel: quaternaryLabel ?? this.quaternaryLabel,
    background: background ?? this.background,
    secondaryBackground: secondaryBackground ?? this.secondaryBackground,
    tertiaryBackground: tertiaryBackground ?? this.tertiaryBackground,
    groupedBackground: groupedBackground ?? this.groupedBackground,
    separator: separator ?? this.separator,
    fill: fill ?? this.fill,
    tint: tint ?? this.tint,
    destructive: destructive ?? this.destructive,
    palette: palette ?? this.palette,
  );

  @override
  AppColors lerp(ThemeExtension<AppColors>? other, double t) {
    if (other is! AppColors) return this;
    return AppColors(
      brightness: t < 0.5 ? brightness : other.brightness,
      label: Color.lerp(label, other.label, t)!,
      secondaryLabel: Color.lerp(secondaryLabel, other.secondaryLabel, t)!,
      tertiaryLabel: Color.lerp(tertiaryLabel, other.tertiaryLabel, t)!,
      quaternaryLabel: Color.lerp(quaternaryLabel, other.quaternaryLabel, t)!,
      background: Color.lerp(background, other.background, t)!,
      secondaryBackground:
          Color.lerp(secondaryBackground, other.secondaryBackground, t)!,
      tertiaryBackground:
          Color.lerp(tertiaryBackground, other.tertiaryBackground, t)!,
      groupedBackground: Color.lerp(groupedBackground, other.groupedBackground, t)!,
      separator: Color.lerp(separator, other.separator, t)!,
      fill: Color.lerp(fill, other.fill, t)!,
      tint: Color.lerp(tint, other.tint, t)!,
      destructive: Color.lerp(destructive, other.destructive, t)!,
      palette: t < 0.5 ? palette : other.palette,
    );
  }
}

/// 便捷访问：`context.colors.tint`
extension AppColorsX on BuildContext {
  AppColors get colors => Theme.of(this).extension<AppColors>() ?? AppColors.light;
  TextTheme get texts => Theme.of(this).textTheme;
}

/// iOS 字号阶梯。
class AppText {
  const AppText._();

  static const List<String> _f = kCjkFallback;

  static const TextStyle largeTitle = TextStyle(
    fontSize: 34,
    height: 1.21,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.37,
    fontFamilyFallback: _f,
  );
  static const TextStyle title1 = TextStyle(
    fontSize: 28,
    height: 1.21,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.36,
    fontFamilyFallback: _f,
  );
  static const TextStyle title2 = TextStyle(
    fontSize: 22,
    height: 1.27,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.26,
    fontFamilyFallback: _f,
  );
  static const TextStyle title3 = TextStyle(
    fontSize: 20,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.45,
    fontFamilyFallback: _f,
  );
  static const TextStyle headline = TextStyle(
    fontSize: 17,
    height: 1.29,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.41,
    fontFamilyFallback: _f,
  );
  static const TextStyle body = TextStyle(
    fontSize: 17,
    height: 1.47,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.41,
    fontFamilyFallback: _f,
  );
  static const TextStyle callout = TextStyle(
    fontSize: 16,
    height: 1.31,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.32,
    fontFamilyFallback: _f,
  );
  static const TextStyle subheadline = TextStyle(
    fontSize: 15,
    height: 1.33,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.24,
    fontFamilyFallback: _f,
  );
  static const TextStyle footnote = TextStyle(
    fontSize: 13,
    height: 1.38,
    fontWeight: FontWeight.w400,
    // 这里**不要**给负字距：13px 的中文在 200% 缩放下正好落在整数像素上，
    // 而 -0.08 这种小数会字距会把每个字的原点推到半个像素外，
    // Windows 的字形微调（hinting）于是各字独立取整 —— 同一个名字里
    // 会出现"某个字低了一像素"的观感（选中时换成 w600 字体，栅格化路径
    // 变了，看着又齐了）。小字号一律保持 0。
    letterSpacing: 0,
    fontFamilyFallback: _f,
  );
  static const TextStyle caption1 = TextStyle(
    fontSize: 12,
    height: 1.33,
    fontWeight: FontWeight.w400,
    fontFamilyFallback: _f,
  );
  static const TextStyle caption2 = TextStyle(
    fontSize: 11,
    height: 1.36,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.07,
    fontFamilyFallback: _f,
  );

  /// 阅读正文：行高放宽，长文更耐读。
  static const TextStyle reading = TextStyle(
    fontSize: 17,
    height: 1.85,
    fontWeight: FontWeight.w400,
    letterSpacing: 0.1,
    fontFamilyFallback: _f,
  );
}

/// 圆角与间距常量。
class AppMetrics {
  const AppMetrics._();

  static const double radiusSm = 8;
  static const double radiusMd = 12;
  static const double radiusLg = 16;
  static const double radiusXl = 22;

  static const double gutter = 16;
  static const double rowGap = 10;

  /// 分组列表的行高（iOS 标准 44）
  static const double rowHeight = 44;
}

class AppTheme {
  const AppTheme._();

  static ThemeData light({Color? seed}) =>
      _build(AppColors.fromSeed(brightness: Brightness.light, seed: seed),
          Brightness.light);

  static ThemeData dark({Color? seed}) =>
      _build(AppColors.fromSeed(brightness: Brightness.dark, seed: seed),
          Brightness.dark);

  /// 把几层背景按 [keep] 保留不透明度（1 = 原样不透明）。
  ///
  /// 只有用户给界面选了背景图时才用：图铺在最底层，各页底色必须让一点
  /// 出来，否则图被实色挡得一点都看不见。
  ///
  /// **卡片比页面底更实**：页面底可以透到 0.5，读正文的卡片只透到
  /// 0.8 左右 —— 字号 17 的黑字压在一张风景照的花纹上，眼睛会一直
  /// 被拉走。分层给不同的 keep 就是这个原因。
  ///
  /// 属于 [AppTheme] 而不是 [AppColors]：它产出的是整套 `ThemeData`
  /// （顺带要把 `scaffoldBackgroundColor` / `canvasColor` 一起改），
  /// 放在颜色类里会让人以为只改颜色。
  static ThemeData translucent(ThemeData base, {double keep = 0.66}) {
    final c = base.extension<AppColors>();
    if (c == null) return base;
    // 先夹一次入参：调用方可能算出 0.9454 这种超过 0.94 的值，
    // 下面那句 clamp(keep, 0.94) 就会变成"下限比上限大"——
    // `double.clamp` 对这种情况直接抛 Invalid argument(s)，
    // 而且是每帧抛一次，整个界面会被 ErrorWidget 顶掉（白屏）。
    final pageKeep = keep.clamp(0.0, 0.94);
    final cardKeep = (pageKeep + (1 - pageKeep) * 0.62).clamp(pageKeep, 0.94);
    Color fade(Color color, double k) => color.withValues(alpha: color.a * k);
    final next = c.copyWith(
      background: fade(c.background, pageKeep),
      groupedBackground: fade(c.groupedBackground, pageKeep),
      secondaryBackground: fade(c.secondaryBackground, cardKeep),
      tertiaryBackground: fade(c.tertiaryBackground, cardKeep),
    );
    return base.copyWith(
      scaffoldBackgroundColor: next.groupedBackground,
      canvasColor: next.background,
      extensions: <ThemeExtension<dynamic>>[next],
    );
  }

  static ThemeData _build(AppColors c, Brightness b) {
    final scheme = ColorScheme.fromSeed(
      seedColor: c.tint,
      brightness: b,
    ).copyWith(
      surface: c.background,
      onSurface: c.label,
      primary: c.tint,
      error: c.destructive,
    );

    final textTheme = const TextTheme().copyWith(
      displayLarge: AppText.largeTitle,
      displayMedium: AppText.title1,
      titleLarge: AppText.title2,
      titleMedium: AppText.title3,
      titleSmall: AppText.headline,
      bodyLarge: AppText.body,
      bodyMedium: AppText.callout,
      bodySmall: AppText.footnote,
      labelLarge: AppText.headline,
      labelMedium: AppText.subheadline,
      labelSmall: AppText.caption1,
    ).apply(bodyColor: c.label, displayColor: c.label);

    return ThemeData(
      useMaterial3: true,
      brightness: b,
      colorScheme: scheme,
      scaffoldBackgroundColor: c.groupedBackground,
      canvasColor: c.background,
      extensions: <ThemeExtension<dynamic>>[c],
      textTheme: textTheme,
      fontFamilyFallback: kCjkFallback,
      splashFactory: NoSplash.splashFactory, // 用自绘的水波纹/高亮替代
      highlightColor: Colors.transparent,
      splashColor: Colors.transparent,
      dividerTheme: DividerThemeData(
        color: c.separator,
        thickness: 0.5,
        space: 0.5,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: AppText.headline.copyWith(color: c.label),
        iconTheme: IconThemeData(color: c.tint, size: 22),
      ),
      iconTheme: IconThemeData(color: c.secondaryLabel, size: 22),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: AppMetrics.gutter),
        iconColor: c.tint,
        titleTextStyle: AppText.body.copyWith(color: c.label),
        subtitleTextStyle: AppText.footnote.copyWith(color: c.secondaryLabel),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.fill,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
          borderSide: BorderSide(color: c.tint, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        hintStyle: AppText.body.copyWith(color: c.tertiaryLabel),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: c.fill,
        side: BorderSide.none,
        labelStyle: AppText.footnote.copyWith(color: c.label),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(999),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Colors.white : Colors.white,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.tint : c.tertiaryLabel,
        ),
        trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.secondaryBackground,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppMetrics.radiusXl)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.secondaryBackground,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
        ),
        titleTextStyle: AppText.headline.copyWith(color: c.label),
        contentTextStyle: AppText.callout.copyWith(color: c.secondaryLabel),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: c.isDark ? const Color(0xFF2C2C2E) : const Color(0xFF1C1C1E),
        contentTextStyle: AppText.subheadline.copyWith(color: Colors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(c.tertiaryLabel),
        thickness: const WidgetStatePropertyAll(6),
        radius: const Radius.circular(3),
        crossAxisMargin: 2,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          // 双端统一用同一套转场，保证观感一致
          TargetPlatform.windows: _NoopTransitionsBuilder(),
          TargetPlatform.android: _NoopTransitionsBuilder(),
          TargetPlatform.linux: _NoopTransitionsBuilder(),
          TargetPlatform.macOS: _NoopTransitionsBuilder(),
        },
      ),
    );
  }
}

/// 关掉系统默认转场，全部改用自定义的 Apple 风格转场。
class _NoopTransitionsBuilder extends PageTransitionsBuilder {
  const _NoopTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}
