/// 把文件交给系统 / 别的应用（Android 需要 FileProvider，桌面端不需要）。
///
/// 为什么单独一个文件：
/// * Android 从 7.0 起禁止 `file://` 外传，必须用 `content://` + FileProvider；
///   而 FileProvider 只能在原生侧拼，所以这里走一个 MethodChannel。
/// * 桌面端（Windows/Linux/macOS）没有这个限制，直接 `launchUrl(Uri.file(...))`
///   就好 —— 保持原来的行为，不动它。
/// * 手机上的**目录**是应用私有的（`/data/user/0/<包名>/files/`），任何文件管理器
///   都读不到，所以"打开目录"在手机上不成立，只能"把里面的文件分享出去"。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../platform/window_mode.dart';

/// 原生侧的方法通道（只有 Android 有实现）。
const MethodChannel _channel = MethodChannel('com.yuanworld.yuan_world/files');

/// 这台设备是不是"文件必须走 FileProvider"的那种（目前只有 Android）。
bool get needsFileProvider => !kIsWeb && Platform.isAndroid;

/// 用系统默认程序打开一个文件。
///
/// 成功返回 null；失败返回一句能直接显示给用户的原因。
/// 目录在手机上不适用 —— 见 [shareFile]。
Future<String?> openFileExternally(String path) async {
  if (needsFileProvider) {
    try {
      await _channel.invokeMethod<bool>('openFile', <String, Object?>{
        'path': path,
      });
      return null;
    } on PlatformException catch (e) {
      return e.message ?? '打不开这个文件';
    } on MissingPluginException {
      return '这个版本的系统不支持直接打开文件';
    }
  }
  // 桌面：目录和文件都能直接交给系统
  try {
    final ok = await launchUrl(
      Uri.file(path),
      mode: LaunchMode.externalApplication,
    );
    return ok ? null : '系统没有接手这个请求';
  } catch (e) {
    return '$e';
  }
}

/// 走系统分享面板把文件发出去（微信、网盘、邮件都在这儿）。
///
/// 这是手机上"把备份拿出来"的正规做法：文件还在私有目录里，
/// 但接收方通过 `content://` 临时授权读到它。
Future<String?> shareFileExternally(
  String path, {
  String title = '分享',
}) async {
  if (!needsFileProvider) {
    // 桌面上没有"分享面板"这个东西，退回"打开文件所在目录"
    final dir = File(path).parent.path;
    return openFileExternally(dir);
  }
  try {
    await _channel.invokeMethod<bool>('shareFile', <String, Object?>{
      'path': path,
      'title': title,
    });
    return null;
  } on PlatformException catch (e) {
    return e.message ?? '分享失败';
  } on MissingPluginException {
    return '这个版本的系统不支持分享文件';
  }
}

/// 把私有目录里的文件/目录导出到公共「下载」目录，让文件管理器能看见。
///
/// 这才是「手动查找目录找不到备份」的正解：
/// 私有目录（`/data/user/0/<包名>/files/`）任何文件管理器都进不去，
/// 分享面板能让别人拿到，但用户自己想"在手机里看见它"只能靠导出到公共目录。
///
/// 目录会被打包成一个 zip（下载目录放不了文件夹）。
/// 成功返回导出后的路径（给用户看，比如 `/sdcard/Download/媒体.zip`），
/// 失败返回 null（原因通过 [lastExportError] 取）。
Future<String?> exportToDownloads(String path, {bool asZip = false}) async {
  if (!needsFileProvider) {
    // 桌面端没有"私有目录"这回事，本来就看得见
    return path;
  }
  try {
    return await _channel.invokeMethod<String>('exportToDownloads', {
      'path': path,
      'asZip': asZip,
    });
  } on PlatformException catch (e) {
    lastExportError = e.message ?? '导出失败';
    return null;
  } on MissingPluginException {
    lastExportError = '这个版本的系统不支持导出';
    return null;
  }
}

/// 最近一次导出失败的原因（成功时为空）。
String? lastExportError;

