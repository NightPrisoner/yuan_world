/// 导入页：选择 .docx / .txt 文件或整个文件夹，批量入库。
///
/// 导入是耗时操作（最大单文件 160MB），因此：
/// - 解析在独立 isolate 里跑（见 ImportService）
/// - 界面显示逐文件进度，而不是一个转圈
/// - 支持中途取消
library;

import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../core/motion/app_motion.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_menu.dart';
import '../../data/importer/import_service.dart';

class ImportPage extends StatefulWidget {
  const ImportPage({super.key});

  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  List<File> _pending = <File>[];
  bool _running = false;
  bool _cancelRequested = false;

  int _done = 0;
  int _total = 0;
  String _current = '';
  ImportStage _stage = ImportStage.reading;
  ImportSummary? _summary;

  /// 从文件夹导入时记住文件夹名，用它当文集名。
  /// 单个选文件时为 null，那时才退回文档内部的「文集：xxx」。
  String? _folderName;

  /// 导入的根目录。有它才能按**相对路径**还原子文件夹的嵌套关系 ——
  /// 只记文件夹名的话，`文集/小小说/a.docx` 和 `文集/杂谈/b.docx`
  /// 会被压进同一个平文集。
  String? _folderRoot;

  /// 是否正有文件悬停在页面上。
  bool _dragging = false;

  Future<void> _pickFiles() async {
    // 一定要 try/catch：文件选择器在无权限、对话框被系统打断、
    // 或选到了不支持的东西时会直接抛异常。不接住的话按钮看上去
    // 就是"点了没反应"，用户只会以为功能坏了。
    List<PlatformFile> res;
    try {
      res = await FilePicker.pickFiles(
        dialogTitle: '选择要导入的文档（.docx / .txt）',
        type: FileType.custom,
        allowedExtensions: <String>['docx', 'txt'],
      );
    } catch (e) {
      _toast('打开文件选择器失败：$e');
      return;
    }
    if (!mounted || res.isEmpty) return;

    final files = res
        .where((f) => f.path != null)
        .map((f) => File(f.path!))
        .toList();
    if (files.isEmpty) {
      _toast('选中的文件没有可用的路径');
      return;
    }
    setState(() {
      _pending = files;
      // 单个选文件时**清掉**文件夹名，否则上一次导入文件夹的名字会
      // 一直粘着，把后面选的文件也塞进那个文集
      _folderName = null;
      _folderRoot = null;
      _summary = null;
    });
  }

  Future<void> _pickFolder() async {
    String? dir;
    try {
      dir = await FilePicker.getDirectoryPath(dialogTitle: '选择文集文件夹');
    } catch (e) {
      _toast('打开文件夹选择器失败：$e');
      return;
    }
    if (!mounted || dir == null) return;

    final files = ImportService.collectDocx(dir);
    if (files.isEmpty) {
      _toast('该文件夹下没有找到 .docx / .txt 文件');
      return;
    }
    setState(() {
      _pending = files;
      // 记住文件夹名：导入时用它建文集，这样文章才会出现在
      // 和文件夹同名的那一项下面
      _folderName = p.basename(dir!);
      _folderRoot = dir;
      _summary = null;
    });
  }

  Future<void> _start() async {
    if (_pending.isEmpty) return;
    final state = context.read<AppState>();

    setState(() {
      _running = true;
      _cancelRequested = false;
      _done = 0;
      _total = _pending.length;
      _summary = null;
    });

    ImportSummary summary;
    try {
      summary = await state.importer.importDocx(
        _pending,
        // 文件夹导入：以文件夹名为文集名
        collectionName: _folderName,
        // 有根目录时按相对路径还原嵌套结构
        rootDir: _folderRoot,
        onProgress: (stage, done, total, label) {
          if (!mounted) return;
          setState(() {
            _stage = stage;
            _done = done;
            _total = total;
            _current = label;
          });
        },
      );
    } catch (e) {
      // 不接住的话 _running 会永远停在 true，界面卡在进度条上，
      // 看上去就是"导入坏了而且退不出来"
      if (!mounted) return;
      setState(() => _running = false);
      _toast('导入失败：$e');
      return;
    }

    if (!mounted) return;
    setState(() {
      _running = false;
      _summary = summary;
      _pending = <File>[];
    });
    await state.refresh();
    if (!mounted) return;

    // **一篇都没进来时要说清原因。**
    // 最常见的其实是"这些文件之前导入过"，被幂等判断跳过了。
    // 只报一句"成功 0 篇"用户会以为功能坏了。
    if (summary.imported == 0 && summary.moved == 0 && summary.skipped > 0) {
      _toast('这些文件之前已经导入过了（跳过 ${summary.skipped} 篇），没有重复添加');
      return;
    }
    _toast(summary.report);
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 4)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final wide = MediaQuery.sizeOf(context).width >= 700;

