/// 给**没有首帧图**的视频补一张封面。
///
/// ## 为什么需要
///
/// 正文里的视频卡默认不建播放器，只显示 `xxx_first_frame.png`（见
/// `features/notes/widgets/media_card.dart`）。但这张图不是我们生成的 ——
/// 只有下载工具顺手导出的视频才有。老视频没有图就退化成一块深色，
/// 反而比原来"建个播放器看第一帧"更差。
///
/// 这里补上：**一次性**用临时播放器抓一帧存成 PNG。存下来以后那个视频
/// 永远走图片路径，再也不会建播放器。
///
/// ## 三条硬约束
///
///   1. **串行**：整个应用同时只允许一个临时播放器存在。否则一屏十个
///      没图的视频会同时建十个 libmpv —— 正是要避免的事。
///   2. **失败就闭嘴**：抓不到就当没有（深色占位块照旧）。一个封面永远
///      不值得弹错误、更不值得挡住界面。
///   3. **要在界面起来之后调**：`VideoController` 的原生画面输出是在
///      "下一帧"里创建的，在 `runApp` 之前建会永远等不到那一帧
///      （实测直接卡死在 `open()`）。
library;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

class PosterMaker {
  PosterMaker._();

  /// 总开关。测试里关掉：`flutter test` 环境没有 libmpv，建播放器只会白等超时。
  static bool enabled = true;

  /// 首帧图的名字：`x.mp4` → `x_first_frame.png`。
  ///
  /// 纯函数、没有 IO。相对路径和绝对路径都吃（只看文件名里的点）。
  static String posterNameFor(String path) {
    final dot = path.lastIndexOf('.');
    // 扩展名必须是**文件名里的**点：路径里的点（`v1.2/clip`）不算，
    // 隐藏文件开头的点（`.hidden`）也不算。
    final slash = path.lastIndexOf('/');
    final back = path.lastIndexOf(r'\');
    final sep = slash > back ? slash : back;
    final base = dot > sep + 1 ? path.substring(0, dot) : path;
    return '${base}_first_frame.png';
  }

  /// 已经排过队的（视频路径），避免同一张卡片反复排队。
  static final Set<String> _queued = <String>{};

  /// 测试用：这条视频排过队没有（关掉 [enabled] 时也会记）。
  @visibleForTesting
  static bool wasRequested(String videoPath) => _queued.contains(videoPath);

  /// 测试用：清掉"排过队"的记录。
  @visibleForTesting
  static void resetForTest() => _queued.clear();

  static final Queue<_Job> _queue = Queue<_Job>();
  static bool _busy = false;

  /// 排队抓一帧。抓好了调 [onReady]（UI 那边 `setState` 重新读图即可）。
  ///
  /// 同一个视频只会真的抓一次；抓失败也记下来，不反复重试。
  static void request({
    required String videoPath,
    required String posterPath,
    VoidCallback? onReady,
  }) {
    if (!_queued.add(videoPath)) return;
    // 测试环境（[enabled] 为 false）：只留下"谁排过队"的痕迹，不真建播放器
    if (!enabled) return;
    _queue.add(_Job(videoPath, posterPath, onReady));
    unawaited(_drain());
  }

  static Future<void> _drain() async {
    if (_busy) return;
    _busy = true;
    try {
      while (_queue.isNotEmpty) {
        final job = _queue.removeFirst();
        final ok =
            await make(videoPath: job.videoPath, posterPath: job.posterPath);
        if (ok) job.onReady?.call();
      }
    } finally {
      _busy = false;
    }
  }

  /// 真的抓一帧：临时播放器 → 等视频参数就绪 → `screenshot-raw` → 存盘。
  ///
  /// 返回是否成功。任何一步失败都返回 false，不抛。
  static Future<bool> make({
    required String videoPath,
    required String posterPath,
  }) async {
    if (!enabled) return false;
    Player? player;
    try {
      if (!File(videoPath).existsSync()) return false;
      player = Player();
      // VideoController 会把 mpv 的 `vid` 从 `no` 打开成 `auto`
      // （media_kit 默认不解码视频，没有它 screenshot 永远拿不到帧）。
      VideoController(player);
      // 它内部的初始化挂在"下一帧"上（`addPostFrameCallback`）：界面闲着
      // 不动的时候不会有帧，得主动要一帧，否则下面 `player.open()` 会一直
      // 等原生画面输出建好而卡死。
      WidgetsBinding.instance.scheduleFrame();
      await player.open(Media(Uri.file(videoPath).toString()), play: false);
      // 等解码器把画面尺寸报出来，说明至少有一个视频帧进来了。
      await player.stream.width
          .firstWhere((w) => w != null && w > 0)
          .timeout(const Duration(seconds: 20));
      final bytes = await player
          .screenshot(format: 'image/png')
          .timeout(const Duration(seconds: 20));
      if (bytes == null || bytes.isEmpty) return false;
      // 先写临时文件再改名：中途失败不会留下半张图
      final tmp = File('$posterPath.part');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(posterPath);
      return true;
    } catch (e) {
      debugPrint('PosterMaker: 抓首帧失败（$videoPath）：$e');
      return false;
    } finally {
      try {
        await player?.dispose();
      } catch (_) {
        // 播放器销毁失败不影响结果
      }
    }
  }
}

class _Job {
  const _Job(this.videoPath, this.posterPath, this.onReady);

  final String videoPath;
  final String posterPath;
  final VoidCallback? onReady;
}
