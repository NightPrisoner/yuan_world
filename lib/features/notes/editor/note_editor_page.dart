/// 笔记编辑器。
///
/// 相比之前的裸 TextField，这一版补齐了：
///   - 标题与正文分离（标题不再靠"取第一行"猜）
///   - 底部格式工具栏：标题级别 / 加粗 / 斜体 / 删除线 / 引用 / 列表 /
///     待办 / 链接 / 行内代码 / 分割线
///   - 编辑 ↔ 预览切换（预览用的是详情页同一套排版）
///   - 自动保存（停止输入 1.2 秒后落库，标题栏显示保存状态）
///   - 撤销 / 重做
///
/// 工具栏放在底部而不是顶部：手机上键盘弹起时它会跟着抬起，
/// 手指够得着；桌面端也不受影响。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../app_state.dart';
import '../../../core/motion/app_motion.dart';
import '../../../core/shortcuts/app_shortcuts.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/text_stats.dart';
import '../../../core/utils/toc.dart';
import '../../../core/widgets/app_menu.dart';
import '../../../core/widgets/local_image.dart';
import '../../../data/media/media_counts.dart';
import '../../../data/media/media_importer.dart';
import '../../../data/models.dart';
import 'body_segments.dart';
import 'markdown_controller.dart';
import 'markdown_editing.dart';
import '../widgets/field_blocks.dart';
import '../widgets/media_card.dart';
import '../widgets/note_link_picker.dart';
import '../widgets/toc_panel.dart';
import '../../../data/repositories/note_repository.dart';

/// 媒体块外面套的悬停壳：鼠标进来才把删除键露出来。
///
/// 单独做成 widget（而不是在编辑器里存一个"当前悬停的是谁"）：
/// 正文里可能有几十个媒体，用编辑器的 State 记悬停目标会让**整篇**
/// 每次都重建；各自的悬停各自管，只有被指到的那一个会重绘。
class _MediaHover extends StatefulWidget {
  const _MediaHover({
    super.key,
    required this.builder,
    this.alwaysShowButton = false,
  });

  final Widget Function(bool hovering) builder;

  /// 触屏端没有 hover：直接常显，否则删不掉。
  final bool alwaysShowButton;

  @override
  State<_MediaHover> createState() => _MediaHoverState();
}

class _MediaHoverState extends State<_MediaHover> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) {
        if (!_hovering) setState(() => _hovering = true);
      },
      onExit: (_) {
        if (_hovering) setState(() => _hovering = false);
      },
      child: widget.builder(widget.alwaysShowButton || _hovering),
    );
  }
}

/// 媒体块右上角的删除键（毛玻璃小圆钮）。
class _MediaDeleteButton extends StatelessWidget {
  const _MediaDeleteButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: '删掉这个文件',
      child: Pressable(
        onTap: onTap,
        scale: 0.9,
        child: Container(
          width: 30,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: c.secondaryBackground.withValues(alpha: 0.92),
            shape: BoxShape.circle,
            border: Border.all(color: c.separator, width: 0.5),
          ),
          child: Icon(
            Icons.delete_outline_rounded,
            size: 17,
            color: c.destructive,
          ),
        ),
      ),
    );
  }
}

class NoteEditorPage extends StatefulWidget {
  const NoteEditorPage({
    super.key,
    required this.noteId,
    this.embedded = false,
    this.onClose,
    this.fullscreen = false,
    this.onToggleFullscreen,
    this.windowFullscreen = false,
    this.onToggleWindowFullscreen,
  });

  final int noteId;

  /// 嵌入三栏布局右侧面板时置 true：
  /// 不套 Scaffold/AppBar，工具栏改放顶部，并显示「完成」按钮。
  final bool embedded;

  /// 嵌入模式下由外部接管关闭动作。
  final VoidCallback? onClose;

  /// **内容**是否已占满整个应用窗口（三栏收起）。
  ///
  /// 注意它和 [windowFullscreen] 是**两件事**：
  /// 这个是"文章占满页面"，窗口本身没变。
  final bool fullscreen;

  /// 切换"占满页面"。为空则不显示对应按钮。
  final VoidCallback? onToggleFullscreen;

  /// **窗口**是否已切到无边框全屏（画面放大、盖住任务栏）。
  ///
  /// 和 [fullscreen] 分开是因为它们的作用域根本不同：
  /// 一个是应用内部的版式，一个是操作系统窗口。
  /// 混在一起做的后果就是用户点"占满页面"，整个屏幕却被放大了。
  final bool windowFullscreen;

  /// 切换窗口全屏。为空则不显示 ⛶ 按钮。
  final VoidCallback? onToggleWindowFullscreen;

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  final GlobalKey _headingButtonKey = GlobalKey();
  final GlobalKey _linkButtonKey = GlobalKey();
  late final AppState _appState;
  final TextEditingController _title = TextEditingController();
  // 用带实时样式的控制器：**加粗**、# 标题、`代码` 输入即生效
  final MarkdownEditingController _body = MarkdownEditingController();
  final FocusNode _bodyFocus = FocusNode();

  /// 快捷键层的焦点节点（Ctrl+S / Ctrl+E / Esc 靠它才收得到按键）。
  final FocusNode _shortcutFocus = FocusNode(debugLabel: 'editor-shortcuts');

  // ── 正文分段：让图片能在正文里显示出来 ──
  //
  // 单个 TextField 画不出图，所以正文被拆成「文字段 ↔ 图片」交替的块：
  // 文字段各是一个输入框，图片段渲染成真正的图。
  // 拼回必须无损，逻辑在 body_segments.dart 里并单独测过。
  List<BodySegment> _segments = const <BodySegment>[];
  final List<MarkdownEditingController> _segControllers = [];
  final List<FocusNode> _segFocus = [];

  /// 每段落一个 GlobalKey（目录跳转用）。
  final List<GlobalKey> _segKeys = [];

  /// 目录面板：开关、停靠侧、宽度。侧向和宽度跟设置走，和阅读页共享。
  bool _tocOpen = false;
  String _tocSide = 'right';
  double _tocWidth = 220;

  /// 正文那个滚动区（目录跳转要按偏移量精确滚）。
  final ScrollController _scroll = ScrollController();
  int? _focusedSegment;

  MarkdownEditingController? _toolbarSelectionController;
  TextSelection? _toolbarSelection;
  // 工具栏按钮按下时，TextField 可能已经先失焦。保留每个正文段最近一次
  // 有效选区，避免连续点「加粗 / 斜体 / 删除线」时选区被 Flutter 清掉。
  final Map<MarkdownEditingController, TextSelection> _segmentSelections =
      <MarkdownEditingController, TextSelection>{};

  void _rememberToolbarSelection() {
    final target = _activeBody;
    final selection = target.selection.isValid
        ? target.selection
        : _segmentSelections[target];
    if (selection != null && selection.isValid) {
      _toolbarSelectionController = target;
      _toolbarSelection = selection;
    }
  }

  /// 是否正有文件悬停在编辑区上方（画那层"松手即插入"的蒙层用）。
  bool _dragging = false;

  /// 工具栏该作用在哪个输入框上。
  ///
  /// 没有任何一段聚焦时（刚打开笔记、刚重建过分段）退回**第一个文字段** ——
  /// 不能退回 `_body`：它是个不挂在任何输入框上的模型，改它屏幕上什么都不动，
  /// 而 `****` 这类标记会被自动保存写进正文（阅读视图里看得见）。
  /// 用户点一下"加粗"结果什么反应都没有、正文里却多了标记，很莫名。
  MarkdownEditingController get _activeBody {
    final i = _focusedSegment;
    if (i != null && i >= 0 && i < _segControllers.length) {
      return _segControllers[i];
    }
    for (var k = 0; k < _segments.length && k < _segControllers.length; k++) {
      if (_segments[k] is TextSegment) return _segControllers[k];
    }
    return _body;
  }

  void _disposeSegments() {
    for (final c in _segControllers) {
      c.dispose();
    }
    for (final f in _segFocus) {
      f.dispose();
    }
    _segControllers.clear();
    _segFocus.clear();
    _segKeys.clear();
    _segmentSelections.clear();
    _focusedSegment = null;
  }

  void _rebuildSegments() {
    _disposeSegments();
    // ensureTextSegment：空笔记和纯图片正文都要补一个空文字段，
    // 否则编辑器里一个输入框都没有，用户打不了字
    _segments = ensureTextSegment(splitBodySegments(_body.text));

    for (var i = 0; i < _segments.length; i++) {
      final seg = _segments[i];
      final controller = MarkdownEditingController(
        text: seg is TextSegment ? seg.text : '',
      );
      final node = FocusNode();
      final index = i;
      node.addListener(() {
        if (node.hasFocus) _focusedSegment = index;
      });
      if (seg is TextSegment) {
        controller.addListener(() {
          final selection = controller.selection;
          if (selection.isValid) _segmentSelections[controller] = selection;
          _onSegmentChanged();
        });
        if (controller.selection.isValid) {
          _segmentSelections[controller] = controller.selection;
        }
      }
      _segControllers.add(controller);
      _segFocus.add(node);
      // 每段落一个 key：目录跳转要靠它 ensureVisible
      _segKeys.add(GlobalKey());
    }
  }

