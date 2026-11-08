import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/motion/app_motion.dart';
import '../../core/motion/apple_page_route.dart';
import '../../core/theme/app_theme.dart';

/// 一个只列目录的文件浏览器，用来在手机上选「要导入的文件夹」。
///
/// 为什么不用系统 SAF（`ACTION_OPEN_DOCUMENT_TREE`）：
///
/// 1. Android 11+ 的 SAF 本身就有限制 —— `Android/` 里的东西干脆不显示，
///    外部存储根目录也不让选；
/// 2. MIUI 把 `com.android.fileexplorer` 的 provider 塞进 DocumentsUI，
///    它不按 AOSP 约定响应 `buildChildDocumentsUriUsingTree` 的 query，
///    递归到第二层就返回空游标 —— 表现成「多层结构没继承」；
/// 3. 每次 query 子目录都可能弹一次授权框，用户看到的是"一闪一闪"。
///
/// 这个应用已经申请了「所有文件访问」（只从 GitHub 分发，不上架商店），
/// 那就干脆直接读文件系统 —— 上面三条全都不存在，而且不用把文件拷到缓存
/// 再导入，选中哪个目录就直接从那儿读。
class DirectoryPickerPage extends StatefulWidget {
  const DirectoryPickerPage({
    super.key,
    this.startPath,
    this.title = '选择文件夹',
  });

  /// 从哪个目录开始。为空就从外部存储根目录起。
  final String? startPath;
  final String title;

  @override
  State<DirectoryPickerPage> createState() => _DirectoryPickerPageState();
}

class _DirectoryPickerPageState extends State<DirectoryPickerPage> {
  late Directory _current;
  List<Directory> _children = const <Directory>[];
  List<File> _files = const <File>[];
  String? _error;

  @override
  void initState() {
    super.initState();
    final start = widget.startPath;
    _current = Directory(
      (start != null && start.trim().isNotEmpty)
          ? start.trim()
          : _defaultRoot().path,
    );
    _load();
  }

  /// 从外部存储根目录起。取不到就退回应用文档目录。
  Directory _defaultRoot() {
    final candidates = <String>[
      '/storage/emulated/0',
      '/sdcard',
    ];
    for (final path in candidates) {
      final dir = Directory(path);
      if (dir.existsSync()) return dir;
    }
    return Directory.systemTemp;
  }

  void _load() {
    final dirs = <Directory>[];
    final files = <File>[];
    String? error;
    try {
      for (final entity in _current.listSync(followLinks: false)) {
        final name = p.basename(entity.path);
        // 系统藏起来的那些，列出来只会让人误选。
        if (name == 'Android' || name.startsWith('.')) continue;
        if (entity is Directory) {
          dirs.add(entity);
        } else if (entity is File) {
          files.add(entity);
        }
      }
      dirs.sort(
        (a, b) => p.basename(a.path).toLowerCase().compareTo(
              p.basename(b.path).toLowerCase(),
            ),
      );
      files.sort(
        (a, b) => p.basename(a.path).toLowerCase().compareTo(
              p.basename(b.path).toLowerCase(),
            ),
      );
    } on FileSystemException catch (e) {
      error = e.message;
    }
    setState(() {
      _children = dirs;
      _files = files;
      _error = error;
    });
  }

  bool get _canGoUp {
    final parent = _current.parent;
    return parent.path != _current.path && parent.existsSync();
  }

  void _enter(Directory dir) {
    setState(() {
      _current = dir;
      _error = null;
    });
    _load();
  }

  void _goUp() {
    if (!_canGoUp) return;
    _enter(_current.parent);
  }

