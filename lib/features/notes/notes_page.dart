/// 笔记列表页。整个应用的主界面。
///
/// 布局参考小米笔记：
///   顶部大标题 + 搜索 → 文集/筛选胶囊条 → 笔记卡片流 → 悬浮新建按钮
///
/// 交互按 Apple 的观感打磨：
///   - 大标题随滚动连续缩小并位移（不是突然切换）
///   - 列表使用 BouncingScrollPhysics，到边界有回弹
///   - 卡片进入用错峰淡入，滚动时不掉帧
///   - 长按卡片弹出操作面板（置顶/收藏/归档/删除）
library;

import 'package:flutter/material.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../core/motion/app_motion.dart';
import '../../core/motion/apple_page_route.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_menu.dart';
import '../../core/widgets/app_refresh.dart';
import '../../data/models.dart';
import '../../data/repositories/note_repository.dart';
import '../collections/collection_sheets.dart';
import '../importer/import_page.dart';
import 'editor/note_editor_page.dart';
import '../search/search_page.dart';
import 'note_detail_page.dart';
import 'widgets/note_actions.dart';
import 'widgets/note_card.dart';

class NotesPage extends StatefulWidget {
  const NotesPage({super.key});

  @override
  State<NotesPage> createState() => _NotesPageState();
}

/// 新建一篇空笔记并直接进编辑器。
///
/// 抽成顶层函数是因为**手机端的快捷键**（Ctrl+N）也要走同一条路：
/// 两处各写一遍的话，改一处忘一处，就会变成"快捷键建出来的笔记
/// 和 FAB 建出来的不一样"。
Future<void> createAndOpenNote(BuildContext context) async {
  final state = context.read<AppState>();
  // 提前取好 navigator：跨 await 之后再用 context 会被 lint 拦（也确实容易出错）
  final navigator = Navigator.of(context);
  final id = state.createNote();
  await state.refresh();
  if (!context.mounted) return;
  // 新建出来的是空笔记，直接进编辑器 —— 跳阅读页什么也看不到
  await navigator.push(
    ApplePageRoute<void>(pageBuilder: (_) => NoteEditorPage(noteId: id)),
  );
  if (context.mounted) state.refreshListOnly();
}

class _NotesPageState extends State<NotesPage> {
  final ScrollController _scroll = ScrollController();

  /// 0 = 大标题完全展开，1 = 完全收起。
  /// 用 ValueNotifier 而不是 setState，避免滚动时重建整个列表。
  final ValueNotifier<double> _collapse = ValueNotifier<double>(0);

