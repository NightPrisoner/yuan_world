/// 文件夹（文集）管理页。
///
/// 三栏布局里可以直接在左栏增删改；手机上没有左栏，
/// 所以单独给一个整页入口（从「设置」进）。
///
/// 支持：新建 / 重命名 / 改颜色 / 拖拽排序 / 删除。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../core/motion/app_motion.dart';
import '../../core/motion/folder_tree_motion.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_menu.dart';
import '../../data/models.dart';
import '../../data/repositories/note_repository.dart';
import '../notes/widgets/note_actions.dart';
import 'collection_sheets.dart';

class ManageCollectionsPage extends StatefulWidget {
  const ManageCollectionsPage({super.key});

  @override
  State<ManageCollectionsPage> createState() => _ManageCollectionsPageState();
}

class _ManageCollectionsPageState extends State<ManageCollectionsPage> {
  final FolderTreeMotion _folderMotion = FolderTreeMotion();
  Set<int> get _collapsed => _folderMotion.collapsed;
  Set<int> get _collapsing => _folderMotion.collapsing;
  Map<int, int> get _revealOrder => _folderMotion.revealOrder;

  @override
  void initState() {
    super.initState();
    _folderMotion.addListener(_onFolderMotion);
  }

  void _onFolderMotion() {
    if (mounted) setState(() {});
  }

  List<int> _descendantsInOrder(int rootId, List<Collection> all) {
    final byParent = <int?, List<Collection>>{};
    for (final c in all) {
      (byParent[c.parentId] ??= <Collection>[]).add(c);
    }
    final out = <int>[];
    void walk(int parentId, int depth) {
      if (depth > 8) return;
      for (final c in byParent[parentId] ?? const <Collection>[]) {
        out.add(c.id);
        walk(c.id, depth + 1);
      }
    }

    walk(rootId, 0);
    return out;
  }

  Set<int> _collapsingRows(List<Collection> all) {
    if (_collapsing.isEmpty) return const <int>{};
    final rows = <int>{};
    for (final id in _collapsing) {
      rows.addAll(_descendantsInOrder(id, all));
    }
    return rows;
  }

  /// 当前可见的深度优先树。收起中的父项仍然保留子树，交给行动画收起。
  List<(Collection, int)> _visibleTree(List<Collection> all) {
    final out = <(Collection, int)>[];
    final hidden = <int>{};
    for (final entry in _treeOrdered(all)) {
      final col = entry.$1;
      if (col.parentId != null && hidden.contains(col.parentId)) {
        hidden.add(col.id);
        continue;
      }
      out.add(entry);
      if (_collapsed.contains(col.id) && !_collapsing.contains(col.id)) {
        hidden.add(col.id);
      }
    }
    return out;
  }

  void _toggleFolderCollapsed(Collection col, List<Collection> all) {
    _folderMotion.toggle(
      col.id,
      _descendantsInOrder(col.id, all),
      reduceMotion: AppMotion.reduceMotion(context),
    );
  }

  void _reorderVisible(
    AppState state,
    List<(Collection, int)> visible,
    int oldIndex,
    int newIndex,
  ) {
    final moved = visible.map((e) => e.$1).toList();
    final item = moved.removeAt(oldIndex);
    moved.insert(newIndex.clamp(0, moved.length), item);

    // 收起状态下不可见的文件夹也要保留在排序结果里，不能因为拖拽一个
    // 可见项就把隐藏子树的相对顺序重置掉。
    final visibleIds = visible.map((e) => e.$1.id).toSet();
    final all = _treeOrdered(state.collections).map((e) => e.$1).toList();
    var cursor = 0;
    for (var i = 0; i < all.length; i++) {
      if (visibleIds.contains(all[i].id)) all[i] = moved[cursor++];
    }
    state.reorderCollections(all);
  }