    // **整页都是拖放区**。
    //
    // 之前只在两个按钮卡片那一小块上挂了 DropTarget，用户把文件拖到
    // 页面别的地方（介绍文字上、空白处）就毫无反应 —— 看上去就是
    // "拖入功能坏了"。而且导入过程中那段代码会把 DropTarget 整个
    // 从树里拿掉，期间也拖不了。
    return DropTarget(
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: _onDrop,
      child: Scaffold(
        backgroundColor: c.groupedBackground,
        appBar: AppBar(
          backgroundColor: c.groupedBackground,
          surfaceTintColor: Colors.transparent,
          leading: IconButton(
            icon: const Icon(Icons.close_rounded, size: 20),
            onPressed: _running ? null : () => Navigator.of(context).maybePop(),
          ),
          title:
              Text('导入文集', style: AppText.headline.copyWith(color: c.label)),
          centerTitle: true,
        ),
        body: Stack(
          children: [
            Center(
              child: ConstrainedBox(
                constraints:
                    BoxConstraints(maxWidth: wide ? 620 : double.infinity),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                  physics: const BouncingScrollPhysics(),
                  children: [
                    _buildIntro(c),
                    const SizedBox(height: 18),
                    if (_running) _buildProgress(c) else ...[
                      _buildPickers(c),
                      if (_pending.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        _buildPendingList(c),
                        const SizedBox(height: 16),
                        _buildStartButton(c),
                      ],
                      if (_summary != null) ...[
                        const SizedBox(height: 16),
                        _buildSummary(c, _summary!),
                      ],
                    ],
                  ],
                ),
              ),
            ),
            // 拖拽时的整页蒙层：不遮住内容，只给一个明确的"松手就导入"
            if (_dragging) _dropOverlay(c),
          ],
        ),
      ),
    );
  }

  /// 拖动悬停时盖一层提示。**不吃事件**（IgnorePointer），
  /// 否则鼠标一进入蒙层，DropTarget 反而收不到后续的拖拽消息。
  Widget _dropOverlay(AppColors c) => Positioned.fill(
    child: IgnorePointer(
      child: Container(
        color: c.tint.withValues(alpha: 0.08),
        alignment: Alignment.center,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 20),
          decoration: BoxDecoration(
            color: c.secondaryBackground,
            borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
            border: Border.all(color: c.tint, width: 2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.download_rounded, size: 34, color: c.tint),
              const SizedBox(height: 10),
              Text(
                '松开即可导入',
                style: AppText.callout.copyWith(
                  color: c.tint,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '支持 .docx / .txt，文件夹会递归导入',
                style: AppText.caption1.copyWith(color: c.tertiaryLabel),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _buildIntro(AppColors c) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: c.secondaryBackground,
        borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 17, color: c.tint),
              const SizedBox(width: 8),
              Text(
                '会保留哪些信息',
                style: AppText.headline.copyWith(color: c.label),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '自动识别文档头部的「作者 / 发布时间 / 文集 / 来源」并归入对应分类，'
            '正文与内嵌图片一并导入。重复导入会自动跳过，不会产生副本。',
            style: AppText.footnote.copyWith(color: c.secondaryLabel, height: 1.7),
          ),
        ],
      ),
    );
  }

  Widget _buildPickers(AppColors c) {
    // 这里**不再挂 DropTarget** —— 整页已经在最外层接住了。
    // 嵌套两个 DropTarget 会让内层把外层的拖拽消息吃掉，
    // 拖到卡片外面就又没反应了。
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _PickCard(
                icon: Icons.folder_open_rounded,
                title: '选择文件夹',
                subtitle: '递归导入整个文集目录',
                onTap: _pickFolder,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _PickCard(
                icon: Icons.description_outlined,
                title: '选择文件',
                subtitle: '手动挑选若干 .docx / .txt',
                onTap: _pickFiles,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        // 「拖到页面任意位置」是**桌面专有**的说法：手机上文件不会从系统
        // 外面拖进来，写着只会让人白试一次。判断沿用全应用那一套
        // （`prefersAnchoredMenu` = 桌面/指针设备）。
        if (prefersAnchoredMenu(context))
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.download_rounded,
                size: 15,
                color: _dragging ? c.tint : c.tertiaryLabel,
              ),
              const SizedBox(width: 6),
              Text(
                _dragging ? '松开即可导入' : '也可以直接把文件或文件夹拖到页面任意位置',
                style: AppText.footnote.copyWith(
                  color: _dragging ? c.tint : c.tertiaryLabel,
                  fontWeight: _dragging ? FontWeight.w600 : null,
                ),
              ),
            ],
          ),
      ],
    );
  }

  /// 处理拖入的文件和文件夹。
  ///
  /// 文件夹会**递归**收集里面的 .docx/.txt —— 拖一个文集目录进来
  /// 和点「选择文件夹」是同一件事，用户不该被迫分两步。
  void _onDrop(DropDoneDetails details) {
    setState(() => _dragging = false);

    final files = <File>[];
    final rejected = <String>[];
    String? folder;
    String? folderRoot;

    for (final path in details.files.map((f) => f.path)) {
      final entity = FileSystemEntity.typeSync(path);

      if (entity == FileSystemEntityType.directory) {
        final found = ImportService.collectDocx(path);
        if (found.isEmpty) {
          rejected.add(p.basename(path));
        } else {
          files.addAll(found);
          // 只拖了一个文件夹时，用它当文集名 + 层级根
          folder ??= p.basename(path);
          folderRoot ??= path;
        }
        continue;
      }

      final lower = path.toLowerCase();
      if (lower.endsWith('.docx') || lower.endsWith('.txt')) {
        files.add(File(path));
      } else {
        rejected.add(p.basename(path));
      }
    }

    if (files.isEmpty) {
      _toast(
        rejected.isEmpty
            ? '没有找到可以导入的文件'
            : '不支持的文件：${rejected.take(3).join('、')}',
      );
      return;
    }

    setState(() {
      _pending = files;
      // 多个文件夹一起拖时不当作文集（分不清该用哪个名字）
      _folderName = folder;
      _folderRoot = folderRoot;
      _summary = null;
    });

    if (rejected.isNotEmpty) {
      _toast(
        '已选中 ${files.length} 个文件，跳过 ${rejected.length} 个不支持的',
      );
    }
  }

  Widget _buildPendingList(AppColors c) {
    final totalMb = _pending.fold<int>(0, (s, f) => s + f.lengthSync()) / 1024 / 1024;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.secondaryBackground,
        borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '待导入 ${_pending.length} 个文件',
                  style: AppText.headline.copyWith(color: c.label),
                ),
              ),
              Text(
                '${totalMb.toStringAsFixed(1)} MB',
                style: AppText.footnote.copyWith(color: c.tertiaryLabel),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _pending.length,
              itemBuilder: (context, i) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: [
                    Icon(Icons.article_outlined, size: 14, color: c.tertiaryLabel),
                    const SizedBox(width: 7),
                    Expanded(
                      child: Text(
                        _pending[i].uri.pathSegments.last,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.footnote.copyWith(color: c.secondaryLabel),
                      ),
                    ),
                    Text(
                      '${(_pending[i].lengthSync() / 1024 / 1024).toStringAsFixed(1)}M',
                      style: AppText.caption2.copyWith(color: c.quaternaryLabel),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStartButton(AppColors c) {
    return Pressable(
      onTap: _start,
      child: Container(
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: c.tint,
          borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
        ),
        child: Text(
          '开始导入',
          style: AppText.headline.copyWith(color: Colors.white),
        ),
      ),
    );
  }

  Widget _buildProgress(AppColors c) {
    final ratio = _total == 0 ? 0.0 : _done / _total;
    final stageText = switch (_stage) {
      ImportStage.reading => '读取文件',
      ImportStage.parsing => '解析文档',
      ImportStage.saving => '写入数据库与图片',
      ImportStage.done => '完成',
    };

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: c.secondaryBackground,
        borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('正在导入', style: AppText.headline.copyWith(color: c.label)),
          const SizedBox(height: 4),
          Text(
            '$stageText · $_done / $_total',
            style: AppText.footnote.copyWith(color: c.secondaryLabel),
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: ratio),
              duration: AppMotion.fast,
              curve: AppMotion.enter,
              builder: (context, v, _) => LinearProgressIndicator(
                value: v,
                minHeight: 6,
                backgroundColor: c.fill,
                valueColor: AlwaysStoppedAnimation<Color>(c.tint),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _current,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption1.copyWith(color: c.tertiaryLabel),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(() => _cancelRequested = true),
              child: Text(
                _cancelRequested ? '将在当前文件后停止…' : '取消导入',
                style: AppText.footnote.copyWith(color: c.destructive),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummary(AppColors c, ImportSummary s) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: c.tint.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
        border: Border.all(color: c.tint.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.check_circle_rounded, size: 18, color: c.palette[1]),
              const SizedBox(width: 8),
              Text('导入完成', style: AppText.headline.copyWith(color: c.label)),
            ],
          ),
          const SizedBox(height: 8),
          Text(s.report, style: AppText.callout.copyWith(color: c.label)),
          if (s.skipped > 0) ...[
            const SizedBox(height: 6),
            Text(
              '跳过的是已存在的同名或同来源文档',
              style: AppText.caption1.copyWith(color: c.tertiaryLabel),
            ),
          ],
          if (s.errors.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('失败详情', style: AppText.footnote.copyWith(color: c.destructive)),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 140),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final e in s.errors.take(20))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(
                          e,
                          style: AppText.caption2.copyWith(color: c.secondaryLabel),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PickCard extends StatelessWidget {
  const _PickCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Pressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 22, horizontal: 14),
        decoration: BoxDecoration(
          color: c.secondaryBackground,
          borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
          border: Border.all(color: c.separator, width: 0.5),
        ),
        child: Column(
          children: [
            Icon(icon, size: 26, color: c.tint),
            const SizedBox(height: 10),
            Text(title, style: AppText.callout.copyWith(color: c.label)),
            const SizedBox(height: 4),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: AppText.caption1.copyWith(color: c.tertiaryLabel),
            ),
          ],
        ),
      ),
    );
  }
}
