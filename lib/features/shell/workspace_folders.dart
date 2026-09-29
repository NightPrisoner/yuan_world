/// 文件夹：行的渲染、拖拽排序/嵌套、右键菜单、删除确认。
///
/// 单独一组是因为这块的交互最密（拖到哪、能不能嵌套、松手之后落到哪），
/// 和"左栏长什么样"混在一起时很难看清。
///
/// 这里是 `desktop_workspace.dart` 的一部分（`part of`），理由见
/// workspace_actions.dart 的说明。
part of 'desktop_workspace.dart';

extension _WsFolders on _DesktopWorkspaceState {
  /// 左栏里的一个文件夹行。
  ///
  /// 抽成方法是因为它现在要拿到 `rowCtx`（收起按钮的点击会 setState），
  /// 内联在 ListView 的 children 里写会非常难读。
  Widget _collectionRow(
    BuildContext context,
    AppState state,
    Collection col,
    int depth,
    int? selectedId, {
    required bool hasKids,
    bool exiting = false,
  }) {
    final collapsed = _collapsed.contains(col.id);
    // 小三角要**立刻**翻过来：真等到动画播完再翻，点下去像没反应
    final showsCollapsed = collapsed || _collapsing.contains(col.id);
    return _TreeReveal(
      // 每一行的动画状态跟着自己的文件夹 id 走：列表会在动画期间增删行，
      // 不挂 key 的话 element 顺位复用会把"别人播到 0 的状态"塞给这一行。
      key: ValueKey<int>(col.id),
      order: _revealOrder[col.id],
      exiting: exiting,
      child: _DropZone(
        indent: true,
        depth: depth,
        // 笔记拖进来 = 归入这个文件夹
        onNote: (note) async {
          await state.moveNoteToCollection(note.id, col.id);
        },
        // 文件夹拖过来：按落点位置决定排序还是嵌套
        onCollectionDrop: (dragged, spot) =>
            _dropCollectionAt(context, state, dragged, col, spot),
        child: _DraggableItem(
          data: CollectionDrag(col),
          label: col.name,
          icon: Icons.folder_rounded,
          accent: Color(col.color),
          child: _NavRow(
            icon: depth > 0
                ? Icons.subdirectory_arrow_right_rounded
                : Icons.folder_rounded,
            label: col.name,
            color: Color(col.color),
            count: col.noteCount,
            indent: true,
            depth: depth,
            pinned: col.isPinned,
            hasChildren: hasKids,
            collapsed: showsCollapsed,
            onToggleCollapse: hasKids
                ? () => _toggleFolderCollapsed(col, state.collections)
                : null,
            selected: _section == _Section.notes && selectedId == col.id,
            onTap: () {
              state.selectCollection(col.id);
              _goSection(_Section.notes);
            },
            onMenu: (anchor) =>
                _showCollectionMenu(context, col, anchor: anchor),
          ),
        ),
      ),
    );
  }

  /// 把扁平列表还原成"深度优先"的顺序，附带层级。
  ///
  /// 左栏要的是缩进后的树，但数据层只给一个扁平列表 ——
  /// 在这里拼一次，比在每层递归里写一遍布局简单得多。
  List<(int, Collection, int)> _flattenTree(List<Collection> all) {
    final byParent = <int?, List<Collection>>{};
    for (final c in all) {
      (byParent[c.parentId] ??= <Collection>[]).add(c);
    }

    final out = <(int, Collection, int)>[];
    var seq = 0;

    void walk(int? parentId, int depth) {
      // 深度上限兜底：数据万一成环也不能把左栏渲染卡死
      if (depth > 8) return;
      for (final c in byParent[parentId] ?? const <Collection>[]) {
        out.add((seq++, c, depth));
        // 收起来的节点不再往下走（**正在收起**的还要留着，让它滑出去）
        if (!_collapsed.contains(c.id) || _collapsing.contains(c.id)) {
          walk(c.id, depth + 1);
        }
      }
    }

    walk(null, 0);
    return out;
  }

  /// 把一个文件夹拖到另一个文件夹上。
  ///
  /// 落点在行的上/下边缘 → 同级排序；落在中间 → 变成它的子文件夹。
  /// 这就是「既能改顺序、又能改层级」的实现方式。
  Future<void> _dropCollectionAt(
    BuildContext context,
    AppState state,
    Collection dragged,
    Collection target,
    DropSpot spot,
  ) async {
    if (dragged.id == target.id) return;

    final asChild = spot == DropSpot.into;
    final before = _flattenTree(state.collections);
    final beforeIndex = before.indexWhere((e) => e.$2.id == dragged.id);
    final beforeParent = dragged.parentId;

    state.repo.moveCollection(
      dragged.id,
      target.id,
      asChild: asChild,
      after: spot == DropSpot.after,
    );
    await state.refresh();
    if (!context.mounted) return;

    // 失败判定：层级没变、位置也没动 —— 多半是"挂到自己后代里"被拒了
    final after = _flattenTree(state.collections);
    final afterIndex = after.indexWhere((e) => e.$2.id == dragged.id);
    final stillSameParent =
        state.collections.firstWhere((c) => c.id == dragged.id).parentId ==
        beforeParent;

    if (asChild && stillSameParent && beforeIndex == afterIndex) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('不能把文件夹移进它自己的子文件夹'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    final msg = asChild
        ? '「${dragged.name}」已移入「${target.name}」'
        : spot == DropSpot.before
        ? '「${dragged.name}」已移到「${target.name}」前面'
        : '「${dragged.name}」已移到「${target.name}」后面';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  /// 拖到文件夹列表最下面的区域 → 直接升到顶层末尾。
  Future<void> _dropToTopLevel(
    BuildContext context,
    AppState state,
    Collection dragged,
  ) async {
    state.repo.moveCollectionToTopLevel(dragged.id);
    await state.refresh();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('「${dragged.name}」已移到顶层'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> _showCollectionMenu(
    BuildContext context,
    Collection col, {
    AppMenuAnchor? anchor,
  }) async {
    final state = context.read<AppState>();
    final action = await showAppMenu<String>(
      context,
      anchor: anchor,
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

    if (action == null || !context.mounted) return;
    switch (action) {
      case 'pin':
        state.repo.setCollectionPinned(col.id, !col.isPinned);
        await state.refresh();
      case 'rename':
        await showCollectionEditor(context, existing: col);
      case 'export':
        await _exportCollection(col);
      case 'sub':
        final created = await showCollectionEditor(context, parentId: col.id);
        if (created != null) await state.refresh();
      case 'top':
        state.repo.moveCollectionToTopLevel(col.id);
        await state.refresh();
      case 'hide':
        state.repo.setCollectionHidden(col.id, true);
        await state.refresh();
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('文件夹「${col.name}」已移入隐私空间'),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      default:
        await _confirmDeleteCollection(context, col);
    }
  }

  Future<void> _confirmDeleteCollection(
    BuildContext context,
    Collection col,
  ) async {
    final state = context.read<AppState>();
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
}
