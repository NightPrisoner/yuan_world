/// 各平台的应用数据目录解析。
///
/// 单独拆出来是为了让 `data/` 层保持对 Flutter 的零依赖：
/// 只有这里（以及 UI 层）才允许碰 `path_provider`。
///
/// 落点策略：
///   **桌面**  可执行文件旁边的 `data/` —— 数据跟着软件走。
///             绿色软件的习惯：把文件夹拷到 U 盘上，数据也一起带走；
///             装在 D 盘就全在 D 盘，不会往 C 盘塞东西。
///   **手机**  应用私有目录。手机上没有"安装位置"这个概念，
///             应用私有目录是唯一既合法又不会被清理的地方。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 解析应用数据根目录；不存在时创建。
Future<String> resolveAppRoot() async {
  if (Platform.isAndroid || Platform.isIOS) {
    final dir = await getApplicationSupportDirectory();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }

  // 桌面：exe 同级的 data/
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final root = p.join(exeDir, 'data');

  await _migrateFromAppData(root);

  final dir = Directory(root);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return root;
}

/// 老版本把数据放在 %APPDATA%，这里做一次性搬迁。
///
/// **不能只换路径不搬数据** —— 那等于用户一升级，73 篇笔记和几百张图片
/// 全部凭空消失。所以在新位置为空、老位置有库时，整目录搬过去。
Future<void> _migrateFromAppData(String newRoot) async {
  final appData = Platform.environment['APPDATA'];
  if (appData == null || appData.isEmpty) return;

  final oldRoot = p.join(appData, 'com.yuanworld', 'yuan_world');
  final oldDir = Directory(oldRoot);
  if (!oldDir.existsSync()) return;

  // 新位置已经有库了就不动 —— 用户可能已经在新位置用了一阵
  if (File(p.join(newRoot, 'yuanworld.db')).existsSync()) return;

  final newDir = Directory(newRoot);
  if (!newDir.existsSync()) newDir.createSync(recursive: true);

  for (final entity in oldDir.listSync()) {
    final name = p.basename(entity.path);
    final target = p.join(newRoot, name);
    try {
      // 跨盘 rename 会失败（C: → D:），所以用"复制 + 删除"兜底
      entity.renameSync(target);
    } on FileSystemException {
      try {
        if (entity is Directory) {
          _copyDir(entity, Directory(target));
        } else if (entity is File) {
          entity.copySync(target);
        } else {
          continue;
        }
        entity.deleteSync(recursive: true);
      } catch (_) {
        // 搬不动就算了：老数据还在原处，至少没毁掉
      }
    }
  }
}

void _copyDir(Directory from, Directory to) {
  if (!to.existsSync()) to.createSync(recursive: true);
  for (final e in from.listSync()) {
    final name = p.basename(e.path);
    if (e is Directory) {
      _copyDir(e, Directory(p.join(to.path, name)));
    } else if (e is File) {
      e.copySync(p.join(to.path, name));
    }
  }
}