  void _choose() {
    // 至少要能读到，否则导进去也是空列表。
    try {
      if (_current.listSync().isEmpty) {
        // 空目录也可能是"要建的文集"，放行 —— 交给导入页去说"没有文档"。
      }
    } catch (_) {
      // 读不了就不让选
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('这个文件夹读不了，换一个试试')),
      );
      return;
    }
    Navigator.of(context).pop(_current.path);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final name = p.basename(_current.path).isEmpty
        ? _current.path
        : p.basename(_current.path);

    return Scaffold(
      backgroundColor: c.groupedBackground,
      appBar: AppBar(
        backgroundColor: c.groupedBackground,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text(widget.title, style: AppText.headline),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, size: 20),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton(
            onPressed: _choose,
            child: const Text('选这个'),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            _pathBar(c, name),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Text(
                  '读不了这个目录：$_error',
                  style: AppText.caption1.copyWith(color: c.destructive),
                ),
              ),
            Expanded(
              child: (_children.isEmpty && _files.isEmpty)
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          '这个文件夹是空的。\n如果就是这里，点右上角「选这个」。',
                          textAlign: TextAlign.center,
                          style: AppText.callout
                              .copyWith(color: c.tertiaryLabel, height: 1.7),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                      physics: const BouncingScrollPhysics(),
                      itemCount: _children.length + _files.length,
                      itemBuilder: (context, i) {
                        // 文件夹排前面，文件跟后面 —— 选目录时最常干的事
                        // 是"往里走"，文件只是让你看见这儿已经有什么。
                        if (i < _children.length) {
                          return _dirTile(c, _children[i]);
                        }
                        return _fileTile(c, _files[i - _children.length]);
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pathBar(AppColors c, String name) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: c.fill,
          borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
        ),
        child: Row(
          children: [
            Pressable(
              scale: 0.94,
              onTap: _canGoUp ? _goUp : null,
              child: Padding(
                padding: const EdgeInsets.only(right: 10),
                child: Icon(
                  Icons.arrow_upward_rounded,
                  size: 18,
                  color: _canGoUp ? c.tint : c.quaternaryLabel,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.callout.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _current.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.caption2.copyWith(color: c.tertiaryLabel),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
  /// 一行子文件夹：点进去。
  Widget _dirTile(AppColors c, Directory dir) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Pressable(
        scale: 0.99,
        onTap: () => _enter(dir),
        child: Container(
          padding: const EdgeInsets.fromLTRB(13, 13, 13, 13),
          decoration: BoxDecoration(
            color: c.secondaryBackground,
            borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
          ),
          child: Row(
            children: [
              Icon(
                Icons.folder_rounded,
                size: 19,
                color: c.functionalPalette[3],
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Text(
                  p.basename(dir.path),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.callout,
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: c.tertiaryLabel,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 一行文件：**只用来给你看见这儿已经有什么**，点不进、也选不中。
  ///
  /// 选文件夹的界面列文件，唯一的用处是让你在按下「选这个」之前
  /// 知道会不会和已有文件撞名 —— 所以右边顺带把大小写出来，
  /// 一眼能认出「这就是上次导出的那份」。
  Widget _fileTile(AppColors c, File file) {
    int? bytes;
    try {
      bytes = file.lengthSync();
    } catch (_) {
      bytes = null;
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
        decoration: BoxDecoration(
          color: c.secondaryBackground.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
        ),
        child: Row(
          children: [
            Icon(
              _iconOf(file.path),
              size: 18,
              color: c.tertiaryLabel,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Text(
                p.basename(file.path),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.callout.copyWith(color: c.secondaryLabel),
              ),
            ),
            if (bytes != null) ...[
              const SizedBox(width: 8),
              Text(
                _sizeText(bytes),
                style: AppText.caption2.copyWith(color: c.quaternaryLabel),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 文件图标按扩展名挑一个，认不出就用通用文档图标。
  IconData _iconOf(String path) {
    switch (p.extension(path).toLowerCase()) {
      case '.docx':
      case '.doc':
        return Icons.description_rounded;
      case '.txt':
      case '.md':
      case '.markdown':
        return Icons.notes_rounded;
      case '.pdf':
        return Icons.picture_as_pdf_rounded;
      case '.zip':
        return Icons.folder_zip_rounded;
      case '.png':
      case '.jpg':
      case '.jpeg':
      case '.gif':
      case '.webp':
      case '.heic':
        return Icons.image_rounded;
      case '.mp4':
      case '.mov':
      case '.mkv':
      case '.webm':
      case '.avi':
        return Icons.videocam_rounded;
      default:
        return Icons.insert_drive_file_rounded;
    }
  }

  /// 文件大小，只留一位小数。
  String _sizeText(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// 打开目录选择器，返回用户选中的路径（取消返回 null）。
Future<String?> pickDirectoryManually(
  BuildContext context, {
  String? startPath,
  String title = '选择文件夹',
}) {
  return Navigator.of(context).push<String>(
    ApplePageRoute<String>(
      fullscreenDialog: true,
      pageBuilder: (_) => DirectoryPickerPage(
        startPath: startPath,
        title: title,
      ),
    ),
  );
}
