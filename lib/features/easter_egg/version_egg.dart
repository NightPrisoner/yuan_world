/// 版本号彩蛋。就一件事：从内置图库里随机抽一张，全屏放出来。
///
///   1. 设置 → 关于 → 连点「版本」几下（每点一下有一点点反馈，不给进度）
///   2. 全屏显示一张随机图片 —— GIF 会自己动（Image 自带动图解码）
///
/// 图库是 `assets/egg/`。往里丢图片就会出现在随机池里，**不用改代码**：
/// 运行时用 AssetManifest 列目录，所以 pubspec 里只要写目录本身。
///
/// 之前做过一版"星海捡字"的小游戏，太复杂了 —— 彩蛋不该是个需要说明书的东西。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/motion/app_motion.dart';
import '../../core/theme/app_theme.dart';

/// 连点几下才出现。
const int kEggTapCount = 3;

/// 图库在资源里的前缀。
const String kEggAssetDir = 'assets/egg/';

/// 打开彩蛋。
Future<void> showVersionEgg(BuildContext context) => Navigator.of(context).push(
  PageRouteBuilder<void>(
    opaque: true,
    barrierColor: Colors.black,
    transitionDuration: AppMotion.page,
    reverseTransitionDuration: AppMotion.page,
    pageBuilder: (_, _, _) => const VersionEggPage(),
    transitionsBuilder: (_, anim, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: anim, curve: AppMotion.enter),
      child: child,
    ),
  ),
);

/// 列出图库里的资源。
///
/// 用 AssetManifest 而不是写死一份清单：往 `assets/egg/` 丢新图就能生效，
/// 不用记得回来改代码 —— 那种"改了资源忘了改清单"的坑不值得踩第二次。
Future<List<String>> loadEggGallery() async {
  try {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final all = manifest
        .listAssets()
        .where((p) => p.startsWith(kEggAssetDir))
        .toList()
      ..sort(); // 固定顺序，便于测试和复现
    return all;
  } catch (_) {
    // 资源清单读不出来不该让彩蛋炸掉，只是没图可放
    return const <String>[];
  }
}

class VersionEggPage extends StatefulWidget {
  const VersionEggPage({super.key, this.gallery, this.random});

  /// 强制指定图库（测试用）。不给就运行时从资源清单里列。
  final List<String>? gallery;

  /// 固定随机源（测试用），保证抽到的是可预期的那张。
  final math.Random? random;

  @override
  State<VersionEggPage> createState() => _VersionEggPageState();
}

class _VersionEggPageState extends State<VersionEggPage> {
  List<String> _gallery = const <String>[];
  String? _current;
  bool _loading = true;

  late final math.Random _rnd = widget.random ?? math.Random();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = widget.gallery ?? await loadEggGallery();
    if (!mounted) return;
    setState(() {
      _gallery = list;
      _current = list.isEmpty ? null : list[_rnd.nextInt(list.length)];
      _loading = false;
    });
  }

  /// 再随机抽一张。抽到和当前同一张就往后挪一格 ——
  /// 只有一张图的时候点一下毫无变化，看着像坏了。
  void _next() {
    if (_gallery.length < 2) return;
    var pick = _rnd.nextInt(_gallery.length);
    if (_gallery[pick] == _current) pick = (pick + 1) % _gallery.length;
    HapticFeedback.selectionClick();
    setState(() => _current = _gallery[pick]);
  }

  @override
  Widget build(BuildContext context) {
    final asset = _current;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white24,
                    ),
                  )
                : asset == null
                ? const Center(
                    child: Text(
                      '图库是空的\n往 assets/egg/ 放几张图就有了',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white38, height: 1.8),
                    ),
                  )
                : GestureDetector(
                    // 点一下换一张。没有别的操作，所以不用按钮
                    onTap: _next,
                    behavior: HitTestBehavior.opaque,
                    child: Center(
                      child: AnimatedSwitcher(
                        duration: AppMotion.normal,
                        child: Image.asset(
                          asset,
                          // key 带上资源名：换了图 AnimatedSwitcher 才知道要做过渡
                          key: ValueKey<String>(asset),
                          // 原图多大就多大，别拉伸变形；GIF 会自己动
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, stack) => const Text(
                            '这张图读不出来了',
                            style: TextStyle(color: Colors.white38),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
          if (asset != null && _gallery.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              // **提示条不能吃点击。**
              //
              // Text 自己是可以被命中的，而它在 Stack 里排在整屏
              // GestureDetector 后面 —— 于是"点一下换一张"这几个字
              // 正好在它自己的位置上把点击吞掉了：越按提示越没反应。
              child: IgnorePointer(
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 14),
                    child: Text(
                      '点一下换一张',
                      textAlign: TextAlign.center,
                      style: AppText.caption2.copyWith(color: Colors.white24),
                    ),
                  ),
                ),
              ),
            ),
          // 随时能出去。彩蛋最容易出的问题是"进去了出不来"，
          // 那比没有彩蛋糟得多
          Positioned(
            top: 8,
            right: 8,
            child: SafeArea(
              child: IconButton(
                tooltip: '离开',
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.close_rounded),
                color: Colors.white70,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
