/// 头图选择器。
///
/// 三条路：
///   1. 从**正文已有的图片**里挑一张（大多数时候用户想要的就是这个）
///   2. 从**本地文件**传一张进来（会拷进这篇笔记的图片目录）
///   3. **移除头图**，回到「默认取正文第一张图」
///
/// 做成一个面板而不是独立页面：选封面是个轻量动作，
/// 跳走一整页再回来，用户会忘了自己在干什么。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../app_state.dart';
import '../../../core/motion/app_motion.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/local_image.dart';
import '../../../data/media/media_importer.dart';
import '../../../data/models.dart';
import '../editor/body_segments.dart';

/// 弹出头图选择器。返回 true 表示有改动。
///
/// 用对话框而不是底部面板：桌面上从屏幕底下升起来的面板
/// 既不符合习惯，也会盖住正在看的内容。
Future<bool> showCoverPicker(BuildContext context, Note note) async {
  final changed = await showDialog<bool>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: ctx.colors.secondaryBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: _CoverPicker(note: note),
      ),
    ),
  );
  return changed ?? false;
}

class _CoverPicker extends StatefulWidget {
  const _CoverPicker({required this.note});
  final Note note;

  @override
  State<_CoverPicker> createState() => _CoverPickerState();
}

class _CoverPickerState extends State<_CoverPicker> {
  List<String> _images = const <String>[];
  String? _current;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final note = widget.note;
    // 正文里的图片就是候选：用同一套分段逻辑，保证和编辑器里看到的一致。
    //
    // **视频必须排除**：正文里视频和图片用的是同一套 `![](路径)` 语法，
    // 但 `Image.file` 打开一个 mp4 会失败，界面上就是一张灰图 ——
    // 用户看到"不存在的图"，其实那是一段视频。
    _images = splitBodySegments(note.content)
        .whereType<ImageSegment>()
        .map((s) => s.path)
        .where((path) => !MediaImporter.isVideoPath(path))
        // 文件真的存在才算候选，否则同样是灰图
        .where((path) => File(p.join(imageRootOf(context), path)).existsSync())
        .toSet()
        .toList();
    _current = note.coverImage;
  }

  String imageRootOf(BuildContext context) =>
      context.read<AppState>().db.imageRoot.path;

  /// 设置头图。[rel] 空串 = 恢复默认（按正文第一张图自动派生），
  /// [kCoverNone] = 明确不要头图。
  void _pick(String rel) {
    final state = context.read<AppState>();
    state.repo.updateNote(id: widget.note.id, coverImage: rel);
    state.refreshListOnly();
    Navigator.pop(context, true);
  }

  /// 从本地传一张进来，拷到这篇笔记的图片目录下再设为头图。
  Future<void> _upload() async {
    final state = context.read<AppState>();
    // file_picker 12.x：静态方法，返回 List<PlatformFile>（不是 FilePickerResult）
    final picked = await FilePicker.pickFile(
      dialogTitle: '选择一张图片作为头图',
      type: FileType.image,
    );
    final path = picked?.path;
    if (path == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final root = state.db.imageRoot.path;
      final dir = Directory(p.join(root, '${widget.note.id}'));
      if (!dir.existsSync()) dir.createSync(recursive: true);

      // 用时间戳命名，避免和已有的同名文件撞上
      final ext = p.extension(path).isEmpty ? '.png' : p.extension(path);
      final fileName = 'cover_${DateTime.now().millisecondsSinceEpoch}$ext';
      File(path).copySync(p.join(dir.path, fileName));

      final rel = '${widget.note.id}/$fileName';
      state.repo.updateNote(id: widget.note.id, coverImage: rel);
      state.refreshListOnly();
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('上传失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final root = context.read<AppState>().db.imageRoot.path;

    return SafeArea(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text('选择头图', style: AppText.headline.copyWith(color: c.label)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                _images.isEmpty
                    ? '正文里还没有图片，可以从本地传一张'
                    : '点一张图设为本篇头图',
                style: AppText.caption1.copyWith(color: c.tertiaryLabel),
              ),
            ),

            if (_images.isNotEmpty)
              Flexible(
                child: GridView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  shrinkWrap: true,
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 1.2,
                  ),
                  itemCount: _images.length,
                  itemBuilder: (context, i) => _thumb(c, root, _images[i]),
                ),
              ),

            const SizedBox(height: 12),
            Divider(height: 1, color: c.separator),
            _action(
              c,
              icon: Icons.upload_file_rounded,
              label: _busy ? '正在上传…' : '从本地选择图片',
              onTap: _busy ? null : _upload,
            ),
            // ── 三种状态各给一个明确的入口，别让一句话兼两件事 ──
            //
            // 以前只有一个「移除头图（回到默认：正文第一张图）」，可它做的
            // 其实是"彻底不要头图"（写空串），文字和行为对不上：用户想
            // "恢复成自动取第一张图"会点它，结果是头图没了。
            // 而且空串还会被自动派生逻辑当成"没设过"给补回来 ——
            // 编辑一下正文头图就自己回来了。
            if (!isCoverDisabled(_current))
              _action(
                c,
                icon: Icons.block_rounded,
                label: '不设置头图',
                onTap: () => _pick(kCoverNone),
              ),
            if (_current != null && _current!.isNotEmpty)
              _action(
                c,
                icon: Icons.restart_alt_rounded,
                label: '恢复默认（用正文第一张图）',
                onTap: () => _pick(''),
              ),
            const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }

  Widget _thumb(AppColors c, String root, String rel) {
    final selected = _current == rel;
    return Pressable(
      onTap: () => _pick(rel),
      scale: 0.96,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
          border: Border.all(
            color: selected ? c.tint : Colors.transparent,
            width: 2,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            LocalImage(
              path: p.join(root, rel),
              fit: BoxFit.cover,
              fallbackColor: c.fill,
              errorBuilder: (_) => ColoredBox(
                color: c.fill,
                child: Icon(Icons.broken_image_outlined,
                    size: 20, color: c.quaternaryLabel),
              ),
            ),
            if (selected)
              Positioned(
                right: 4,
                top: 4,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: c.tint,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.check_rounded,
                      size: 12, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _action(
    AppColors c, {
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
  }) =>
      Pressable(
        onTap: onTap,
        scale: 0.99,
        opacity: 0.6,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          child: Row(
            children: [
              Icon(icon, size: 18, color: onTap == null ? c.quaternaryLabel : c.label),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: AppText.callout.copyWith(
                    color: onTap == null ? c.quaternaryLabel : c.label,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}