/// 打开一个路径 —— **手机上是"把它送到你能到的地方"**。
///
/// 为什么不能真的"跳转"：
/// Android 上 SQLite 只能待在 app-specific 目录里（应用私有目录或
/// `Android/data/<包名>/files`）。而从 Android 11 起，**任何应用**（包括
/// 系统文件管理器自己）都不允许进入 `Android/data/`，所以"跳到那个位置"
/// 在系统层面就是不可能的 —— 点了只会静默失败。
///
/// 所以手机上的「打开」= 把这个目录/文件导出到公共的「下载」目录，
/// 那里任何文件管理器都进得去。用户在提示里能看到确切路径。
///
/// 返回给用户看的一句话（null 表示已经打开/导出，不用提示）。
Future<String?> openPathSmart(String path, {bool isDirectory = true}) async {
  final target = isDirectory ? path : File(path).parent.path;
  if (!Directory(target).existsSync()) return '目录还不存在';

  if (!needsFileProvider) {
    final ok = await launchUrl(
      Uri.file(target),
      mode: LaunchMode.externalApplication,
    );
    return ok ? null : '系统没有接手这个请求';
  }

  // 手机：把目录 URI 交给系统自带的「打开方式」选择器。
  //
  // 不再提前拦"私有目录读不到"—— FileProvider 出的
  // `content://<包名>.fileprovider/...` 是带临时读授权的，支持
  // DocumentsContract 的文件管理器（MT 管理器、ZArchiver）能真的翻进去。
  // 打不开由接收方报错，比我们在这里猜要准确。
  try {
    await _channel.invokeMethod<bool>('openDirectory', {'path': target});
    return null;
  } on PlatformException catch (e) {
    return e.message ?? '打不开这个目录';
  } on MissingPluginException {
    return '这个版本的系统不支持跳转目录';
  }
}

/// 跳进系统文件管理器，并停在这个目录上（不改动任何东西）。
///
/// 和 [openPathSmart] 分工：「打开」是"选个应用打开它"，这个是"带我去那儿"。
/// 返回 null 表示跳过去了；否则是给用户看的原因。
Future<String?> locateDirectoryInFileManager(String path) async {
  if (!needsFileProvider) return openFileExternally(path);
  try {
    await _channel.invokeMethod<bool>('locateDirectory', {'path': path});
    return null;
  } on PlatformException catch (e) {
    return e.message ?? '定位不到这个目录';
  } on MissingPluginException {
    return '这个版本的系统不支持定位目录';
  }
}

/// 有没有「所有文件访问」权限（Android 11+ 才有这个概念）。
///
/// 没有它时，应用只能写自己的两个私有目录，用户挑的任意文件夹会 EACCES ——
/// 这是手机上"修改位置"做不到像桌面端那样自由的根本原因。
/// 桌面端和 Android 10 及以下一律返回 true（不需要这个权限）。
Future<bool> hasAllFilesAccess() async {
  if (!needsFileProvider) return true;
  try {
    return await _channel.invokeMethod<bool>('hasAllFilesAccess') ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// 跳系统设置页让用户开「所有文件访问」。
/// 返回 null 表示跳过去了；否则是给用户看的原因。
Future<String?> requestAllFilesAccess() async {
  if (!needsFileProvider) return null;
  try {
    await _channel.invokeMethod<bool>('requestAllFilesAccess');
    return null;
  } on PlatformException catch (e) {
    return e.message ?? '打不开系统设置';
  } on MissingPluginException {
    return '这个版本的系统不支持';
  }
}

/// 这个路径是不是「应用私有目录」（`/data/user/0/<包名>/...`）。
///
/// 外部私有目录是 `/storage/emulated/0/Android/data/<包名>/...`，
/// 那个文件管理器能翻到；`/data/user/0` 下面的一律读不到。
bool isPrivateAndroidPath(String path) {
  if (!needsFileProvider) return false;
  final norm = path.replaceAll('\\', '/');
  return norm.startsWith('/data/user/') ||
      norm.startsWith('/data/data/') ||
      norm.startsWith('/data/private/');
}

/// 列出所有能打开这个目录的应用（`package` / `label`）。
///
/// 系统那个 `createChooser` 在 MIUI 上只显示几个应用，MT 管理器明明装着
/// 却不出现。所以留一条"自己画列表"的路。
Future<List<({String package, String label, String icon})>>
    listDirectoryViewers(String path) async {
  if (!needsFileProvider) return const [];
  try {
    final raw = await _channel.invokeListMethod<Map<Object?, Object?>>(
      'listDirectoryViewers',
      {'path': path},
    );
    return [
      for (final m in raw ?? const <Map<Object?, Object?>>[])
        (
          package: '${m['package'] ?? ''}',
          label: '${m['label'] ?? ''}',
          icon: '${m['icon'] ?? ''}',
        ),
    ];
  } on PlatformException {
    return const [];
  } on MissingPluginException {
    return const [];
  }
}

/// 用指定的应用打开目录（配合 [listDirectoryViewers] 自绘列表）。
Future<String?> openDirectoryWith(String path, String package) async {
  if (!needsFileProvider) return '这个平台不需要指定应用';
  try {
    await _channel.invokeMethod<bool>('openDirectoryWith', {
      'path': path,
      'package': package,
    });
    return null;
  } on PlatformException catch (e) {
    return e.message ?? '打不开';
  } on MissingPluginException {
    return '这个版本的系统不支持';
  }
}

/// 桌面端判断（沿用项目里唯一那份实现）。
bool get canOpenFolder => isDesktopWindow;
