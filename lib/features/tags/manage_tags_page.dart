/// 标签管理：改名 / 合并 / 换色 / 删除。
///
/// 标签在数据层一直有（`tags` + `note_tags`），但界面上从来没有过入口 ——
/// 既看不到、也改不了。这一页补上"管"的那一半，另外两个入口在
/// 阅读页标题栏的「标签」按钮和左栏的标签列表。
///
/// 三个动作里最容易做错的是**删除**：用户想要的多半是"这个标签不要了"，
/// 而不是"把这些笔记删掉"。所以删除只解绑，并且弹窗里明说这一点。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../core/motion/app_motion.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models.dart';

class ManageTagsPage extends StatelessWidget {
  const ManageTagsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final state = context.watch<AppState>();
    final tags = state.tags;

    return Scaffold(
      backgroundColor: c.groupedBackground,
      appBar: AppBar(
        backgroundColor: c.groupedBackground,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 19),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text('标签', style: AppText.headline.copyWith(color: c.label)),
      ),
      body: tags.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  '还没有标签。\n在笔记里点标题栏的「标签」按钮就能加。',
                  textAlign: TextAlign.center,
                  style: AppText.footnote
                      .copyWith(color: c.tertiaryLabel, height: 1.8),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 60),
              physics: const BouncingScrollPhysics(),
              children: [
                Text(
                  '改名成已有的标签就是**合并**：两边的笔记会并到一起。\n'
                  '删除标签只是把它从笔记上摘掉，笔记本身一篇都不会少。',
                  style: AppText.caption1
                      .copyWith(color: c.tertiaryLabel, height: 1.7),
                ),
                const SizedBox(height: 14),
                for (final t in tags) ...[
                  _TagRow(tag: t),
                  const SizedBox(height: 8),
                ],
              ],
            ),
    );
  }
}

class _TagRow extends StatelessWidget {
  const _TagRow({required this.tag});

  final TagStat tag;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.secondaryBackground,
        borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        children: [
          Pressable(
            onTap: () => _pickColor(context, tag),
            scale: 0.9,
            child: Tooltip(
              message: '换颜色',
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: Color(tag.color),
                  shape: BoxShape.circle,
                  border: Border.all(color: c.separator, width: 0.5),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Pressable(
              onTap: () => _rename(context, tag),
              scale: 0.99,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tag.name, style: AppText.body.copyWith(color: c.label)),
                  const SizedBox(height: 2),
                  Text(
                    '${tag.count} 篇笔记',
                    style: AppText.caption1.copyWith(color: c.tertiaryLabel),
                  ),
                ],
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.drive_file_rename_outline_rounded,
                size: 18, color: c.tertiaryLabel),
            tooltip: '重命名',
            onPressed: () => _rename(context, tag),
          ),
          IconButton(
            icon: Icon(Icons.delete_outline_rounded,
                size: 18, color: c.tertiaryLabel),
            tooltip: '删除标签',
            onPressed: () => _delete(context, tag),
          ),
        ],
      ),
    );
  }
}

/// 改名。新名字撞上已有标签时**不拦着**，而是把"会合并"讲清楚 ——
/// 合并正是整理标签时最常用的操作，藏起来反而要用户绕路。
Future<void> _rename(BuildContext context, TagStat tag) async {
  final state = context.read<AppState>();
  final others =
      state.tags.where((t) => t.id != tag.id).map((t) => t.name).toSet();

  final name = await showDialog<String>(
    context: context,
    builder: (_) => _RenameTagDialog(initial: tag.name, existing: others),
  );
  final trimmed = name?.trim() ?? '';
  if (trimmed.isEmpty || trimmed == tag.name) return;

  await state.renameTag(tag.id, trimmed);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('已重命名为「$trimmed」'),
      duration: const Duration(seconds: 2),
    ),
  );
}

/// 改名弹窗。
///
/// **必须是个独立的 StatefulWidget**（而不是 `showDialog` 里塞一个
/// StatefulBuilder + 外面拿一个 controller）：controller 得由弹窗自己持有，
/// 在它自己的 `dispose` 里释放。放在外面 `await showDialog` 之后立刻
/// dispose 的话，弹窗还在播关闭动画、里面的输入框还在重建 ——
/// 那个 controller 已经被释放了，直接抛 "used after being disposed"。
class _RenameTagDialog extends StatefulWidget {
  const _RenameTagDialog({required this.initial, required this.existing});

  final String initial;
  final Set<String> existing;

  @override
  State<_RenameTagDialog> createState() => _RenameTagDialogState();
}

class _RenameTagDialogState extends State<_RenameTagDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _mergeInto {
    final n = _controller.text.trim();
    if (n == widget.initial) return '';
    return widget.existing.contains(n) ? n : '';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final merge = _mergeInto;
    return AlertDialog(
      backgroundColor: c.secondaryBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
      ),
      title: Text('重命名标签', style: AppText.headline),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            onChanged: (_) => setState(() {}),
            onSubmitted: (v) => Navigator.of(context).pop(v),
            style: AppText.body.copyWith(color: c.label),
            decoration: const InputDecoration(hintText: '标签名'),
          ),
          if (merge.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                '已经有「$merge」了，这两组笔记会合并到一起。',
                style: AppText.caption1.copyWith(color: c.palette[2]),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('取消', style: AppText.body.copyWith(color: c.tertiaryLabel)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: Text(
            merge.isEmpty ? '保存' : '合并',
            style: AppText.body
                .copyWith(color: c.tint, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

Future<void> _delete(BuildContext context, TagStat tag) async {
  final state = context.read<AppState>();
  final c = context.colors;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dCtx) => AlertDialog(
      backgroundColor: c.secondaryBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
      ),
      title: Text('删除标签「${tag.name}」', style: AppText.headline),
      content: Text(
        // 说清楚"删的是什么" —— 这句话少了，用户不敢点
        '会把它从 ${tag.count} 篇笔记上摘掉，**笔记本身不会被删除**。',
        style: AppText.footnote.copyWith(color: c.secondaryLabel, height: 1.7),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dCtx).pop(false),
          child: Text('取消', style: AppText.body.copyWith(color: c.tertiaryLabel)),
        ),
        TextButton(
          onPressed: () => Navigator.of(dCtx).pop(true),
          child: Text(
            '删除',
            style: AppText.body
                .copyWith(color: c.destructive, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
  if (ok != true) return;
  await state.deleteTag(tag.id);
}

/// 换颜色。用调色板直接选，不弹取色器 —— 一共就十来种颜色，
/// 和多处使用的 `palette` 保持一致，深浅色主题下都不会难看。
Future<void> _pickColor(BuildContext context, TagStat tag) async {
  final state = context.read<AppState>();
  final c = context.colors;
  await showDialog<void>(
    context: context,
    builder: (dCtx) => AlertDialog(
      backgroundColor: c.secondaryBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
      ),
      title: Text('标签颜色', style: AppText.headline),
      content: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final color in c.palette)
            Pressable(
              onTap: () async {
                await state.setTagColor(tag.id, color.toARGB32());
                if (dCtx.mounted) Navigator.of(dCtx).pop();
              },
              scale: 0.9,
              child: Container(
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: color.toARGB32() == tag.color
                        ? c.label
                        : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dCtx).pop(),
          child: Text('关闭', style: AppText.body.copyWith(color: c.tint)),
        ),
      ],
    ),
  );
}
