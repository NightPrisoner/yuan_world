/// 桌面端三栏工作区。
///
/// 布局参考小米笔记网页端与 macOS 版 Apple Notes：
///
///   ┌──────────┬──────────────┬────────────────────┐
///   │ 分类导航  │  笔记列表     │  阅读 / 编辑        │
///   │ 全部笔记  │  🔍 搜索      │  标题               │
///   │ 未分类    │  共 N 篇      │  正文…              │
///   │ 收藏      │  ─────────   │                    │
///   │ 文件夹…   │  笔记行…      │                    │
///   │ 待办/统计 │              │                    │
///   └──────────┴──────────────┴────────────────────┘
///
/// 为什么用三栏而不是"列表 → 详情"两级跳：
///   桌面屏幕本来就是宽的，两级跳会浪费掉一半横向空间，
///   而且每次看笔记都要来回切换，效率和观感都差。
///
/// 窄屏（手机）不走这里，仍然用底部标签栏那套。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../core/motion/app_motion.dart';
import '../../core/platform/window_mode.dart';
import '../../core/motion/apple_page_route.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_menu.dart';
import '../../data/exporter/note_exporter.dart';
import '../../data/models.dart';
import '../../data/repositories/note_repository.dart';
import '../collections/collection_sheets.dart';
import '../importer/import_page.dart';
import '../notes/editor/note_editor_page.dart';
import '../notes/note_detail_page.dart';
import '../notes/widgets/note_actions.dart';
import '../notes/widgets/note_card.dart' show formatRelative;
import '../settings/settings_page.dart';
import '../stats/stats_page.dart';
import '../todos/todos_page.dart';
import '../trash/trash_page.dart';

enum _Section { notes, archived, todos, stats, trash, settings }

class DesktopWorkspace extends StatefulWidget {
  const DesktopWorkspace({super.key});

  @override
  State<DesktopWorkspace> createState() => _DesktopWorkspaceState();
}

class _DesktopWorkspaceState extends State<DesktopWorkspace> {
  _Section _section = _Section.notes;
  int? _selectedNoteId;
  bool _editing = false;
  /// 是否处于"占满页面"（三栏收起，阅读/编辑共用）。
  bool _editorFullscreen = false;

  /// 是否处于**窗口**无边框全屏。和上面那个是两件独立的事。
  bool _windowFullscreen = false;

  /// 多选模式开关与已选项。
  bool _selecting = false;
  final Set<int> _selected = <int>{};

  /// 收起来的文件夹 id。
  ///
  /// 只影响左栏的**显示**，不动数据 —— 收起一个文件夹不会把它里面的
  /// 子文件夹或笔记挪走，展开回来还是原样。
  final Set<int> _collapsed = <int>{};

