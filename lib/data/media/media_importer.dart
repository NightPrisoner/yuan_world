/// 把本地媒体（图片 / 动图 / 视频）收进笔记自己的目录。
///
/// **必须复制进来，不能只记一个外部路径。** 用户选的图可能在桌面、
/// 在 U 盘、在下载文件夹里，过几天被删掉或者挪走，笔记里的图就全断了。
/// 收进 `data/images/<noteId>/` 之后，整个 data 目录拷走就是完整备份。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// 能插进正文的媒体类型。
enum MediaKind {
  image('图片', '插入图片', 'image'),
  video('视频', '插入视频', 'video');

  const MediaKind(this.label, this.actionLabel, this.folder);

  final String label;
  final String actionLabel;
  final String folder;
}

class MediaImporter {
  const MediaImporter._();

  /// 图片和动图允许的扩展名。
  static const Set<String> imageExts = <String>{
    'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'heic', 'avif',
  };

  /// 视频允许的扩展名。
  static const Set<String> videoExts = <String>{
    'mp4', 'mov', 'm4v', 'webm', 'mkv', 'avi', 'wmv', 'flv', '3gp',
  };

  /// 这个路径是不是视频。渲染时靠它决定画成图还是画成播放卡片。
  static bool isVideoPath(String path) =>
      videoExts.contains(extensionOf(path));

  /// 同上，别名 —— 统计逻辑里读起来更顺。
  static bool isVideo(String path) => isVideoPath(path);

  static bool isImagePath(String path) =>
      imageExts.contains(extensionOf(path));

  static String extensionOf(String path) =>
      p.extension(path).toLowerCase().replaceFirst('.', '');

  /// 这个路径能不能直接进笔记正文（图片或视频）。
  static bool isMediaPath(String path) =>
      isImagePath(path) || isVideoPath(path);

  /// 把一批拖进来的路径分成"能插入正文的媒体"和"其它的"。
  ///
  /// 抽成纯函数是为了能直接测：拖入这条路径没有别的入口可以验证
  /// （系统拖拽事件在测试里造不出来），所以"认不认这个文件"这件事
  /// 必须能单独测。
  static ({List<String> media, List<String> others}) splitMediaPaths(
    Iterable<String> paths,
  ) {
    final media = <String>[];
    final others = <String>[];
    for (final path in paths) {
      if (path.isEmpty) continue;
      // 文件夹在笔记里放不了，归到"其它"
      if (FileSystemEntity.typeSync(path) == FileSystemEntityType.directory) {
        others.add(path);
      } else if (isMediaPath(path)) {
        media.add(path);
      } else {
        others.add(path);
      }
    }
    return (media: media, others: others);
  }

  /// 把 [source] 复制进 `<imageRoot>/<noteId>/`，返回**相对 imageRoot 的路径**。
  ///
  /// 返回值就是正文里 `![](…)` 要写的东西。
  static String import({
    required File source,
    required int noteId,
    required String imageRoot,
  }) {
    final dir = Directory(p.join(imageRoot, '$noteId'));
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final name = _uniqueName(dir, source);
    source.copySync(p.join(dir.path, name));
    return '$noteId/$name';
  }

  /// 生成一个不会撞名的文件名。
  ///
  /// 保留原文件名（用户认得出来），撞了才加序号 ——
  /// 全都改成时间戳的话，图片目录会变成一堆看不懂的数字。
  static String _uniqueName(Directory dir, File source) {
    final raw = p.basename(source.path);
    final ext = p.extension(raw);
    var base = p.basenameWithoutExtension(raw);
    // 文件名里的路径分隔符和奇怪字符清掉，避免生成非法路径
    base = base.replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), '_').trim();
    if (base.isEmpty) base = 'media';
    if (base.runes.length > 50) {
      base = String.fromCharCodes(base.runes.take(50));
    }

    var candidate = '$base$ext';
    var n = 2;
    while (File(p.join(dir.path, candidate)).existsSync()) {
      candidate = '$base-$n$ext';
      n++;
    }
    return candidate;
  }
}
