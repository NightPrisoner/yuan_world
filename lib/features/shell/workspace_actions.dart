/// 多选 / 批量操作 / 导出 / 提示。
///
/// 这里是 `desktop_workspace.dart` 的一部分（`part of`）：这些方法本来就是
/// `_DesktopWorkspaceState` 的私有方法，拆出来只是**为了让单个文件别太长**
/// —— 之前一个文件 2000 多行，改一处要在里面翻半天。`part` 不引入新的
/// 抽象层，调用关系也不变（同一个 library，私有成员照样可见）。
part of 'desktop_workspace.dart';

extension _WsActions on _DesktopWorkspaceState {
  /// 多选模式下的一条操作栏：计数 + 全选 / 反选 / 批量操作。
  Widget _selectionBar(BuildContext context, AppState state, List<Note> notes) {
    final c = context.colors;
    final ids = notes.map((n) => n.id).toSet();

    Widget btn(String label, VoidCallback? onTap) => Pressable(
      onTap: onTap,
      scale: 0.95,
      haptic: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        child: Text(
          label,
          style: AppText.caption1.copyWith(
            color: onTap == null ? c.quaternaryLabel : c.tint,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 8, 6),
      child: Row(
        children: [
          Text(
            '已选 ${_selected.length} 项',
            style: AppText.caption1.copyWith(
              color: _selected.isEmpty ? c.tertiaryLabel : c.tint,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          btn(
            '全选',
            () => _setState(() {
              _selected
                ..clear()
                ..addAll(ids);
            }),
          ),
          btn(
            '反选',
            () => _setState(() {
              final next = ids.difference(_selected);
              _selected
                ..clear()
                ..addAll(next);
            }),
          ),
          btn(
            '批量操作',
            _selected.isEmpty ? null : () => _batchMenu(state, notes),
          ),
        ],
      ),
    );
  }

  void _toggleSelect(int id) => _setState(() {
    if (!_selected.remove(id)) _selected.add(id);
  });

  Future<void> _batchMenu(AppState state, List<Note> notes) async {
    final ids = _selected.toList();
    final picked = await showAppMenu<String>(
      context,
      header: '已选 ${ids.length} 篇',
      items: <AppMenuItem<String>>[
        const AppMenuItem(
          value: 'move',
          label: '移动到文集',
          icon: Icons.drive_file_move_outline,
        ),
        const AppMenuItem(
          value: 'export',
          label: '导出为压缩包',
          icon: Icons.download_rounded,
        ),
        const AppMenuItem(
          value: 'archive',
          label: '归档',
          icon: Icons.archive_outlined,
        ),
        AppMenuItem(
          value: 'hide',
          label: state.privacyMode ? '移出隐私空间' : '移入隐私空间',
          icon: state.privacyMode
              ? Icons.visibility_outlined
              : Icons.visibility_off_outlined,
        ),
        const AppMenuItem(
          value: 'delete',
          label: '删除',
          icon: Icons.delete_outline_rounded,
          destructive: true,
        ),
      ],
    );
    if (picked == null || !mounted) return;

    switch (picked) {
      case 'move':
        final target = await _pickCollection(state);
        if (target == null) return;
        state.repo.moveNotesToCollection(ids, target.value);
        await state.refresh();
      case 'export':
        await _exportNotes(ids);
      case 'archive':
        state.repo.setNotesArchived(ids, true);
        await state.refresh();
        _toast('已归档 ${ids.length} 篇');
      case 'hide':
        state.repo.setNotesHidden(ids, !state.privacyMode);
        await state.refresh();
        _toast(state.privacyMode ? '已移出隐私空间' : '已移入隐私空间');
      case 'delete':
        final ok = await _confirmBatchDelete(ids.length);
        if (!ok) return;
        // 走 state.trashNotes：它会连回收站计数一起刷新，
        // 否则左栏那个"回收站 N 篇"删完还是旧数字
        await state.trashNotes(ids);
    }
    if (mounted) _setState(() => _selected.clear());
  }

  /// 选一个文集。返回 null 表示取消；用 `_MoveTarget(null)` 表示"未分类"。
  Future<_MoveTarget?> _pickCollection(AppState state) async {
    final picked = await showAppMenu<String>(
      context,
      header: '移动到',
      items: <AppMenuItem<String>>[
        const AppMenuItem(
          value: 'none',
          label: '未分类',
          icon: Icons.inbox_rounded,
        ),
        for (final col in state.collections)
          AppMenuItem(
            value: '${col.id}',
            label: col.name,
            icon: Icons.folder_rounded,
            color: Color(col.color),
          ),
      ],
    );
    if (picked == null) return null;
    return _MoveTarget(picked == 'none' ? null : int.tryParse(picked));
  }

  /// 导出整个文集（含子文件夹）为压缩包。
  ///
  /// 逻辑在 [exportCollection] 里（note_actions.dart）—— 手机上也能进
  /// 「文件夹管理」页导出，两端共用一份，免得选项/包内结构走偏。
  Future<void> _exportCollection(Collection col) =>
      exportCollection(context, col);

  Future<void> _exportNotes(List<int> ids) async {
    final format = await pickExportFormat(context, header: '导出格式');
    if (format == null || !mounted) return;

    final state = context.read<AppState>();
    final notes = state.repo.notesForExport(ids: ids);
    if (notes.isEmpty) return;

    // **批量导出打包成一个 zip**，而不是往文件夹里撒一堆散文件。
    // 包内按文集层级放，解压出来和左栏看到的目录结构一致。
    await exportZip(
      context,
      items: <({List<String> path, Note note})>[
        for (final n in notes)
          (path: collectionPathOf(n, state.collections), note: n),
      ],
      format: format,
      zipName: '元世界导出 ${notes.length} 篇.zip',
    );
  }

  Future<bool> _confirmBatchDelete(int count) async {
    final c = context.colors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除这 $count 篇笔记？'),
        content: Text(
          // **别写"删除后无法恢复"**：这里是软删除，内容先进回收站，
          // 之后随时能捞回来。吓唬用户的话，他们会因为怕丢数据而不敢整理。
          '会先放进回收站，之后随时能恢复。',
          style: AppText.callout.copyWith(color: c.secondaryLabel),
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
    return ok ?? false;
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }
}
