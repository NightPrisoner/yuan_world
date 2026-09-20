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
import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../core/motion/app_motion.dart';
import '../../core/platform/window_mode.dart';
import '../../core/motion/apple_page_route.dart';
import '../../core/shortcuts/app_shortcuts.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_menu.dart';
import '../../core/widgets/local_image.dart';
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
import '../tags/manage_tags_page.dart';
import '../todos/todos_page.dart';
import '../trash/trash_page.dart';

part 'workspace_actions.dart';
part 'workspace_folders.dart';
part 'workspace_nav.dart';
part 'workspace_panes.dart';
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

class _DesktopWorkspaceState extends State<DesktopWorkspace>
    with SingleTickerProviderStateMixin {
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

  /// 正文栏是否展开。
  ///
  /// 默认收起：一进应用是「导航 + 列表」两栏。
  /// 点某篇笔记或新建一篇时才把正文栏拉出来 ——
  /// 这样冷启动不会先甩给用户一块空白。
  bool _detailOpen = false;
  final TextEditingController _search = TextEditingController();

  /// 搜索框的焦点：`Ctrl+F` 要能把光标送进去。
  final FocusNode _searchFocus = FocusNode();

  /// 工作区自己的焦点节点。快捷键层挂在它外面（见 build），
  /// 所以**它有没有焦点决定了 Ctrl+N 这些能不能按**。
  final FocusNode _workspaceFocus = FocusNode(debugLabel: 'workspace');

  // ── 三栏宽度（可拖动） ──
  // 上限给得比较宽松：宽屏下用户可能想把列表栏拉得很宽看瀑布流
  static const double _navMin = 160;
  static const double _navMax = 560;
  static const double _listMin = 220;
  static const double _listMax = 1100;

  double _navWidth = 236;
  double _listWidth = 316;

  /// 导航栏"收起 ↔ 展开"的进度：1 = 展开，0 = 收起。
  ///
  /// 单独用一个 controller，而不是从宽度反推：
  /// **拖动宽度**时宽度在变，但从"收起度"这个角度看它一直是"展开"的。
  /// 以前用 `(当前宽 - 58) / (目标宽 - 58)` 当进度，一拖就把自己算成
  /// "收起了一半"，于是内容开始交叉淡入、分隔条还被从树里拿掉 ——
  /// 拖拽当场中断。分成两个量之后，拖动只动宽度，收起/展开只动进度。
  late final AnimationController _navAnim = AnimationController(
    vsync: this,
    duration: AppMotion.normal,
    value: 1,
  );

  void _setNavCollapsed(bool collapsed) {
    if (_navCollapsed == collapsed) return;
    setState(() => _navCollapsed = collapsed);
    collapsed ? _navAnim.reverse() : _navAnim.forward();
  }

  /// 拖左侧分隔条：**直接跟手**，不走动画。
  void _dragNavWidth(double delta) {
    setState(() => _navWidth = (_navWidth + delta).clamp(_navMin, _navMax));
    // 拖动期间进度锁死在"展开"，缩放的补间也就不需要了
    _navAnim.value = 1;
  }

  @override
  void initState() {
    super.initState();
    _restoreWidths();
    // 焦点一有变化就看看是不是"悬空"了（见 [_refocusIfDangling]）
    FocusManager.instance.addListener(_refocusIfDangling);
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

  /// 给四个 `part` 文件里的扩展方法用。
  ///
  /// 扩展不是 `State` 的子类，里面直接调 `setState` 会被判成"用了受保护
  /// 成员"（`@protected`，只是警告，但没必要留一堆噪音）。这里开一个
  /// 同库内的转发口，行为完全一样。
  void _setState(VoidCallback fn) => setState(fn);

  @override
  void dispose() {
    FocusManager.instance.removeListener(_refocusIfDangling);
    _navAnim.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _workspaceFocus.dispose();
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

  /// Ctrl+F：把光标送进搜索框，并**选中已有内容**。
  ///
  /// 选中是有意的：连按两次 Ctrl+F 然后直接打字，就是"改搜索词"，
  /// 不用先全选或退格 —— 这是 macOS/Windows 上搜索快捷键的共同约定。
  void _focusSearch() {
    // 分区不对（比如正在统计页）时先切回笔记区：搜索框只在那一栏里，
    // 而且它要等下一帧才建出来。
    if (_section != _Section.notes && _section != _Section.archived) {
      _goSection(_Section.notes);
      // 注意：`addPostFrameCallback` 自己**不会**要一帧，界面闲着的时候
      // 这个回调可能永远不跑（Ctrl+F 就这么静默失效过）—— 所以只有在
      // setState 已经安排好下一帧的情况下才用它。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _grabSearchFocus();
      });
      return;
    }
    _grabSearchFocus();
  }

  void _grabSearchFocus() {
    _searchFocus.requestFocus();
    _search.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _search.text.length,
    );
  }

  /// 焦点掉到"作用域"上（而不是某个真控件）时，把它要回工作区。
  ///
  /// 为什么要管这个：按键是从**当前焦点**一路往祖先冒泡的，工作区的
  /// 快捷键层在焦点节点外面；焦点一旦落到包着我们的那个作用域上
  /// （unfocus、弹窗收掉、编辑器关掉拆节点都会），冒泡路径里就没有
  /// 快捷键层了 —— Ctrl+N / Ctrl+F 全部静默失效。
  ///
  /// **不能无脑抢**：弹窗、别的路由有自己的作用域，焦点落在它们身上时
  /// 说明用户正在那边操作，抢回来会打断键盘导航。所以只在"焦点就是
  /// 我们自己那个作用域"（或者干脆没有焦点）时才要回来。
  void _refocusIfDangling() {
    final f = FocusManager.instance.primaryFocus;
    final ours = _workspaceFocus.nearestScope;
    final dangling = f == null ||
        identical(f, FocusManager.instance.rootScope) ||
        (f is FocusScopeNode && identical(f, ours));
    if (!dangling) return;
    // requestFocus 会在下一帧应用，不需要自己再排一帧
    _workspaceFocus.requestFocus();
  }

  /// 打开标签管理页（左栏标签区那个小齿轮、以及设置里那一行都走这里）。
  void _openTagManager(BuildContext context) {
    Navigator.of(context).push(
      ApplePageRoute<void>(pageBuilder: (_) => const ManageTagsPage()),
    );
  }

  void _goSection(_Section s) {    setState(() {
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

    // 焦点"悬空"的时候把工作区接回来：编辑器关掉、输入框被 unfocus、
    // 弹窗收掉……都可能让焦点落到某个**作用域**上，而快捷键收不到按键
    // （按键从焦点往上冒泡，作用域在快捷键层外面）—— 表现就是
    // "快捷键时灵时不灵"，最难查。
    //
    // 挂在 FocusManager 上而不是"每次 build 查一次"：崩掉的那一刻
    // 往往**没有重建**（unfocus 不会触发 build），查不到。

    return CallbackShortcuts(
      // 按键 → 动作的对照表来自 core/shortcuts（帮助面板读的是同一份，
      // 所以"面板里写的"和"实际能按的"不可能对不上）
      bindings: bindShortcuts(<String, VoidCallback>{
        AppShortcutIds.newNote: () => _createNote(state),
        AppShortcutIds.search: _focusSearch,
        // 只在"阅读态"里进入编辑：编辑态里 Ctrl+E 由编辑器自己处理
        // （它才知道怎么安全地存盘退出，见 note_editor_page.dart）
        AppShortcutIds.edit: () {
          if (!_editing && _selectedNoteId != null && listSection) {
            setState(() => _editing = true);
          }
        },
        AppShortcutIds.allNotes: () => _goSection(_Section.notes),
        AppShortcutIds.archived: () => _goSection(_Section.archived),
        AppShortcutIds.todos: () => _goSection(_Section.todos),
        AppShortcutIds.stats: () => _goSection(_Section.stats),
        AppShortcutIds.trash: () => _goSection(_Section.trash),
        AppShortcutIds.settings: () => _goSection(_Section.settings),
        AppShortcutIds.help: () => showShortcutHelp(context),
        // Esc 退出全屏。全屏之后没有任何可见的"退出"提示，
        // 不给个键盘出口用户会以为卡住了。
        // 从外往里退：先退**窗口**全屏，再退**占满页面**。
        AppShortcutIds.exitFullscreen: () {
          if (_windowFullscreen) {
            setState(() => _windowFullscreen = false);
            setAppFullscreen(false);
            return;
          }
          if (_editorFullscreen) {
            setState(() => _editorFullscreen = false);
          }
        },
      }),
      // **顺序很重要**：焦点节点必须在快捷键层**里面**。
      //
      // 按键是从当前焦点一路往上冒泡的，所以只有"焦点是 Shortcuts 的后代"
      // 时才收得到。反过来（Focus 包着 Shortcuts）焦点落在外面，
      // 绑什么键都永远不会触发 —— 这个错误的表现就是"快捷键全都没反应"，
      // 而且外观上一点异常都没有，很难查。
      child: Focus(
        focusNode: _workspaceFocus,
        autofocus: true,
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

        return AnimatedBuilder(
          animation: _navAnim,
          builder: (context, _) {
            // 宽度 = 收起宽 → 用户设的宽度，按进度插值。
            // 拖动时进度锁在 1，所以宽度**直接跟手**，没有 300ms 的拖尾。
            final progress =
                CurvedAnimation(parent: _navAnim, curve: AppMotion.enter).value;
            final navW = railWidth + (_navWidth - railWidth) * progress;
            // 0 = 完全收起，1 = 完全展开（用于内容交叉淡入）
            final navT = _navAnim.value;
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
                //
                // 注意判断用的是 `_navCollapsed`（**目标状态**）而不是动画值
                // `navT`：拖动宽度时 navT 会因为"当前宽度 / 目标宽度"的比值
                // 掉到 1 以下，分隔条就会被从树里拿掉 —— 手正按着它，
                // 结果是"拉着拉着就断了"（用户报的正是这个）。
                final navResW =
                    (!fullscreenEditor && !_navCollapsed) ? resizerWidth : 0.0;
                final areaW = math.max(0.0, avail - navPaneW - navResW);
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
                    // 分隔条按**目标状态**给：展开着就一直有。
                    // 以前按动画值 navT 判断，拖动时 navT 会掉下来，
                    // 分隔条被从树里拿掉 —— 手还按着，拖拽就此中断
                    // （用户说的"拉着拉着断掉"）。
                    if (!fullscreenEditor && !_navCollapsed)
                      _PaneResizer(
                        onDrag: _dragNavWidth,
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
                          // **只用 withDetail 判断淡入淡出。**
                          //
                          // 之前写的是 `isDetailPane ? f(t) : 1`，而 t 是
                          // "正文栏展开度"：全屏编辑时它的目标值是 0（那种情况
                          // 压根不是"滑入"），于是整层被设成透明度 0 ——
                          // 编辑器在树里、鼠标也点得到（widget 测试查得到文字），
                          // 但屏幕上**一片白**。这就是"占满页面后白屏"。
                          opacity: withDetail ? Curves.easeOut.transform(t) : 1,
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
                                    : _sectionSwitcher(state),
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

  /// 分栏页面之间的切换动画。
  ///
  /// 以前是**瞬间替换**：点「统计」整块内容"啪"地换掉，层级关系断了。
  /// 现在用 [AnimatedSwitcher]：旧页淡出，新页从右侧 2% 处轻微滑入
  /// —— 幅度很小（不是整页平移），够表达"换了一页"，又不至于让人等动画。
  /// 按 [_section] 给 key，切换时 Flutter 才认得出"这是另一页"。
  Widget _sectionSwitcher(AppState state) {
    final page = KeyedSubtree(
      key: ValueKey<String>('section-${_section.name}'),
      child: _sectionPage(state),
    );
    return AnimatedSwitcher(
      duration: AppMotion.normal,
      switchInCurve: AppMotion.enter,
      switchOutCurve: AppMotion.exit,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0.02, 0),
            end: Offset.zero,
          ).animate(anim),
          child: child,
        ),
      ),
      child: page,
    );
  }

  Widget _sectionPage(AppState state) => switch (_section) {
    _Section.todos => const TodosPage(),
    _Section.stats => const StatsPage(),
    _Section.trash => const TrashPage(embedded: true),
    _Section.settings => const SettingsPage(),
    // 归档复用中间那栏的笔记列表，不需要单独页面
    _Section.notes || _Section.archived => const SizedBox.shrink(),
  };

  // ── 左栏：分类导航 ──────────────────────────────────────────────────────

  // ── 中栏：笔记列表 ──────────────────────────────────────────────────────

  /// 左栏是否已收起成一条窄条。
  bool _navCollapsed = false;

  // ── 拖拽落地 ────────────────────────────────────────────────────────────

  // ── 文集的右键/⋯ 菜单 ───────────────────────────────────────────────────

  // ── 右栏：阅读 / 编辑 ───────────────────────────────────────────────────

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