  /// 文件夹列表的滚动控制器。拖拽靠近边缘时用它自动滚。
  final ScrollController _folderScroll = ScrollController();

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
            _selected.isEmpty
                ? null
                : () => _batchMenu(state, notes),
          ),
        ],
      ),
    );
  }

  void _toggleSelect(int id) => setState(() {
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
          label: '导出为文件',
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
        state.repo.deleteNotes(ids);
        await state.refresh();
        _toast('已删除 ${ids.length} 篇');
    }
    if (mounted) setState(() => _selected.clear());
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

  Future<void> _exportNotes(List<int> ids) async {
    final dir = await FilePicker.getDirectoryPath(
      dialogTitle: '选择导出到哪个文件夹',
    );
    if (dir == null || !mounted) return;

    final format = await showAppMenu<ExportFormat>(
      context,
      header: '导出格式',
      items: <AppMenuItem<ExportFormat>>[
        for (final f in ExportFormat.values)
          AppMenuItem(
            value: f,
            label: '${f.label}（.${f.ext}）',
            icon: Icons.description_outlined,
          ),
      ],
    );
    if (format == null || !mounted) return;

    final state = context.read<AppState>();
    final notes = <Note>[
      for (final id in ids) ?state.repo.getNote(id),
    ];
    final n = NoteExporter.exportToDirectory(
      notes: notes,
      format: format,
      dir: dir,
      imageRoot: state.db.imageRoot.path,
    );
    _toast('已导出 $n 篇到 $dir');
  }

  Future<bool> _confirmBatchDelete(int count) async {
    final c = context.colors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除这 $count 篇笔记？'),
        content: Text(
          '删除后无法恢复。',
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

  /// 正文栏是否展开。
  ///
  /// 默认收起：一进应用是「导航 + 列表」两栏。
  /// 点某篇笔记或新建一篇时才把正文栏拉出来 ——
  /// 这样冷启动不会先甩给用户一块空白。
  bool _detailOpen = false;
  final TextEditingController _search = TextEditingController();

  // ── 三栏宽度（可拖动） ──
  // 上限给得比较宽松：宽屏下用户可能想把列表栏拉得很宽看瀑布流
  static const double _navMin = 160;
  static const double _navMax = 560;
  static const double _listMin = 220;
  static const double _listMax = 1100;

  double _navWidth = 236;
  double _listWidth = 316;

  @override
  void initState() {
    super.initState();
    _restoreWidths();
    if (!kDebugMode) return;
    final env = Platform.environment;

    // 调试用：YW_TAB=0..3 直接落到对应分栏（窄屏那边也有一套同名开关，
    // 之前只在窄屏生效，宽屏没法直达统计页，截图验证很别扭）
    final tab = int.tryParse(env['YW_TAB'] ?? '');
    if (tab != null) {
      _section = _Section.values[tab.clamp(0, _Section.values.length - 1)];
    }

    // 调试用：YW_EDIT_FULLSCREEN=1 直接进入全屏编辑，方便截图与演示
    if (env['YW_EDIT_FULLSCREEN'] == '1') {
      _editing = true;
      _editorFullscreen = true;
    }
  }

  @override
  void dispose() {
    _search.dispose();
    _folderScroll.dispose();
    super.dispose();
  }

  // ── 三栏宽度 ────────────────────────────────────────────────────────────

  void _restoreWidths() {
    final repo = context.read<AppState>().repo;
    final nav = double.tryParse(repo.getSetting('layout.navWidth') ?? '');
    final list = double.tryParse(repo.getSetting('layout.listWidth') ?? '');
    if (nav != null) _navWidth = nav.clamp(_navMin, _navMax);
    if (list != null) _listWidth = list.clamp(_listMin, _listMax);
  }

  void _saveWidths() {
    final repo = context.read<AppState>().repo;
    // 只在松手时写库，拖动过程中每帧写库纯属浪费
    repo.setSetting('layout.navWidth', _navWidth.round().toString());
    repo.setSetting('layout.listWidth', _listWidth.round().toString());
  }

  /// 切到瀑布流时，如果中栏太窄就自动撑开一点 —— 两列挤在 300px 里没法看。
  /// 用户之后手动拖过就按用户自己的来。
  ///
  /// 每列按 150px 算：一格里要放得下缩略图 + 两行标题，再窄就只剩省略号了。
  void _ensureWidthForGrid() {
    final columns = context.read<AppState>().gridColumns;
    final need = 150.0 * columns + 40;
    if (_listWidth < need && need <= _listMax) {
      _listWidth = need;
      _saveWidths();
    }
  }

  void _openNote(int id) {
    setState(() {
      _selectedNoteId = id;
      _editing = false;
      _editorFullscreen = false;
      _detailOpen = true;
    });
  }

  /// 收起正文栏。顺手清掉选中态和编辑态，
  /// 否则下次展开会莫名其妙地回到上次那篇的编辑中。
  void _closeDetail() {
    setState(() {
      _detailOpen = false;
      _editing = false;
      _editorFullscreen = false;
      _selectedNoteId = null;
    });
  }

  void _goSection(_Section s) {
    setState(() {
      _section = s;
      if (s != _Section.notes) {
        _editing = false;
        _exitAllFullscreen();
      }
    });

    // 归档区就是"列表换成归档的那些" —— 中间栏复用同一套列表。
    // 离开时要切回来，否则用户会以为笔记全没了。
    final state = context.read<AppState>();
    if (s == _Section.archived) {
      state.setFilter(
        state.filter.copyWith(archivedOnly: true, hiddenOnly: false),
      );
    } else if (s == _Section.notes && state.filter.archivedOnly) {
      state.setFilter(state.filter.copyWith(archivedOnly: false));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = context.colors;
    final notes = state.notes;

    // 归档区也用同一套选中逻辑，所以这两处判断要把它算进去
    final listSection =
        _section == _Section.notes || _section == _Section.archived;

    // 列表变了之后，之前选中的笔记可能已经不在当前筛选里了
    if (listSection &&
        _selectedNoteId != null &&
        !notes.any((n) => n.id == _selectedNoteId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _selectedNoteId = null;
            _editing = false;
            _editorFullscreen = false;
          });
        }
      });
    }

    // 首次进入自动选中第一篇，避免右侧一片空白
    if (listSection &&
        _selectedNoteId == null &&
        notes.isNotEmpty &&
        state.filter.query.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _selectedNoteId == null) {
          setState(() => _selectedNoteId = notes.first.id);
        }
      });
    }

    // 外部改动筛选（比如搜索）时同步输入框
    if (_search.text != state.filter.query) {
      _search.value = TextEditingValue(
        text: state.filter.query,
        selection: TextSelection.collapsed(offset: state.filter.query.length),
      );
    }

    return Focus(
      // 让整个工作区能接收快捷键；子控件（搜索框、编辑器）拿到焦点后
      // 事件仍会向上冒泡到这里
      autofocus: true,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.keyN, control: true): () =>
              _createNote(state),
          const SingleActivator(LogicalKeyboardKey.keyN, meta: true): () =>
              _createNote(state),
          // Esc 退出全屏。全屏之后没有任何可见的"退出"提示，
          // 不给个键盘出口用户会以为卡住了。
          // 从外往里退：先退**窗口**全屏，再退**占满页面**。
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (_windowFullscreen) {
              setState(() => _windowFullscreen = false);
              setAppFullscreen(false);
              return;
            }
            if (_editorFullscreen) {
              setState(() => _editorFullscreen = false);
            }
          },
        },
        child: Scaffold(
          backgroundColor: c.background,
          // 全屏编辑时把导航栏和列表栏都收起来，编辑器占满整窗
          body: Row(
            children: [
              if (!fullscreenEditor) ...[
                if (_navCollapsed)
                  // 58 = 10 + 38 + 10：让收起后的功能键左边缘正好落在
                  // 展开态那个 10px 的内边距上，两种状态同一竖线，
                  // 收起来的时候整排图标不会横向跳一下
                  SizedBox(width: 58, child: _navRail(context, state))
                else ...[
                SizedBox(width: _navWidth, child: _navPane(context, state)),
                _PaneResizer(
                  onDrag: (d) => setState(
                    () => _navWidth = (_navWidth + d).clamp(_navMin, _navMax),
                  ),
                  onDragEnd: _saveWidths,
                ),
                ],
              ],
              if ((_section == _Section.notes || _section == _Section.archived) && !fullscreenEditor) ...[
                // 列表栏：正文栏收起时它撑满剩余空间，不留下一条空白
                if (_detailOpen)
                  SizedBox(
                    width: _listWidth,
                    child: _listPane(context, state, notes),
                  )
                else
                  Expanded(child: _listPane(context, state, notes)),

                if (_detailOpen)
                  _PaneResizer(
                    onDrag: (d) => setState(
                      () =>
                          _listWidth = (_listWidth + d).clamp(_listMin, _listMax),
                    ),
                    onDragEnd: _saveWidths,
                  ),

                // 正文栏：收起时整块不存在
                if (_detailOpen)
                  Expanded(
                    key: const ValueKey<String>('detail-pane'),
                    child: _detailPane(context, state),
                  ),
              ] else
                Expanded(
                  // 给这一栏一个固定 key：全屏切换时 Row 的子项数量会变，
                  // 有 key 才能让 Flutter 认出"还是同一个位置"，
                  // 从而保住编辑器的 State（否则正在写的字会丢）。
                  key: const ValueKey<String>('detail-pane'),
                  child: fullscreenEditor
                      ? _detailPane(context, state, fullscreen: true)
                      : _sectionPage(state),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 新建一篇笔记，并**直接进入编辑态**。
  ///
  /// 新建出来的是空笔记，跳到阅读页什么也看不到，还得再点一次「编辑」，
  /// 所以这里一步到位。新笔记会落在当前选中的文件夹里（createNote 内部处理）。
  Future<void> _createNote(AppState state) async {
    final id = state.createNote();
    await state.refresh();
    if (!mounted) return;
    setState(() {
      _section = _Section.notes;
      _selectedNoteId = id;
      _editing = true;
      _editorFullscreen = false;
      // 新建必然要把正文栏拉出来，否则用户看不到自己刚建的东西
      _detailOpen = true;
    });
  }

  /// 是否处于"占满页面"（三栏收起）。
  ///
  /// 阅读和编辑都算 —— 之前这里多了一个 `_editing` 条件，
  /// 导致阅读时点全屏界面毫无变化。
  bool get fullscreenEditor =>
      _editorFullscreen &&
      (_section == _Section.notes || _section == _Section.archived) &&
      _selectedNoteId != null;

  /// 退出所有全屏状态。
  ///
  /// 有些入口（关详情栏、切导航）用户不会意识到自己还在全屏里，
  /// 必须一次收干净，否则窗口会卡在无边框状态。
  void _exitAllFullscreen() {
    if (_windowFullscreen) setAppFullscreen(false);
    _windowFullscreen = false;
    _editorFullscreen = false;
  }

  Widget _sectionPage(AppState state) => switch (_section) {
    _Section.todos => const TodosPage(),
    _Section.stats => const StatsPage(),
    _Section.trash => const TrashPage(),
    _Section.settings => const SettingsPage(),
    // 归档复用中间那栏的笔记列表，不需要单独页面
    _Section.notes || _Section.archived => const SizedBox.shrink(),
  };

  /// 左栏顶部的标识。隐私空间里换成醒目的提示 + 退出按钮 ——
  /// 「现在看的是哪一套数据」必须一眼可见，否则容易误操作。
  Widget _brandHeader(AppColors c, AppState state) {
    if (!state.privacyMode) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
        child: Row(
          children: [
            Container(
              width: 26,
              height: 26,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [c.palette[0], c.palette[4]],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.auto_awesome,
                  size: 16, color: Colors.white),
            ),
            const SizedBox(width: 9),
            Text('元世界', style: AppText.title3.copyWith(color: c.label)),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: c.palette[6].withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
        ),
        child: Row(
          children: [
            Icon(Icons.lock_rounded, size: 16, color: c.palette[6]),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '隐私空间',
                style: AppText.callout.copyWith(
                  color: c.palette[6],
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Pressable(
              onTap: state.exitPrivacyMode,
              scale: 0.94,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: Text(
                  '退出',
                  style: AppText.footnote.copyWith(
                    color: c.palette[6],
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 左栏：分类导航 ──────────────────────────────────────────────────────

  Widget _navPane(BuildContext context, AppState state) {
    final c = context.colors;
    final f = state.filter;

    final allSelected = _section == _Section.notes &&
        f.collectionId == null &&
        !f.favoritesOnly &&
        !f.uncategorizedOnly;

    return Container(
      decoration: BoxDecoration(
        color: c.isDark ? const Color(0xFF141416) : const Color(0xFFF7F7FA),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── 标识（隐私空间里换成锁形提示） ──
            _brandHeader(c, state),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── 固定区：常用入口（不随文件夹列表滚动） ──
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // **收起开关放在最上面，且两种状态同一个位置。**
                        //
                        // 以前它夹在"视图"和"文件夹"两组中间，而收起后的
                        // 展开按钮在最顶上 —— 同一个开关点一下会跳到另一个
                        // 高度，很难受。放到固定区第一个，两边 y 就一致了。
                        _NavRow(
                          icon: Icons.chevron_left_rounded,
                          label: '收起侧栏',
                          selected: false,
                          onTap: () => setState(() => _navCollapsed = true),
                        ),
                  _NavRow(
                    icon: Icons.article_rounded,
                    label: '全部笔记',
                    count: state.overview?.noteCount ?? 0,
                    selected: allSelected,
                    onTap: () {
                      state.selectAll();
                      _goSection(_Section.notes);
                    },
                  ),
                  // 未分类也是一个投放目标：把笔记拖出去就从文件夹里移出来了
                  _DropZone(
                    onNote: (note) async {
                      await state.moveNoteToCollection(note.id, null);
                    },
                    child: _NavRow(
                      icon: Icons.inbox_rounded,
                      label: '未分类',
                      color: c.palette[2],
                      selected:
                          _section == _Section.notes && f.uncategorizedOnly,
                      onTap: () {
                        state.selectUncategorized();
                        _goSection(_Section.notes);
                      },
                    ),
                  ),
                  _NavRow(
                    icon: Icons.star_rounded,
                    label: '收藏',
                    color: c.palette[7],
                    count: state.overview?.favoriteCount ?? 0,
                    selected: _section == _Section.notes && f.favoritesOnly,
                    onTap: () {
                      state.selectAll();
                      state.toggleFavorites();
                      _goSection(_Section.notes);
                    },
                  ),

                      ],
                    ),
                  ),

                  // ── 分组分隔：上面三个是「视图」，下面是「我的文件夹」 ──
                  // 一条细线 + 上下留白，让两组一眼分得开
                  const SizedBox(height: 10),
                  Divider(height: 1, indent: 14, endIndent: 14, color: c.separator),
                  const SizedBox(height: 6),

                  // ── 固定：文件夹标题（新建按钮始终够得着） ──
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: _NavGroupLabel(
                      '我的文件夹',
                      onAdd: () async {
                        final created = await showCollectionEditor(context);
                        // 弹窗挂在根 Navigator 上，等它关掉的这段时间里
                        // 窗口被拖窄到 1000px 以下会让这个 workspace 被销毁
                        if (created != null && mounted) {
                          _goSection(_Section.notes);
                        }
                      },
                    ),
                  ),

                  // ── 可滚动：文件夹列表 ──
                  // 文件夹可能很多（还支持嵌套），让它自己滚：
                  // 上下的固定项就不会被顶出屏幕、不用满世界找。
                  //
                  // 外面套一层自动滚动：拖着一个文件夹靠近上下边缘时列表
                  // 自己滚，否则想把文件夹拖到列表另一端根本做不到 ——
                  // 手一松就掉回原处。
                  Expanded(
                    child: _AutoScrollWhenDragging(
                      child: ListView(
                        controller: _folderScroll,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        physics: const BouncingScrollPhysics(),
                        children: [
                  for (final (_, col, depth) in _flattenTree(state.collections))
                    Builder(
                      builder: (rowCtx) => _collectionRow(
                        rowCtx,
                        state,
                        col,
                        depth,
                        f.collectionId,
                        // 有子文件夹的才给收起/展开的小三角
                        hasKids:
                            state.collections.any((x) => x.parentId == col.id),
                      ),
                    ),
                  if (state.collections.isEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(22, 4, 10, 4),
                      child: Text(
                        '还没有文件夹',
                        style:
                            AppText.caption1.copyWith(color: c.quaternaryLabel),
                      ),
                    )
                  else
                    // 拖到这里 = 升到顶层。没有这块的话，
                    // 文件夹全都嵌套着时就没地方把它拎出来了。
                    _DropZone(
                      onCollectionDrop: (dragged, _) =>
                          _dropToTopLevel(context, state, dragged),
                      child: SizedBox(
                        height: 26,
                        child: Center(
                          child: Text(
                            '拖到此处移到顶层',
                            style: AppText.caption2
                                .copyWith(color: c.quaternaryLabel),
                          ),
                        ),
                      ),
                    ),

                      ],
                      ),
                    ),
                  ),

                  // ── 分组分隔：文件夹区 / 功能区（待办、归档、回收站…） ──
                  Divider(height: 1, indent: 14, endIndent: 14, color: c.separator),
                  const SizedBox(height: 6),

                  // ── 固定区：待办 / 统计 ──
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 6),
                        Divider(color: c.separator, height: 1),
                        const SizedBox(height: 6),
                        _NavRow(
                          icon: Icons.check_circle_rounded,
                          label: '待办',
                          count: state.openTodoCount,
                          color: c.palette[1],
                          selected: _section == _Section.todos,
                          onTap: () => _goSection(_Section.todos),
                        ),
                        _NavRow(
                          icon: Icons.archive_outlined,
                          label: '归档',
                          color: c.palette[4],
                          selected: _section == _Section.archived,
                          onTap: () => _goSection(_Section.archived),
                        ),
                        _NavRow(
                          icon: Icons.delete_outline_rounded,
                          label: '回收站',
                          count: state.trashedNotes.length,
                          color: c.palette[3],
                          selected: _section == _Section.trash,
                          onTap: () => _goSection(_Section.trash),
                        ),                        _NavRow(
                          icon: Icons.insights_rounded,
                          label: '统计',
                          color: c.palette[5],
                          selected: _section == _Section.stats,
                          onTap: () => _goSection(_Section.stats),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // ── 导入文集（在设置上面） ──
            //
            // **用 _NavRow，不要手写一行。** 之前这里是手搓的
            // `Pressable > _HoverTint > Row`，而 _HoverTint 的左内边距是
            // 22px（那是给缩进的子文件夹用的），_NavRow 是 10px ——
            // 于是"导入文集"整体比同级右移了 12px，一眼就看得出来没对齐。
            // 复用 _NavRow 之后几何由同一份代码决定，不可能再走偏。
            //
            // 顺带保住了原来的意图：selected 传 false，静息态没有底色，
            // 悬停才浮现 —— 它是"动作"，不是"当前所在"，不该看着像被按住。
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 0),
              child: _NavRow(
                icon: Icons.download_rounded,
                label: '导入文集',
                selected: false,
                onTap: () => Navigator.of(context).push(
                  ApplePageRoute<void>(
                    pageBuilder: (_) => const ImportPage(),
                    fullscreenDialog: true,
                  ),
                ),
              ),
            ),

            // ── 底部固定：设置（不随任何列表滚动，永远在左下角） ──
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 6),
              child: _NavRow(
                icon: Icons.tune_rounded,
                label: '设置',
                selected: _section == _Section.settings,
                onTap: () => _goSection(_Section.settings),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 中栏：笔记列表 ──────────────────────────────────────────────────────

  /// 左栏是否已收起成一条窄条。
  bool _navCollapsed = false;

  /// 左栏收起后的窄条。
  ///
  /// 只留图标、去掉文字和文件夹树 —— 收起的意义就是"把地方让给正文"，
  /// 所以它必须真的窄。点顶部的箭头展开。
  Widget _navRail(BuildContext context, AppState state) {
    final c = context.colors;
    final f = state.filter;

    Widget item(IconData icon, String tip, bool active, VoidCallback onTap) =>
        Tooltip(
          message: tip,
          child: Pressable(
            onTap: onTap,
            scale: 0.92,
            child: Container(
              width: 38,
              height: 38,
              margin: const EdgeInsets.symmetric(vertical: 2),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: active
                    ? c.tint.withValues(alpha: c.isDark ? 0.24 : 0.14)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(
                icon,
                size: 18,
                color: active ? c.tint : c.secondaryLabel,
              ),
            ),
          ),
        );

    return Container(
      decoration: BoxDecoration(
        color: c.isDark ? const Color(0xFF141416) : const Color(0xFFF7F7FA),
        border: Border(right: BorderSide(color: c.separator, width: 0.5)),
      ),
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 10),
            Tooltip(
              message: '展开侧栏',
              child: Pressable(
                onTap: () => setState(() => _navCollapsed = false),
                scale: 0.9,
                child: Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: c.secondaryLabel,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),
            item(Icons.article_rounded, '全部笔记',
                _section == _Section.notes && f.collectionId == null &&
                    !f.favoritesOnly && !f.uncategorizedOnly, () {
              state.selectCollection(null);
              _goSection(_Section.notes);
            }),
            item(Icons.star_rounded, '收藏', f.favoritesOnly, () {
              state.selectAll();
              state.toggleFavorites();
              _goSection(_Section.notes);
            }),
            const Spacer(),
            item(Icons.check_circle_rounded, '待办',
                _section == _Section.todos, () => _goSection(_Section.todos)),
            item(Icons.archive_outlined, '归档',
                _section == _Section.archived, () => _goSection(_Section.archived)),
            item(Icons.delete_outline_rounded, '回收站',
                _section == _Section.trash, () => _goSection(_Section.trash)),
            item(Icons.insights_rounded, '统计',
                _section == _Section.stats, () => _goSection(_Section.stats)),
            item(Icons.tune_rounded, '设置',
                _section == _Section.settings, () => _goSection(_Section.settings)),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

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
  }) {
    final collapsed = _collapsed.contains(col.id);
    return _DropZone(
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
          collapsed: collapsed,
          onToggleCollapse: hasKids
              ? () => setState(() {
                    // 点一下收起、再点展开
                    if (!_collapsed.remove(col.id)) _collapsed.add(col.id);
                  })
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
    );
  }

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
                  onTap: () => setState(() {
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

  // ── 拖拽落地 ────────────────────────────────────────────────────────────

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
        // 收起来的节点不再往下走 —— 这就是「每一级都能收纳」
        if (!_collapsed.contains(c.id)) walk(c.id, depth + 1);
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

  // ── 文集的右键/⋯ 菜单 ───────────────────────────────────────────────────

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

  // ── 右栏：阅读 / 编辑 ───────────────────────────────────────────────────

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
              setState(() => _editorFullscreen = !_editorFullscreen),
          // ⛶ 无边框窗口全屏：只放大窗口，**不动版式**
          windowFullscreen: _windowFullscreen,
          onToggleWindowFullscreen: () {
            setState(() => _windowFullscreen = !_windowFullscreen);
            setAppFullscreen(_windowFullscreen);
          },
          onClose: () {
            _exitAllFullscreen();
            setState(() => _editing = false);
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
            setState(() => _editorFullscreen = !_editorFullscreen),
        onToggleWindowFullscreen: () {
          setState(() => _windowFullscreen = !_windowFullscreen);
          setAppFullscreen(_windowFullscreen);
        },
        windowFullscreen: _windowFullscreen,
        onRequestEdit: () => setState(() => _editing = true),
        onClose: () {
          _exitAllFullscreen();
          _closeDetail();
        },
      ),
    );
  }
}

// ── 瀑布流列数 ────────────────────────────────────────────────────────────


// ── 拖拽时自动滚动 ────────────────────────────────────────────────────────

/// 手指/鼠标按住并靠近上下边缘时，让里面那个可滚动区域自己滚。
///
/// 为什么需要它：文件夹多了以后，想把一个文件夹从列表底部拖到顶部
/// **物理上做不到** —— 列表不会跟着动，手一松就掉回原处。
///
/// 实现上用 [Listener] 盯指针位置而不是监听拖拽事件：现有的
/// `Draggable` 拖拽把指针"借走"了，普通的滚动手势收不到事件，
/// 但底层指针消息仍然会经过这里。
class _AutoScrollWhenDragging extends StatefulWidget {
  const _AutoScrollWhenDragging({required this.child});

  final Widget child;

  @override
  State<_AutoScrollWhenDragging> createState() =>
      _AutoScrollWhenDraggingState();
}

class _AutoScrollWhenDraggingState extends State<_AutoScrollWhenDragging> {
  /// 距边缘多少像素内开始滚。
  static const double _edge = 56;

  /// 每帧最多滚多少像素（越靠边越快）。
  static const double _maxSpeed = 14;

  Timer? _timer;
  double _velocity = 0;
  Offset? _pointer;
  ScrollController? _controller;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _onMove(PointerMoveEvent e) {
    _pointer = e.position;
    _ensureTicking();
    _updateVelocity();
  }

  void _onDown(PointerDownEvent e) {
    _pointer = e.position;
    _ensureTicking();
  }

  void _onUp(PointerEvent e) {
    _pointer = null;
    _velocity = 0;
    _timer?.cancel();
    _timer = null;
  }

  /// 找到里面那个可滚动区域的控制器。
  ScrollController? _findController() {
    if (_controller != null && _controller!.hasClients) return _controller;
    ScrollController? found;
    void visit(Element el) {
      if (found != null) return;
      final w = el.widget;
      if (w is Scrollable && w.controller != null) {
        found = w.controller;
        return;
      }
      el.visitChildren(visit);
    }

    context.visitChildElements(visit);
    _controller = found;
    return found;
  }

  void _ensureTicking() {
    _timer ??= Timer.periodic(const Duration(milliseconds: 16), (_) {
      final v = _velocity;
      final c = _findController();
      if (v == 0 || c == null || !c.hasClients) return;
      final next = (c.offset + v).clamp(
        c.position.minScrollExtent,
        c.position.maxScrollExtent,
      );
      if (next != c.offset) c.jumpTo(next);
    });
  }

  /// 按指针离上下边缘的远近算滚动速度。
  void _updateVelocity() {
    final p = _pointer;
    final box = context.findRenderObject();
    if (p == null || box is! RenderBox || !box.hasSize) {
      _velocity = 0;
      return;
    }

    final top = box.localToGlobal(Offset.zero).dy;
    final bottom = top + box.size.height;
    final y = p.dy;

    if (y < top + _edge) {
      // 越靠上越快，最少也给 3px/帧，否则贴边了却几乎不动
      final t = ((top + _edge - y) / _edge).clamp(0.0, 1.0);
      _velocity = -(3 + (_maxSpeed - 3) * t);
    } else if (y > bottom - _edge) {
      final t = ((y - (bottom - _edge)) / _edge).clamp(0.0, 1.0);
      _velocity = 3 + (_maxSpeed - 3) * t;
    } else {
      _velocity = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onUp,
      child: widget.child,
    );
  }
}

// ── 三栏之间的拖拽分隔条 ──────────────────────────────────────────────────
/// 拖它来调整左右两栏的宽度。
///
/// 视觉上只画 1px 的线，但**命中区域给到 8px** ——
/// 1px 的线鼠标根本抓不住，这是可拖拽分隔条的常见坑。
class _PaneResizer extends StatefulWidget {
  const _PaneResizer({required this.onDrag, required this.onDragEnd});

  final void Function(double delta) onDrag;
  final VoidCallback onDragEnd;

  @override
  State<_PaneResizer> createState() => _PaneResizerState();
}

class _PaneResizerState extends State<_PaneResizer> {
  bool _hover = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final active = _hover || _dragging;

    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
        onHorizontalDragEnd: (_) {
          setState(() => _dragging = false);
          widget.onDragEnd();
        },
        onHorizontalDragCancel: () {
          setState(() => _dragging = false);
          widget.onDragEnd();
        },
        child: SizedBox(
          width: 8,
          child: Align(
            child: AnimatedContainer(
              duration: AppMotion.instant,
              width: active ? 2 : 0.5,
              height: double.infinity,
              color: active ? c.tint : c.separator,
            ),
          ),
        ),
      ),
    );
  }
}

/// 批量移动的目标：id 为 null 表示「未分类」。
///
/// 用一个包装类而不是裸 `int?`，是因为 null 同时表示"取消"和"未分类"，
/// 直接返回 `int?` 分不清这两种情况。
class _MoveTarget {
  const _MoveTarget(this.value);
  final int? value;
}

// ── 拖拽载荷 ──────────────────────────────────────────────────────────────
// 用一个统一的 Object 通道承载两种拖拽：笔记、文件夹。
// 目标区按运行时类型分派，比开两个 DragTarget 更省事。

class NoteDrag {
  const NoteDrag(this.note);
  final Note note;
}

class CollectionDrag {
  const CollectionDrag(this.collection);
  final Collection collection;
}

/// 给控件套上「可拖出去」。
///
/// 桌面直接拖（鼠标按下即起拖），手机长按起拖——
/// 手机上直接拖会跟列表滚动抢手势。
class _DraggableItem extends StatelessWidget {
  const _DraggableItem({
    required this.data,
    required this.label,
    required this.icon,
    required this.child,
    this.accent,
  });

  final Object data;
  final String label;
  final IconData icon;
  final Widget child;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final feedback = _DragChip(label: label, icon: icon, accent: accent);
    final whenDragging = Opacity(opacity: 0.35, child: child);

    if (isDesktopPlatform()) {
      return Draggable<Object>(
        data: data,
        // 让拖拽影像跟着指针走，而不是从控件左上角偏移
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: feedback,
        childWhenDragging: whenDragging,
        child: child,
      );
    }
    return LongPressDraggable<Object>(
      data: data,
      feedback: feedback,
      childWhenDragging: whenDragging,
      child: child,
    );
  }
}

/// 拖拽文件夹时，落点在目标行的哪个位置。
enum DropSpot {
  /// 插到目标**前面**（同级）
  before,

  /// 变成目标的**子文件夹**
  into,

  /// 插到目标**后面**（同级）
  after,
}

/// 接收投放的区域。悬停时按落点位置给出不同的提示。
///
/// 上/下 30% 是同级排序，中间 40% 是嵌套 —— 这是树形拖拽的通行做法：
/// 只给一种行为的话，用户就没法既排序又调层级。
class _DropZone extends StatefulWidget {
  const _DropZone({
    required this.child,
    this.onNote,
    this.onCollectionDrop,
  });

  final Widget child;

  /// 接收笔记：把笔记移到这个文件夹。
  final void Function(Note note)? onNote;

  /// 接收文件夹：按落点决定排序还是嵌套。
  final void Function(Collection col, DropSpot spot)? onCollectionDrop;

  @override
  State<_DropZone> createState() => _DropZoneState();
}

class _DropZoneState extends State<_DropZone> {
  DropSpot _spot = DropSpot.into;

  DropSpot _spotFor(Offset globalPosition) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize || box.size.height <= 0) {
      return DropSpot.into;
    }
    final r = box.globalToLocal(globalPosition).dy / box.size.height;
    if (r < 0.3) return DropSpot.before;
    if (r > 0.7) return DropSpot.after;
    return DropSpot.into;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return DragTarget<Object>(
      onWillAcceptWithDetails: (d) {
        if (d.data is NoteDrag) return widget.onNote != null;
        if (d.data is CollectionDrag) return widget.onCollectionDrop != null;
        return false;
      },
      onMove: (d) {
        if (d.data is! CollectionDrag) return;
        final next = _spotFor(d.offset);
        if (next != _spot) setState(() => _spot = next);
      },
      onLeave: (_) {
        if (mounted) setState(() => _spot = DropSpot.into);
      },
      onAcceptWithDetails: (d) {
        final data = d.data;
        if (data is NoteDrag) {
          widget.onNote?.call(data.note);
        } else if (data is CollectionDrag) {
          widget.onCollectionDrop?.call(data.collection, _spot);
          setState(() => _spot = DropSpot.into);
        }
      },
      builder: (context, candidates, rejected) {
        final active = candidates.isNotEmpty;
        final nest = active && _spot == DropSpot.into;

        // 用 Stack 叠加提示线，而不是在上下插入新行 ——
        // 后者会在拖拽过程中改变布局高度，导致整列抖一下。
        return Stack(
          children: [
            AnimatedContainer(
              duration: AppMotion.instant,
              margin: const EdgeInsets.symmetric(vertical: 1),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: nest ? c.tint : Colors.transparent,
                  width: 1.5,
                ),
                color:
                    nest ? c.tint.withValues(alpha: 0.10) : Colors.transparent,
              ),
              child: widget.child,
            ),
            if (active && _spot == DropSpot.before)
              Positioned(top: 0, left: 4, right: 4, child: _line(c)),
            if (active && _spot == DropSpot.after)
              Positioned(bottom: 0, left: 4, right: 4, child: _line(c)),
          ],
        );
      },
    );
  }

  Widget _line(AppColors c) => Container(
    height: 2.5,
    decoration: BoxDecoration(
      color: c.tint,
      borderRadius: BorderRadius.circular(2),
    ),
  );
}

