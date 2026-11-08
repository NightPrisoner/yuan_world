/// 手机上从别的应用把文件拖进来（分屏、悬浮小窗、中转站）。
///
/// 为什么只能在原生侧做：Android 的拖放手势（`DragEvent`）只派发给原生
/// View，Flutter 的 gesture 系统看不到。所以 `MainActivity` 拦下
/// `ACTION_DROP`、把 `content://` 的内容拷进 `cache/drops/`，再把路径报上来。
///
/// 桌面端不用这一套 —— 那边有 `desktop_drop`，拖进来时路径本来就是真实
/// 文件系统路径，可以直接用。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 一次拖入的结果。
class DropPayload {
  const DropPayload({
    required this.paths,
    required this.rejected,
    this.reasons = const <String>[],
  });

  /// 已经落到本机缓存里的绝对路径。调用方负责用完后删除。
  final List<String> paths;

  /// 拿到名字但没读成功的（目录、权限不够、0 字节）。
  final List<String> rejected;

  /// 每一条 [rejected] 对应的原因（"权限"、"URI 无效"、"0 字节"…）。
  /// 原生侧以前把异常直接扔了，用户只看到“导入失败：文件名”，
  /// 排查时完全不知道卡在哪一步，所以现在一并带上来。
  final List<String> reasons;

  bool get isEmpty => paths.isEmpty && rejected.isEmpty;

  /// 给人看的一句话说明。`rejected` 里的每一条都带原因（如果有）。
  String get summary {
    if (reasons.isNotEmpty) return reasons.first;
    if (rejected.isNotEmpty) return rejected.first;
    return '没有读到任何文件';
  }
}

/// 拖拽事件的入口。挂在应用最外层，全局只此一个。
class NativeDrop {
  const NativeDrop._();

  static const MethodChannel _channel = MethodChannel(
    'com.yuanworld.yuan_world/drop',
  );

  /// 手机上才有；桌面端走 `desktop_drop`。
  static bool get supported => !kIsWeb && Platform.isAndroid;

  /// 整棵树外面包一层，接收 [onDrop] / [onDragStarted] / [onDragEnded]。
  ///
  /// 不支持的平台上直接返回 `child`，不引入任何额外 widget。
  static Widget host({
    required Widget child,
    required Future<void> Function(DropPayload payload) onDrop,
    VoidCallback? onDragStarted,
    VoidCallback? onDragEnded,
  }) {
    if (!supported) return child;
    return _DropHost(
      onDrop: onDrop,
      onDragStarted: onDragStarted,
      onDragEnded: onDragEnded,
      child: child,
    );
  }
}

class _DropHost extends StatefulWidget {
  const _DropHost({
    required this.child,
    required this.onDrop,
    this.onDragStarted,
    this.onDragEnded,
  });

  final Widget child;
  final Future<void> Function(DropPayload payload) onDrop;
  final VoidCallback? onDragStarted;
  final VoidCallback? onDragEnded;

  @override
  State<_DropHost> createState() => _DropHostState();
}

class _DropHostState extends State<_DropHost> {
  @override
  void initState() {
    super.initState();
    NativeDrop._channel.setMethodCallHandler(_onCall);
  }

  @override
  void dispose() {
    NativeDrop._channel.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'onDragStarted':
        widget.onDragStarted?.call();
      case 'onDragEnded':
        widget.onDragEnded?.call();
      case 'onDrop':
        final args = (call.arguments as Map?) ?? const <Object?, Object?>{};
        final paths = _strings(args['paths']);
        final rejected = _strings(args['rejected']);
        final reasons = _strings(args['reasons']);
        await widget.onDrop(
          DropPayload(paths: paths, rejected: rejected, reasons: reasons),
        );
    }
  }

  static List<String> _strings(Object? raw) {
    if (raw is! List) return const <String>[];
    return raw.whereType<String>().toList(growable: false);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
