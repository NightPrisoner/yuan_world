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

/// 用户选的位置如果是盘符根（`F:\`），数据不能直接摊在根目录里。
///
/// 盘根上全是用户自己的东西，把 `images/`、`yuanworld.db` 摊在那儿既难找
/// 也容易和别的软件撞名。统一收进一个子目录。
String dataDirIn(String chosen) =>
    isDriveRoot(chosen) ? p.join(chosen, '元世界数据') : chosen;

/// 把散在 [from]（盘符根）上的数据项收进 [into]（子目录）。
///
/// 只在目标里还没有同名项时才搬，避免把用户后来又写出来的新数据盖掉。
/// 失败一律吞掉：搬不动就按原来的路径用，绝不能因此启动不了。
///
/// 先写 `-wal`：库文件单独摆出去而日志没跟上，恢复时 SQLite 会把它当成
/// 一个没提交过事务的旧库，最近写的内容就没了。
Future<String> resolveAppRoot() async {
  if (Platform.isAndroid || Platform.isIOS) {
    return defaultAppRoot();
  }

  final custom = configuredAppRoot();
  if (custom != null) {
    // 老版本允许把数据目录指到盘符根，数据就直接摊在 `F:\` 上。
    // 这里**照旧**用它 —— 不能擅自改成子目录，那等于换了个空目录，
    // 用户看到的是"我的笔记全没了"。新选位置时才收进子目录。
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

/// 数据目录里"属于用户数据"的条目名。
///
/// 只搬这些 —— 以前这里是 `source.listSync()` 全搬，于是当用户把数据目录
/// 指到 `F:\`（盘符根）之后，程序会把整个盘的 56 个条目、1.2TB 的相册
/// 和番剧全当成"数据"往目标里拷，看起来就是「迁移卡死 / 迁不回去」。
/// 数据目录可能是任何目录，里面放什么完全不可控，所以必须按名字挑。
const List<String> kDataEntryNames = <String>[
  'yuanworld.db',
  'yuanworld.db-wal',
  'yuanworld.db-shm',
  'yuanworld.db.before-restore',
  'images',
  'snapshots',
  'backups',
  'logs',
];

/// 同 [kDataEntryNames]，但把 `-wal` 排在最前面 —— 真正搬运时用这个顺序。
const List<String> kDataEntryNamesWalFirst = <String>[
  'yuanworld.db-wal',
  'yuanworld.db',
  'yuanworld.db-shm',
  'yuanworld.db.before-restore',
  'images',
  'snapshots',
  'backups',
  'logs',
];

/// [path] 是不是盘符根目录（`F:\`、`C:\` 这种）。
bool isDriveRoot(String path) {
  final norm = p.normalize(p.absolute(path));
  return p.dirname(norm) == norm;
}



/// 把 [from] 目录下的数据搬到 [to]。
///
/// **语义是"搬"，不是"复制"**：搬完源位置的数据项就删掉，数据永远只有
/// 一份。以前这里只复制不删除，于是 `F:\` 里的库和 `data\` 里的库同时存在
/// 且内容不同（一个是 23:08、一个是 21:33），用户根本分不清哪个算数，
/// 下次换位置又会把旧的盖到新的上面。
///
/// 目标位置原有的数据项会被**先清掉**：源是用户当前正在用的那份，它才是
/// 准的；把两份混在一起会得到一堆没人认识的重复笔记和孤儿图片。
///
/// **调用方必须先关掉数据库**（不然 SQLite 还开着文件，复制出来的是半截）。
///
/// 只搬 [kDataEntryNames] 里列出的数据项，不搬程序（`app.so`、
/// `flutter_assets` 属于安装目录本身），也不碰同目录下的其它文件。
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
    for (final name in kDataEntryNamesWalFirst) {
      final path = p.join(source.path, name);
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.notFound) continue;
      // 目标就在源里面（或反过来）时跳过自己，否则会无限复制
      if (p.equals(path, target.path)) continue;
      if (p.isWithin(path, target.path)) continue;
      if (p.isWithin(target.path, path)) continue;
      entries.add(type == FileSystemEntityType.directory
          ? Directory(path)
          : File(path));
    }
  }

  // 目标里原有的同名数据项先清掉：不能让新数据落到旧文件旁边混着用。
  // 只清数据项，目标目录里别的文件（用户自己放的东西）一律不动。
  for (final e in entries) {
    final name = p.basename(e.path);
    final stale = p.join(target.path, name);
    if (FileSystemEntity.typeSync(stale) == FileSystemEntityType.notFound) {
      continue;
    }
    try {
      if (FileSystemEntity.isDirectorySync(stale)) {
        Directory(stale).deleteSync(recursive: true);
      } else {
        File(stale).deleteSync();
      }
    } catch (_) {
      // 删不掉就让后面的 copy 去报错，这里不吞成"看起来成功了"
      rethrow;
    }
  }

  var done = 0;
  var files = 0;
  var bytes = 0;
  final total = entries.length;
  try {
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
  } catch (_) {
    // 拷到一半断了（磁盘满、U 盘拔了）：把目标里刚落下的半截清掉，
    // **源一个字节都不动** —— 宁可这次搬不成，也不能让用户两头都是坏的。
    for (final e in entries) {
      final stale = p.join(target.path, p.basename(e.path));
      try {
        if (FileSystemEntity.isDirectorySync(stale)) {
          Directory(stale).deleteSync(recursive: true);
        } else if (FileSystemEntity.isFileSync(stale)) {
          File(stale).deleteSync();
        }
      } catch (_) {
        // 清理尽力而为
      }
    }
    rethrow;
  }

  // 数据已经完整落到新位置，把源位置的那几项删掉 —— 「搬」不是「复制」。
  // 只删数据项，源目录本身和里面别的东西留着，用户不会一觉醒来发现
  // `F:\` 被清空。删失败也只影响源目录里多留一份，不影响新位置可用。
  for (final e in entries) {
    try {
      if (e is Directory) {
        if (e.existsSync()) e.deleteSync(recursive: true);
      } else if (e is File) {
        if (e.existsSync()) e.deleteSync();
      }
    } catch (_) {
      // 有文件被别的进程占着（比如正在看视频）：留着，下次再清
    }
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
