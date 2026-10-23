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
import '../../core/motion/folder_tree_motion.dart';
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
import '../privacy/privacy_transition.dart';
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
        // 两个 controller（侧栏收放 + 占满收放），所以不能再用 Single
        with
        TickerProviderStateMixin {
  _Section _section = _Section.notes;

  /// 切页时的滑入方向：1 = 从右边进来（往后翻），-1 = 从左边进来（往前翻）。
  ///
  /// 原来永远从右边滑 2%：点回上一个入口也是从右边冒出来，方向跟视线对不上。
  int _sectionDir = 1;
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
  final FolderTreeMotion _folderMotion = FolderTreeMotion();
  Set<int> get _collapsed => _folderMotion.collapsed;

  /// 文件夹列表的滚动控制器。拖拽靠近边缘时用它自动滚。
  final ScrollController _folderScroll = ScrollController();

  /// 正文栏是否展开。
  ///
  /// 默认收起：一进应用是「导航 + 列表」两栏。
  /// 点某篇笔记或新建一篇时才把正文栏拉出来 ——
  /// 这样冷启动不会先甩给用户一块空白。
  bool _detailOpen = false;

  /// 关闭时保留正文子树，等滑出完成后再拆掉，避免中途变成空白。
  bool _detailMounted = false;
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

  /// 导航栏曲线的只读视图：**只建一次**。
  ///
  /// 收起与展开都按 enter 的节奏运行；反向曲线需翻转坐标，
  /// 不能直接倒放展开曲线。持久对象也保留中途反向的位置连续性。
  late final CurvedAnimation _navCurve = CurvedAnimation(
    parent: _navAnim,
    curve: AppMotion.enter,
    reverseCurve: AppMotion.enter.flipped,
  );
  late final Animation<double> _navIconTurns = _navCurve.drive(
    Tween<double>(begin: 0.5, end: 0),
  );

  /// "占满页面"的进度：0 = 三栏都在，1 = 三栏收起（正文占满整窗）。
  ///
  /// 以前这里是个 bool，布局直接写 `fullscreenEditor ? 0 : navW` ——
  /// 于是**退出**占满的第一帧，列表栏宽度瞬间等于"整块剩余宽度"，
  /// 先铺满全屏，正文再从右边插进来。用户看到的就是
  /// "退出占满怎么是从右边冒出来的动画"。改成补间之后，收放方向由
  /// 宽度本身表达：列表从左边长回来、正文原地缩回右边。
  late final AnimationController _fsAnim = AnimationController(
    vsync: this,
    duration: AppMotion.normal,
    value: _editorFullscreen ? 1 : 0,
  );

  /// 正文栏自己的进度。独立 controller 避免动画期间反复创建隐式动画，
  /// 也让侧栏、正文、全屏切换可以共用同一个帧节奏。
  late final AnimationController _detailAnim = AnimationController(
    vsync: this,
    duration: AppMotion.normal,
    value: 0,
  );

  /// 三栏布局要跟着**两个**动画走：侧栏收放 + 占满收放。
  /// `Listenable.merge` 的返回值只会被 AnimatedBuilder 订阅一次，
  /// 所以把它存下来，别每帧新建（每帧新建就是每帧重新订阅一遍）。
  late final Listenable _paneTicker = Listenable.merge(<Listenable>[
    _navAnim,
    _fsAnim,
    _detailAnim,
  ]);

  /// 切"占满页面"（三栏收起）。所有入口都走这里，动画才跟得上。
  void _setEditorFullscreen(bool fullscreen) {
    if (_editorFullscreen == fullscreen) return;
    setState(() => _editorFullscreen = fullscreen);
    _syncFullscreenAnim();
  }

  /// 让 [_fsAnim] 跟上"占满"的目标状态。
  ///
  /// 目标不只看 `_editorFullscreen`：换分栏、选中态被清掉、关掉详情栏
  /// 都会让 [fullscreenEditor] 变成 false —— 那些路径不必各自记得收动画，
  /// 只要在改完之后调一次这里。
  void _syncFullscreenAnim() {
    if (AppMotion.reduceMotion(context)) {
      _fsAnim.value = fullscreenEditor ? 1 : 0;
      return;
    }
    if (fullscreenEditor) {
      if (_fsAnim.value < 1 && _fsAnim.status != AnimationStatus.forward) {
        _fsAnim.forward();
      }
    } else {
      if (_fsAnim.value > 0 && _fsAnim.status != AnimationStatus.reverse) {
        _fsAnim.reverse();
      }
    }
  }

  void _setNavCollapsed(bool collapsed) {
    if (_navCollapsed == collapsed) return;
    setState(() => _navCollapsed = collapsed);
    if (AppMotion.reduceMotion(context)) {
      _navAnim.value = collapsed ? 0 : 1;
    } else {
      collapsed ? _navAnim.reverse() : _navAnim.forward();
    }
  }

  Future<void> _toggleWindowFullscreen() async {
    _setState(() => _windowFullscreen = !_windowFullscreen);
    await setAppFullscreen(_windowFullscreen);
  }

  void _syncDetailAnim() {
    final target =
        _detailOpen &&
            (_section == _Section.notes || _section == _Section.archived)
        ? 1.0
        : 0.0;
    if (AppMotion.reduceMotion(context)) {
      _detailAnim.value = target;
    } else if (target == 1.0) {
      _detailAnim.forward();
    } else {
      _detailAnim.reverse();
    }
  }

  void _onDetailAnimationStatus(AnimationStatus status) {
    if (status != AnimationStatus.dismissed || _detailOpen || !mounted) return;
    // 等正文真正滑出后再清掉选中项/编辑态。关闭动画期间继续保留原来的
    // 编辑器或阅读页，避免第一帧就换成加载中的新页面而出现白屏。
    if (_selectedNoteId != null || _editing || _detailMounted) {
      setState(() {
        _selectedNoteId = null;
        _editing = false;
        _detailMounted = false;
      });
    }
  }

  // ── 文件夹树：展开/收起"一个一个来" ──────────────────────────────────────
  //
  // 以前 `_collapsed` 一翻，子树就在同一帧里整块出现/消失，一片东西
  // "啪"地闪一下，看不出谁挂在谁底下。现在给本批次里的每一行派一个
  // 出场序号（[_revealOrder]），行自己延迟 28ms × 序号再淡入滑出。
  //
  // 收起比展开多一件事：动画期间子树必须**留在树里**滑出去，
  // 所以先记进 [_collapsing]（[_flattenTree] 把它当"还开着"），
  // 等最后一行收完再真正写进 `_collapsed`。

  Map<int, int> get _revealOrder => _folderMotion.revealOrder;
  Set<int> get _collapsing => _folderMotion.collapsing;

  /// 按左栏显示顺序取出某文件夹的全部后代 id（从浅到深）。
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

  /// 正在收起的那些**后代行**（用来给每一行标 `exiting`）。
  ///
  /// 注意**不包括父文件夹自己**：父行要留着（名字还在、小三角当场翻过来），
  /// 只有子树滑出去。之前把父 id 也塞进这个集合了，于是父行自己也被标成
  /// `exiting`、反向动画到 0 —— 表现就是"文件夹一收起，它自己也整个不见了"，
  /// 而且收完之后没人再把它放回可见，只能等组件被重建。
  Set<int> _collapsingRows(List<Collection> all) {
    if (_collapsing.isEmpty) return const <int>{};
    final out = <int>{};
    for (final id in _collapsing) {
      out.addAll(_descendantsInOrder(id, all));
    }
    return out;
  }

  /// 点小三角：展开，或者带着交错动画收起。
  void _toggleFolderCollapsed(Collection col, List<Collection> all) {
    _folderMotion.toggle(
      col.id,
      _descendantsInOrder(col.id, all),
      reduceMotion: AppMotion.reduceMotion(context),
    );
  }

  void _onFolderMotion() {
    if (mounted) setState(() {});
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
    _folderMotion.addListener(_onFolderMotion);
    _detailAnim.addStatusListener(_onDetailAnimationStatus);
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
    _detailAnim.removeStatusListener(_onDetailAnimationStatus);
    _folderMotion.removeListener(_onFolderMotion);
    _folderMotion.dispose();
    _navCurve.dispose();
    _navAnim.dispose();
    _fsAnim.dispose();
    _detailAnim.dispose();
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
    // Clicking the open card toggles the same panel closed; while it is
    // closing, another click can reverse the animation and open it again.
    if (_detailOpen && _selectedNoteId == id) {
      _exitAllFullscreen();
      _closeDetail();
      return;
    }
    setState(() {
      _selectedNoteId = id;
      _editing = false;
      _editorFullscreen = false;
      _detailOpen = true;
      _detailMounted = true;
    });
    _syncDetailAnim();
    _syncFullscreenAnim();
  }

  /// 收起正文栏。顺手清掉选中态和编辑态，
  /// 否则下次展开会莫名其妙地回到上次那篇的编辑中。
  void _closeDetail() {
    setState(() {
      _detailOpen = false;
      _editorFullscreen = false;
      // 选中态也一起清掉。之前只关面板、留着 _selectedNoteId，列表里那一行
      // 还会是蓝底 —— 面板都收起来了，行却还是"选中"的样子，点它还会因为
      // 同一篇而重新打开，看起来像"关不掉"。
      _selectedNoteId = null;
    });
    _syncDetailAnim();
    _syncFullscreenAnim();
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
    final dangling =
        f == null ||
        identical(f, FocusManager.instance.rootScope) ||
        (f is FocusScopeNode && identical(f, ours));
    if (!dangling) return;
    // requestFocus 会在下一帧应用，不需要自己再排一帧
    _workspaceFocus.requestFocus();
  }

  /// 打开标签管理页（左栏标签区那个小齿轮、以及设置里那一行都走这里）。
  void _openTagManager(BuildContext context) {
    Navigator.of(context)
        .push(ApplePageRoute<void>(pageBuilder: (_) => const ManageTagsPage()));
  }

  /// 左栏里这些入口的**视觉顺序**。
  ///
  /// 跟枚举顺序不一样：枚举是 notes/archived/todos/...，而左栏底下那组从上往下
  /// 是 待办 → 归档 → 回收站 → 统计 → 设置。滑入方向按视觉顺序算才对得上视线。
  static int _sectionRank(_Section s) => switch (s) {
    _Section.notes => 0,
    _Section.todos => 1,
    _Section.archived => 2,
    _Section.trash => 3,
    _Section.stats => 4,
    _Section.settings => 5,
  };

  /// 记下这次切页该往哪边滑（往后翻进、往前翻退）。
  void _updateSectionDir(_Section next) {
    final from = _sectionRank(_section);
    final to = _sectionRank(next);
    if (to != from) _sectionDir = to > from ? 1 : -1;
  }

  void _goSection(_Section s) {
    setState(() {
      _updateSectionDir(s);
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
    _syncDetailAnim();
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
          _syncFullscreenAnim();
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
            _setEditorFullscreen(false);
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
  ///    内容先淡出再接入图标列。同样用 OverflowBox 让
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

    // ── 先把三栏里"贵"的子树建好，再进动画 ──────────────────────────────
    //
    // 以前它们在动画 builder **里面**构造：收起/展开侧栏的每一帧都要重建
    // 导航树（文件夹递归展开、每个文件夹一行）+ 笔记列表 + 正文（一篇文章
    // 可能有几百个段落控件）。这就是"收起侧栏有明显卡顿感"的主因。
    //
    // 现在每次 build 只构造一次，动画的每一帧都复用**同一批 widget 实例**——
    // Flutter 对 identical 的 widget 会直接跳过 rebuild，只重新布局。
    final navRail = _navRail(context, state);
    final navPane = _navPane(context, state);
    final listPane = _listPane(context, state, notes);
    final sectionPage = _sectionSwitcher(state);
    final detailPane = _detailPane(
      context,
      state,
      fullscreen: fullscreenEditor,
    );

    return LayoutBuilder(
      builder: (context, box) {
        final avail = box.maxWidth;

        // 正文开合保持稳定排版；侧栏收放时宽度跟随实际进度，
        // 不能在点击第一帧提前采用目标宽度，否则文字和头图会跳位。
        return AnimatedBuilder(
          // 侧栏收放 + 占满收放共用同一段布局，只是"谁在变宽变窄"不同
          animation: _paneTicker,
          builder: (context, _) {
            // 宽度 = 收起宽 → 用户设的宽度，按进度插值。
            // 拖动时进度锁在 1，所以宽度**直接跟手**，没有 300ms 的拖尾。
            final navT = _navCurve.value;
            final navW = railWidth + (_navWidth - railWidth) * navT;
            // 对齐的图标轨道始终垫底，展开内容覆盖其上。
            // 分阶段淡出/淡入会在交接处把两层都变透明，造成闪空。
            // 上层连同底色一起淡出，重合的图标无需再次淡入。
            const railOpacity = 1.0;
            final paneOpacity = navT;
            // 0 = 三栏，1 = 三栏收起（占满）
            final fs = _fsAnim.value;
            final navPaneW = navW * (1 - fs);

            final t = Curves.easeOut.transform(_detailAnim.value);
            return Builder(
              builder: (context) {
                // 分隔条也要算进宽度：**漏算就是 8px 溢出**（Row 里
                // 每多一个分隔条就少 8px 可用宽度）
                //
                // 占满时分隔条跟着一起收窄到 0，不再占宽度。
                final navResW = resizerWidth * _navCurve.value * (1 - fs);
                final areaW = math.max(0.0, avail - navPaneW - navResW);
                // 关闭动画还在跑的时候**必须继续渲染**（否则没有滑出动画），
                // 动画归零后立刻拆掉 —— 留一个 0 宽的编辑器在树里，
                // 既浪费又会让"正文栏收起"这件事在语义上说不清。
                final withDetail = showNotesSection && _detailMounted;

                /// 这一栏渲染的是"正文/笔记内容"（而不是列表或统计页）
                final isDetailPane = withDetail || fullscreenEditor;
                // 正文的**排版宽度**在"三栏态"和"占满态"之间按 fs 连续插值。
                //
                // 以前这里是个二选一（占满就整窗宽、否则固定栏宽），于是
                // 切换的第一帧宽度就"啪"地跳过去：进入时正文已经按整窗宽排好、
                // 从左往右被一点点露出来（看着像"从右边冒出来"），退出时反过来
                // 先跳回窄栏再让列表长回来。改成插值之后，正文跟着补间连续
                // 变宽变窄 —— 退出占满就是"缩回右边"。
                //
                // 侧栏变化与正文可用宽度使用同一进度，快速反向也连续。
                final settledDetailW = math.max(
                  0.0,
                  avail -
                      navW -
                      resizerWidth * navT -
                      _listWidth -
                      resizerWidth,
                );
                final contentW = settledDetailW + (avail - settledDetailW) * fs;
                final listResW = (withDetail && t > 0.001)
                    ? resizerWidth * (1 - fs)
                    : 0.0;

                // 列表栏：从"整块让给正文"补间到用户设的宽度，再乘上
                // "占满"的收放 —— 占满时收到 0 宽（滑向左边），退出占满时
                // 从左往右长回来，正文**原地缩回右边**。
                var listW = (!withDetail)
                    ? areaW
                    : (areaW * (1 - t) + _listWidth * t) * (1 - fs);
                // 列表栏最多占到"剩余空间减去正文栏分隔条"，否则会挤爆
                listW = listW.clamp(0.0, math.max(0.0, areaW - listResW));
                final detailW = math.max(0.0, areaW - listW - listResW);
                // 内容槽里装的是正文时按 [contentW] 排版；装的是列表或
                // 统计页时就按它自己的格子宽（否则列表会被挤到右边去）
                final layoutW = isDetailPane ? contentW : areaW;

                return Row(
                  children: [
                    // 导航栏：占满时收到 0 宽（滑向左边）。
                    // 宽度还没归零就继续渲染，归零后拆掉 —— 不留 0 宽的树。
                    if (fs < 0.999)
                      SizedBox(
                        key: const ValueKey('nav-column'),
                        width: navPaneW,
                        child: ClipRect(
                          child: ColoredBox(
                            color: context.colors.isDark
                                ? const Color(0xFF141416)
                                : const Color(0xFFF7F7FA),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                Offstage(
                                  offstage: navT == 1,
                                  child: IgnorePointer(
                                    ignoring: !_navCollapsed,
                                    child: ExcludeFocus(
                                      excluding: !_navCollapsed,
                                      child: Opacity(
                                        key: const ValueKey('nav-rail-opacity'),
                                        opacity: railOpacity,
                                        // RepaintBoundary 必须是 Opacity 的**直接**
                                        // 子节点：这样侧栏内容被缓存成一层，每帧只换
                                        // 透明度，不再逐帧重新光栅化整棵树。
                                        child: RepaintBoundary(
                                          child: OverflowBox(
                                            alignment: Alignment.centerLeft,
                                            // minWidth 必须显式给 0：外面那个
                                            // SizedBox 是**紧约束**，不覆盖的话
                                            // 会出现 minWidth > maxWidth 的非法约束
                                            // （动画途中直接抛 assertion）
                                            minWidth: 0,
                                            maxWidth: railWidth,
                                            child: navRail,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                Offstage(
                                  offstage: paneOpacity == 0,
                                  child: IgnorePointer(
                                    ignoring: _navCollapsed,
                                    child: ExcludeFocus(
                                      excluding: _navCollapsed,
                                      child: Opacity(
                                        key: const ValueKey('nav-pane-opacity'),
                                        opacity: paneOpacity,
                                        child: RepaintBoundary(
                                          child: OverflowBox(
                                            alignment: Alignment.centerLeft,
                                            minWidth: 0,
                                            maxWidth: _navWidth,
                                            child: navPane,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    // 分隔条按**目标状态**给：展开着就一直有。
                    // 以前按动画值 navT 判断，拖动时 navT 会掉下来，
                    // 分隔条被从树里拿掉 —— 手还按着，拖拽就此中断
                    // （用户说的"拉着拉着断掉"）。占满时它跟着收窄到 0。
                    // 占满过程中分隔条要**跟着一起变窄**：宽度按 navResW
                    // 给死。不夹这一下的话，公式里只扣了 8*(1-fs)，
                    // 而分隔条自己仍按 8 宽渲染 —— 多出来的 8*fs 就是
                    // 退出/进入占满时那几像素的 Row 溢出。
                    if (navResW > 0.5)
                      SizedBox(
                        width: navResW,
                        child: _PaneResizer(
                          onDrag: _dragNavWidth,
                          onDragEnd: _saveWidths,
                        ),
                      ),

                    // 列表栏始终留在中栏位置。冷启动的两栏状态也从这里渲染，
                    // 打开正文时只补间它的宽度，避免列表从最后的内容槽突然搬家。
                    if (showNotesSection && fs < 0.999) ...[
                      SizedBox(
                        // 只给测试/调试用：量"列表栏这一格"的宽度，
                        // 用它钉住"退出占满时列表从左边长回来"
                        key: const ValueKey<String>('list-column'),
                        width: withDetail ? listW : areaW,
                        child: ClipRect(
                          child: RepaintBoundary(
                            child: OverflowBox(
                              alignment: Alignment.centerLeft,
                              minWidth: 0,
                              maxWidth: withDetail
                                  ? math.max(_listWidth, listW)
                                  : areaW,
                              child: listPane,
                            ),
                          ),
                        ),
                      ),
                      if (withDetail && listResW > 0.5)
                        SizedBox(
                          width: listResW,
                          child: _PaneResizer(
                            onDrag: (d) => setState(
                              () => _listWidth = (_listWidth + d).clamp(
                                _listMin,
                                _listMax,
                              ),
                            ),
                            onDragEnd: _saveWidths,
                          ),
                        ),
                    ],
                    // **正文栏/内容栏只在这一处渲染。**
                    //
                    // 关键：不管"正文栏开着""全屏编辑""其它分栏"，这一段的
                    // 包装层级（SizedBox → ClipRect → Opacity → OverflowBox）
                    // 必须**完全一致**，只有宽度和内容不同。层级一旦不同，
                    // Flutter 就认不出"还是那一栏"，切换全屏时编辑器会被
                    // 重建 —— 正在写还没保存的内容就丢了。
                    // 正文栏只做“右侧裁切”动画：内容固定在最终位置，
                    // 不随 Row 宽度每帧重新布局。这样图片、长文和输入框
                    // 都不会在展开/收起时反复重排而闪白。
                    if (isDetailPane || !showNotesSection)
                      SizedBox(
                        // key 区分"这一栏现在装的是正文还是列表"：
                        // 内容不同就该是不同的 element；而"正文栏在笔记分栏
                        // ↔ 全屏编辑之间切换"用的是同一个 key、同一套包装层级，
                        // 于是编辑器的 State 会被复用（未保存的字不会丢）。
                        key: const ValueKey<String>('detail-pane'),
                        // **withDetail 而不是 isDetailPane**：detailW 只有在
                        // "列表栏也在场"时才有意义；全屏编辑时列表不在场，
                        // 用 detailW 会算出 0 宽（内容被推到屏幕左侧外面）
                        width: withDetail ? detailW : areaW,
                        child: ClipRect(
                          // 用 Stack 把内容固定在最终宽度，并从右侧裁切。
                          // 外层只改变“露出多少”，正文不会因每一帧拿到不同
                          // 的约束而重新排版、闪白或重新解码图片。
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Positioned(
                                top: 0,
                                bottom: 0,
                                right: isDetailPane ? 0 : null,
                                left: isDetailPane ? null : 0,
                                width: layoutW,
                                child: RepaintBoundary(
                                  child: isDetailPane
                                      ? detailPane
                                      : sectionPage,
                                ),
                              ),
                            ],
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
      _updateSectionDir(_Section.notes);
      _section = _Section.notes;
      _selectedNoteId = id;
      _editing = true;
      _editorFullscreen = false;
      // 新建必然要把正文栏拉出来，否则用户看不到自己刚建的东西
      _detailOpen = true;
      _detailMounted = true;
    });
    _syncDetailAnim();
    _syncFullscreenAnim();
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
    // 这个函数可能正被别的 setState 闭包调用，所以这里只改字段 + 让动画
    // 跟上，不再套一层 setState（调用方随后一定会重建）。
    if (_editorFullscreen) {
      _editorFullscreen = false;
      _syncFullscreenAnim();
    }
  }

  /// 分栏页面之间的切换动画。
  ///
  /// 以前是**瞬间替换**：点「统计」整块内容"啪"地换掉，层级关系断了。
  /// 现在用 [AnimatedSwitcher]：旧页淡出，新页从侧面 2% 处轻微滑入
  /// —— 幅度很小（不是整页平移），够表达"换了一页"，又不至于让人等动画。
  /// 按 [_section] 给 key，切换时 Flutter 才认得出"这是另一页"。
  ///
  /// 方向跟着 [_sectionDir] 走：往后翻 = 新页从右边进、旧页往左退；往前翻反过来。
  /// 以前不管往哪翻都从右边冒出来，往回翻时方向是反的。
  Widget _sectionSwitcher(AppState state) {
    final page = KeyedSubtree(
      key: ValueKey<String>('section-${_section.name}'),
      child: _sectionPage(state),
    );
    final currentKey = 'section-${_section.name}';
    return AnimatedSwitcher(
      duration: AppMotion.respecting(context, AppMotion.normal),
      switchInCurve: AppMotion.enter,
      switchOutCurve: AppMotion.exit,
      transitionBuilder: (child, anim) {
        // KeyedSubtree 的 key 就是上面那个 ValueKey：认出这是新页还是旧页，
        // 好让两页朝相反方向走（推进感），而不是一起朝同一边挪。
        final incoming = (child.key as ValueKey<String>?)?.value == currentKey;
        final from = 0.02 * _sectionDir * (incoming ? 1 : -1);
        return FadeTransition(
          opacity: anim,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: Offset(from, 0),
              end: Offset.zero,
            ).animate(anim),
            child: child,
          ),
        );
      },
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
