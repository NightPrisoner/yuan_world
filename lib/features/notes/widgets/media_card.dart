/// 正文里的视频卡片：直接在笔记里播放。
///
/// 用 `media_kit` 而不是 `video_player`：后者在 Windows 上**没有官方实现**，
/// 而这个应用是桌面优先的。media_kit 四端都有，控制条也能完全自己写。
///
/// ## 封面态：不建播放器
///
/// 视频**没被点过之前只显示一张首帧图** `xxx_first_frame.png`，播放器是懒创建
/// 的 —— 正文里可能有多个视频，一进笔记就为每个都建一个解码器，内存和原生
/// 句柄都吃不消（一屏几个视频就是几个 libmpv 实例）。
///
/// 这张图有两种来源：下载工具（B 站那种）本来就导出了一张；没有的话由
/// [PosterMaker] 在卡片**真的出现在屏幕上**时补抓一张存下来（也是一次性的，
/// 存下来之后永远走图片路径）。两个都没有就退化成深色占位块 —— 三种情况都
/// 居中盖一个大播放键。点下去才 `Player()` + `VideoController()`，
/// 之后这张卡片一直走播放器态。
///
/// ## 控制条什么时候出现（很重要的一处交互）
///
///   · 鼠标不在画面上 → 什么都不显示，只有画面本身
///   · 暂停 / 播完 → 画面**正中央一个大按钮**（播放 / 重播），
///     鼠标移上去才额外露出底部控制条（要拖进度、改倍速）
///   · 播放中且鼠标在画面上 → 显示底部控制条
///   · 播放中鼠标停在画面上**不动**超过 [kControlsIdleHide] → 控制条自动收起
///     （全屏看片时它一直压着画面最烦人），动一下鼠标又出来
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import '../../../core/media/poster_maker.dart';
import '../../../core/motion/app_motion.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_menu.dart';
import 'video_controls_visibility.dart';

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

  /// 首帧图的名字：`x.mp4` → `x_first_frame.png`。
  ///
  /// 纯函数、没有 IO，所以单独放在 widget 上给测试直接调
  /// （真正干的活是 [PosterMaker]）。
  static String posterNameFor(String relPath) =>
      PosterMaker.posterNameFor(relPath);

  @override
  State<MediaCard> createState() => _MediaCardState();
}

