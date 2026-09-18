/// 正文里的视频卡片：直接在笔记里播放。
///
/// 用 `media_kit` 而不是 `video_player`：后者在 Windows 上**没有官方实现**，
/// 而这个应用是桌面优先的。media_kit 的四端都有，而且能拿到首帧当预览图。
///
/// 播放器是**懒创建**的：正文里可能有多个视频，一进笔记就为每个都建一个
/// 解码器，内存和句柄都吃不消。点播放才建。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import '../../../core/motion/app_motion.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_menu.dart';

class MediaCard extends StatefulWidget {
  const MediaCard({
    super.key,
    required this.path,
    required this.relPath,
    this.index,
  });

  /// 绝对路径。
  final String path;

  /// 相对图片根目录的路径，用于显示。
  final String relPath;

  /// 在正文里的序号，可空。
  final int? index;

  @override
  State<MediaCard> createState() => _MediaCardState();
}

class _MediaCardState extends State<MediaCard> {
  Player? _player;
  VideoController? _controller;

  /// 是否正在播放。决定显示"播放按钮"还是"完整控件"。
  bool _playing = false;
  StreamSubscription<bool>? _playingSub;

  /// 当前倍速。
  double _rate = 1.0;

  /// 支持的倍速档位。
  ///
  /// 只到 2×：再快人耳已经听不清，对看视频没帮助。
  static const List<double> _rates = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  bool get _exists => File(widget.path).existsSync();

  @override
  void initState() {
    super.initState();
    // **一进来就打开但不播放** —— 这样能直接看到第一帧画面当预览图。
    // 之前是点播放才创建，用户看到的是一张灰卡片，不知道视频里是什么。
    if (_exists) _open(play: false);
  }

  @override
  void dispose() {
    _playingSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  void _open({required bool play}) {
    final player = Player();
    final controller = VideoController(player);
    player.open(Media(Uri.file(widget.path).toString()), play: play);
    _playingSub = player.stream.playing.listen((v) {
      if (mounted && v != _playing) setState(() => _playing = v);
    });
    _player = player;
    _controller = controller;
  }

  void _start() {
    final player = _player;
    if (player != null) {
      player.play();
      return;
    }
    // 理论上不会走到这，留个兜底
    setState(() => _open(play: true));
  }

  /// 选播放速度。
  ///
  /// [btnCtx] 是那个按钮自己的 context —— 拿它当锚点，菜单才会贴着按钮弹。
  /// 不传的话会退化成"上一次菜单的位置"，飘到页面别处去。
  Future<void> _pickRate(BuildContext btnCtx) async {
    final player = _player;
    if (player == null) return;

    final picked = await showAppMenu<double>(
      btnCtx,
      anchor: AppMenuAnchor(context: btnCtx),
      header: '播放速度',
      items: <AppMenuItem<double>>[
        for (final r in _rates)
          AppMenuItem(
            value: r,
            label: r == 1.0 ? '正常 1×' : '${formatRate(r)}×',
            icon: _rate == r ? Icons.check_circle_rounded : Icons.speed_rounded,
            color: _rate == r ? btnCtx.colors.tint : null,
          ),
      ],
    );
    if (picked == null || !mounted) return;

    await player.setRate(picked);
    if (mounted) setState(() => _rate = picked);
  }

  /// 1.0 → "1"，0.75 → "0.75"。别显示成 "1.0×" 那种别扭写法。
  static String formatRate(double r) =>
      r == r.roundToDouble() ? r.toStringAsFixed(0) : '$r';

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    if (!_exists || _player == null || _controller == null) {
      return _shell(
        c,
        icon: _exists ? Icons.play_arrow_rounded : Icons.videocam_off_outlined,
        title: _exists ? '视频' : '视频找不到了',
        subtitle: _exists ? widget.relPath : widget.relPath,
        onTap: _exists ? _start : null,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
            child: AspectRatio(
              // 播放器需要确定的高度；16:9 是最常见的视频比例
              aspectRatio: 16 / 9,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 未播放时这里就是**第一帧画面**，当作预览图。
                  //
                  // 控件用自己写的 `_controls` 而不是内置 AdaptiveVideoControls:
                  // 内置那套**加不了按钮**，而倍速必须和暂停/音量/全屏同一行。
                  Video(
                    controller: _controller!,
                    controls: _controls,
                    fill: Colors.black,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 5),
          _caption(c),
        ],
      ),
    );
  }

