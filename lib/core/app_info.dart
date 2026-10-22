import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// 应用自身的元信息（目前只有版本号）。
///
/// 版本号的**唯一来源**是 `pubspec.yaml` 的 `version:` 字段，它会被平台构建
/// 写进 Android 的 versionName / versionCode 和 Windows 的文件版本。这里
/// 只是运行时把那份值读出来给界面用 —— 代码里不要再手写版本号字面量。
///
/// 以前设置页「关于」里写死 `'1.0.0'`，pubspec 改版本时必然漏改一处，
/// 于是界面显示的和实际装的包不是一回事。`test/app_version_test.dart`
/// 专门钉这条：界面显示的必须是平台包里读出来的那个值。
class AppInfo {
  const AppInfo._();

  /// 未加载完（或读取失败）时回落的值。这不是"另一份版本号"，只是一个
  /// 明显不像版本的占位，界面上看到它就知道读取没成功。
  static const String unknownVersion = '—';

  static String _version = '';

  /// 形如 `1.0.0`。读不到时返回 [unknownVersion]。
  ///
  /// **只显示三段式版本号，不拼 build 号**：`1.0.0+1` 里 `+` 右边是
  /// Android 的 versionCode，它只用来让系统判断"这个包比装的新"，
  /// 每发一次版就得加一。把它显示在「关于」里，看起来像另一个版本号，
  /// 用户会以为应用有两个版本。它属于构建细节，不该出现在界面上。
  static String get version => _version.isEmpty ? unknownVersion : _version;

  /// 是否已经读到真实版本号。
  static bool get loaded => _version.isNotEmpty;

  /// 在 `main()` 里、`runApp` 之前调用一次。
  ///
  /// 读平台包信息是异步的，但它很快（本地平台通道），失败也**绝不能挡住
  /// 启动** —— 设置页显示个破折号远好过应用起不来。
  static Future<void> load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      // buildNumber 是 versionCode，只给系统做"覆盖安装"判断用，
      // 界面上不显示 —— 见 [version] 的说明。
      _version = info.version.trim();
    } catch (_) {
      _version = '';
    }
  }

  /// 测试用：直接注入版本号，绕过平台通道。
  @visibleForTesting
  static void setVersionForTesting(String value) {
    _version = value;
  }

  /// 测试用：恢复未加载状态。
  @visibleForTesting
  static void resetForTesting() {
    _version = '';
  }
}