class _MediaCardState extends State<MediaCard>
    with AutomaticKeepAliveClientMixin {
  Player? _player;
  VideoController? _controller;

  /// 打开/播放失败的原因。非空时直接在卡片上显示 —— 静默失败的
  /// 表现就是"点播放没反应"，用户和我都无从下手。
  String? _error;
  StreamSubscription<String>? _errorSub;

  /// 用户点过播放没有。**没点之前不建播放器**（见类文档）。
  bool _activated = false;

  /// 当前是否在播（只用来决定"要不要保活"，见 [wantKeepAlive]）。
  bool _playing = false;
  StreamSubscription<bool>? _playingSub;

  /// 已经为这张卡片排过"抓首帧"的队了（不管成没成，只排一次）。
  bool _posterAsked = false;

  /// 这一帧的"看看它在不在屏幕上"已经约好了（避免 build 一次约一个）。
  bool _posterCheckPending = false;

  bool get _exists => File(widget.path).existsSync();

  /// 首帧图**应该**在的位置（不一定存在）。
  String get _posterFile => p.join(
    p.dirname(widget.path),
    p.basename(MediaCard.posterNameFor(widget.relPath)),
  );

  /// 首帧图的绝对路径；没有就 null。
  String? get _posterPath {
    // 变量名不能用 p（会和 path 包的前缀 p 冲突）
    final candidate = _posterFile;
    return File(candidate).existsSync() ? candidate : null;
  }

  /// 没有首帧图 → 排一次队让 [PosterMaker] 补一张。
  ///
  /// 只在**这张卡片真的在屏幕上**的时候才排：一屏之外的视频抓了也白抓
  /// （用户翻到那儿可能都好几天以后了），而且白占一个解码器。
  void _maybeAskForPoster() {
    if (_posterAsked || _posterCheckPending || _activated || !_exists) return;
    if (_posterPath != null) return; // 图已经有了，什么都不用做
    _posterCheckPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _posterCheckPending = false;
      if (!mounted || _activated || _posterPath != null) return;
      if (!_onScreen()) return; // 这次不算数，滚进来的时候会再排一次
      _posterAsked = true;
      PosterMaker.request(
        videoPath: widget.path,
        posterPath: _posterFile,
        onReady: () {
          if (mounted) setState(() {});
        },
      );
    });
  }

  /// 卡片现在看得见吗（只按竖直方向算，正文是竖着的）。
  bool _onScreen() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;
    final h = MediaQuery.sizeOf(context).height;
    return bottom > 0 && top < h;
  }

  // **不再一进来就建播放器**（原来这里是 `initState`，现在整个搬走了）。
  //
  // 以前为了拿到首帧画面，每个可见的视频卡都会建一个 Player ——
  // 一屏里放几个视频就是几个 libmpv 实例（每个都带解码器和纹理）。
  // 现在封面用 `xxx_first_frame.png`（现成的就用，没有就让 [PosterMaker]
  // 补一张，见 [_maybeAskForPoster]），一个播放器都不用建。

  @override
  void dispose() {
    _playingSub?.cancel();
    _errorSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  /// 懒加载：用户点了才建播放器并开始播。
  void _activate() {
    if (_activated) return;
    setState(() => _activated = true);
    _open(play: true);
  }

  void _open({required bool play}) {
    try {
      final player = Player();
      final controller = VideoController(player);
      _player = player;
      _controller = controller;
      // 打开失败要让用户**看得见**，不能只是"点了没反应"：
      // 之前这里把异常吞了，卡片就变成一个永远按不动的播放键。
      _errorSub = player.stream.error.listen((e) {
        if (mounted) setState(() => _error = e);
      });
      // 播放状态只用来决定保活：正在播的时候别让列表把它回收掉
      _playingSub = player.stream.playing.listen((v) {
        if (!mounted || v == _playing) return;
        setState(() => _playing = v);
        updateKeepAlive();
      });
      // **必须 await open** —— 这是"点播放没反应"的根因。
      //
      // media_kit 的 Player 是**异步初始化**的，`open()` 只有在原生播放器就绪
      // 之后才真正执行。之前这里不 await（fire-and-forget），命令会落在
      // 就绪之前被丢掉：媒体从来没被打开过，`state.duration` 一直是 0，
      // 于是点播放、点重播、拖进度条**全都没反应**。
      unawaited(_openMedia(player, play: play));
    } catch (e) {
      // 建播放器本身失败（原生库缺失等）也要说清楚，别留个死按钮
      _error = '$e';
    }
  }

  Future<void> _openMedia(
    Player player, {
    required bool play,
    bool hard = false,
  }) async {
    try {
      if (hard) await player.stop();
      await player.open(Media(Uri.file(widget.path).toString()), play: play);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// 只有**正在播**的时候才保活。
  ///
  /// 懒构建的列表会把滚出视口的卡片回收掉，播放器跟着被销毁 ——
  /// 滚回来就回到 00:00 重新加载（用户会觉得"播到一半被打断了"）。
  /// 但不能无脑保活：那样一屏视频就常驻一堆播放器。
  /// 折中：播着就留住，没播就允许回收（回收了再点播放会重新建，可接受）。
  @override
  bool get wantKeepAlive => _activated && _playing;

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin 要求
    final c = context.colors;

    if (!_exists) {
      return _shell(
        c,
        icon: Icons.videocam_off_outlined,
        title: '视频找不到了',
        subtitle: '${widget.relPath}（文件已删除）',
        onTap: null,
      );
    }

    // 老视频没有首帧图：让 PosterMaker 补一张（只有这一张卡片在屏幕上才排）
    _maybeAskForPoster();

    final live = _player != null && _controller != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
            child: AspectRatio(
              // 播放器需要确定的高度；16:9 是最常见的视频比例。
              // **封面态用同一个比例**：否则点播放时整篇笔记会跳一下。
              aspectRatio: 16 / 9,
              child: live
                  ? Video(
                      controller: _controller!,
                      controls: _controls,
                      fill: Colors.black,
                    )
                  : _poster(c),
            ),
          ),
          const SizedBox(height: 5),
          if (_error != null) _errorLine(c),
          _caption(c),
        ],
      ),
    );
  }

  /// 还没点播放时的封面：首帧图（导入时生成的）+ 正中一个大播放键。
  ///
  /// 这层替代了以前"一进来就建播放器看第一帧"的做法：视觉上一样能看出
  /// 视频里是什么，但**一个原生播放器都不用建**。
  /// 没有首帧图就用深色占位块（老视频可能没生成过）。
  Widget _poster(AppColors c) {
    final poster = _posterPath;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerUp: (_) => _activate(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (poster != null)
            Image.file(
              File(poster),
              fit: BoxFit.cover,
              // 首帧图是给卡片用的，按显示尺寸解码就够 ——
              // 九兆的原图直接在瀑布流里解码会拖慢滚动
              cacheWidth: 900,
              errorBuilder: (_, _, _) => ColoredBox(color: Colors.black),
            )
          else
            ColoredBox(color: Colors.black.withValues(alpha: 0.88)),
          // 压一层渐变，白底画面上播放键也看得清
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.10),
                  Colors.black.withValues(alpha: 0.35),
                ],
              ),
            ),
          ),
          Center(
            child: _BigPlayButton(
              icon: Icons.play_arrow_rounded,
              tip: '播放',
              onTap: _activate,
            ),
          ),
        ],
      ),
    );
  }

  /// 播放失败时把原因写在卡片下面。
  ///
  /// **不能让失败无声无息**：之前异常被吞掉，卡片就是一个永远按不动的
  /// 播放键，用户只能反馈"点了没反应"，谁也不知道卡在哪一步。
  Widget _errorLine(AppColors c) => Padding(
    padding: const EdgeInsets.only(bottom: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.error_outline_rounded, size: 13, color: c.destructive),
        const SizedBox(width: 5),
        Expanded(
          child: Text(
            '这个视频播放失败：$_error',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption2.copyWith(color: c.destructive),
          ),
        ),
      ],
    ),
  );

  /// 控件层单独做成一个 StatefulWidget，而不是这里的方法。
  ///
  /// 硬理由：全屏时 media_kit 会 **push 一个新路由**，并用同一个
  /// `controls` 构造器重建一个 `Video`。挂在 MediaCard 上的状态
  /// （悬停、控制条显隐）**不会让新路由里的控件重建** —— 结果就是全屏下
  /// 悬停失灵，控制条永远不出现，连退出全屏都点不到。
  /// 状态放进控件层自己身上，两个实例各自独立工作。
  Widget _controls(VideoState state) => _VideoControls(
    state: state,
    // 媒体没打开时重新打开 —— 只有 MediaCard 知道文件路径。
    // hard=true 时先 stop() 再 open：原生播放器状态卡住时，
    // 只有整个重来一次才拉得动。
    onReload: ({bool hard = false}) async {
      final p = _player;
      if (p != null) await _openMedia(p, play: true, hard: hard);
    },
  );

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
                          style: AppText.caption1.copyWith(
                            color: c.tertiaryLabel,
                          ),
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

  /// 视频下面那一行：图标 + 文件名。
  ///
  /// 这一行**始终显示**：它是笔记里唯一能看出"这是哪个文件"的地方
  /// （正文里的路径是不渲染成文字的）。它也不压在画面上，和播放控件
  /// 那套"鼠标进来才出现"的规则是两回事。
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