  Widget _shell(
    AppColors c, {
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onTap,
  }) {
    final ext = p.extension(widget.path).replaceFirst('.', '').toUpperCase();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Pressable(
            onTap: onTap,
            scale: 0.99,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
              decoration: BoxDecoration(
                color: c.fill,
                borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
                border: Border.all(color: c.separator, width: 0.5),
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: c.tint.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(icon, size: 24, color: c.tint),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: AppText.callout.copyWith(
                            color: c.label,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              AppText.caption1.copyWith(color: c.tertiaryLabel),
                        ),
                      ],
                    ),
                  ),
                  if (ext.isNotEmpty && onTap != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: c.secondaryBackground,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        ext,
                        style: AppText.caption2.copyWith(
                          color: c.secondaryLabel,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 5),
          _caption(c),
        ],
      ),
    );
  }

  // ── 自定义控件条 ────────────────────────────────────────────────────────
  //
  // [暂停] [音量]  00:31 / 04:29        [1×] [全屏]
  // ————————————— 进度条 —————————————
  //
  // 自己写的原因：media_kit 内置的 AdaptiveVideoControls **没法往里加按钮**，
  // 而倍速天然属于播放器控制 —— 和暂停/音量/全屏是一类东西，
  // 放到画面外面既不符合直觉，菜单锚点也会乱飘。

  Widget _controls(VideoState state) {
    final player = state.widget.controller.player;

    return StreamBuilder<bool>(
      stream: player.stream.playing,
      initialData: player.state.playing,
      builder: (context, playingSnap) {
        final playing = playingSnap.data ?? false;
        return StreamBuilder<Duration>(
          // position 一直在推，进度条才会动
          stream: player.stream.position,
          initialData: player.state.position,
          builder: (context, posSnap) {
            final pos = posSnap.data ?? Duration.zero;
            final dur = player.state.duration;
            final vol = player.state.volume;

            return Container(
              // 底部压一层渐变，白底视频上控件也看得清
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.55),
                  ],
                ),
              ),
              padding: const EdgeInsets.fromLTRB(10, 24, 10, 6),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 3,
                      // 滑块平时藏起来，只在拖动时露头
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      overlayShape: SliderComponentShape.noOverlay,
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.white24,
                      thumbColor: Colors.white,
                    ),
                    child: Slider(
                      value: dur.inMilliseconds == 0
                          ? 0
                          : pos.inMilliseconds
                              .clamp(0, dur.inMilliseconds)
                              .toDouble(),
                      // 时长还没读到时给 1，避免 max=0 让 Slider 断言失败
                      max: dur.inMilliseconds < 1
                          ? 1.0
                          : dur.inMilliseconds.toDouble(),
                      onChanged: (v) => player.seek(
                        Duration(milliseconds: v.round()),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      _ctrlBtn(
                        playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        playing ? '暂停' : '播放',
                        () => playing ? player.pause() : player.play(),
                      ),
                      _volumeControl(player, vol),
                      const SizedBox(width: 8),
                      Text(
                        '${_fmt(pos)} / ${_fmt(dur)}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const Spacer(),
                      _speedBtn(state.context),
                      _ctrlBtn(
                        state.isFullscreen()
                            ? Icons.fullscreen_exit_rounded
                            : Icons.fullscreen_rounded,
                        state.isFullscreen() ? '退出全屏' : '全屏',
                        state.toggleFullscreen,
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// 音量：图标（点击静音切换）+ **一条滑杆**。
  ///
  /// 只给"静音/取消静音"是不够的 —— media_kit 内置控件本来带音量滑杆，
  /// 换成自定义控件后如果只剩一个开关，就等于**把调音量的能力砍掉了**。
  /// 这是换控件时最容易漏掉的东西。
  Widget _volumeControl(Player player, double vol) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ctrlBtn(
          vol <= 0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
          vol <= 0 ? '取消静音' : '静音',
          () => player.setVolume(vol <= 0 ? 100 : 0),
        ),
        SizedBox(
          width: 66,
          child: SliderTheme(
            data: SliderThemeData(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: SliderComponentShape.noOverlay,
              activeTrackColor: Colors.white,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
            ),
            child: Slider(
              value: vol.clamp(0, 100),
              max: 100,
              onChanged: (v) => player.setVolume(v),
            ),
          ),
        ),
      ],
    );
  }

  Widget _ctrlBtn(IconData icon, String tip, VoidCallback onTap) => Tooltip(
    message: tip,
    child: Pressable(
      onTap: onTap,
      scale: 0.9,
      child: SizedBox(
        width: 34,
        height: 30,
        child: Icon(icon, size: 20, color: Colors.white),
      ),
    ),
  );

  /// 倍速按钮 —— 和暂停、音量、全屏**在同一行**。
  Widget _speedBtn(BuildContext anchorCtx) => Builder(
    builder: (btnCtx) => Tooltip(
      message: '播放速度',
      child: Pressable(
        onTap: () => _pickRate(btnCtx),
        scale: 0.92,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: _rate == 1.0 ? 0.16 : 0.32),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            '${formatRate(_rate)}×',
            style: TextStyle(
              color: Colors.white,
              fontSize: 12,
              // 非正常速度加粗，一眼看出"我在快进"
              fontWeight: _rate == 1.0 ? FontWeight.w500 : FontWeight.w700,
            ),
          ),
        ),
      ),
    ),
  );

  /// `04:29` / 超过一小时给 `1:02:03`。
  static String _fmt(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  /// 视频下面那一行：图标 + 文件名。
  Widget _caption(AppColors c) => Row(
    children: [
      Icon(Icons.movie_outlined, size: 12, color: c.quaternaryLabel),
      const SizedBox(width: 5),
      Expanded(
        child: Text(
          widget.index == null
              ? widget.relPath
              : '第 ${widget.index} 个 · ${widget.relPath}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.caption2.copyWith(color: c.quaternaryLabel),
        ),
      ),
    ],
  );
}
