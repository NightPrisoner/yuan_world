/// 中栏（列表 / 瀑布流）与右栏（阅读 / 编辑）的内容。
///
/// 三栏的**布局**（宽度补间、推入推出的动画）在 `desktop_workspace.dart`
/// 的 `_panes` 里；这里只放"每一栏里面装什么"。
///
/// 这里是 `desktop_workspace.dart` 的一部分（`part of`），理由见
/// workspace_actions.dart 的说明。
part of 'desktop_workspace.dart';

extension _WsPanes on _DesktopWorkspaceState {
  Widget _listPane(BuildContext context, AppState state, List<Note> notes) {
    final c = context.colors;
    final f = state.filter;

    final title = f.query.isNotEmpty
        ? '搜索结果'
        : f.favoritesOnly
            ? '收藏'
            : f.uncategorizedOnly
                ? '未分类'
                : f.collectionId != null
                    ? (state.collections
                            .where((x) => x.id == f.collectionId)
                            .firstOrNull
                            ?.name ??
                        '文集')
                    : '全部笔记';

    return Container(
      decoration: BoxDecoration(color: c.groupedBackground),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 18, 8, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: AppText.title3.copyWith(color: c.label),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // 新建笔记：做成醒目的实心按钮。
                // 它是这个页面最高频的动作，和旁边几个灰底小图标混在一起
                // 就没人找得到。
                Tooltip(
                  message: '新建笔记（Ctrl+N）',
                  child: Pressable(
                    onTap: () => _createNote(state),
                    scale: 0.92,
                    child: Container(
                      height: 34,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: c.tint,
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(
                            color: c.tint.withValues(alpha: 0.35),
                            blurRadius: 10,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add_rounded, size: 18, color: Colors.white),
                          SizedBox(width: 4),
                          Text(
                            '新建',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                // 列表 / 瀑布流 切换
                GlassIconButton(
                  icon: state.gridMode
                      ? Icons.view_list_rounded
                      : Icons.grid_view_rounded,
                  size: 28,
                  iconSize: 15,
                  tooltip: state.gridMode ? '列表视图' : '瀑布流视图',
                  onTap: () {
                    state.setGridMode(!state.gridMode);
                    if (!state.gridMode) return;
                    _ensureWidthForGrid();
                  },
                ),
                // 列数挪到设置里了，这里只留「列表 / 瀑布流」这一个切换
                _SortButton(state: state),
                const SizedBox(width: 4),
                // 进入多选：全选 / 反选 / 批量操作都在下面那条栏里
                GlassIconButton(
                  icon: _selecting
                      ? Icons.close_rounded
                      : Icons.checklist_rounded,
                  size: 28,
                  iconSize: 15,
                  tooltip: _selecting ? '退出多选' : '多选',
                  color: _selecting ? c.tint : null,
                  onTap: () => _setState(() {
                    _selecting = !_selecting;
                    if (!_selecting) _selected.clear();
                  }),
                ),
              ],
            ),
          ),
          if (_selecting) _selectionBar(context, state, notes),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
            child: Text(
              '共 ${notes.length} 篇 · ${f.sort.label}',
              style: AppText.caption1.copyWith(color: c.tertiaryLabel),
            ),
          ),

          // 搜索框
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Container(
              height: 34,
              decoration: BoxDecoration(
                color: c.fill,
                borderRadius: BorderRadius.circular(AppMetrics.radiusSm),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 9),
                  Icon(Icons.search_rounded, size: 16, color: c.tertiaryLabel),
                  const SizedBox(width: 6),
                  Expanded(
                    child: TextField(
                      controller: _search,
                      focusNode: _searchFocus,
                      onChanged: (v) {
                        state.setQuery(v);
                        _goSection(_Section.notes);
                      },
                      style: AppText.footnote.copyWith(color: c.label),
                      decoration: InputDecoration(
                        isDense: true,
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                        hintText: '搜索全部笔记',
                        hintStyle:
                            AppText.footnote.copyWith(color: c.tertiaryLabel),
                      ),
                    ),
                  ),
                  if (f.query.isNotEmpty)
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 28, minHeight: 28),
                      icon: Icon(Icons.cancel_rounded,
                          size: 15, color: c.tertiaryLabel),
                      onPressed: () {
                        _search.clear();
                        state.setQuery('');
                      },
                    ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),

          Expanded(
            child: notes.isEmpty
                ? Center(
                    child: Text(
                      f.query.isNotEmpty ? '没有匹配的笔记' : '这里还没有笔记',
                      style: AppText.footnote.copyWith(color: c.tertiaryLabel),
                    ),
                  )
                : state.gridMode
                    ? _gridView(context, notes)
                    : _listView(context, notes),
          ),
        ],
      ),
    );
  }

  Widget _listView(BuildContext context, List<Note> notes) {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      physics: const BouncingScrollPhysics(),
      itemCount: notes.length,
      itemBuilder: (context, i) => _DraggableItem(
        data: NoteDrag(notes[i]),
        label: notes[i].title.isEmpty ? '无标题笔记' : notes[i].title,
        icon: Icons.article_rounded,
        child: _NoteListRow(
          note: notes[i],
          // 显示的时间跟着当前排序字段走
          displayTime: context.read<AppState>().filter.sort.field.timeOf(notes[i]),
          selected: _selecting
              ? _selected.contains(notes[i].id)
              : notes[i].id == _selectedNoteId,
          onTap: () => _selecting
              ? _toggleSelect(notes[i].id)
              : _openNote(notes[i].id),
          onActions: (anchor) =>
              showNoteActions(context, notes[i], anchor: anchor),
        ),
      ),
    );
  }

  Widget _gridView(BuildContext context, List<Note> notes) {
    final imageRoot = context.read<AppState>().db.imageRoot.path;
    return MasonryGridView.count(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      physics: const BouncingScrollPhysics(),
      crossAxisCount: context.read<AppState>().gridColumns,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      itemCount: notes.length,
      itemBuilder: (context, i) => _DraggableItem(
        data: NoteDrag(notes[i]),
        label: notes[i].title.isEmpty ? '无标题笔记' : notes[i].title,
        icon: Icons.article_rounded,
        child: _NoteGridCard(
          note: notes[i],
          imageRoot: imageRoot,
          // 显示的时间跟着当前排序字段走
          displayTime: context.read<AppState>().filter.sort.field.timeOf(notes[i]),
          selected: _selecting
              ? _selected.contains(notes[i].id)
              : notes[i].id == _selectedNoteId,
          onTap: () => _selecting
              ? _toggleSelect(notes[i].id)
              : _openNote(notes[i].id),
          onActions: (anchor) =>
              showNoteActions(context, notes[i], anchor: anchor),
        ),
      ),
    );
  }

  Widget _detailPane(
    BuildContext context,
    AppState state, {
    bool fullscreen = false,
  }) {
    final c = context.colors;
    final id = _selectedNoteId;

    if (id == null) {
      return Container(
        color: c.background,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.article_outlined, size: 38, color: c.quaternaryLabel),
              const SizedBox(height: 14),
              Text(
                '从左侧选一篇笔记',
                style: AppText.callout.copyWith(color: c.tertiaryLabel),
              ),
            ],
          ),
        ),
      );
    }

    if (_editing) {
      // 注意：全屏与分栏两种状态走的是同一棵子树（同样的 Container + key），
      // 这样切换全屏时编辑器 State 会被复用，不会重建、不会丢未保存的内容。
      return Container(
        color: c.background,
        child: NoteEditorPage(
          key: ValueKey<String>('edit-$id'),
          noteId: id,
          embedded: true,
          fullscreen: fullscreen,
          // 「占满页面」：只收起三栏，**不碰窗口**
          onToggleFullscreen: () =>
              _setState(() => _editorFullscreen = !_editorFullscreen),
          // ⛶ 无边框窗口全屏：只放大窗口，**不动版式**
          windowFullscreen: _windowFullscreen,
          onToggleWindowFullscreen: () {
            _setState(() => _windowFullscreen = !_windowFullscreen);
            setAppFullscreen(_windowFullscreen);
          },
          onClose: () {
            _exitAllFullscreen();
            _setState(() => _editing = false);
          },
        ),
      );
    }

    return Container(
      color: c.background,
      child: NoteDetailPage(
        key: ValueKey<String>('read-$id'),
        noteId: id,
        embedded: true,
        // 阅读时也能"占满页面" —— 注意它**不动窗口**，
        // 窗口全屏是编辑器里那个 ⛶ 按钮的事
        fullscreen: fullscreen,
        onToggleFullscreen: () =>
            _setState(() => _editorFullscreen = !_editorFullscreen),
        onToggleWindowFullscreen: () {
          _setState(() => _windowFullscreen = !_windowFullscreen);
          setAppFullscreen(_windowFullscreen);
        },
        windowFullscreen: _windowFullscreen,
        onRequestEdit: () => _setState(() => _editing = true),
        onClose: () {
          _exitAllFullscreen();
          _closeDetail();
        },
      ),
    );
  }
}