/// 底部控制条的外壳：渐变底 + 内边距，**只占它自己那一截**。
///
/// 单独做成公开 widget 是为了能直接测它。这一层踩过一个很隐蔽的坑：
/// `Column` 默认 `mainAxisSize: max`，会把外壳撑到**整个视频那么高** ——
/// 于是画面上的所有点击都被它吃掉，正中的播放键永远收不到点击，
/// 而它自己的按钮却是好的（那些按钮本来就在这一层里）。
/// 表现就是用户说的"点中间没反应、下面那排能用"。
class VideoControlBarShell extends StatelessWidget {
  const VideoControlBarShell({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      // 底部压一层渐变，白底视频上控件也看得清
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black.withValues(alpha: 0.55)],
        ),
      ),
      padding: const EdgeInsets.fromLTRB(10, 24, 10, 6),
      child: Column(
        // **必须是 min**：max 会把这一层撑满整个视频高度，
        // 于是它把画面上的点击全部吃掉（详见类文档）
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: children,
      ),
    );
  }
}

/// 画面正中那个大播放键。
///
/// 封面态和播放器态**共用同一个**（尺寸、描边、按下反馈都一样）：
/// 点播放时按钮不该"换一个长相"，那会让人觉得换了个东西。
class _BigPlayButton extends StatelessWidget {
  const _BigPlayButton({
    required this.icon,
    required this.tip,
    required this.onTap,
  });

