/// 视频控制条的显隐规则。
///
/// 抽成独立的一个类、并且和 UI 完全无关，是因为这套规则是"悬停 / 是否在播放 /
/// 鼠标静止超时"三个条件的组合 —— 藏在 widget 的私有 state 里就只能靠手点验证，
/// 而这恰恰是最容易被改坏的地方（用户报的就是"那一堆控件老是杵在画面上"）。
///
/// 规则（和 [MediaCard] 的说明一致）：
///   · 鼠标不在画面上 → 不显示
///   · 鼠标在画面上 → 显示；**播放中**一旦静止 [idleHide] 就自动收起
///   · 暂停时不自动收起 —— 用户正盯着进度条准备拖，藏了纯属添乱
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// 鼠标在画面上静止多久后收起控制条。
const Duration kControlsIdleHide = Duration(seconds: 3);

class VideoControlsVisibility {
  VideoControlsVisibility({this.idleHide = kControlsIdleHide, this.onChanged});

  /// 静止多久后收起。测试里调小，免得等 3 秒。
  final Duration idleHide;

  /// 控制条显隐**发生变化**时回调（仅变化时触发，不是每次鼠标移动都触发）。
  /// widget 用它来 setState —— 鼠标移动事件非常密集，不能每次都重绘。
  final VoidCallback? onChanged;

  bool _hovering = false;
  bool _playing = false;
  bool _barVisible = false;
  Timer? _timer;

  /// 鼠标是否在画面范围内。
  bool get hovering => _hovering;

  /// 底部控制条当前是否该显示。
  bool get barVisible => _barVisible;

  /// 鼠标进入画面。
  void enter() {
    _hovering = true;
    _show();
  }

  /// 鼠标在画面里动了（`onHover` 会非常频繁地触发）。
  void hover() {
    if (!_hovering) return;
    _show();
  }

  /// 鼠标离开画面。
  void exit() {
    _hovering = false;
    _timer?.cancel();
    _setBar(false);
  }

  /// 播放状态变化。
  void setPlaying(bool playing) {
    if (playing == _playing) return;
    _playing = playing;
    if (playing) {
      // 开始播放：鼠标多半还在画面上（刚点的播放），亮出来再计时收起
      if (_hovering) _show();
    } else {
      // 暂停/播完：停止自动收起，让用户能从容拖进度、改倍速
      _timer?.cancel();
      if (_hovering) _setBar(true);
    }
  }

  void dispose() => _timer?.cancel();

  /// 亮出控制条，并把"收起"的倒计时重新开始。
  void _show() {
    _timer?.cancel();
    _setBar(true);
    _timer = Timer(idleHide, _autoHide);
  }

  void _autoHide() {
    // 只在"正在播 + 鼠标还在画面上"时收起：
    // 鼠标都走了就该由 exit() 收，暂停了就该让它留着
    if (!_playing || !_hovering) return;
    _setBar(false);
  }

  void _setBar(bool v) {
    if (v == _barVisible) return;
    _barVisible = v;
    onChanged?.call();
  }
}