  @override
  void dispose() {
    _folderMotion.removeListener(_onFolderMotion);
    _folderMotion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = context.colors;
    final list = state.collections;
    // 按**父子层级**排成一棵扁平的树（父在前、子紧随其后，带深度）。
    //
    // 原来这一页是平铺的：嵌套关系在库里有、桌面左栏也能看出来，
    // 到了手机上就全乱了 —— 子文件夹和父文件夹长得一模一样、位置也看不出
    // 归属（用户报的"文件夹也要和 Windows 一样支持嵌套"）。
    final tree = _visibleTree(list);
    final collapsingRows = _collapsingRows(list);

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
                    Icon(
                      Icons.folder_off_outlined,
                      size: 38,
                      color: c.quaternaryLabel,
                    ),
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
                          horizontal: 20,
                          vertical: 11,
                        ),
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
              itemCount: tree.length,
              // 拖动时保留阴影，但代理本身必须是透明材质：
              // 默认代理会再画一块不透明 Material，手机上就像卡片外又套了一层白框。
              proxyDecorator: (child, index, animation) => AnimatedBuilder(
                animation: animation,
                builder: (context, child) {
                  final t = Curves.easeInOut.transform(animation.value);
                  return Material(
                    type: MaterialType.transparency,
                    elevation: 6 * t,
                    shadowColor: Colors.black54,
                    child: child,
                  );
                },
                child: child,
              ),
              // onReorderItem 的 newIndex 已经处理过"移除后下标偏移"
              onReorderItem: (oldIndex, newIndex) =>
                  _reorderVisible(state, tree, oldIndex, newIndex),
              itemBuilder: (context, i) {
                final (col, depth) = tree[i];
                return FolderTreeReveal(
                  key: ValueKey<int>(col.id),
                  order: _revealOrder[col.id],
                  exiting: collapsingRows.contains(col.id),
                  child: _CollectionTile(
                    col: col,
                    index: i,
                    depth: depth,
                    hasChildren: list.any((x) => x.parentId == col.id),
                    collapsed:
                        _collapsed.contains(col.id) ||
                        _collapsing.contains(col.id),
                    onToggleCollapse: () => _toggleFolderCollapsed(col, list),
                    pinned: col.isPinned,
                    onEdit: () => showCollectionEditor(context, existing: col),
                    onMenu: (anchorContext) =>
                        _showCollectionMenu(anchorContext, state, col),
                    // 导出整个文集：**手机上唯一的入口**。
                    // 桌面是在文件夹上点右键，手机没有右键，所以放在这一页。
                    onExport: () => exportCollection(context, col),
                    onDelete: () => _confirmDelete(context, state, col),
                  ),
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
          n == 0 ? '文件夹会移入回收站，之后仍可恢复。' : '文件夹连同里面的 $n 篇笔记一起移入回收站，之后仍可恢复。',
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
          n == 0 ? '已把「${col.name}」移入回收站' : '已把「${col.name}」和 $n 篇笔记移入回收站',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// 手机没有桌面端的右键菜单，文件夹行上的「⋯」承载同一套操作。
  /// 菜单动作直接调用和桌面左栏相同的仓库 API，避免两端行为逐渐分叉。
  Future<void> _showCollectionMenu(
    BuildContext anchorContext,
    AppState state,
    Collection col,
  ) async {
    final action = await showAppMenu<String>(
      context,
      anchor: AppMenuAnchor(context: anchorContext),
      header: col.name,
      items: <AppMenuItem<String>>[
        AppMenuItem(
          value: 'pin',
          label: col.isPinned ? '取消置顶' : '置顶',
          icon: col.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
        ),
        const AppMenuItem(
          value: 'sub',
          label: '新建子文件夹',
          icon: Icons.create_new_folder_outlined,
        ),
        const AppMenuItem(
          value: 'top',
          label: '移到顶层',
          icon: Icons.vertical_align_top_rounded,
        ),
        const AppMenuItem(
          value: 'rename',
          label: '重命名 / 改颜色',
          icon: Icons.drive_file_rename_outline,
        ),
        const AppMenuItem(
          value: 'export',
          label: '导出为压缩包',
          icon: Icons.folder_zip_outlined,
        ),
        const AppMenuItem(
          value: 'hide',
          label: '移入隐私空间',
          icon: Icons.visibility_off_outlined,
        ),
        const AppMenuItem(
          value: 'delete',
          label: '删除文件夹',
          icon: Icons.delete_outline_rounded,
          destructive: true,
        ),
      ],
    );

    if (action == null || !mounted) return;
    switch (action) {
      case 'pin':
        state.repo.setCollectionPinned(col.id, !col.isPinned);
        await state.refresh();
        _toast(col.isPinned ? '已取消置顶「${col.name}」' : '已置顶「${col.name}」');
      case 'sub':
        final created = await showCollectionEditor(context, parentId: col.id);
        if (created != null && mounted) await state.refresh();
      case 'top':
        state.repo.moveCollectionToTopLevel(col.id);
        await state.refresh();
        _toast('「${col.name}」已移到顶层');
      case 'rename':
        await showCollectionEditor(context, existing: col);
      case 'export':
        await exportCollection(context, col);
      case 'hide':
        state.repo.setCollectionHidden(col.id, true);
        await state.refresh();
        _toast('文件夹「${col.name}」已移入隐私空间');
      case 'delete':
        await _confirmDelete(context, state, col);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }
}

/// 把扁平列表排成"父在前、子紧随"的顺序，并带上深度。
///
/// 递归而不是排序：只按 `parentId` 排序是排不出层级的（同一父下的子要
/// 紧跟在父后面，而孙又要跟在子后面）。
List<(Collection, int)> _treeOrdered(List<Collection> all) {
  final byParent = <int?, List<Collection>>{};
  for (final c in all) {
    byParent.putIfAbsent(c.parentId, () => <Collection>[]).add(c);
  }
  final out = <(Collection, int)>[];
  void walk(int? parent, int depth) {
    for (final c in byParent[parent] ?? const <Collection>[]) {
      // 防环：真要被拖成环了也别让这里无限递归
      if (depth > 8) return;
      out.add((c, depth));
      walk(c.id, depth + 1);
    }
  }

  walk(null, 0);
  // 兜底：父级不在当前列表里的（数据异常）也得显示出来，否则"看不见就删不掉"
  final seen = out.map((e) => e.$1.id).toSet();
  for (final c in all) {
    if (!seen.contains(c.id)) out.add((c, 0));
  }
  return out;
}

class _CollectionTile extends StatelessWidget {
  const _CollectionTile({
    required this.col,
    required this.index,
    required this.onEdit,
    required this.onDelete,
    this.depth = 0,
    this.hasChildren = false,
    this.collapsed = false,
    this.onToggleCollapse,
    this.pinned = false,
    this.onMenu,
    this.onExport,
  });

  final Collection col;
  final int index;

  /// 嵌套深度（0 = 顶层）。子文件夹要缩进，一眼看出归属。
  final int depth;
  final bool hasChildren;
  final bool collapsed;
  final VoidCallback? onToggleCollapse;
  final bool pinned;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final void Function(BuildContext anchorContext)? onMenu;

  /// 导出整个文集。给 null 就不显示这个按钮（别的地方复用这一行时用得上）。
  final VoidCallback? onExport;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      // 子文件夹缩进 + 一层"树线"的感觉（左边一条浅竖线）
      padding: EdgeInsets.only(bottom: 8, left: depth * 18.0),
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
          child: const Icon(
            Icons.delete_outline_rounded,
            color: Colors.white,
            size: 20,
          ),
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
                    if (hasChildren)
                      _MobileCollapseToggle(
                        collapsed: collapsed,
                        color: c.tertiaryLabel,
                        onTap: onToggleCollapse,
                      )
                    else
                      const SizedBox(width: 22),
                    Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        color: Color(col.color).withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Icon(
                        Icons.folder_rounded,
                        size: 17,
                        color: Color(col.color),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  col.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppText.callout.copyWith(
                                    color: c.label,
                                  ),
                                ),
                              ),
                              if (pinned)
                                Padding(
                                  padding: const EdgeInsets.only(left: 4),
                                  child: Icon(
                                    Icons.push_pin_rounded,
                                    size: 12,
                                    color: c.tint,
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '${col.noteCount} 篇笔记',
                            style: AppText.caption1.copyWith(
                              color: c.tertiaryLabel,
                            ),
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
                    if (onMenu != null)
                      Builder(
                        builder: (anchorContext) => Pressable(
                          onTap: () => onMenu!(anchorContext),
                          scale: 0.9,
                          child: Tooltip(
                            message: '更多操作',
                            child: Padding(
                              padding: const EdgeInsets.all(6),
                              child: Icon(
                                Icons.more_horiz_rounded,
                                size: 18,
                                color: c.tertiaryLabel,
                              ),
                            ),
                          ),
                        ),
                      ),
                    Icon(
                      Icons.drag_indicator_rounded,
                      size: 18,
                      color: c.quaternaryLabel,
                    ),
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

/// 与桌面左栏相同的收起/展开控件：只占自己的小区域，点击不会触发整行编辑。
class _MobileCollapseToggle extends StatelessWidget {
  const _MobileCollapseToggle({
    required this.collapsed,
    required this.color,
    required this.onTap,
  });

  final bool collapsed;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 22,
        height: 30,
        child: SpringAnimatedValue(
          value: collapsed ? 0 : 0.25,
          spring: AppMotion.bouncy,
          builder: (context, v) => Transform.rotate(
            angle: v * 2 * math.pi,
            child: Icon(Icons.chevron_right_rounded, size: 18, color: color),
          ),
        ),
      ),
    );
  }
}