  final IconData icon;
  final String tip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Tooltip(
        message: tip,
        child: Pressable(
          onTap: onTap,
          scale: 0.94,
          child: Container(
            width: 58,
            height: 58,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.42),
              shape: BoxShape.circle,
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.9),
                width: 2,
              ),
            ),
            child: Icon(icon, size: 34, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// 播放器控件层。
///
/// 结构（Stack 自下而上）：
///   1. 整块可点区域 —— 点画面任意处播放/暂停
///   2. 画面正中的大按钮 —— 未播放/播完时显示
///   3. 底部控制条 —— 鼠标在画面上时显示，静止 [kControlsIdleHide] 后收起
///
/// 最外层套 [MouseRegion]：悬停检测必须在**这一层**里，才能跟着全屏路由走。
class _VideoControls extends StatefulWidget {
  const _VideoControls({required this.state, required this.onReload});

  final VideoState state;

  /// 媒体还没打开成功时，重新打开一次（由 MediaCard 实现，它才知道路径）。
  ///
  /// 为什么需要：media_kit 的 `open()` 是异步的，命令有可能落在原生播放器
  /// 就绪之前被丢掉，那种状态下 `duration` 是 0、点播放永远没反应。
  /// [hard] 为 true 时先 stop 再 open（原生状态卡死时的兜底）。
  final Future<void> Function({bool hard}) onReload;

  @override
  State<_VideoControls> createState() => _VideoControlsState();
}

class _VideoControlsState extends State<_VideoControls> {
  /// 控制条显隐规则。真正的判断在 [VideoControlsVisibility] 里（单独测过）。
  late final VideoControlsVisibility _vis = VideoControlsVisibility(
    // 显隐变了才重绘：鼠标移动事件非常密集
    onChanged: () {
      if (mounted) setState(() {});
    },
  );

  bool _playing = false;
  bool _completed = false;
  double _rate = 1.0;

  /// 支持的倍速档位。只到 2×：再快人耳已经听不清，对看视频没帮助。
  static const List<double> _rates = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];

  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];

  Player get _player => widget.state.widget.controller.player;

  @override
  void initState() {
    super.initState();
    final player = _player;
    _playing = player.state.playing;
    _rate = player.state.rate;
    _completed = player.state.completed;
    _vis.setPlaying(_playing);

    _subs.add(
      player.stream.playing.listen((v) {
        if (!mounted || v == _playing) return;
        setState(() => _playing = v);
        _vis.setPlaying(v);
      }),
    );
    _subs.add(
      player.stream.completed.listen((v) {
        if (mounted && v != _completed) setState(() => _completed = v);
      }),
    );
    // 倍速从 player 读，而不是自己存一份：全屏那个新实例也就能显示对
    _subs.add(
      player.stream.rate.listen((v) {
        if (mounted && v != _rate) setState(() => _rate = v);
      }),
    );
  }

  @override
  void dispose() {
    _vis.dispose();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  // ── 播放控制 ────────────────────────────────────────────────────────────

  /// 点画面 / 中间那个大按钮：播放 ⇄ 暂停。
  ///
  /// 这里有三处必须防的坑（都是"看起来点了没反应"）：
  ///   1. **以 player 的实时状态为准**，而不是本组件缓存的那份 ——
  ///      缓存过时的话，明明暂停着却调 pause()，等于什么都没做；
  ///   2. **媒体没打开就先重新打开**：`open()` 是异步的，命令有可能落在
  ///      原生播放器就绪之前被丢掉，此时 duration 是 0、play() 无效果。
  ///      与其让用户对着一个永远不动的播放键，不如现场补一次 open；
  ///   3. **播完再点要先 seek 回 0 并等它完成**：media_kit 停在结尾时
  ///      play() 什么都不做；seek 又是异步的，不等它完成就 play 会立刻
  ///      再次"播完"。
  Future<void> _toggle() async {
    final player = _player;

    if (player.state.playing) {
      await player.pause();
      return;
    }

    // 没有媒体（duration 为 0）说明当初的 open 没生效，补一次
    if (player.state.duration == Duration.zero) {
      await widget.onReload();
      _watchdog(player);
      // **补完 open 要把"播"这件事做完。**
      //
      // 以前这里 `return` 就走了：媒体还没就绪时点一下，界面只亮了个控制条、
      // 什么都没发生（用户的原话是"点击空白的地方只是唤起控件"），
      // 于是"第一次点"经常落空。补完再踢一脚 play，并且让 watchdog 兜底。
      if (!player.state.playing) {
        try {
          await player.play();
        } catch (_) {
          // 打开失败已经由 stream.error 报给界面了，这里不再重复处理
        }
      }
      return;
    }

    if (player.state.completed) {
      await player.seek(Duration.zero);
      if (mounted) setState(() => _completed = false);
    }
    await player.play();
    _watchdog(player);
  }

  /// 点完播放后**确认它真的动起来了**，没动就硬重启一次。
  ///
  /// media_kit 偶尔会出现"命令收下了但原生播放器没动"（位置和状态都不变），
  /// 表现就是用户说的"点了没反应"。与其让他反复点，不如自己救一次。
  /// 只在"还在开头 + 没在播"时才救：用户自己暂停（位置 > 0）不该被重启。
  void _watchdog(Player player) {
    Future<void>.delayed(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      if (player.state.playing) return;
      if (player.state.position > Duration.zero) return;
      unawaited(widget.onReload(hard: true));
    });
  }

  /// 选播放速度。
  ///
  /// [btnCtx] 是那个按钮自己的 context —— 拿它当锚点，菜单才会贴着按钮弹。
  Future<void> _pickRate(BuildContext btnCtx) async {
    final picked = await showAppMenu<double>(
      btnCtx,
      anchor: AppMenuAnchor(context: btnCtx),
      header: '播放速度',
      items: <AppMenuItem<double>>[
        for (final r in _rates)
          AppMenuItem(
            value: r,
            label: r == 1.0 ? '正常 1×' : '${_formatRate(r)}×',
            icon: _rate == r ? Icons.check_circle_rounded : Icons.speed_rounded,
            color: _rate == r ? btnCtx.colors.tint : null,
          ),
      ],
    );
    if (picked == null || !mounted) return;
    await _player.setRate(picked);
  }

  /// 1.0 → "1"，0.75 → "0.75"。别显示成 "1.0×" 那种别扭写法。
  static String _formatRate(double r) =>
      r == r.roundToDouble() ? r.toStringAsFixed(0) : '$r';

  @override
  Widget build(BuildContext context) {
    final player = _player;
    final barVisible = _vis.barVisible;

    return MouseRegion(
      onEnter: (_) => _vis.enter(),
      onExit: (_) => _vis.exit(),
      // 只要鼠标动就"续命"：倒计时重新开始，控制条重新亮出来
      onHover: (_) => _vis.hover(),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1) 整块画面收**裸指针事件**：点任意处播放/暂停。
          //
          // 用的是 Listener 而不是 GestureDetector —— 这一条是用户
          // "点中间死活播不了"换来的：手势识别要走**竞技场**，
          // 上层任何一个人（滚动、选择、别的 detector）在竞技场里赢了，
          // 这一路就再也收不到 onTap，但**外观上一切正常**，于是表现为
          // "按钮看得见、点了没反应"。Listener 拿的是最原始的指针消息，
          // 不参与竞技场，谁都抢不走。
          //
          // 它放在 Stack 最底下：点到底部控制条上的滑块/按钮时，
          // 命中测试会停在那一条，这里就不会跟着误触发播放。
          Listener(
            behavior: HitTestBehavior.opaque,
            onPointerUp: (_) => _onSurfaceTap(),
            child: const SizedBox.expand(),
          ),

          // 2) 正中央的大按钮：未播放或播完时显示。
          //    **和底部那排控件同一套做法**（Pressable，直接吃手势），
          //    而且是 Stack 里最上面的一层 —— 用户的原话就是
          //    "不能做进视频控件里？"，那就让它和能用的那些按钮完全同构。
          //
          //    **只在"没在播"的时候出现**（暂停→播放、播完→重播）。
          //    用户的话：「播放的时候不显示，点暂停或者视频播放完了才出来」，
          //    上一版我把它做成常显，中间老杵着一个圆钮，很怪。
          //    同时也跟着控制条一起显隐、收起时不接收点击：
          //    否则那个看不见的圆钮会吃掉画面正中的点击。
          AnimatedOpacity(
            opacity: (!_playing && barVisible) ? 1 : 0,
            duration: AppMotion.respecting(context, AppMotion.fast),
            child: IgnorePointer(
              ignoring: _playing || !barVisible,
              child: Center(
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: _centerButton(),
                ),
              ),
            ),
          ),

          // 3) 底部控制条
          Align(
            alignment: Alignment.bottomCenter,
            child: IgnorePointer(
              // 收起来的时候**不能留着可点区域**，
              // 否则看不见的进度条会吃掉画面上的点击
              ignoring: !barVisible,
              child: AnimatedOpacity(
                opacity: barVisible ? 1 : 0,
                duration: AppMotion.respecting(context, AppMotion.fast),
                child: _controlBar(player),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 画面正中的播放/重播按钮。
  ///
  /// 和底部那排控件**完全同构**（Tooltip + Pressable，自己吃手势）：
  /// 用户反馈底部那排能用、中间这个不能，那就别让中间那条路特殊。
  /// 点画面**空白处**：只切控制条的显示/隐藏。
  ///
  /// 用户明确要的分工：
  ///   · **正中央那个按钮** —— 播放 / 暂停 / 重播；
  ///   · **空白处** —— 显示 ↔ 隐藏控制条。
  /// 以前空白处一点就播/暂停，于是"点一下亮控件、再点一下想收起来"会变成
  /// 暂停，手感很怪。两端同一套（桌面悬停照旧能显示/隐藏）。
  void _onSurfaceTap() => _vis.toggle();

  /// 正中央那个按钮：播放 / 暂停 / 重播。
  ///
  /// 一直显示（播放中是"暂停"、暂停时是"播放"、播完是"重播"），
  /// 这样"点中间才管播放"这条规则在任何状态下都成立。
  Widget _centerButton() => _BigPlayButton(
    icon: _playing
        ? Icons.pause_rounded
        : (_completed ? Icons.replay_rounded : Icons.play_arrow_rounded),
    tip: _playing ? '暂停' : (_completed ? '重新播放' : '播放'),
    onTap: () => unawaited(_toggle()),
  );

  // ── 底部控制条 ──────────────────────────────────────────────────────────
  //
  // [暂停] [音量]  00:31 / 04:29        [1×] [全屏]
  // ————————————— 进度条 —————————————
  //
  // 自己写的原因：media_kit 内置的 AdaptiveVideoControls **没法往里加按钮**，
  // 而倍速天然属于播放器控制 —— 和暂停/音量/全屏是一类东西，
  // 放到画面外面既不符合直觉，菜单锚点也会乱飘。

  Widget _controlBar(Player player) {
    return StreamBuilder<Duration>(
      // position 一直在推，进度条才会动
      stream: player.stream.position,
      initialData: player.state.position,
      builder: (context, posSnap) {
        final pos = posSnap.data ?? Duration.zero;
        final dur = player.state.duration;
        final vol = player.state.volume;

        return VideoControlBarShell(
          children: [
            SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                // 滑块平时藏起来，只在拖动时露头
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
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
                onChanged: (v) =>
                    player.seek(Duration(milliseconds: v.round())),
              ),
            ),
            Row(
              children: [
                _ctrlBtn(
                  _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  _playing ? '暂停' : '播放',
                  () => unawaited(_toggle()),
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
                _speedBtn(),
                _ctrlBtn(
                  widget.state.isFullscreen()
                      ? Icons.fullscreen_exit_rounded
                      : Icons.fullscreen_rounded,
                  widget.state.isFullscreen() ? '退出全屏' : '全屏',
                  widget.state.toggleFullscreen,
                ),
              ],
            ),
          ],
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
  Widget _speedBtn() => Builder(
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
            '${_formatRate(_rate)}×',
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
}
