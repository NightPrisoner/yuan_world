/// 崩溃与错误日志。
///
/// 开源软件最常见的一类 issue 是「点了几下就崩了」—— 没有日志，开发者连
/// 从哪儿查都不知道。这个文件做三件事：
///
///   1. 接管三处错误出口：Flutter 框架错误、引擎/平台异步错误、未捕获的
///      区间错误（`runZonedGuarded`）；
///   2. 把最近若干条错误写进 `data/logs/`，**保留最近 N 份**，不会无限涨；
///   3. 生成一份可复制的诊断文本（版本、平台、库大小、最近的错误），
///      用户在设置页一点就能拿到，贴到 issue 里。
///
/// 刻意做得很小：不引第三方崩溃上报（那要联网，与本应用"数据全在本机"
/// 的定位冲突），也不拦截错误本身 —— 只记录，然后照原样继续抛给控制台。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../app_info.dart';

/// 最多保留多少份日志文件。
const int kCrashLogKeep = 30;

/// 单条日志里堆栈最多保留多少行（防止一个巨大的栈把文件撑爆）。
const int _kMaxStackLines = 40;

class CrashLog {
  const CrashLog._();

  static Directory? _dir;

  /// 已经安装过处理器（避免热重载时重复挂）。
  static bool _installed = false;

  /// 日志目录；[install] 之前为 null。
  static Directory? get directory => _dir;

  /// 在 `runApp` 之前调用一次。
  ///
  /// [root] 是应用数据根目录（`data/`），日志落在它的 `logs/` 子目录里。
  static void install(Directory root) {
    if (_installed) return;
    _installed = true;

    try {
      final dir = Directory(p.join(root.path, 'logs'));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      _dir = dir;
      _rotate();
    } catch (_) {
      // 建不出目录（权限/磁盘满）就退化成只打控制台，绝不因为日志而起不来
      _dir = null;
    }

    // Flutter 框架错误：build/layout/paint 里抛的，以及异步 Future 里没接的
    final previous = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      record(
        details.exception,
        details.stack,
        kind: details.library ?? 'flutter',
        extra: details.context?.toDescription(),
      );
      // 照原样交给原来的处理器：debug 下红屏、release 下控制台，都不改变行为
      if (previous != null) {
        previous(details);
      } else {
        FlutterError.presentError(details);
      }
    };

    // 引擎侧（平台通道、isolate）的错误：返回值表示"已处理"，照常返回 false
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      record(error, stack, kind: 'platform');
      return false;
    };
  }

  /// 记录一条错误。写盘失败也只是打控制台，不会二次抛。
  static void record(
    Object error,
    StackTrace? stack, {
    String kind = 'error',
    String? extra,
  }) {
    final now = DateTime.now();
    final buffer = StringBuffer()
      ..writeln('时间：${now.toIso8601String()}')
      ..writeln('版本：${AppInfo.version}')
      ..writeln('类型：$kind');
    if (extra != null && extra.isNotEmpty) buffer.writeln('上下文：$extra');
    buffer.writeln('错误：$error');
    if (stack != null) {
      final lines = stack.toString().trimRight().split('\n');
      buffer
        ..writeln('堆栈：')
        ..writeln(
          lines.take(_kMaxStackLines).join('\n'),
        );
      if (lines.length > _kMaxStackLines) {
        buffer.writeln('…（还有 ${lines.length - _kMaxStackLines} 行）');
      }
    }

    final text = buffer.toString();
    // 控制台始终打一份：用户在终端里跑的时候能立刻看到
    debugPrint('[CrashLog/$kind] $text');

    final dir = _dir;
    if (dir == null) return;
    try {
      final file = File(p.join(dir.path, _fileNameFor(now)));
      file.writeAsStringSync(text, mode: FileMode.append, flush: true);
      _rotate();
    } catch (_) {
      // 忽略：日志写不进去不该影响正在跑的应用
    }
  }

  static String _fileNameFor(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return 'log-${t.year}${two(t.month)}${two(t.day)}.txt';
  }

  /// 只留最近 [kCrashLogKeep] 份，按文件名（即日期）倒序。
  static void _rotate() {
    final dir = _dir;
    if (dir == null) return;
    try {
      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('log-'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      for (var i = kCrashLogKeep; i < files.length; i++) {
        try {
          files[i].deleteSync();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 现有日志文件，新的在前。
  static List<File> files() {
    final dir = _dir;
    if (dir == null) return const <File>[];
    try {
      final list = dir
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('log-'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      return list;
    } catch (_) {
      return const <File>[];
    }
  }

  /// 日志总字节数（设置页显示"占多少空间"用）。
  static int totalBytes() {
    var bytes = 0;
    for (final f in files()) {
      try {
        bytes += f.lengthSync();
      } catch (_) {}
    }
    return bytes;
  }

  static void clear() {
    for (final f in files()) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
  }

  /// 最近的错误文本（给设置页直接预览）。
  static String recentText({int maxChars = 4000}) {
    final list = files();
    if (list.isEmpty) return '';
    final buffer = StringBuffer();
    for (final f in list) {
      try {
        buffer.writeln(f.readAsStringSync());
      } catch (_) {}
      if (buffer.length >= maxChars) break;
    }
    final text = buffer.toString();
    if (text.length <= maxChars) return text;
    // 截前面：最新的错误在最后写进去的那份文件里，反倒更该看
    return text.substring(text.length - maxChars);
  }

  /// 测试用：复位，让下一次 [install] 生效。
  @visibleForTesting
  static void resetForTesting() {
    _installed = false;
    _dir = null;
  }

  /// 测试用：不装处理器、只指定目录。
  @visibleForTesting
  static void attachForTesting(Directory dir) {
    _dir = dir;
  }
}