/// 拖拽时跟着指针的小标签。
class _DragChip extends StatelessWidget {
  const _DragChip({required this.label, required this.icon, this.accent});

  final String label;
  final IconData icon;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = accent ?? c.tint;
    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 240),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(9),
          boxShadow: const <BoxShadow>[
            BoxShadow(
              color: Color(0x38000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.white),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption1.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 左栏导航行 ────────────────────────────────────────────────────────────

class _NavGroupLabel extends StatelessWidget {
  const _NavGroupLabel(this.text, {this.onAdd});
  final String text;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 16, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: AppText.caption1.copyWith(
                color: c.tertiaryLabel,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
          ),
          if (onAdd != null)
            Tooltip(
              message: '新建文件夹',
              child: Pressable(
                onTap: onAdd,
                scale: 0.85,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.add_rounded, size: 16, color: c.tint),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 文件夹前面的收起/展开小三角。
///
/// 命中区域给到 15px 见方，比图标本身大 —— 这个小东西点起来本来就费劲，
/// 做成"看得见但点不中"比不放还糟。
class _CollapseToggle extends StatelessWidget {
  const _CollapseToggle({
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
      // 只吃自己这块的点击，不能让整行也跟着被选中
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 15,
        height: 20,
        // 三角转 90° 用带过冲的弹簧：转到头会"甩"过一点再收回来。
        // 隐式动画没有回弹，转起来是"转过去、停住"，很死。
        child: SpringAnimatedValue(
          value: collapsed ? 0 : 0.25,
          spring: AppMotion.bouncy,
          builder: (context, v) => Transform.rotate(
            angle: v * 2 * math.pi,
            child: Icon(
              Icons.chevron_right_rounded,
              size: 16,
              color: color,
            ),
          ),
        ),
      ),
    );
  }
}

class _NavRow extends StatefulWidget {  const _NavRow({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
    this.color,
    this.indent = false,
    this.depth = 0,
    this.pinned = false,
    this.hasChildren = false,
    this.collapsed = false,
    this.onToggleCollapse,
    this.onMenu,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int? count;
  final Color? color;
  final bool indent;

  /// 嵌套层级，每一层缩进一点。
  final int depth;

  /// 置顶的给一个小图钉，否则用户看不出来哪些被钉住了。
  final bool pinned;

  /// 有没有子文件夹。有才显示收起/展开的小三角 ——
  /// 叶子节点前面挂个三角会让人以为"点了能展开"，点下去却没反应。
  final bool hasChildren;

  /// 子级是否已收起。
  final bool collapsed;

  /// 点小三角收起/展开。为空表示这一行不可收纳。
  final VoidCallback? onToggleCollapse;

  /// 传了就在悬停时露出 ⋯ 按钮（目前只有文件夹用）。
  final void Function(AppMenuAnchor anchor)? onMenu;

  @override
  State<_NavRow> createState() => _NavRowState();
}

class _NavRowState extends State<_NavRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final accent = widget.color ?? c.tint;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: AppMotion.enter,
          margin: const EdgeInsets.symmetric(vertical: 1),
          padding: EdgeInsets.only(
            left: (widget.indent ? 22 : 10) + widget.depth * 13,
            right: 6,
            top: 7,
            bottom: 7,
          ),
          decoration: BoxDecoration(
            color: widget.selected
                ? accent.withValues(alpha: c.isDark ? 0.22 : 0.13)
                : (_hover ? c.fill : Colors.transparent),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              // 收起/展开的小三角。**只有真的有子文件夹时才显示**，
              // 否则叶子节点前面挂个三角，点下去没反应，很困惑。
              if (widget.hasChildren)
                _CollapseToggle(
                  collapsed: widget.collapsed,
                  color: widget.selected ? accent : c.tertiaryLabel,
                  onTap: widget.onToggleCollapse,
                )
              else if (widget.indent)
                // 没子级的补一块等宽占位，让同级的名字左对齐
                const SizedBox(width: 15),
              Icon(
                widget.icon,
                size: 17,
                color: widget.selected ? accent : c.secondaryLabel,
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.footnote.copyWith(
                    color: widget.selected ? accent : c.label,
                    fontWeight:
                        widget.selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (widget.pinned)
                Padding(
                  padding: const EdgeInsets.only(left: 5),
                  child: Icon(Icons.push_pin, size: 11, color: c.tint),
                ),
              if (widget.onMenu != null && _hover)
                Builder(
                  builder: (btnCtx) => GestureDetector(
                    onTap: () => widget.onMenu!(AppMenuAnchor(context: btnCtx)),
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Icon(Icons.more_horiz_rounded,
                          size: 15, color: c.tertiaryLabel),
                    ),
                  ),
                )
              else if (widget.count != null && widget.count! > 0)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Text(
                    '${widget.count}',
                    style: AppText.caption1.copyWith(color: c.tertiaryLabel),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SortButton extends StatelessWidget {
  const _SortButton({required this.state});
  final AppState state;

  /// 把两组选项塞进一个菜单：值编码成 `f:xxx` / `d:xxx`。
  ///
  /// 用编码而不是两个菜单，是因为 Windows 资源管理器就是**一个面板里分两段**，
  /// 用户点开一次就能同时看到「按什么排」和「正着还是倒着」。
  static const String _fieldPrefix = 'f:';
  static const String _dirPrefix = 'd:';

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final sort = state.filter.sort;

    return Builder(
      // 用按钮自己的 context 做锚点，菜单才会贴着它弹
      builder: (btnCtx) => Tooltip(
        message: '排序',
        child: Pressable(
          onTap: () async {
            final picked = await showAppMenu<String>(
              btnCtx,
              anchor: AppMenuAnchor(context: btnCtx),
              header: '排序',
              items: <AppMenuItem<String>>[
                for (final f in SortField.values)
                  AppMenuItem(
                    value: '$_fieldPrefix${f.name}',
                    label: f.label,
                    icon: sort.field == f
                        ? Icons.check_circle_rounded
                        : Icons.circle_outlined,
                    color: sort.field == f ? c.tint : null,
                  ),
                for (final d in SortDir.values)
                  AppMenuItem(
                    value: '$_dirPrefix${d.name}',
                    label: '${d.label} ${d.arrow}',
                    icon: sort.dir == d
                        ? Icons.check_circle_rounded
                        : Icons.unfold_more_rounded,
                    color: sort.dir == d ? c.tint : null,
                    // 方向是另一组选项，画条线分开
                    dividerBefore: d == SortDir.values.first,
                  ),
              ],
            );
            if (picked == null) return;

            if (picked.startsWith(_fieldPrefix)) {
              final name = picked.substring(_fieldPrefix.length);
              final f = SortField.values.firstWhere((x) => x.name == name);
              // 换字段时**保留方向** —— 两次点击是独立的，不该互相重置
              state.setSort(NoteSort.of(f, sort.dir));
            } else {
              final name = picked.substring(_dirPrefix.length);
              final d = SortDir.values.firstWhere((x) => x.name == name);
              state.setSort(NoteSort.of(sort.field, d));
            }
          },
          scale: 0.94,
          child: Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 9),
            decoration: BoxDecoration(
              color: c.fill,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.swap_vert_rounded,
                    size: 14, color: c.secondaryLabel),
                const SizedBox(width: 4),
                Text(
                  '排序',
                  style: AppText.caption1.copyWith(color: c.secondaryLabel),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── 中栏瀑布流卡片 ────────────────────────────────────────────────────────

/// 中栏只有 200px 左右一格，所以卡片只放封面 + 标题 + 时间，
/// 摘要放不下（放了也只会变成一行省略号，反而更乱）。
class _NoteGridCard extends StatefulWidget {
  const _NoteGridCard({
    required this.note,
    required this.imageRoot,
    required this.selected,
    required this.onTap,
    required this.onActions,
    required this.displayTime,
  });

  final Note note;
  final String imageRoot;
  final bool selected;
  final VoidCallback onTap;
  final void Function(AppMenuAnchor anchor) onActions;

  /// 跟着排序字段走的时间。
  final DateTime displayTime;

  @override
  State<_NoteGridCard> createState() => _NoteGridCardState();
}

class _NoteGridCardState extends State<_NoteGridCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final n = widget.note;
    final hasCover = n.coverImage != null && n.coverImage!.isNotEmpty;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Pressable(
        onTap: widget.onTap,
        onSecondaryTap: (pos) => widget.onActions(AppMenuAnchor.at(pos)),
        scale: 0.98,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: AppMotion.enter,
          decoration: BoxDecoration(
            color: c.secondaryBackground,
            borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
            border: Border.all(
              color: widget.selected
                  ? c.tint
                  : (c.isDark
                      ? c.separator.withValues(alpha: 0.4)
                      : const Color(0x0F000000)),
              width: widget.selected ? 1.5 : 0.5,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasCover)
                    AspectRatio(
                      aspectRatio: 16 / 11,
                      child: Image.file(
                        File(p.join(widget.imageRoot, n.coverImage!)),
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => ColoredBox(color: c.fill),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(9, 7, 9, 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            if (n.isPinned)
                              Padding(
                                padding: const EdgeInsets.only(right: 3),
                                child:
                                    Icon(Icons.push_pin, size: 10, color: c.tint),
                              ),
                            Expanded(
                              child: Text(
                                n.title.isEmpty ? '无标题笔记' : n.title,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: AppText.caption1.copyWith(
                                  color:
                                      n.title.isEmpty ? c.tertiaryLabel : c.label,
                                  fontWeight: FontWeight.w600,
                                  height: 1.35,
                                ),
                              ),
                            ),
                            if (n.isFavorite)
                              Icon(Icons.star_rounded,
                                  size: 11, color: c.palette[7]),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          [
                            formatRelative(widget.displayTime),
                            if (n.charCount > 0) '${n.charCount} 字',
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              AppText.caption2.copyWith(color: c.tertiaryLabel),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              // ⋯ 按钮必须放在**整张卡片**这一层，不能塞进封面里 ——
              // 之前放在封面 Stack 内，导致没有封面的笔记（新建的都是纯文字）
              // 完全没有操作入口。
              if (_hover)
                Positioned(
                  top: 4,
                  right: 4,
                  child: Builder(
                    builder: (btnCtx) => Pressable(
                      onTap: () =>
                          widget.onActions(AppMenuAnchor(context: btnCtx)),
                      scale: 0.88,
                      child: Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          // 有封面时压在图上，用深色底 + 白图标才看得清；
                          // 纯文字卡片用浅色底，否则会像块膏药
                          color: hasCover
                              ? Colors.black.withValues(alpha: 0.45)
                              : c.fill,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.more_horiz_rounded,
                          size: 14,
                          color: hasCover ? Colors.white : c.secondaryLabel,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── 中栏列表行 ────────────────────────────────────────────────────────────

class _NoteListRow extends StatefulWidget {
  const _NoteListRow({
    required this.note,
    required this.selected,
    required this.onTap,
    required this.onActions,
    required this.displayTime,
  });

  final Note note;
  final bool selected;
  final VoidCallback onTap;
  final void Function(AppMenuAnchor anchor) onActions;

  /// 跟着排序字段走的时间。
  final DateTime displayTime;

  @override
  State<_NoteListRow> createState() => _NoteListRowState();
}

class _NoteListRowState extends State<_NoteListRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final n = widget.note;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Pressable(
        onTap: widget.onTap,
        onSecondaryTap: (pos) => widget.onActions(AppMenuAnchor.at(pos)),
        scale: 0.99,
        opacity: 0.85,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: AppMotion.enter,
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.fromLTRB(11, 9, 8, 9),
          decoration: BoxDecoration(
            color: widget.selected
                ? c.tint.withValues(alpha: c.isDark ? 0.20 : 0.12)
                : (_hover ? c.secondaryBackground : Colors.transparent),
            borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (n.isPinned)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Icon(Icons.push_pin, size: 11, color: c.tint),
                    ),
                  Expanded(
                    child: Text(
                      n.title.isEmpty ? '无标题笔记' : n.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.footnote.copyWith(
                        color: n.title.isEmpty ? c.tertiaryLabel : c.label,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (n.isFavorite)
                    Icon(Icons.star_rounded, size: 12, color: c.palette[7]),
                  // 悬停时露出操作入口，避免只能靠右键才发现
                  if (_hover)
                    Builder(
                      builder: (btnCtx) => GestureDetector(
                        onTap: () =>
                            widget.onActions(AppMenuAnchor(context: btnCtx)),
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 6),
                          child: Icon(Icons.more_horiz_rounded,
                              size: 15, color: c.tertiaryLabel),
                        ),
                      ),
                    ),
                ],
              ),
              if (n.excerpt.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  n.excerpt,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption1.copyWith(
                    color: c.secondaryLabel,
                    height: 1.45,
                  ),
                ),
              ],
              const SizedBox(height: 5),
              Row(
                children: [
                  if (n.collectionColor != null) ...[
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: Color(n.collectionColor!),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(
                      <String>[
                        formatRelative(widget.displayTime),
                        if (n.collectionName != null && n.collectionName!.isNotEmpty)
                          n.collectionName!,
                        if (n.charCount > 0) '${n.charCount} 字',
                      ].join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption2.copyWith(color: c.tertiaryLabel),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