  static const double _expandedHeight = 112;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final max = _expandedHeight - kToolbarHeight;
    final t = (_scroll.offset / max).clamp(0.0, 1.0);
    if ((t - _collapse.value).abs() > 0.004) _collapse.value = t;
  }

  // ── 多选（桌面有的，手机也得有） ──────────────────────────────────────
  //
  // 桌面多选是"工具条 + 批量操作菜单"，手机上照搬那一套：进多选后点卡片
  // 是勾选而不是打开，底部长出一条操作栏（全选 / 反选 / 批量操作 / 取消）。
  //
  // 入口放在右上角的列表菜单里（那里本来就是"对列表做什么"的地方），
  // 而不是长按：**长按已经给了单篇的操作菜单**（置顶/归档/删除…），
  // 再抢过去会让人以为长按坏了。
  bool _selecting = false;
  final Set<int> _selected = <int>{};

  void _enterSelection([int? first]) {
    setState(() {
      _selecting = true;
      _selected.clear();
      if (first != null) _selected.add(first);
    });
  }

  void _exitSelection() {
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  void _toggleSelect(int id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  /// 批量操作。和桌面的那份**能力一致**：移动 / 导出压缩包 / 归档 /
  /// 移入隐私空间 / 删除。
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
        final target = await _pickMoveTarget(state);
        if (target == null) return;
        state.repo.moveNotesToCollection(ids, target);
        await state.refresh();
      case 'export':
        await _exportSelected(state, ids);
      case 'archive':
        state.repo.setNotesArchived(ids, true);
        await state.refresh();
      case 'hide':
        state.repo.setNotesHidden(ids, !state.privacyMode);
        await state.refresh();
      case 'delete':
        final ok = await _confirmBatchDelete(ids.length);
        if (ok != true) return;
        await state.trashNotes(ids);
    }
    if (mounted) _exitSelection();
  }

  /// 批量导出成一个 zip。和桌面那份**同一套逻辑**（走 notesForExport
  /// 把正文一起取出来，包内按文集层级放）。
  Future<void> _exportSelected(AppState state, List<int> ids) async {
    final format = await pickExportFormat(context, header: '导出格式');
    if (format == null || !mounted) return;
    final notes = state.repo.notesForExport(ids: ids);
    if (notes.isEmpty) return;
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

  /// 选一个目标文集（null = 移出到「未分类」）。
  Future<int?> _pickMoveTarget(AppState state) async {
    // 用 -1 代表"未分类"：`showAppMenu` 的 value 是 int?，
    // null 会和"用户取消"撞在一起
    final picked = await showAppMenu<int>(
      context,
      header: '移动到',
      items: <AppMenuItem<int>>[
        const AppMenuItem(
          value: -1,
          label: '未分类',
          icon: Icons.inbox_rounded,
        ),
        for (final col in state.collections)
          AppMenuItem(
            value: col.id,
            label: col.name,
            icon: Icons.folder_rounded,
          ),
      ],
    );
    if (picked == null) return null;
    return picked == -1 ? -1 : picked;
  }

  Future<bool?> _confirmBatchDelete(int count) => showDialog<bool>(
        context: context,
        builder: (dCtx) => AlertDialog(
          backgroundColor: dCtx.colors.secondaryBackground,
          title: Text('删除 $count 篇笔记？', style: AppText.headline),
          content: Text(
            '会先放进回收站，之后随时能恢复。',
            style: AppText.footnote.copyWith(color: dCtx.colors.secondaryLabel),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dCtx).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dCtx).pop(true),
              child: Text(
                '删除',
                style: TextStyle(color: dCtx.colors.destructive),
              ),
            ),
          ],
        ),
      );

  /// 多选模式下的底部操作栏（贴在底部标签栏上面）。
  Widget _selectionBar(AppState state, List<Note> notes) {
    final c = context.colors;
    final ids = notes.map((n) => n.id).toSet();
    Widget btn(String label, VoidCallback? onTap) => Pressable(
          onTap: onTap,
          scale: 0.95,
          haptic: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Text(
              label,
              style: AppText.callout.copyWith(
                color: onTap == null ? c.quaternaryLabel : c.tint,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        );

    return Container(
      decoration: BoxDecoration(
        color: c.secondaryBackground,
        border: Border(top: BorderSide(color: c.separator, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 52,
          child: Row(
            children: [
              const SizedBox(width: 16),
              Text(
                '已选 ${_selected.length}',
                style: AppText.callout.copyWith(
                  color: _selected.isEmpty ? c.tertiaryLabel : c.tint,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              btn('全选', () => setState(() {
                    _selected
                      ..clear()
                      ..addAll(ids);
                  })),
              btn('反选', () => setState(() {
                    final next = ids.difference(_selected);
                    _selected
                      ..clear()
                      ..addAll(next);
                  })),
              btn(
                '批量操作',
                _selected.isEmpty ? null : () => _batchMenu(state, notes),
              ),
              btn('取消', _exitSelection),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _collapse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = context.colors;
    final notes = state.notes;
    final imageRoot = state.db.imageRoot.path;

    return Scaffold(
      backgroundColor: c.groupedBackground,
      body: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: <Widget>[
          AppRefresh.sliver(onRefresh: state.refresh),
          _buildHeader(context, state),
          SliverToBoxAdapter(child: _buildFilterBar(context, state)),
          if (notes.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyHint(
                icon: (state.overview?.noteCount ?? 0) > 0
                    ? Icons.search_off_rounded
                    : Icons.auto_stories_rounded,
                title: (state.overview?.noteCount ?? 0) > 0 ? '没有匹配的笔记' : '还没有内容',
                subtitle: (state.overview?.noteCount ?? 0) > 0
                    ? '换个关键词，或切换到「全部」看看'
                    : '导入你的 .docx 文集，或直接新建一篇笔记',
                action: (state.overview?.noteCount ?? 0) > 0
                    ? null
                    : _importButton(context),
              ),
            )
          else if (state.gridMode)
            _buildGrid(context, notes, imageRoot)
          else
            _buildList(context, notes, imageRoot),
          const SliverToBoxAdapter(child: SizedBox(height: 110)),
        ],
      ),
      floatingActionButton: _selecting ? null : _buildFab(context, state),
      bottomNavigationBar: _selecting ? _selectionBar(state, notes) : null,
    );
  }

  // ── 顶部标题栏 ──────────────────────────────────────────────────────────

  Widget _buildHeader(BuildContext context, AppState state) {
    final c = context.colors;
    final total = state.overview?.noteCount ?? 0;
    final subtitle = _selecting
        ? '已选 ${_selected.length} 篇'
        : state.filter.collectionId == null && state.filter.tag == null
            ? '共 $total 篇'
            : '筛选出 ${state.notes.length} 篇';

    return SliverAppBar(
      pinned: true,
      expandedHeight: _expandedHeight,
      backgroundColor: c.groupedBackground,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      titleSpacing: 0,
      automaticallyImplyLeading: false,
      title: ValueListenableBuilder<double>(
        valueListenable: _collapse,
        builder: (context, t, _) => Opacity(
          // 收起后才显示小标题，避免和大标题叠字
          opacity: ((t - 0.55) / 0.45).clamp(0.0, 1.0),
          child: Text('笔记', style: AppText.headline.copyWith(color: c.label)),
        ),
      ),
      actions: [
        // 多选：桌面有批量操作，手机也得有入口。
        // 放这里（而不是抢长按）是因为长按已经给了单篇的操作菜单。
        GlassIconButton(
          icon: _selecting
              ? Icons.check_circle_rounded
              : Icons.checklist_rounded,
          color: _selecting ? context.colors.tint : null,
          tooltip: _selecting ? '完成多选' : '多选',
          onTap: () => _selecting ? _exitSelection() : _enterSelection(),
        ),
        const SizedBox(width: 6),
        GlassIconButton(
          icon: Icons.search_rounded,
          tooltip: '搜索',
          onTap: () => Navigator.of(context).push(
            ApplePageRoute<void>(pageBuilder: (_) => const SearchPage()),
          ),
        ),
        const SizedBox(width: 6),
        _SortMenu(state: state),
        const SizedBox(width: 4),
        GlassIconButton(
          icon: state.gridMode ? Icons.view_list_rounded : Icons.grid_view_rounded,
          tooltip: state.gridMode ? '列表视图' : '瀑布流视图',
          onTap: () => state.setGridMode(!state.gridMode),
        ),
        const SizedBox(width: 16),
      ],
      flexibleSpace: ValueListenableBuilder<double>(
        valueListenable: _collapse,
        builder: (context, t, _) {
          return FlexibleSpaceBar(
            titlePadding: const EdgeInsetsDirectional.only(start: 20, bottom: 12),
            title: Opacity(
              opacity: (1 - t * 1.6).clamp(0.0, 1.0),
              child: Transform.translate(
                offset: Offset(0, -t * 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '笔记',
                      style: AppText.largeTitle.copyWith(color: c.label),
                    ),
                    Text(
                      subtitle,
                      style: AppText.footnote.copyWith(color: c.tertiaryLabel),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ── 筛选胶囊条 ──────────────────────────────────────────────────────────

  Widget _buildFilterBar(BuildContext context, AppState state) {
    final c = context.colors;
    final f = state.filter;

    final chips = <Widget>[
      _Pill(
        label: '全部',
        selected: f.collectionId == null && f.tag == null && !f.favoritesOnly,
        onTap: () {
          state.selectCollection(null);
          state.selectTag(null);
          if (f.favoritesOnly) state.toggleFavorites();
        },
      ),
      _Pill(
        label: '收藏',
        icon: Icons.star_rounded,
        selected: f.favoritesOnly,
        accent: c.palette[7],
        onTap: state.toggleFavorites,
      ),
      // 归档：和「收藏」一样是一种**视图**，所以放在这一排。
      //
      // 桌面左栏有「归档」这一项，手机上原本没有 —— 结果是：手机上长按
      // 笔记选「归档」之后，那篇笔记就从列表里消失了，而且**再也看不到、
      // 也没法取消归档**（只能在电脑上处理）。这个胶囊补上这条路。
      _Pill(
        label: '归档',
        icon: Icons.archive_outlined,
        selected: f.archivedOnly,
        accent: c.palette[4],
        onTap: () => state.setFilter(
          f.archivedOnly
              ? f.copyWith(archivedOnly: false, hiddenOnly: false)
              // 归档和"未归档"是互斥的两边，切过去时先清掉其它互斥筛选
              : NoteFilter(
                  archivedOnly: true,
                  sort: f.sort,
                  query: f.query,
                ),
        ),
      ),
      for (final col in state.collections)
        _Pill(
          label: col.name,
          count: col.noteCount,
          accent: Color(col.color),
          selected: f.collectionId == col.id,
          onTap: () => state.selectCollection(col.id),
          onLongPress: () => showCollectionEditor(context, existing: col),
        ),
      // **标签也要能筛。**
      //
      // 之前手机上只能给笔记贴标签（阅读页的标签按钮），却没有任何地方
      // 能按标签筛 —— `selectTag()` 只有桌面左栏在调，手机上连入口都没有，
      // 标签功能等于残了一半。桌面有的，手机也得有。
      //
      // 放在文件夹后面、和文件夹同一排：两者都是"横切的分类"，
      // 再往下一排单独放标签会让筛选条占掉两行高度。
      if (f.tag != null && !state.tags.any((t) => t.name == f.tag))
        // 选中的标签在筛选结果里消失了（最后一篇被取消标签）：
        // 留一个可见的胶囊让它**能取消**，否则用户卡在一个空列表上
        _Pill(
          label: f.tag!,
          icon: Icons.label_rounded,
          accent: c.palette[5],
          selected: true,
          onTap: () => state.selectTag(null),
        ),
      for (final tag in state.tags)
        _Pill(
          label: tag.name,
          icon: Icons.label_rounded,
          count: tag.count,
          accent: Color(tag.color),
          selected: f.tag == tag.name,
          // 再点一下取消：标签是"随手贴"的东西，不该逼用户去找取消入口
          onTap: () => state.selectTag(f.tag == tag.name ? null : tag.name),
        ),
      // 末尾常驻「新建」入口：手机上没有左栏，不这样放用户找不到
      _Pill(
        label: '新建',
        icon: Icons.add_rounded,
        selected: false,
        onTap: () => showCollectionEditor(context),
      ),
    ];

    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: chips.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) => Center(child: chips[i]),
      ),
    );
  }

  // ── 列表 / 瀑布流 ───────────────────────────────────────────────────────

  Widget _buildList(BuildContext context, List<Note> notes, String imageRoot) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      sliver: SliverList.builder(
        itemCount: notes.length,
        itemBuilder: (context, i) => Padding(
          padding: const EdgeInsets.only(bottom: AppMetrics.rowGap),
          child: _Staggered(
            index: i,
            child: Builder(
              builder: (cardCtx) => _selectable(
                notes[i],
                NoteCard(
                  note: notes[i],
                  imageRoot: imageRoot,
                  onTap: () => _selecting
                      ? _toggleSelect(notes[i].id)
                      : _openNote(notes[i]),
                  onLongPress: () => _selecting
                      ? _toggleSelect(notes[i].id)
                      : _showActions(
                          notes[i],
                          AppMenuAnchor(context: cardCtx),
                        ),
                  onSecondaryTap: (a) => _showActions(notes[i], a),
                  onMore: (a) => _showActions(notes[i], a),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 多选模式下给卡片盖一层"选中"标记。
  ///
  /// 用外面包一层而不是改 [NoteCard] 的签名：卡片是列表/瀑布流/搜索页
  /// 共用的，加一个只有这里用的参数会把三处都搅进来。
  Widget _selectable(Note n, Widget card) {
    if (!_selecting) return card;
    final c = context.colors;
    final on = _selected.contains(n.id);
    return Stack(
      children: [
        card,
        Positioned(
          right: 10,
          top: 10,
          child: IgnorePointer(
            child: AnimatedContainer(
              duration: AppMotion.fast,
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: on ? c.tint : c.secondaryBackground.withValues(alpha: 0.85),
                shape: BoxShape.circle,
                border: Border.all(
                  color: on ? c.tint : c.separator,
                  width: 1.5,
                ),
              ),
              child: on
                  ? const Icon(Icons.check_rounded, size: 15, color: Colors.white)
                  : null,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildGrid(BuildContext context, List<Note> notes, String imageRoot) {
    // 尊重用户的列数设置，但窄屏上会收敛：手机宽度塞 5 列，
    // 一格只剩几十像素，标题全变省略号。
    final width = MediaQuery.sizeOf(context).width;
    final fit = (width / 150).floor().clamp(2, 5);
    final columns = context.read<AppState>().gridColumns.clamp(2, fit);
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      sliver: SliverMasonryGrid.count(
        crossAxisCount: columns,
        mainAxisSpacing: AppMetrics.rowGap,
        crossAxisSpacing: AppMetrics.rowGap,
        childCount: notes.length,
        itemBuilder: (context, i) => _Staggered(
          index: i,
          child: Builder(
            builder: (cardCtx) => _selectable(
              notes[i],
              NoteCard(
                note: notes[i],
                imageRoot: imageRoot,
                compact: true,
                onTap: () => _selecting
                    ? _toggleSelect(notes[i].id)
                    : _openNote(notes[i]),
                onLongPress: () => _selecting
                    ? _toggleSelect(notes[i].id)
                    : _showActions(
                        notes[i],
                        AppMenuAnchor(context: cardCtx),
                      ),
                onSecondaryTap: (a) => _showActions(notes[i], a),
                onMore: (a) => _showActions(notes[i], a),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildFab(BuildContext context, AppState state) {
    final c = context.colors;
    return Pressable(
      scale: 0.92,
      onTap: () => createAndOpenNote(context),
      child: Container(
        width: 54,
        height: 54,
        decoration: BoxDecoration(
          color: c.tint,
          shape: BoxShape.circle,
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: c.tint.withValues(alpha: 0.35),
              blurRadius: 16,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: const Icon(Icons.edit_rounded, color: Colors.white, size: 22),
      ),
    );
  }

  // ── 交互 ────────────────────────────────────────────────────────────────

  void _openNote(Note note) {
    Navigator.of(context).push(
      ApplePageRoute<void>(
        pageBuilder: (_) => NoteDetailPage(noteId: note.id),
      ),
    );
  }

  /// 统一走共用菜单：卡片右键、长按、悬停 ⋯ 按钮都调这里，
  /// 保证三个入口的行为完全一致；[anchor] 决定菜单贴着哪里弹。
  void _showActions(Note note, [AppMenuAnchor? anchor]) {
    showNoteActions(context, note, anchor: anchor);
  }
}

/// 错峰淡入：前若干项带一点延迟，形成柔和的出现节奏。
/// 只对首屏可见的项生效（超过 12 项就不再延迟，避免滚动时反而卡顿）。
class _Staggered extends StatefulWidget {
  const _Staggered({required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  State<_Staggered> createState() => _StaggeredState();
}

class _StaggeredState extends State<_Staggered>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: AppMotion.normal,
  );

  @override
  void initState() {
    super.initState();
    final delay = widget.index < 12 ? widget.index * 22 : 0;
    Future<void>.delayed(Duration(milliseconds: delay), () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// 曲线只建一次。
  ///
  /// `CurvedAnimation` 的构造函数会给 `_c` 挂一个 status 监听，
  /// 而只有 `dispose()` 才摘掉。写在 build 里的话，卡片每重建一次
  /// （任何一次 AppState 通知：编辑器敲一个字、切个筛选）就漏一个监听，
  /// 越积越多。用 `drive` 不产生额外对象，最省。
  late final Animation<double> _fade = _c.drive(
    CurveTween(curve: AppMotion.enter),
  );

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduceMotion(context)) return widget.child;
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.06),
          end: Offset.zero,
        ).animate(_fade),
        child: widget.child,
      ),
    );
  }
}

/// 顶部筛选胶囊。
class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.selected,
    required this.onTap,
    this.onLongPress,
    this.icon,
    this.count,
    this.accent,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// 长按：文件夹胶囊上用来打开重命名/改色面板。
  final VoidCallback? onLongPress;

  final IconData? icon;
  final int? count;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tint = accent ?? c.tint;
    return Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      scale: 0.95,
      child: AnimatedContainer(
        duration: AppMotion.fast,
        curve: AppMotion.enter,
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? tint : c.fill,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(
                icon,
                size: 13,
                color: selected ? Colors.white : tint,
              ),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: AppText.subheadline.copyWith(
                color: selected ? Colors.white : c.label,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            if (count != null && count! > 0) ...[
              const SizedBox(width: 5),
              Text(
                '$count',
                style: AppText.caption2.copyWith(
                  color: selected
                      ? Colors.white.withValues(alpha: 0.8)
                      : c.tertiaryLabel,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 排序菜单。
class _SortMenu extends StatelessWidget {
  const _SortMenu({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return PopupMenuButton<NoteSort>(
      tooltip: '排序',
      position: PopupMenuPosition.under,
      color: c.secondaryBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
      ),
      icon: Icon(Icons.swap_vert_rounded, size: 20, color: c.tint),
      onSelected: state.setSort,
      itemBuilder: (context) => [
        for (final s in NoteSort.values)
          PopupMenuItem<NoteSort>(
            value: s,
            child: Row(
              children: [
                Icon(
                  state.filter.sort == s
                      ? Icons.check_circle_rounded
                      : Icons.circle_outlined,
                  size: 16,
                  color: state.filter.sort == s ? c.tint : c.tertiaryLabel,
                ),
                const SizedBox(width: 10),
                Text(s.label, style: AppText.callout.copyWith(color: c.label)),
              ],
            ),
          ),
      ],
    );
  }
}

/// 「导入文集」按钮（空状态里用）。
Widget _importButton(BuildContext context) {
  final c = context.colors;
  return Pressable(
    onTap: () => Navigator.of(context).push(
      ApplePageRoute<void>(
        pageBuilder: (_) => const ImportPage(),
        fullscreenDialog: true,
      ),
    ),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
      decoration: BoxDecoration(
        color: c.tint,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.download_rounded, size: 17, color: Colors.white),
          const SizedBox(width: 7),
          Text(
            '导入文集',
            style: AppText.callout.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    ),
  );
}
