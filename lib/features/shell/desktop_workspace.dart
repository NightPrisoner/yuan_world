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

part 'workspace_widgets.dart';

enum _Section { notes, archived, todos, stats, trash, settings }

/// 品牌头的内边距。**展开态和收起态共用**。
///
/// 收起态的轨道里必须留出同样高度的头部，两边的"收起/展开"开关才会
/// 落在同一条水平线上 —— 以前收起态开头只有一个 `SizedBox(height: 10)`，
/// 而展开态开关上面压着 56px 的品牌头，点一下开关它自己会往上跳 48px。
const EdgeInsets _kBrandPad = EdgeInsets.fromLTRB(18, 18, 18, 12);

/// logo 标的边长。
const double _kBrandMarkSize = 26;

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

  /// 导出整个文集（含子文件夹）为压缩包。
  ///
  /// 包内保留目录层级：`文集/子文件夹/标题.docx`。
  /// 用的是和批量导出**同一个** [NoteExporter.zipBytes]，
  /// 区别只是每篇的 path 换成它自己在文集树里的位置。
  Future<void> _exportCollection(Collection col) async {
    final state = context.read<AppState>();
    // 必须走 notesForExport —— 它会把正文一起取出来。
    // listNotes 走的是不含 content 列的轻量查询，直接拿它的结果去导出，
    // 出来的 docx 全是空壳（正文一个字都没有），用户报的正是这个问题。
    final notes = state.repo.notesForExport(collectionId: col.id);
    if (!mounted) return;
    if (notes.isEmpty) {
      _toast('「${col.name}」里还没有笔记');
      return;
    }

    final format = await pickExportFormat(context, header: '导出格式');
    if (format == null || !mounted) return;

    await exportZip(
      context,
      items: <({List<String> path, Note note})>[
        for (final n in notes)
          (path: collectionPathOf(n, state.collections), note: n),
      ],
      format: format,
      // 压缩包名用文集名，用户一眼知道这是哪一包
      zipName: '${NoteExporter.safeZipName(col.name)}.zip',
    );
  }

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
          body: _panes(context, state, notes, fullscreenEditor),
        ),
      ),
    );
  }

  /// 三栏布局（导航 / 列表 / 正文），**两个动画都在这里**。
  ///
  /// 1. 正文栏：打开时从**右边滑进来**，收起时滑回右边。
  ///    做法是把列表栏的宽度从"占满"补间到用户设的宽度，正文栏吃下剩下的
  ///    空间；正文栏内容按**最终宽度**排版（OverflowBox）再被裁剪、
  ///    并跟着动画淡入 —— 这样文字不会在动画过程中反复回流重排，
  ///    观感是"面板从右侧推出来"，而不是"内容被压扁"。
  ///
  /// 2. 导航栏：收起/展开是宽度的补间（58 ↔ 用户设的宽度），
  ///    内容交叉淡入（收起时只留一列图标）。同样用 OverflowBox 让
  ///    面板按原宽度排版、被"帘子"一样裁掉，而不是挤成一团。
  ///
  /// 两者用同一个 [AppMotion.normal] 时长和 [AppMotion.enter] 曲线，
  /// 和页面切换的节奏一致。
  Widget _panes(
    BuildContext context,
    AppState state,
    List<Note> notes,
    bool fullscreenEditor,
  ) {
    // 收起态的导航栏宽度：10 + 38 + 10，让图标列和展开态同一条竖线
    const double railWidth = 58;
    const double resizerWidth = 8;
    final showNotesSection =
        _section == _Section.notes || _section == _Section.archived;

    return LayoutBuilder(
      builder: (context, box) {
        final avail = box.maxWidth;

        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: _navCollapsed ? railWidth : _navWidth),
          duration: AppMotion.normal,
          curve: AppMotion.enter,
          builder: (context, navW, _) {
            // 0 = 完全收起，1 = 完全展开
            final navT =
                ((navW - railWidth) / math.max(1, _navWidth - railWidth))
                    .clamp(0.0, 1.0);
            final navPaneW = fullscreenEditor ? 0.0 : navW;

            return TweenAnimationBuilder<double>(
              // 正文栏：只有"笔记分栏 + 非全屏"才展开
              tween: Tween<double>(
                end: (_detailOpen && showNotesSection && !fullscreenEditor)
                    ? 1.0
                    : 0.0,
              ),
              duration: AppMotion.normal,
              curve: AppMotion.enter,
              builder: (context, t, _) {
                // 分隔条也要算进宽度：**漏算就是 8px 溢出**（Row 里
                // 每多一个分隔条就少 8px 可用宽度）
                final navResW =
                    (!fullscreenEditor && navT > 0.99) ? resizerWidth : 0.0;
                final areaW = math.max(0.0, avail - navPaneW - navResW);
                // 正文栏"该展开"的目标状态
                final detailTarget =
                    _detailOpen && showNotesSection && !fullscreenEditor;
                // 关闭动画还在跑的时候**必须继续渲染**（否则没有滑出动画），
                // 动画归零后立刻拆掉 —— 留一个 0 宽的编辑器在树里，
                // 既浪费又会让"正文栏收起"这件事在语义上说不清。
                //
                // 全屏编辑时**立即**不渲染列表栏：那时 t 还在从 1 掉到 0，
                // 若跟着 t 走，列表会在全屏的第一帧里闪一下。
                final withDetail = !fullscreenEditor &&
                    showNotesSection &&
                    (_detailOpen || t > 0.001);
                /// 这一栏渲染的是"正文/笔记内容"（而不是列表或统计页）
                final isDetailPane = withDetail || fullscreenEditor;
                final listResW =
                    (withDetail && t > 0.001) ? resizerWidth : 0.0;

                // 列表栏：从"占满"补间到用户设的宽度
                var listW = (!withDetail) ? areaW : areaW * (1 - t) + _listWidth * t;
                // 列表栏最多占到"剩余空间减去正文栏分隔条"，否则会挤爆
                listW = listW.clamp(0.0, math.max(0.0, areaW - listResW));
                final detailW =
                    math.max(0.0, areaW - listW - listResW);
                // 正文栏内容按**最终**宽度排版（动画过程中不回流重排）
                final settledDetailW = math.max(
                  0.0,
                  areaW - _listWidth - resizerWidth,
                );

                return Row(
                  children: [
                    if (!fullscreenEditor)
                      SizedBox(
                        width: navW,
                        child: ClipRect(
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (navT < 1)
                                Opacity(
                                  opacity: 1 - navT,
                                  child: OverflowBox(
                                    alignment: Alignment.centerLeft,
                                    // minWidth 必须显式给 0：外面那个
                                    // SizedBox 是**紧约束**，不覆盖的话
                                    // 会出现 minWidth > maxWidth 的非法约束
                                    // （动画途中直接抛 assertion）
                                    minWidth: 0,
                                    maxWidth: railWidth,
                                    child: _navRail(context, state),
                                  ),
                                ),
                              if (navT > 0)
                                Opacity(
                                  opacity: navT,
                                  child: OverflowBox(
                                    alignment: Alignment.centerLeft,
                                    minWidth: 0,
                                    maxWidth: _navWidth,
                                    child: _navPane(context, state),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    // 展开态才给分隔条：收起时那 58px 没什么好拖的
                    if (!fullscreenEditor && navT > 0.99)
                      _PaneResizer(
                        onDrag: (d) => setState(
                          () => _navWidth =
                              (_navWidth + d).clamp(_navMin, _navMax),
                        ),
                        onDragEnd: _saveWidths,
                      ),

                    if (withDetail) ...[
                      SizedBox(
                        width: listW,
                        child: _listPane(context, state, notes),
                      ),
                      if (t > 0.001)
                        _PaneResizer(
                          onDrag: (d) => setState(
                            () => _listWidth =
                                (_listWidth + d).clamp(_listMin, _listMax),
                          ),
                          onDragEnd: _saveWidths,
                        ),
                    ],
                    // **正文栏/内容栏只在这一处渲染。**
                    //
                    // 关键：不管"正文栏开着""全屏编辑""其它分栏"，这一段的
                    // 包装层级（SizedBox → ClipRect → Opacity → OverflowBox）
                    // 必须**完全一致**，只有宽度和内容不同。层级一旦不同，
                    // Flutter 就认不出"还是那一栏"，切换全屏时编辑器会被
                    // 重建 —— 正在写还没保存的内容就丢了。
                    SizedBox(
                      // key 区分"这一栏现在装的是正文还是列表"：
                      // 内容不同就该是不同的 element；而"正文栏在笔记分栏
                      // ↔ 全屏编辑之间切换"用的是同一个 key、同一套包装层级，
                      // 于是编辑器的 State 会被复用（未保存的字不会丢）。
                      key: isDetailPane
                          ? const ValueKey<String>('detail-pane')
                          : const ValueKey<String>('list-pane'),
                      // **withDetail 而不是 isDetailPane**：detailW 只有在
                      // "列表栏也在场"时才有意义；全屏编辑时列表不在场，
                      // 用 detailW 会算出 0 宽（内容被推到屏幕左侧外面）
                      width: withDetail ? detailW : areaW,
                      child: ClipRect(
                        child: Opacity(
                          opacity: isDetailPane ? Curves.easeOut.transform(t) : 1,
                          child: OverflowBox(
                            // 内容按最终宽度排版、被右侧裁掉 ——
                            // 观感就是"面板从右边推进来"，而不是被压扁重排
                            alignment: Alignment.centerRight,
                            minWidth: 0,
                            maxWidth: withDetail ? settledDetailW : areaW,
                            child: isDetailPane
                                ? _detailPane(
                                    context,
                                    state,
                                    fullscreen: fullscreenEditor,
                                  )
                                : showNotesSection
                                    ? _listPane(context, state, notes)
                                    : _sectionPage(state),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
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

  /// 品牌标。用**真 logo 资源**，不再是手画的渐变色块。
  ///
  /// 以前这里是一个 `LinearGradient` 色块 + `Icons.auto_awesome` 的占位图，
  /// 和 exe 图标（`assets/branding/logo.png` 生成的那套）长得完全不一样 ——
  /// 用户看到的是一个紫色小方块，而不是自己给的 logo。
  ///
  /// 资源读不出来时退回那个占位色块：侧栏左上角空一块比图标不精致更糟。
  Widget _brandMark(AppColors c) => Image.asset(
    'assets/branding/logo.png',
    width: _kBrandMarkSize,
    height: _kBrandMarkSize,
    // logo 自带圆角和透明外角，直接用就好，不用再裁
    fit: BoxFit.cover,
    filterQuality: FilterQuality.medium,
    errorBuilder: (_, _, _) => Container(
      width: _kBrandMarkSize,
      height: _kBrandMarkSize,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [c.palette[0], c.palette[4]],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.auto_awesome, size: 15, color: Colors.white),
    ),
  );

  /// 左栏顶部的标识。隐私空间里换成醒目的提示 + 退出按钮 ——
  /// 「现在看的是哪一套数据」必须一眼可见，否则容易误操作。
  Widget _brandHeader(AppColors c, AppState state) {
    if (!state.privacyMode) {
      return Padding(
        padding: _kBrandPad,
        child: Row(
          children: [
            _brandMark(c),
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
            // ── 头部：只留 logo 标，**高度和展开态一模一样** ──
            //
            // 这是"收起/展开开关同一条水平线"的关键。以前这里只有
            // `SizedBox(height: 10)`，而展开态开关上面压着整个品牌头
            // （18 + 26 + 12 = 56），于是点一下开关，它自己往上跳 48px。
            // 留出同样高度的头部之后，两种状态下开关的 y 就一致了。
            Padding(
              // 不能 const：常量对象上取不到 .top（Dart 的常量求值限制）
              padding: EdgeInsets.only(
                top: _kBrandPad.top,
                bottom: _kBrandPad.bottom,
              ),
              child: SizedBox(
                height: _kBrandMarkSize,
                child: Center(child: _brandMark(c)),
              ),
            ),
            Tooltip(
              message: '展开侧栏',
              child: Pressable(
                onTap: () => setState(() => _navCollapsed = false),
                scale: 0.9,
                child: Container(
                  // **和展开态那个 _NavRow 用同一套 margin + padding**。
                  //
                  // 只对齐外框是不够的：展开态的箭头是包在
                  // `margin 1 + padding 7` 里的行内图标，收起态原来是个
                  // 光秃秃的 38px 方块 —— 外框差了 8px，图标中心也跟着差。
                  // 补齐这两层之后，两边的箭头中心才落在同一条水平线上。
                  margin: const EdgeInsets.symmetric(vertical: 1),
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: SizedBox(
                    width: 38,
                    child: Center(
                      child: Icon(
                        Icons.chevron_right_rounded,
                        size: 16,
                        color: c.secondaryLabel,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 展开态里开关下面紧跟着第一项，这里也留同样的间距
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
