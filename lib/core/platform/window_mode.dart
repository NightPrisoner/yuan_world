/// 桌面窗口的显示模式。
///
/// 「全屏」有两层含义，必须一起做：
///   1. **界面层**：把三栏收起来，只留内容
///   2. **窗口层**：让操作系统把窗口切成真全屏（盖住任务栏、没有标题栏）
///
/// 只做第 1 层的话，用户看到的是"内容区域变大了，但上面还顶着一条标题栏"，
/// 那不叫全屏。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:window_manager/window_manager.dart';

bool get isDesktopWindow =>
    !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

/// 切换真正的全屏。手机上没有窗口概念，直接忽略。
Future<void> setAppFullscreen(bool value) async {
  if (!isDesktopWindow) return;
  try {
    await windowManager.setFullScreen(value);
  } catch (_) {
    // 某些环境下窗口管理器还没就绪。**不能让它把界面搞崩** ——
    // 界面层的全屏已经生效了，少一层就少一层。
  }
}