  /// 某一段文字变了 → 立刻拼回整体。
  ///
  /// 拼回后的文本是保存与统计的**唯一来源**，不另存一份，
  /// 否则两份状态迟早会不一致。
  void _onSegmentChanged() {
    final next = <BodySegment>[];
    for (var i = 0; i < _segments.length; i++) {
      final seg = _segments[i];
      next.add(seg is TextSegment ? TextSegment(_segControllers[i].text) : seg);
    }
    _segments = next;

    final joined = joinBodySegments(next);
    if (joined != _body.text) {
      _body.text = joined;
    } else if (mounted) {
      // Cursor-only moves must update the heading/format indicators too.
      setState(() {});
    }
  }

  Timer? _saveTimer;
  bool _loaded = false;

  /// 当前生效的标题级别（0 = 正文），供工具栏按钮显示状态。
  int get _headingLevel {
    final target = _activeBody;
    final at = target.selection.isValid ? target.selection.start : 0;
    final start = at == 0 ? 0 : target.text.lastIndexOf('\n', at - 1) + 1;
    final match = RegExp(r'^(#{1,6})\s+')
        .firstMatch(target.text.substring(start));
    return match?.group(1)?.length ?? 0;
  }

  // ── 撤销 / 重做 ─────────────────────────────────────────────────────────
  final List<TextEditingValue> _undoStack = <TextEditingValue>[];
  final List<TextEditingValue> _redoStack = <TextEditingValue>[];
  TextEditingValue? _lastValue;
  Timer? _snapshotTimer;
  bool _applyingHistory = false;

  /// 上一次落库时的标题与正文。用来判断"到底改没改"。
  String _savedTitle = '';
  String _savedBody = '';

  /// 上一次落库是否成功。**失败时必须让用户看见** ——
  /// 以前这里只按定时器状态显示"编辑中…/已自动保存"，`updateNote` 抛异常
  /// 时界面照样说"已自动保存"，用户关掉窗口就以为存上了。
  bool _saveFailed = false;

  /// 上次失败的原因，显示在提示条里。
  String _saveError = '';

  /// 后台重试定时器：保存失败后每隔几秒再试一次，直到成功。
  Timer? _retryTimer;

  /// 草稿落盘定时器。
  Timer? _draftTimer;

  /// 页面已经开始销毁。
  ///
  /// `dispose` 里会再存一次（切换笔记时桌面端可能不经过「完成」），
  /// 那次要是失败，[ _save ] 会排一个重试定时器 —— 而页面马上就没了，
  /// 这个定时器永远没人取消。用标志位挡住这种"僵尸重试"。
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _appState = state;
    _tocSide = state.tocSide;
    _tocWidth = state.tocWidth;
    final note = state.repo.getNote(widget.noteId);
    if (note != null) {
      _title.text = note.title;
      _body.text = note.content;
      // 记住"刚载入时长什么样"。保存时拿它比对 —— 内容没变就不写库，
      // 修改时间自然也不会变。进编辑器看一眼就退出不该留下痕迹。
      _savedTitle = note.title;
      _savedBody = note.content;
      _lastValue = _body.value;
      _rebuildSegments();
      // 有比库里更新的草稿？先问一句再决定用哪个。
      //
      // 正常关闭时保存成功会顺手删草稿，所以这里能命中只有两种情况：
      // 上次保存失败（用户在对话框里选了"先离开"），或者进程被强杀。
      _maybeRestoreDraft(note.title, note.content);
    }
    _loaded = true;
    // 草稿和库里内容一致（上一次其实存上了，只是删草稿那步失败），清掉
    _appState.repo.deleteDraftIfMatches(
      widget.noteId,
      title: _savedTitle,
      content: _savedBody,
    );
    _title.addListener(_markDirty);
    _body.addListener(_onBodyChanged);
    // 把焦点要过来，快捷键才生效（见 [_shortcuts]）。不等用户先点一下：
    // 打开笔记随手 Ctrl+S 是很自然的动作，那时候还得先点一下太别扭。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_shortcutFocus.hasFocus) _shortcutFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _saveTimer?.cancel();
    _snapshotTimer?.cancel();
    _retryTimer?.cancel();
    _draftTimer?.cancel();
    // Desktop selection/layout changes may remove this editor without going
    // through its Done button. Persist the pending draft before disposal;
    // avoid notifying widgets while their tree is being rebuilt.
    _save(notify: false);
    _title.removeListener(_markDirty);
    _body.removeListener(_onBodyChanged);
    _disposeSegments();
    _title.dispose();
    _body.dispose();
    _bodyFocus.dispose();
    _shortcutFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ── 保存 ────────────────────────────────────────────────────────────────

  void _markDirty() {
    _scheduleSave();
    setState(() {});
  }

