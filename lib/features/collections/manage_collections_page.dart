/// 文件夹（文集）管理页。
///
/// 三栏布局里可以直接在左栏增删改；手机上没有左栏，
/// 所以单独给一个整页入口（从「设置」进）。
///
/// 支持：新建 / 重命名 / 改颜色 / 拖拽排序 / 删除。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../core/motion/app_motion.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models.dart';
import '../notes/widgets/note_actions.dart';
import 'collection_sheets.dart';

class ManageCollectionsPage extends StatelessWidget {
  const ManageCollectionsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = context.colors;
    final list = state.collections;

    return Scaffold(
      backgroundColor: c.groupedBackground,
      appBar: AppBar(
        backgroundColor: c.groupedBackground,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 19),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text('文件夹管理', style: AppText.headline.copyWith(color: c.label)),
        actions: [
          IconButton(
            tooltip: '新建文件夹',
            icon: Icon(Icons.add_rounded, color: c.tint),
            onPressed: () => showCollectionEditor(context),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: list.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.folder_off_outlined,
                        size: 38, color: c.quaternaryLabel),
                    const SizedBox(height: 14),
                    Text(
                      '还没有文件夹',
                      style: AppText.callout.copyWith(color: c.secondaryLabel),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '点右上角 + 新建一个，\n然后就能把笔记归进去了',
                      textAlign: TextAlign.center,
                      style: AppText.footnote.copyWith(
                        color: c.tertiaryLabel,
                        height: 1.6,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Pressable(
                      onTap: () => showCollectionEditor(context),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 11),
                        decoration: BoxDecoration(
                          color: c.tint,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '新建文件夹',
                          style: AppText.callout.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 40),
              physics: const BouncingScrollPhysics(),
              itemCount: list.length,
              // onReorderItem 的 newIndex 已经处理过"移除后下标偏移"
              onReorderItem: (oldIndex, newIndex) {
                final ordered = List<Collection>.from(list);
                final item = ordered.removeAt(oldIndex);
                ordered.insert(newIndex, item);
                state.reorderCollections(ordered);
              },
              itemBuilder: (context, i) {
                final col = list[i];
                return _CollectionTile(
                  key: ValueKey<int>(col.id),
                  col: col,
                  index: i,
                  onEdit: () => showCollectionEditor(context, existing: col),
                  // 导出整个文集：**手机上唯一的入口**。
                  // 桌面是在文件夹上点右键，手机没有右键，所以放在这一页
                  // （设置 → 文件夹管理，两端都进得来）。
                  onExport: () => exportCollection(context, col),
                  onDelete: () => _confirmDelete(context, state, col),
                );
              },
            ),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    AppState state,
    Collection col,
  ) async {
    final c = context.colors;
    final n = col.noteCount;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${col.name}」？'),
        content: Text(
          n == 0
              ? '文件夹会移入回收站，之后仍可恢复。'
              : '文件夹连同里面的 $n 篇笔记一起移入回收站，之后仍可恢复。',
          style: AppText.callout.copyWith(color: c.secondaryLabel, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: c.destructive),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await state.deleteCollection(col.id);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          n == 0
              ? '已把「${col.name}」移入回收站'
              : '已把「${col.name}」和 $n 篇笔记移入回收站',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }
}

class _CollectionTile extends StatelessWidget {
  const _CollectionTile({
    super.key,
    required this.col,
    required this.index,
    required this.onEdit,
    required this.onDelete,
    this.onExport,
  });

  final Collection col;
  final int index;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  /// 导出整个文集。给 null 就不显示这个按钮（别的地方复用这一行时用得上）。
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Dismissible(
        key: ValueKey<String>('dismiss-${col.id}'),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          decoration: BoxDecoration(
            color: c.destructive,
            borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
          ),
          child: const Icon(Icons.delete_outline_rounded,
              color: Colors.white, size: 20),
        ),
        confirmDismiss: (_) async {
          onDelete();
          return false; // 交给确认框处理，Dismissible 自己不动
        },
        child: Container(
          decoration: BoxDecoration(
            color: c.secondaryBackground,
            borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
            border: Border.all(
              color: c.isDark
                  ? c.separator.withValues(alpha: 0.4)
                  : const Color(0x0F000000),
              width: 0.5,
            ),
          ),
          child: ReorderableDelayedDragStartListener(
            index: index,
            child: Pressable(
              onTap: onEdit,
              scale: 0.99,
              opacity: 0.7,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 13, 10, 13),
                child: Row(
                  children: [
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: Color(col.color).withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(Icons.folder_rounded,
                          size: 17, color: Color(col.color)),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            col.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.callout.copyWith(color: c.label),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${col.noteCount} 篇笔记',
                            style:
                                AppText.caption1.copyWith(color: c.tertiaryLabel),
                          ),
                        ],
                      ),
                    ),
                    if (onExport != null)
                      Pressable(
                        onTap: onExport,
                        scale: 0.9,
                        child: Tooltip(
                          message: '导出为压缩包',
                          child: Padding(
                            padding: const EdgeInsets.all(6),
                            child: Icon(
                              Icons.download_rounded,
                              size: 18,
                              color: c.tint,
                            ),
                          ),
                        ),
                      ),
                    Icon(Icons.drag_indicator_rounded,
                        size: 18, color: c.quaternaryLabel),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
