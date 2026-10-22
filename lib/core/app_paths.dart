/// 各平台的应用数据目录解析。
///
/// 单独拆出来是为了让 `data/` 层保持对 Flutter 的零依赖：
/// 只有这里（以及 UI 层）才允许碰 `path_provider`。
///
/// 落点策略：
///   **桌面**  默认在可执行文件旁边的 `data/` —— 数据跟着软件走。
///             绿色软件的习惯：把文件夹拷到 U 盘上，数据也一起带走；
///             装在 D 盘就全在 D 盘，不会往 C 盘塞东西。
///             **可以在设置里改到别的位置**，改了之后记在 exe 旁边的
///             `data-location.txt` 里，下次启动照着它开。
///   **手机**  应用私有目录。手机上没有"安装位置"这个概念，
///             应用私有目录是唯一既合法又不会被清理的地方，所以不给改。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 记住"数据放在别处"的指针文件名。
///
/// 刻意放在 exe 同级而不是 `data/` 里：数据一旦搬走，`data/` 可能就没了，
/// 指针跟着一起消失就再也找不到新位置。
const String kLocationFileName = 'data-location.txt';

/// 默认的数据根目录（不考虑用户改过位置的情况）。
Future<String> defaultAppRoot() async {
  if (Platform.isAndroid || Platform.isIOS) {
    final dir = await getApplicationSupportDirectory();
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir.path;
  }
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  final root = p.join(exeDir, 'data');
  final dir = Directory(root);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  return root;
}

/// 指针文件路径（桌面才用得上）。
String? get _pointerPath {
  if (Platform.isAndroid || Platform.isIOS) return null;
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  return p.join(exeDir, kLocationFileName);
}

/// 用户改过的数据目录；没改过（或手机）返回 null。
///
/// 只读指针、不检查目录是否还在 —— 界面要能显示"你设的是这个"，
/// 哪怕那块盘现在没插上。
String? configuredAppRoot() {
  final path = _pointerPath;
  if (path == null) return null;
  try {
    final f = File(path);
    if (!f.existsSync()) return null;
    final text = f.readAsStringSync().trim();
    return text.isEmpty ? null : text;
  } catch (_) {
    return null;
  }
}

/// 解析应用数据根目录；不存在时创建。
///
/// 优先用用户指定的位置；那里打不开（外接盘没插、目录被删）就退回默认，
/// **但不删指针** —— 用户下次把盘插回来，数据就回来了。
Future<String> resolveAppRoot() async {
  if (Platform.isAndroid || Platform.isIOS) {
    return defaultAppRoot();
  }

  final custom = configuredAppRoot();
  if (custom != null) {
    final dir = Directory(custom);
    try {
      if (!dir.existsSync()) dir.createSync(recursive: true);
      // 能建不等于能写。探一下，免得打开数据库时才炸
      final probe = File(p.join(dir.path, '.yw-write-test'));
      probe.writeAsStringSync('ok');
      probe.deleteSync();
      return dir.path;
    } catch (_) {
      // 指定位置暂时不可用：退回默认，指针留着
    }
  }

  final root = await defaultAppRoot();
  await _migrateFromAppData(root);
  return root;
}

/// 把数据目录设成 [path]（写指针）。真正搬文件由 [migrateDataRoot] 负责。
Future<void> rememberAppRoot(String path) async {
  final pointer = _pointerPath;
  if (pointer == null) return;
  final text = path.trim();
  if (text.isEmpty) {
    await forgetAppRoot();
    return;
  }
  File(pointer).writeAsStringSync(text);
}

/// 回到默认位置（删指针）。已经在默认位置时无副作用。
Future<void> forgetAppRoot() async {
  final pointer = _pointerPath;
  if (pointer == null) return;
  final f = File(pointer);
  if (f.existsSync()) f.deleteSync();
}

/// 一次搬运的结果，给界面报数用。
class MoveDataResult {
  const MoveDataResult({
    required this.target,
    required this.files,
    required this.bytes,
  });

  final String target;
  final int files;
  final int bytes;
}

/// 把 [from] 目录下的数据整体搬到 [to]。
///
/// **调用方必须先关掉数据库**（不然 SQLite 还开着文件，复制出来的是半截）。
/// 搬完不删原目录 —— 出问题时用户还能自己翻回去找。
///
/// 只搬数据，不搬程序：`app.so`、`flutter_assets` 这些属于安装目录本身。
Future<MoveDataResult> migrateDataRoot(
  String from,
  String to, {
  void Function(double progress)? onProgress,
}) async {
  final target = Directory(to);
  if (!target.existsSync()) target.createSync(recursive: true);

  final source = Directory(from);
  final entries = <FileSystemEntity>[];
  if (source.existsSync()) {
    for (final e in source.listSync()) {
      // 目标就在源里面（或反过来）时跳过自己，否则会无限复制
      if (p.equals(e.path, target.path)) continue;
      if (p.isWithin(e.path, target.path)) continue;
      entries.add(e);
    }
  }

  var done = 0;
  var files = 0;
  var bytes = 0;
  final total = entries.length;
  for (final e in entries) {
    final name = p.basename(e.path);
    final dst = p.join(target.path, name);
    if (e is Directory) {
      final r = await _copyDir(e, Directory(dst));
      files += r.files;
      bytes += r.bytes;
    } else if (e is File) {
      final len = e.lengthSync();
      await e.copy(dst);
      files += 1;
      bytes += len;
    }
    done += 1;
    onProgress?.call(total == 0 ? 1 : done / total);
  }
  onProgress?.call(1);
  return MoveDataResult(target: target.path, files: files, bytes: bytes);
}

/// 旧版接口保留：只算文件数/字节数，供界面显示。
Future<({int files, int bytes})> _copyDir(Directory from, Directory to) async {
  if (!to.existsSync()) to.createSync(recursive: true);
  var files = 0;
  var bytes = 0;
  for (final e in from.listSync()) {
    final name = p.basename(e.path);
    final dst = p.join(to.path, name);
    if (e is Directory) {
      final r = await _copyDir(e, Directory(dst));
      files += r.files;
      bytes += r.bytes;
    } else if (e is File) {
      final len = e.lengthSync();
      await e.copy(dst);
      files += 1;
      bytes += len;
    }
  }
  return (files: files, bytes: bytes);
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
          _copyDirSync(entity, Directory(target));
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

void _copyDirSync(Directory from, Directory to) {
  if (!to.existsSync()) to.createSync(recursive: true);
  for (final e in from.listSync()) {
    final name = p.basename(e.path);
    if (e is Directory) {
      _copyDirSync(e, Directory(p.join(to.path, name)));
    } else if (e is File) {
      e.copySync(p.join(to.path, name));
    }
  }
}