  void _onBodyChanged() {
    if (!_applyingHistory) {
      // 以 700ms 为粒度记录快照，避免每个按键都进撤销栈
      if (_snapshotTimer == null || !_snapshotTimer!.isActive) {
        final prev = _lastValue;
        if (prev != null && prev.text != _body.text) {
          _undoStack.add(prev);
          if (_undoStack.length > 120) _undoStack.removeAt(0);
          _redoStack.clear();
        }
        _snapshotTimer = Timer(const Duration(milliseconds: 700), () {});
      }
      _lastValue = _body.value;
    }
    _scheduleSave();
    setState(() {});
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 1200), _save);
    // 草稿比正式保存更早落盘：它是"崩了也能找回来"的保险，
    // 落库只要 1.2 秒，草稿没理由等更久。
    _draftTimer?.cancel();
    _draftTimer = Timer(const Duration(milliseconds: 600), _persistDraft);
  }

  /// 把"现在屏幕上的内容"记进草稿表。
  ///
  /// 和自动保存的区别：草稿**不碰 notes 表**，只在崩溃/断电/强杀之后
  /// 能找回最近敲的东西。落库成功就删掉。
  void _persistDraft() {
    try {
      final title = _title.text.trim();
      final text = _body.text;
      if (title == _savedTitle && text == _savedBody) return;
      _appState.repo.saveDraft(
        noteId: widget.noteId,
        title: title,
        content: text,
      );
    } catch (_) {
      // 草稿写不进去不该影响输入
    }
  }

  /// 落库。返回**这次是不是真的写了**（没改动就什么都不做，返回 false）。
  ///
  /// 写库这一步是**可能失败的**（磁盘满、库被占用、权限）。以前这里
  /// 不做任何 try/catch：异常顺着定时器抛出去，界面上的"已自动保存"
  /// 照旧显示，用户以为存上了。现在失败会：记下原因、显示红色提示、
  /// 每隔几秒自动重试，并且退出前一定会再试一次。
  bool _save({bool notify = true}) {
    final text = _body.text;
    final title = _title.text.trim();

    // **内容没变就什么都不做。**
    //
    // updateNote 会顺带刷新 updated_at，所以"进编辑器看一眼就退出"
    // 会把修改时间改掉，列表里的排序也跟着乱跳。
    // 用字符串比对而不是靠 dirty 标志：不用在每个改动入口都记得打标记，
    // 漏一个就会退化成旧行为。
    if (title == _savedTitle && text == _savedBody) {
      // 内容没变但上一次是失败状态（比如空笔记第一次保存失败后
      // 用户又把内容删回原样）—— 清掉错误提示，别一直红着。
      if (_saveFailed) _clearSaveError(notify: notify);
      return false;
    }

    final state = _appState;
    try {
      // 真的要从旧内容改成新内容了 —— **先把旧内容记一条历史**。
      //
      // 放在 updateNote 之前：如果写失败了，历史里多一条旧版本没有坏处；
      // 放在之后的话，写成功后崩溃就再也拿不到旧内容了。
      state.repo.addRevision(
        noteId: widget.noteId,
        title: _savedTitle,
        content: _savedBody,
        reason: 'save',
      );
      state.repo.updateNote(
        id: widget.noteId,
        title: title,
        content: text,
        excerpt: makeExcerpt(text),
        charCount: countChars(text),
        wordCount: countWords(text),
        // 图片数也要重算，否则插了图那个数字还是旧的。
        //
        // 只算**图片**：以前这里是 mediaCountOf，把视频也计进
        // image_count，于是侧栏汇总的图片数比统计页多出视频那部分 ——
        // 同一个指标在两处对不上。视频另有自己的「N 视频」。
        imageCount: countNoteMedia(text).images,
      );
      // 落库成功：草稿这个"未确认现场"就可以删了
      try {
        state.repo.deleteDraft(widget.noteId);
      } catch (_) {
        // 删草稿失败不影响"已经存上了"这个事实
      }
      _savedTitle = title;
      _savedBody = text;
      _clearSaveError(notify: false);
      _retryTimer?.cancel();
      _retryTimer = null;
    } catch (e) {
      // 失败：留下现场，把原因放到界面上，并排一次后台重试
      _saveError = _describeSaveError(e);
      _saveFailed = true;
      _persistDraft();
      _scheduleRetry();
      if (notify && mounted) setState(() {});
      return false;
    }

    // **顺手让列表页知道内容变了。**
    //
    // 以前保存只写库、不发通知：手机上手势返回（不走 _flushAndLeave）以后
    // 回到列表，看到的还是旧标题/旧摘要，得下拉才刷新。这里用的是
    // `refreshListOnly()`（只重查列表那一条轻量查询），自动保存期间也扛得住。
    state.refreshListOnly(notify: notify, dataChanged: true);
    if (notify && mounted) setState(() {});
    return true;
  }

  /// 把异常翻译成用户能看懂的一句话。
  String _describeSaveError(Object e) {
    final raw = e.toString();
    if (raw.contains('database is locked') ||
        raw.contains('database is busy')) {
      return '数据库正被占用';
    }
    if (raw.contains('disk') && raw.contains('full')) {
      return '磁盘空间不足';
    }
    if (raw.contains('Permission') || raw.contains('denied')) {
      return '没有写入权限';
    }
    if (raw.contains('readonly') || raw.contains('read-only')) {
      return '文件是只读的';
    }
    // 兜底：保留原始信息的前一段，别把一屏堆栈塞进提示条
    final oneLine = raw.replaceAll(RegExp(r'\s+'), ' ');
    return oneLine.length <= 120 ? oneLine : '${oneLine.substring(0, 120)}…';
  }

  void _clearSaveError({bool notify = true}) {
    if (!_saveFailed) return;
    _saveFailed = false;
    _saveError = '';
    if (notify && mounted) setState(() {});
  }

  /// 保存失败后的自动重试：3 秒一次，成功为止。
  ///
  /// 不用指数退避：这类失败大多是暂时的（文件被占用），3 秒足够；
  /// 一直失败的话提示条本身就在提醒用户，不需要靠间隔变长来省资源。
  void _scheduleRetry() {
    if (_disposed) return;
    _retryTimer?.cancel();
    _retryTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      _save();
    });
  }

  /// 离开页面前强制落库。
  /// 打开编辑器时检查有没有没落库的草稿。
  ///
  /// 判定规则：
  ///   · 草稿跟库里内容一样 → 忽略（清理由 initState 末尾做）
  ///   · 草稿跟库里不一样   → 弹窗让用户选，默认**不覆盖**库里内容
  void _maybeRestoreDraft(String dbTitle, String dbBody) {
    NoteDraft? draft;
    try {
      draft = _appState.repo.getDraft(widget.noteId);
    } catch (_) {
      return;
    }
    if (draft == null) return;
    if (draft.title == dbTitle && draft.content == dbBody) return;
    // 草稿比库里还旧（比如之后又在别处保存过）也不该拿它覆盖
    final note = _appState.repo.getNote(widget.noteId);
    if (note != null && draft.updatedAt.isBefore(note.updatedAt)) return;

    // 不能在 initState 里直接弹 —— 没有 Overlay 上下文
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('发现未保存的编辑内容'),
          content: Text(
            '上次这段内容没有保存成功（${_formatTime(draft!.updatedAt)}）。'
            '要恢复吗？',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                try {
                  _appState.repo.deleteDraft(widget.noteId);
                } catch (_) {}
              },
              child: const Text('丢弃草稿'),
            ),
            TextButton(
              onPressed: () {
                Navigator.of(ctx).pop();
                setState(() {
                  _title.text = draft!.title;
                  _body.text = draft.content;
                  _lastValue = _body.value;
                  _rebuildSegments();
                });
                _scheduleSave();
              },
              child: const Text('恢复'),
            ),
          ],
        ),
      );
    });
  }

  /// 历史版本。列出最近的版本，选中一条即可预览/恢复。
  Future<void> _showHistory() async {
    final c = context.colors;
    final state = _appState;
    final revisions = (() {
      try {
        return state.repo.revisionsOf(widget.noteId, limit: 60);
      } catch (_) {
        return const <NoteRevision>[];
      }
    })();

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('历史版本'),
        content: SizedBox(
          width: 520,
          height: 420,
          child: revisions.isEmpty
              ? Center(
                  child: Text(
                    '还没有历史版本。\n改写并保存后，旧内容会自动留在这里。',
                    textAlign: TextAlign.center,
                    style: AppText.callout.copyWith(color: c.secondaryLabel),
                  ),
                )
              : ListView.separated(
                  itemCount: revisions.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, color: c.separator),
                  itemBuilder: (_, i) {
                    final r = revisions[i];
                    return ListTile(
                      dense: true,
                      title: Text(
                        '${_formatTime(r.createdAt)}'
                        '${r.reason == 'restore' ? '（恢复前留存）' : ''}',
                        style: AppText.callout.copyWith(color: c.label),
                      ),
                      subtitle: Text(
                        r.preview,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.footnote.copyWith(
                          color: c.secondaryLabel,
                        ),
                      ),
                      trailing: TextButton(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _restoreRevision(r);
                        },
                        child: const Text('恢复'),
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 恢复某个历史版本。
  ///
  /// 先把**当前**内容也存一条历史（reason: 'restore'），
  /// 这样"恢复错了"还能再恢复回来。
  Future<void> _restoreRevision(NoteRevision r) async {
    final hasUnsaved =
        _title.text.trim() != _savedTitle || _body.text != _savedBody;
    if (hasUnsaved) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('当前有未保存的修改'),
          content: const Text('恢复历史版本会丢掉这些未保存的修改，继续吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('继续恢复'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
    }
    try {
      _appState.repo.addRevision(
        noteId: widget.noteId,
        title: _title.text.trim(),
        content: _body.text,
        reason: 'restore',
      );
    } catch (_) {
      // 留不下当前内容也不该挡住恢复，但要让用户知道
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('当前内容未能存为历史版本')));
      }
    }
    if (!mounted) return;
    setState(() {
      _title.text = r.title;
      _body.text = r.content;
      _lastValue = _body.value;
      _rebuildSegments();
    });
    _saveTimer?.cancel();
    _save();
  }

  String _formatTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }

  Future<void> _flushAndLeave() async {
    _saveTimer?.cancel();
    _draftTimer?.cancel();
    final saved = _save();
    // 存不上就别默默关掉 —— 至少告诉用户内容还在草稿里。
    if (!saved && _dirty) {
      final retry = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('这次没有保存成功'),
          content: Text(
            '原因：$_saveError\n\n'
            '你刚才写的内容还在草稿里，不会丢。可以再试一次；'
            '也可以先离开，下次打开这篇笔记时会提示恢复。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('先离开'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('再试一次'),
            ),
          ],
        ),
      );
      if (retry == true && mounted) {
        _save();
        if (_saveFailed) return; // 还是不行就留在编辑器里
      }
    }
    if (!mounted) return;
    final state = _appState;
    await state.refresh();
    if (!mounted) return;
    final external = widget.onClose;
    if (external != null) {
      external();
    } else {
      // 用 pop 而不是 maybePop：外层套了 PopScope（canPop: false），
      // maybePop 会被它自己挡回来 —— 转一圈又回到这里，变成死循环。
      Navigator.of(context).pop();
    }
  }

  // ── 撤销 / 重做 ─────────────────────────────────────────────────────────

  /// 撤销 / 重做。
  ///
  /// **改完 `_body` 必须重建分段。**
  ///
  /// `_body` 是唯一真源（保存、统计都读它），但屏幕上显示的是
  /// `_segControllers` 里那些输入框。以前这里只改 `_body` 就 setState ——
  /// 屏幕上一动不动，1.2 秒后自动保存却把"撤销后的"内容写进了库。
  /// 用户的感受是"按了撤销没反应"，再打开笔记发现刚写的东西没了。
  /// 更糟的是接着敲一个字：`_onSegmentChanged` 会用**屏幕上那份旧文本**
  /// 覆盖 `_body`，撤销彻底作废。
  void _applyHistory(TextEditingValue v) {
    _applyingHistory = true;
    _body.value = v;
    _lastValue = v;
    _applyingHistory = false;
    // 让可见的输入框跟着回到同一个状态：看到的就是会存下去的
    _rebuildSegments();
    _scheduleSave();
    setState(() {});
  }

  void _undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_body.value);
    _applyHistory(_undoStack.removeLast());
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_body.value);
    _applyHistory(_redoStack.removeLast());
  }

  // ── 工具栏动作 ──────────────────────────────────────────────────────────

  /// 插入本地媒体：选文件 → 复制进笔记目录 → 在光标处写一行 `![](相对路径)`。
  ///
  /// 只有「插入」这一个动作，因为这是用户唯一合理的期望：
  /// 他选了文件，就该看到东西出现在正文里。
  Future<void> _insertMedia(MediaKind kind) async {
    PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(
        dialogTitle: kind.actionLabel,
        type: FileType.custom,
        allowedExtensions: kind == MediaKind.video
            ? MediaImporter.videoExts.toList()
            : MediaImporter.imageExts.toList(),
      );
    } catch (e) {
      _toast('选择文件失败：$e');
      return;
    }
    final src = picked?.path;
    if (src == null || !mounted) return;

    final r = _importAndInsert(<String>[src]);
    if (r.failed.isNotEmpty && r.ok == 0) _toast('导入失败：${r.failed.first}');
  }

  /// 把本地文件导入笔记目录，并在**光标处**各插一行 `![](相对路径)`。
  ///
  /// 「插入图片/视频」按钮和"拖文件进来"都走这里。
  /// 两条路径各写一遍的话，迟早有一边漏掉 `_rebuildSegments()` ——
  /// 用户的感受就是"弄进去了但什么都没出现"。
  ({int ok, List<String> failed}) _importAndInsert(List<String> paths) {
    final state = context.read<AppState>();
    var ok = 0;
    final failed = <String>[];
    for (final path in paths) {
      try {
        final rel = MediaImporter.import(
          source: File(path),
          noteId: widget.noteId,
          imageRoot: state.db.imageRoot.path,
        );
        _withBody(() => MarkdownEditing.insertBlock(_activeBody, '![]($rel)'));
        ok++;
      } catch (_) {
        failed.add(p.basename(path));
      }
    }
    // insertBlock 改的是文字，而图片/视频段是**另外渲染**的，
    // 必须重建分段才会真的显示出来 —— 只改文字的话用户看到的是一行路径
    _rebuildSegments();
    if (mounted) setState(() {});
    return (ok: ok, failed: failed);
  }

  /// 给正文里的媒体（图片/视频）套一层删除入口。
  ///
  /// 交互和别处一致：**鼠标移上去才露出**删除键，平时不干扰阅读；
  /// 移动端没有 hover，则常驻显示（否则手机上根本删不掉）。
  Widget _deletableMedia(
    AppColors c, {
    required String key,
    required VoidCallback onDelete,
    required Widget child,
  }) {
    return _MediaHover(
      key: ValueKey<String>('wrap-$key'),
      // 桌面端靠悬停，触屏端没有 hover 事件，直接常显
      alwaysShowButton: !isDesktopPlatform(),
      builder: (hovering) => Stack(
        children: [
          child,
          if (hovering)
            Positioned(
              top: 6,
              right: 6,
              child: _MediaDeleteButton(
                onTap: () => _confirmDeleteMedia(onDelete),
              ),
            ),
        ],
      ),
    );
  }

  /// 删除前确认一次：正文里的媒体是**用户看得见的内容**，
  /// 误点一下就没了（虽然有撤销，但没人知道能撤销）。
  Future<void> _confirmDeleteMedia(VoidCallback onDelete) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删掉这个文件？'),
        content: const Text(
          '正文里的这一行会去掉，磁盘上的文件也一起删掉。'
          '删了就找不回来，需要的话得重新插入。',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: context.colors.destructive,
            ),
            child: const Text('删掉'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    onDelete();
  }

  /// 删掉一个媒体段：从分段列表里去掉它，再拼回正文。
  ///
  /// 走 [joinBodySegments] 而不是自己去字符串里找那一行 ——
  /// 分段和拼回是**严格互逆**的一对（单独测过），
  /// 手写字符串替换早晚会多删/少删一个换行。
  void _deleteSegment(ImageSegment seg) {
    final next = <BodySegment>[
      for (final s in _segments)
        if (!identical(s, seg)) s,
    ];
    _undoStack.add(TextEditingValue(text: _body.text));
    _redoStack.clear();
    _body.text = joinBodySegments(ensureTextSegment(next));
    _rebuildSegments();
    _deleteMediaFile(seg, next);
    _syncCoverAfterDelete(seg);
    _scheduleSave();
    if (mounted) setState(() {});
  }

  /// 删掉的正好是头图时，头图要跟着换（或干脆没有），
  /// 不能继续指着那个已经被删掉的文件 —— 否则详情页顶一块灰。
  void _syncCoverAfterDelete(ImageSegment seg) {
    final repo = context.read<AppState>().repo;
    final current = repo.getNote(widget.noteId);
    if (current == null) return;
    final cover = current.coverImage;
    // 没设过头图、或者用户明确选了"不设置头图"，都不该自作主张
    if (cover == null || cover.isEmpty || cover == kCoverNone) return;
    if (cover != seg.path) return;
    // 有剩下的图就用第一张，一张不剩就清成空串（将来插图还能再派生）
    repo.updateNote(
      id: widget.noteId,
      coverImage: firstImageOf(_body.text) ?? '',
      touch: false,
    );
  }

  /// 把正文里移除的那个文件**从磁盘上删掉**。
  ///
  /// 以前只删正文那一行，文件永远留在 `images/<noteId>/` 里：
  /// 用户以为删了，其实是躲在角落里占空间（也是隐私 —— 用户不想要的内容
  /// 还在硬盘上）。现在跟着删。
  ///
  /// 三条保护：
  ///   - 同一篇里还引用了同一个文件（复制了一行）就先不删；
  ///   - 路径必须落在图片根目录之内，防止 `..` 之类的东西误删到别处；
  ///   - 删不掉（被占用、只读）只提示，不回滚正文 —— 用户要的是"别出现在
  ///     笔记里"，这一步绝不能失败。
  void _deleteMediaFile(ImageSegment seg, List<BodySegment> remaining) {
    final stillUsed = remaining.any((s) => s is ImageSegment && s.path == seg.path);
    if (stillUsed) return;
    try {
      final root = context.read<AppState>().db.imageRoot.path;
      final abs = p.normalize(p.join(root, seg.path));
      if (!p.isWithin(root, abs)) return;
      final file = File(abs);
      if (!file.existsSync()) return;
      // 别的笔记把它当封面用着？那就留着 —— 删了那边就一块灰。
      final coverUsers = context.read<AppState>().repo.notesUsingCover(seg.path);
      if (coverUsers.any((id) => id != widget.noteId)) return;
      file.deleteSync();
      _vacuumImageDir(abs);
    } catch (e) {
      _toast('正文里的图片已经去掉了，但磁盘文件没能删除：$e');
    }
  }

  /// 删完文件顺手清掉空的笔记媒体目录，让它真的回到"没有图片"的样子。
  void _vacuumImageDir(String abs) {
    final dir = Directory(p.dirname(abs));
    if (!dir.existsSync()) return;
    if (dir.listSync().isNotEmpty) return;
    try {
      dir.deleteSync();
    } catch (_) {
      // 目录删不掉无所谓，它是空的
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  // ── 拖入媒体 ────────────────────────────────────────────────────────────
  //
  // 和工具栏的「插入图片/视频」走**同一段导入 + 插入逻辑**：
  // 两条路径各写一遍的话，迟早有一边漏掉 `_rebuildSegments()`，
  // 用户的感受就是"拖进去了但什么都没出现"。
  //
  // 拖拽只有桌面端有（desktop_drop 在手机上不产生事件），
  // 所以不额外做平台判断 —— 没有事件就没有入口，也不需要提示。

  /// 包一层拖放区。**整页都是落点**：用户不会瞄准某一个输入框去拖。
  Widget _wrapDrop(Widget child, AppColors c) => DropTarget(
    onDragEntered: (_) {
      if (mounted) setState(() => _dragging = true);
    },
    onDragExited: (_) {
      if (mounted) setState(() => _dragging = false);
    },
    onDragDone: _onDropFiles,
    child: Stack(children: [child, if (_dragging) _dropOverlay(c)]),
  );

  /// 悬停蒙层。**不能吃事件**（IgnorePointer），
  /// 否则鼠标一进入蒙层，DropTarget 就收不到后续消息，松手时反而不触发。
  Widget _dropOverlay(AppColors c) => Positioned.fill(
    child: IgnorePointer(
      child: Container(
        color: c.tint.withValues(alpha: 0.08),
        alignment: Alignment.center,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 20),
          decoration: BoxDecoration(
            color: c.secondaryBackground,
            borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
            border: Border.all(color: c.tint, width: 2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_photo_alternate_outlined, size: 34, color: c.tint),
              const SizedBox(height: 10),
              Text(
                '松开即可插入到笔记里',
                style: AppText.callout.copyWith(
                  color: c.tint,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '支持图片和视频，可一次拖多个',
                style: AppText.caption1.copyWith(color: c.tertiaryLabel),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _onDropFiles(DropDoneDetails details) async {
    if (mounted) setState(() => _dragging = false);

    // 认不认这个文件由 MediaImporter 判断（纯函数、单独测过）
    final split = MediaImporter.splitMediaPaths(
      details.files.map((f) => f.path),
    );
    final accepted = split.media;
    final skipped = split.others
        .map((path) => p.basename(path))
        .toList(growable: false);

    if (accepted.isEmpty) {
      // 说清楚该去哪儿，否则用户只知道"拖不进去"
      _toast(
        skipped.isEmpty
            ? '没有识别到文件'
            : '只能拖入图片或视频；${skipped.first} 这类文档请到「导入」页拖入',
      );
      return;
    }

    final r = _importAndInsert(accepted);

    if (r.ok > 0) {
      final extra = <String>[
        if (skipped.isNotEmpty) '${skipped.length} 个不是图片/视频，已跳过',
        if (r.failed.isNotEmpty) '${r.failed.length} 个导入失败',
      ];
      _toast(
        extra.isEmpty ? '已插入 ${r.ok} 个' : '已插入 ${r.ok} 个（${extra.join('；')}）',
      );
    } else if (r.failed.isNotEmpty) {
      _toast('导入失败：${r.failed.first}');
    }
  }

  void _withBody(void Function() action) {
    final before = _body.value;
    final target = _activeBody;
    final saved = identical(target, _toolbarSelectionController)
        ? _toolbarSelection
        : _segmentSelections[target];
    if (saved != null && saved.isValid && saved.end <= target.text.length) {
      target.selection = saved;
    }
    _applyingHistory = true;
    try {
      action();
      // 工具栏改的是当前这一段，改完立刻拼回整体。
      if (identical(target, _body)) {
        _rebuildSegments();
      } else {
        _onSegmentChanged();
      }
    } finally {
      _applyingHistory = false;
    }
    if (before.text != _body.text) {
      _snapshotTimer?.cancel();
      _undoStack.add(before);
      if (_undoStack.length > 120) _undoStack.removeAt(0);
      _redoStack.clear();
      _lastValue = _body.value;
    }
    final index = _segControllers.indexOf(target);
    if (index >= 0 && index < _segFocus.length) {
      _segFocus[index].requestFocus();
    }
    _toolbarSelectionController = null;
    _toolbarSelection = null;
    _scheduleSave();
    setState(() {});
  }

  /// 插入链接：先问是**内部**（跳到另一篇笔记）还是**外部**（打开网址）。
  ///
  /// 以前这个按钮只会插 `[文字](url)` —— 想链自己另一篇笔记得手打
  /// `[[标题]]`，慢、容易打错，打错了还只是"点了没反应"。现在内部链接
  /// 走一个能搜索、能翻页的选笔记界面，选完直接插入（有选中文字就当别名）。
  Future<void> _insertLinkFlow() async {
    final kind = await showAppMenu<String>(
      context,
      anchor: AppMenuAnchor(context: _linkButtonKey.currentContext),
      header: '插入链接',
      items: <AppMenuItem<String>>[
        AppMenuItem(
          value: 'note',
          label: '内部链接（跳到另一篇笔记）',
          icon: Icons.article_outlined,
        ),
        AppMenuItem(
          value: 'url',
          label: '外部链接（打开网址）',
          icon: Icons.public_rounded,
        ),
      ],
    );
    if (!mounted || kind == null) return;

    if (kind == 'url') {
      _withBody(() => MarkdownEditing.insertLink(_activeBody));
      return;
    }

    final picked = await pickNoteToLink(context, excludeNoteId: widget.noteId);
    if (!mounted || picked == null) return;
    _withBody(() => MarkdownEditing.insertNoteLink(_activeBody, picked.title));
    _toast('已插入指向《${picked.title}》的链接');
  }

  /// 插入一对围栏代码块，光标落在中间那一行。
  ///
  /// `insertBlock` 只负责把整段塞进去并把光标放到**块尾**，用在代码块上
  /// 就成了"插完还得自己往回按一行"。这里自己摆光标：
  /// 插完的可选区域是 ` ``` + \n + 空行 + \n + ``` + \n`，
  /// 光标要落在两块围栏之间的那一行开头。
  void _insertCodeBlock(MarkdownEditingController controller) {
    MarkdownEditing.insertBlock(controller, '```\n\n```');
    final at = controller.selection.baseOffset;
    if (at < 0) return;
    // 从块尾往回数：末尾多出的那个 \n、收尾围栏的 ```、它们之间那个 \n
    final inner = at - 1 - 3 - 1;
    if (inner < 0 || inner > controller.text.length) return;
    controller.selection = TextSelection.collapsed(offset: inner);
  }

  Future<void> _chooseHeading() async {
    final next = await showAppMenu<int>(
      context,
      anchor: AppMenuAnchor(context: _headingButtonKey.currentContext),
      header: '段落样式',
      items: [
        AppMenuItem(value: 0, label: '正文', icon: Icons.text_fields_rounded),
        for (var i = 1; i <= 6; i++)
          AppMenuItem(
            value: i,
            label: '$i 级标题 · H$i',
            icon: Icons.title_rounded,
          ),
      ],
    );
    if (!mounted || next == null) return;
    _withBody(() => MarkdownEditing.setHeading(_activeBody, next));
  }

  /// 立刻落库并给个明确回执（`Ctrl+S`）。
  ///
  /// 为什么还要这个：编辑器本来就有 1.2 秒的自动保存，但"我现在就要它存下去"
  /// 是写东西时最本能的一个动作；按了没反应会让人怀疑到底存没存。
  /// 没有任何改动时也回话（"没有改动"），而不是假装保存了。
  void _saveNow() {
    _saveTimer?.cancel();
    final saved = _save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(saved ? '已保存' : '没有改动'),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// Esc：从最外层往里退 —— 先退窗口全屏，再退占满页面，最后退出编辑。
  void _escape() {
    if (widget.windowFullscreen) {
      widget.onToggleWindowFullscreen?.call();
    } else if (widget.fullscreen) {
      widget.onToggleFullscreen?.call();
    } else {
      _flushAndLeave();
    }
  }

  /// 编辑器自己的快捷键。
  ///
  /// `Ctrl+E`（结束编辑）在这里绑、而不是在工作区：退出编辑前必须先把
  /// 没保存的内容落库（[_flushAndLeave]），只有编辑器自己知道怎么做。
  /// 编辑器嵌在三栏里时它的绑定比外层工作区的更近，会先命中。
  ///
  /// 结构上**焦点节点在快捷键层里面**：按键是从当前焦点往上冒泡的，
  /// 焦点要是落在这一层外面（比如工作区那个节点），这里一条都收不到。
  /// 所以编辑器一建好就主动把 [_shortcutFocus] 拿到手。
  Widget _shortcuts(Widget child) => CallbackShortcuts(
    bindings: bindShortcuts(<String, VoidCallback>{
      AppShortcutIds.save: _saveNow,
      AppShortcutIds.edit: _flushAndLeave,
      AppShortcutIds.exitFullscreen: _escape,
    }),
    child: Focus(focusNode: _shortcutFocus, child: child),
  );

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final chars = countChars(_body.text);
    final words = countWords(_body.text);

    // 编辑器本身就是所见即所得（语法符号已隐藏），不再需要"预览"模式
    final content = _buildEditor(c);
    final toolbar = _toolbar(c, chars, words);
    // 目录：和阅读页共用同一个面板（编辑长文时要能跳段）
    final toc = extractToc(_body.text);

    // 嵌入三栏布局：工具栏放顶部（桌面端顶部工具栏更顺手），
    // 且不套 Scaffold —— 外层面板已经提供了边框与背景。
    if (widget.embedded) {
      // 给正文限个宽：一行横跨 1900px 没法读；但不能限太死 —— 以前写死 860，
      // 在大屏上左右各留一大片空白，用户的原话是「全屏不要左右两边留白那么多」，
      // 所以宽屏给到 1200。
      //
      // 判据从 `widget.fullscreen` 这个 bool 换成「当前可用宽度」：占满动画的每
      // 一帧这一栏都在变宽，用 bool 的话退出占满的第一帧正文就从「居中限宽 1200」
      // 跳到「满宽」，然后才慢慢缩回去 —— 用户看到的「动画很怪」就有这一步。
      // 按宽度来：栏宽 ≤ 1200 时这个上限不生效（三栏态和以前一模一样），
      // 只有真超过 1200 才居中限宽，而且随宽度连续变化。
      final body = LayoutBuilder(
        builder: (context, box) {
          // min 与 max 同值：居中且保持「紧」约束，正文该填满就填满，
          // 不会因为外面套了 Center 就塌成内容宽度。
          final cap = math.min(1200.0, box.maxWidth);
          return Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: cap, maxWidth: cap),
              child: content,
            ),
          );
        },
      );

      return _wrapDrop(
        _shortcuts(
          Focus(
            canRequestFocus: false,
            skipTraversal: true,
            child: Column(
              children: [
                Container(
                  height: 46,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: c.background,
                    border: Border(
                      bottom: BorderSide(color: c.separator, width: 0.5),
                    ),
                  ),
                  child: Row(
                    children: [
                      Text(
                        '编辑',
                        style: AppText.footnote.copyWith(
                          color: c.secondaryLabel,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 6),
                      GlassIconButton(
                        icon: Icons.history_rounded,
                        size: 28,
                        iconSize: 16,
                        tooltip: '历史版本',
                        onTap: _showHistory,
                      ),
                      const Spacer(),
                      _saveHint(c),
                      const SizedBox(width: 8),
                      // 目录：正文里有标题时才给入口（编辑长文要能跳段）
                      if (toc.isNotEmpty) ...[
                        GlassIconButton(
                          icon: Icons.toc_rounded,
                          size: 28,
                          iconSize: 16,
                          color: _tocOpen ? c.tint : null,
                          tooltip: _tocOpen ? '关闭目录' : '目录',
                          onTap: () => setState(() => _tocOpen = !_tocOpen),
                        ),
                        const SizedBox(width: 4),
                      ],
                      // 占满页面：收起三栏，文章铺满应用窗口。窗口本身不动。
                      if (widget.onToggleFullscreen != null)
                        GlassIconButton(
                          icon: widget.fullscreen
                              ? Icons.close_fullscreen_rounded
                              : Icons.open_in_full_rounded,
                          size: 28,
                          iconSize: 16,
                          color: widget.fullscreen ? c.tint : null,
                          tooltip: widget.fullscreen ? '退出占满页面' : '占满页面',
                          onTap: widget.onToggleFullscreen!,
                        ),
                      // ⛶ 无边框窗口全屏：画面放大、盖住任务栏。
                      if (widget.onToggleWindowFullscreen != null) ...[
                        const SizedBox(width: 4),
                        GlassIconButton(
                          icon: widget.windowFullscreen
                              ? Icons.fullscreen_exit_rounded
                              : Icons.fullscreen_rounded,
                          size: 28,
                          iconSize: 16,
                          color: widget.windowFullscreen ? c.tint : null,
                          tooltip: widget.windowFullscreen
                              ? '退出窗口全屏（Esc）'
                              : '窗口全屏',
                          onTap: widget.onToggleWindowFullscreen!,
                        ),
                      ],
                      const SizedBox(width: 4),
                      TextButton(
                        onPressed: _flushAndLeave,
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        child: Text(
                          '完成',
                          style: AppText.callout.copyWith(
                            color: c.tint,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                toolbar,
                Expanded(child: _withToc(context, body, toc)),
              ],
            ),
          ),
        ),
        c,
      );
    }

    return _wrapDrop(
      _shortcuts(
        // **任何退出方式都要先落库 + 刷新状态。**
        //
        // 以前只有左上角那个返回箭头走 `_flushAndLeave`；手机上是手势返回 /
        // 系统返回键，那条路直接 pop —— 于是：1) `dispose` 把 1.2 秒的自动保存
        // 定时器**取消掉**，刚敲的字可能根本没落库；2) 列表页拿不到通知，
        // 回去看到的是旧内容，得下拉才更新（用户报的正是这个）。
        PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            _flushAndLeave();
          },
          child: Scaffold(
            backgroundColor: c.background,
            appBar: AppBar(
              backgroundColor: c.background,
              surfaceTintColor: Colors.transparent,
              leading: IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 19),
                onPressed: _flushAndLeave,
              ),
              titleSpacing: 20,
              title: Text(
                '编辑',
                style: AppText.headline.copyWith(color: c.label),
              ),
              actions: [
                GlassIconButton(
                  icon: Icons.history_rounded,
                  size: 30,
                  iconSize: 17,
                  tooltip: '历史版本',
                  onTap: _showHistory,
                ),
                // 目录：正文里有两个以上标题才给入口（没标题时它是空面板）
                if (toc.isNotEmpty)
                  GlassIconButton(
                    icon: Icons.toc_rounded,
                    size: 30,
                    iconSize: 17,
                    color: _tocOpen ? c.tint : null,
                    tooltip: _tocOpen ? '关闭目录' : '目录',
                    onTap: () => setState(() => _tocOpen = !_tocOpen),
                  ),
                Padding(
                  padding: const EdgeInsets.only(right: 14),
                  child: Center(child: _saveHint(c)),
                ),
              ],
            ),
            body: SafeArea(
              top: false,
              child: Column(
                children: [
                  Expanded(child: _withToc(context, content, toc)),
                  // 手机上工具栏放底部：键盘弹起时会跟着抬起，手指够得着
                  toolbar,
                ],
              ),
            ),
          ),
        ),
      ),
      c,
    );
  }

  /// 把正文和目录并排：目录**停靠**在旁边，位置与宽度跟着设置走。
  ///
  /// 和阅读页共用同一个 [TocPanel]，两边长得一样、行为也一样；
  /// 但编辑器里的跳转是"滚到那一段并把光标放进去"，见 [_jumpToHeading]。
  Widget _withToc(BuildContext context, Widget body, List<TocEntry> toc) {
    if (toc.isEmpty) return body;
    final app = context.read<AppState>();
    final panel = TocPanel(
      entries: toc,
      minLevel: minTocLevel(toc),
      width: _tocWidth,
      side: _tocSide,
      onTap: (e) => _jumpToHeading(toc.indexOf(e)),
      onFlipSide: () => setState(() {
        _tocSide = _tocSide == 'left' ? 'right' : 'left';
        app.setTocSide(_tocSide);
      }),
      onClose: () => setState(() => _tocOpen = false),
    );
    // 窄屏（手机）不能停靠：目录固定 220 宽会把正文挤到 170，
    // 编辑器的工具栏和分段立刻撑爆（阅读页那边真机上已经踩过了：
    // 一开目录就出现 "RIGHT OVERFLOWED BY ..." 的条纹）。改成浮层。
    final narrow = MediaQuery.sizeOf(context).width < 700;
    final duration = AppMotion.respecting(context, AppMotion.normal);

    if (narrow) {
      return Stack(
        children: [
          body,
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_tocOpen,
              child: AnimatedOpacity(
                opacity: _tocOpen ? 1 : 0,
                duration: duration,
                curve: AppMotion.enter,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _tocOpen = false),
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: 0.18),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: MediaQuery.paddingOf(context).top,
            bottom: 0,
            left: _tocSide == 'left' ? 0 : null,
            right: _tocSide == 'right' ? 0 : null,
            child: TocMotion(
              open: _tocOpen,
              side: _tocSide,
              width: _tocWidth,
              duration: duration,
              child: panel,
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        if (_tocSide == 'left') ...[
          TocMotion(
            open: _tocOpen,
            side: _tocSide,
            width: _tocWidth,
            duration: duration,
            child: panel,
          ),
          if (_tocOpen) TocResizer(onDrag: _resizeToc),
        ],
        Expanded(child: body),
        if (_tocSide == 'right') ...[
          if (_tocOpen) TocResizer(onDrag: (d) => _resizeToc(-d)),
          TocMotion(
            open: _tocOpen,
            side: _tocSide,
            width: _tocWidth,
            duration: duration,
            child: panel,
          ),
        ],
      ],
    );
  }

  void _resizeToc(double delta) {
    final app = context.read<AppState>();
    setState(() => _tocWidth = (_tocWidth + delta).clamp(160.0, 420.0));
    app.setTocWidth(_tocWidth);
  }

  /// 跳到第 [order] 个标题（0 起，按正文出现顺序）。
  ///
  /// 目录条目给的是"在 parseContent 结果里的下标"，而编辑器是按**分段**
  /// 渲染的 —— 两者的坐标系不同。所以走"第 N 个标题"这个中间量：
  /// 先数出它在正文的第几行，再找那一行落在哪个分段里。
  ///
  /// **只把分段滚进视野是不够的**：编辑器里"图片之间的一大段文字"是
  /// **一个**输入框，一篇纯文字笔记就是**一整段** —— 对它 ensureVisible
  /// 等于滚回开头（用户报的"跳转有点问题"就是这个：点了目录没反应）。
  /// 所以分两步：先让这一段被构建出来（懒列表里远处段落还没建），
  /// 再用 RenderEditable 量出那一行的真实位置，精确滚过去。
  Future<void> _jumpToHeading(int order) async {
    if (order < 0) return;
    final lines = _body.text.split('\n');
    final isHeading = RegExp(r'^\s{0,3}#{1,6}\s');
    var seen = -1;
    var lineIndex = -1;
    for (var i = 0; i < lines.length; i++) {
      if (!isHeading.hasMatch(lines[i])) continue;
      seen++;
      if (seen == order) {
        lineIndex = i;
        break;
      }
    }
    if (lineIndex < 0) return;

    // 这一行属于哪个分段：文字段按行数累加，图片段占一行
    var cursor = 0;
    var segIndex = -1;
    for (var i = 0; i < _segments.length; i++) {
      final seg = _segments[i];
      final span = seg is TextSegment ? seg.text.split('\n').length : 1;
      if (lineIndex < cursor + span) {
        segIndex = i;
        break;
      }
      cursor += span;
    }
    if (segIndex < 0 || segIndex >= _segKeys.length) return;

    final key = _segKeys[segIndex];
    if (!await _ensureSegmentBuilt(key, segIndex)) return;

    // 段落内、这一行之前有多少字符（用来把光标/视图放到那一行）
    final seg = _segments[segIndex];
    var offsetInSegment = 0;
    if (seg is TextSegment) {
      final segLines = seg.text.split('\n');
      for (var i = 0; i < lineIndex - cursor && i < segLines.length; i++) {
        offsetInSegment += segLines[i].length + 1;
      }
      offsetInSegment = offsetInSegment.clamp(0, seg.text.length);
    }

    await _refineToLine(key, offsetInSegment, segIndex);
    // 顺便把光标放进那一段：跳过去就是为了接着改
    if (segIndex < _segFocus.length && seg is TextSegment) {
      _segFocus[segIndex].requestFocus();
      _segControllers[segIndex].selection = TextSelection.collapsed(
        offset: offsetInSegment,
      );
    }
  }

  /// 让第 [segIndex] 段被构建出来并（大致）滚进视野。
  ///
  /// 懒构建的列表里，离视口远的段落**根本没有 RenderObject**，
  /// 这时候 ensureVisible 会静默失败 —— 表现就是"点目录一点反应都没有"。
  Future<bool> _ensureSegmentBuilt(GlobalKey key, int segIndex) =>
      revealTocTarget(controller: _scroll, key: key, alignment: 0.0);

  /// 精确滚到段落内的第 [offsetInSegment] 个字符那一行。
  ///
  /// 用 `RenderEditable.getLocalRectForCaret` 量出那一行的真实位置，
  /// 再按差值滚 —— 段落有多长都不影响精度。
  Future<void> _refineToLine(
    GlobalKey key,
    int offsetInSegment,
    int segIndex,
  ) async {
    final ctx = key.currentContext;
    if (ctx == null || !_scroll.hasClients) return;
    // currentContext 是 BuildContext，往下找 RenderEditable 要的是 Element
    final editable = ctx is Element ? _findRenderEditable(ctx) : null;
    if (editable == null) return;

    final rect = editable.getLocalRectForCaret(
      TextPosition(offset: offsetInSegment),
    );
    final dy = editable.localToGlobal(rect.topLeft).dy;
    // 想让这一行落在视口上沿往下一点的位置
    final want = _scroll.position.viewportDimension * 0.12;
    final delta = dy - want;
    if (delta.abs() < 2) return;
    final target = (_scroll.offset + delta).clamp(
      0.0,
      _scroll.position.maxScrollExtent,
    );
    // 时长与曲线都用动效体系里那一套：这里是"点目录跳过去"的定位滚动，
    // 属于常规过渡，跟全应用步调一致（也才会跟着「减弱动态效果」变成瞬移）。
    await _scroll.animateTo(
      target,
      duration: AppMotion.respecting(context, AppMotion.normal),
      curve: AppMotion.enter,
    );
  }

  /// 在子树里找 TextField 内部那个 RenderEditable。
  RenderEditable? _findRenderEditable(Element root) {
    RenderEditable? found;
    void visit(Element e) {
      if (found != null) return;
      final ro = e.renderObject;
      if (ro is RenderEditable) {
        found = ro;
        return;
      }
      e.visitChildren(visit);
    }

    visit(root);
    return found;
  }

  /// 保存状态提示：让"有没有存上"这件事一眼可见。
  ///
  /// 三种状态（优先级从高到低）：
  ///   1. 保存失败 —— 红字 + 原因，点一下立刻重试
  ///   2. 编辑中（有未落库的改动）
  ///   3. 已自动保存
  Widget _saveHint(AppColors c) {
    final (String label, Color color, bool tappable) = _saveFailed
        ? ('未保存：$_saveError', c.destructive, true)
        : _hasPendingSave
        ? ('编辑中…', c.tertiaryLabel, false)
        : ('已自动保存', c.tertiaryLabel, false);
    final text = AnimatedSwitcher(
      duration: AppMotion.respecting(context, AppMotion.fast),
      child: Text(
        label,
        key: ValueKey<String>(label),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppText.caption1.copyWith(color: color),
      ),
    );
    if (!tappable) return text;
    return Tooltip(
      message: '点一下立刻重试保存',
      child: Pressable(
        // 失败时整块可点：不用去猜"重试"按钮在哪
        onTap: () {
          _saveTimer?.cancel();
          _save();
        },
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: text,
        ),
      ),
    );
  }

  bool get _hasPendingSave => _saveTimer?.isActive ?? false;

  /// 有未落库的改动（包括"保存失败"这种更严重的）。
  bool get _dirty =>
      _saveFailed ||
      _title.text.trim() != _savedTitle ||
      _body.text != _savedBody;

  // ── 编辑态 ──────────────────────────────────────────────────────────────

  Widget _buildEditor(AppColors c) {
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      physics: const BouncingScrollPhysics(),
      children: [
        TextField(
          controller: _title,
          style: AppText.title2.copyWith(color: c.label, height: 1.35),
          maxLines: null,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            filled: false,
            isDense: true,
            contentPadding: EdgeInsets.zero,
            hintText: '标题',
            hintStyle: AppText.title2.copyWith(color: c.quaternaryLabel),
          ),
        ),
        const SizedBox(height: 10),
        // ── 头参数：标题与正文之间，一个参数一个块（填空式） ──
        if (context.watch<AppState>().headFieldsEnabled)
          HeadFieldsBlock(noteId: widget.noteId),
        const SizedBox(height: 10),
        Container(height: 0.5, color: c.separator),
        const SizedBox(height: 12),
        // 正文：文字段各是一个输入框，图片段渲染成真正的图 ——
        // 这样编辑时就能看到图片，而不是一串 ![](path)
        for (var i = 0; i < _segments.length; i++)
          KeyedSubtree(
            // key 给目录跳转用：靠它 ensureVisible 到那一段
            key: i < _segKeys.length ? _segKeys[i] : null,
            child: _segmentView(c, i),
          ),
        // ── 尾参数：文章末尾，右对齐一行 `——2026年9月14日18:43` ──
        if (context.watch<AppState>().tailFieldsEnabled)
          TailFieldsLine(noteId: widget.noteId),
      ],
    );
  }

  /// 渲染一段正文。
  Widget _segmentView(AppColors c, int i) {
    final seg = _segments[i];
    if (seg is ImageSegment) {
      return _imageBlock(c, seg, imageIndexOf(_segments, i));
    }

    return TextField(
      controller: _segControllers[i],
      focusNode: _segFocus[i],
      style: AppText.reading.copyWith(color: c.label),
      maxLines: null,
      keyboardType: TextInputType.multiline,
      inputFormatters: [_segControllers[i].inputFormatter],
      selectionWidthStyle: MarkdownEditingController.selectionWidthStyle,
      // 语法符号被渲染成透明且近乎零宽，光标落到它附近时
      // 默认会按极小字号画得看不见，所以固定一个光标高度。
      cursorHeight: 22,
      decoration: InputDecoration(
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        filled: false,
        isDense: true,
        contentPadding: EdgeInsets.zero,
        // 提示只在第一段显示，否则每段都顶着一段说明很吵
        hintText: i == 0
            ? '开始写点什么…\n\n'
                  '支持 Markdown：# 标题、**加粗**、- 列表、> 引用、- [ ] 待办\n'
                  '格式符号会自动隐藏，看到的就是最终效果'
            : null,
        hintStyle: AppText.body.copyWith(
          color: c.quaternaryLabel,
          height: 1.75,
        ),
      ),
    );
  }

  /// 一段图片：直接画成真图，而不是让用户盯着一串路径。
  ///
  /// **视频走另一条路**：正文里存的同样是 `![](路径)`，但按扩展名判断，
  /// 视频画成一张可点开的卡片 —— 塞进 Image.file 只会得到一个加载失败。
  Widget _imageBlock(AppColors c, ImageSegment seg, int index) {
    final root = context.read<AppState>().db.imageRoot.path;
    final abs = p.join(root, seg.path);

    // 图片和视频都要能删：以前正文里的媒体**没有任何删除入口**，
    // 插错了只能去源码里找那一行删掉。统一套一层"悬停出删除键"。
    return _deletableMedia(
      c,
      key: 'media-${seg.path}',
      onDelete: () => _deleteSegment(seg),
      child: MediaImporter.isVideoPath(seg.path)
          ?
            // **key 不能省**：编辑器的分段列表会因为"头参数开关""自动保存状态"
            // 之类的原因整体重建，没有 key 的话 Flutter 按位置配对，位置一挪
            // 视频卡片就被销毁重建 —— 播放器跟着重建，视频回到 00:00 暂停，
            // 用户看到的就是"点播放没反应"。有 key 才能保住同一个播放器。
            MediaCard(
              key: ValueKey<String>('media-${seg.path}'),
              path: abs,
              relPath: seg.path,
              index: index,
            )
          : _imageOnly(c, abs, seg, index),
    );
  }

  /// 图片那一路的渲染（视频走 [MediaCard]）。
  Widget _imageOnly(AppColors c, String abs, ImageSegment seg, int index) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
            child: LocalImage(
              path: abs,
              fit: BoxFit.cover,
              errorBuilder: (_) => Container(
                height: 76,
                alignment: Alignment.center,
                color: c.fill,
                child: Text(
                  '图片找不到：${seg.path}',
                  style: AppText.caption1.copyWith(color: c.tertiaryLabel),
                ),
              ),
            ),
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              Icon(Icons.image_rounded, size: 12, color: c.quaternaryLabel),
              const SizedBox(width: 5),
              Expanded(
                child: Text(
                  '第 $index 张 · ${seg.path}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.caption2.copyWith(color: c.quaternaryLabel),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── 底部工具栏 ──────────────────────────────────────────────────────────
  Widget _toolbar(AppColors c, int chars, int words) {
    final canUndo = _undoStack.isNotEmpty;
    final canRedo = _redoStack.isNotEmpty;

    return Listener(
      onPointerDown: (_) => _rememberToolbarSelection(),
      child: Container(
        decoration: BoxDecoration(
          color: c.secondaryBackground,
          border: Border(top: BorderSide(color: c.separator, width: 0.5)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 46,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  _ToolButton(
                    icon: Icons.undo_rounded,
                    tooltip: '撤销',
                    enabled: canUndo,
                    onTap: _undo,
                  ),
                  _ToolButton(
                    icon: Icons.redo_rounded,
                    tooltip: '重做',
                    enabled: canRedo,
                    onTap: _redo,
                  ),
                  _Sep(c),
                  _ToolButton(
                    key: _headingButtonKey,
                    icon: Icons.title_rounded,
                    tooltip: _headingLevel == 0 ? '设为标题' : '标题 H$_headingLevel',
                    active: _headingLevel > 0,
                    badge: _headingLevel == 0 ? null : 'H$_headingLevel',
                    onTap: _chooseHeading,
                  ),
                  _ToolButton(
                    icon: Icons.format_bold_rounded,
                    tooltip: '加粗',
                    active: _activeBody.typingMarkActive('**'),
                    onTap: () =>
                        _withBody(() => _activeBody.toggleInline('**')),
                  ),
                  _ToolButton(
                    icon: Icons.format_italic_rounded,
                    tooltip: '斜体',
                    active: _activeBody.typingMarkActive('*'),
                    onTap: () => _withBody(() => _activeBody.toggleInline('*')),
                  ),
                  _ToolButton(
                    icon: Icons.format_strikethrough_rounded,
                    tooltip: '删除线',
                    active: _activeBody.typingMarkActive('~~'),
                    onTap: () =>
                        _withBody(() => _activeBody.toggleInline('~~')),
                  ),
                  _ToolButton(
                    icon: Icons.code_rounded,
                    tooltip: '行内代码',
                    active: _activeBody.typingMarkActive('`'),
                    onTap: () => _withBody(() => _activeBody.toggleInline('`')),
                  ),
                  _Sep(c),
                  _ToolButton(
                    icon: Icons.format_quote_rounded,
                    tooltip: '引用',
                    onTap: () => _withBody(
                      () => MarkdownEditing.toggleLinePrefix(_activeBody, '> '),
                    ),
                  ),
                  _ToolButton(
                    icon: Icons.format_list_bulleted_rounded,
                    tooltip: '无序列表',
                    onTap: () => _withBody(
                      () => MarkdownEditing.toggleLinePrefix(_activeBody, '- '),
                    ),
                  ),
                  _ToolButton(
                    icon: Icons.format_list_numbered_rounded,
                    tooltip: '有序列表',
                    onTap: () => _withBody(
                      () =>
                          MarkdownEditing.toggleLinePrefix(_activeBody, '1. '),
                    ),
                  ),
                  _ToolButton(
                    icon: Icons.check_box_outlined,
                    tooltip: '待办',
                    onTap: () => _withBody(
                      () => MarkdownEditing.toggleLinePrefix(
                        _activeBody,
                        '- [ ] ',
                      ),
                    ),
                  ),
                  _Sep(c),
                  _ToolButton(
                    key: _linkButtonKey,
                    icon: Icons.link_rounded,
                    tooltip: '插入链接',
                    onTap: _insertLinkFlow,
                  ),
                  _ToolButton(
                    // 代码块是这里唯一"插入一对围栏"的按钮：
                    // 和行内代码共用 code 图标会让人分不清，
                    // 所以用 data_object（看起来像一段独立文本块）。
                    icon: Icons.data_object_rounded,
                    tooltip: '代码块',
                    onTap: () =>
                        _withBody(() => _insertCodeBlock(_activeBody)),
                  ),
                  _ToolButton(
                    icon: Icons.horizontal_rule_rounded,
                    tooltip: '分割线',
                    onTap: () => _withBody(
                      () => MarkdownEditing.insertBlock(_activeBody, '---'),
                    ),
                  ),
                  _Sep(c),
                  // 插入本地媒体：图片 / gif / 视频
                  _ToolButton(
                    icon: Icons.add_photo_alternate_outlined,
                    tooltip: '插入图片或动图',
                    onTap: () => _insertMedia(MediaKind.image),
                  ),
                  _ToolButton(
                    icon: Icons.videocam_outlined,
                    tooltip: '插入视频',
                    onTap: () => _insertMedia(MediaKind.video),
                  ),
                ],
              ),
            ),
            Container(height: 0.5, color: c.separator),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 8),
              child: Row(
                children: [
                  Text(
                    '$chars 字 · $words 词',
                    style: AppText.caption1.copyWith(color: c.tertiaryLabel),
                  ),
                  const Spacer(),
                  // 让用户知道"不用切到预览也能看到效果"
                  Row(
                    children: [
                      Icon(
                        Icons.auto_awesome,
                        size: 10,
                        color: c.quaternaryLabel,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '输入即生效',
                        style: AppText.caption2.copyWith(
                          color: c.quaternaryLabel,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.active = false,
    this.enabled = true,
    this.badge,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool active;
  final bool enabled;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = !enabled
        ? c.quaternaryLabel
        : (active ? c.tint : c.secondaryLabel);

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: Pressable(
        onTap: enabled ? onTap : null,
        scale: 0.9,
        haptic: false,
        child: Container(
          width: 38,
          alignment: Alignment.center,
          margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 1),
          decoration: BoxDecoration(
            color: active ? c.tint.withValues(alpha: 0.14) : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(icon, size: 19, color: color),
              if (badge != null)
                Positioned(
                  right: 2,
                  bottom: 4,
                  child: Text(
                    badge!,
                    style: AppText.caption2.copyWith(
                      color: c.tint,
                      fontSize: 8,
                      fontWeight: FontWeight.w700,
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

class _Sep extends StatelessWidget {
  const _Sep(this.c);
  final AppColors c;

  @override
  Widget build(BuildContext context) => Container(
    width: 0.5,
    height: 20,
    margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 13),
    color: c.separator,
  );
}
