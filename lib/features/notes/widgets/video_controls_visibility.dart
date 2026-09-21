/// 视频控制条什么时候显示、什么时候收起。
///
/// 规则（用户逐条提过，这里钉住）：
///   · 桌面：鼠标进画面就显示、静止一段时间收起、离开立刻收起；
///   · **手机**：没有悬停，所以"点画面空白处"= 显示/隐藏控制条；
///   · **播放/暂停/重播只归正中央那个按钮**，空白处不碰播放状态；
///   · 暂停时控制条留着不收（手机上要能拖进度、改倍速、全屏）。
///
/// 规则本身和 UI 无关，单独放这里是为了能直接测。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

/// 播放中静止多久后收起控制条。
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

  /// **点画面空白处：显示 ↔ 隐藏。**
  ///
  /// 这是用户明确要的行为：空白处只管控件的显隐，播放/暂停归正中央那个按钮
  /// （以前空白处一点就播/暂停，反而"点一下亮控件、再点一下把控件收掉"
  /// 这种期望落空）。
  void toggle() {
    if (_barVisible) {
      // 手动收起：把自动收起的倒计时也取消，否则它还会再来一次
      _timer?.cancel();
      _setBar(false);
      return;
    }
    _show();
  }

  /// 播放状态变化。
  void setPlaying(bool playing) {
    if (playing == _playing) return;
    _playing = playing;
    if (playing) {
      // 开始播放：控制条要是正显示着，就开始计时收起
      if (_barVisible) _show();
    } else {
      // 暂停/播完：停止自动收起，让用户能从容拖进度、改倍速。
      // **这里不要求"鼠标在画面上"** —— 手机上暂停了却看不到控制条，
      // 等于没法拖进度、没法全屏。
      _timer?.cancel();
      _setBar(true);
    }
  }

  void dispose() => _timer?.cancel();

  /// 亮出控制条；**只在播放中**才开始"到点自动收起"的倒计时
  /// （暂停时让它一直留着）。
  void _show() {
    _timer?.cancel();
    _setBar(true);
    if (_playing) _timer = Timer(idleHide, _autoHide);
  }

  void _autoHide() {
    if (!_playing) return;
    _setBar(false);
  }

  void _setBar(bool v) {
    if (v == _barVisible) return;
    _barVisible = v;
    onChanged?.call();
  }
}
