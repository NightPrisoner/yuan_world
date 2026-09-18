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

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../app_state.dart';
import '../../../core/motion/app_motion.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/text_stats.dart';
import '../../../data/media/media_importer.dart';
import 'body_segments.dart';
import 'markdown_controller.dart';
import 'markdown_editing.dart';
import '../widgets/field_blocks.dart';
import '../widgets/media_card.dart';

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
  final TextEditingController _title = TextEditingController();
  // 用带实时样式的控制器：**加粗**、# 标题、`代码` 输入即生效
  final MarkdownEditingController _body = MarkdownEditingController();
  final FocusNode _bodyFocus = FocusNode();

  // ── 正文分段：让图片能在正文里显示出来 ──
  //
  // 单个 TextField 画不出图，所以正文被拆成「文字段 ↔ 图片」交替的块：
  // 文字段各是一个输入框，图片段渲染成真正的图。
  // 拼回必须无损，逻辑在 body_segments.dart 里并单独测过。
  List<BodySegment> _segments = const <BodySegment>[];
  final List<MarkdownEditingController> _segControllers = [];
  final List<FocusNode> _segFocus = [];
  int? _focusedSegment;

  /// 工具栏该作用在哪个输入框上。
  ///
  /// 正文拆成多段之后，"光标在哪一段"决定了加粗作用于谁。
  /// 没有任何一段聚焦时退回整体，避免按钮点了没反应。
  MarkdownEditingController get _activeBody {
    final i = _focusedSegment;
    if (i != null && i >= 0 && i < _segControllers.length) {
      return _segControllers[i];
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
      if (seg is TextSegment) controller.addListener(_onSegmentChanged);
      _segControllers.add(controller);
      _segFocus.add(node);
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
      next.add(
        seg is TextSegment ? TextSegment(_segControllers[i].text) : seg,
      );
    }
    _segments = next;

    final joined = joinBodySegments(next);
    if (joined != _body.text) _body.text = joined;
  }

  Timer? _saveTimer;
  bool _loaded = false;

  /// 当前生效的标题级别（0 = 正文），供工具栏按钮显示状态。
  int _headingLevel = 0;

  // ── 撤销 / 重做 ─────────────────────────────────────────────────────────
  final List<TextEditingValue> _undoStack = <TextEditingValue>[];
  final List<TextEditingValue> _redoStack = <TextEditingValue>[];
  TextEditingValue? _lastValue;
  Timer? _snapshotTimer;
  bool _applyingHistory = false;

  /// 上一次落库时的标题与正文。用来判断"到底改没改"。
  String _savedTitle = '';
  String _savedBody = '';

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
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
    }
    _loaded = true;
    _title.addListener(_markDirty);
    _body.addListener(_onBodyChanged);
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _snapshotTimer?.cancel();
    _title.removeListener(_markDirty);
    _body.removeListener(_onBodyChanged);
    _disposeSegments();
    _title.dispose();
    _body.dispose();
    _bodyFocus.dispose();
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
  }

  void _save() {
    final text = _body.text;
    final title = _title.text.trim();

    // **内容没变就什么都不做。**
    //
    // updateNote 会顺带刷新 updated_at，所以"进编辑器看一眼就退出"
    // 会把修改时间改掉，列表里的排序也跟着乱跳。
    // 用字符串比对而不是靠 dirty 标志：不用在每个改动入口都记得打标记，
    // 漏一个就会退化成旧行为。
    if (title == _savedTitle && text == _savedBody) return;

    final state = context.read<AppState>();
    state.repo.updateNote(
      id: widget.noteId,
      title: title,
      content: text,
      excerpt: makeExcerpt(text),
      charCount: countChars(text),
      wordCount: countWords(text),
      // 图片/视频数也要重算，否则插了图那个数字还是旧的
      imageCount: mediaCountOf(text),
    );
    _savedTitle = title;
    _savedBody = text;
    if (mounted) setState(() {});
  }

  /// 离开页面前强制落库。
  Future<void> _flushAndLeave() async {
    _saveTimer?.cancel();
    _save();
    final state = context.read<AppState>();
    await state.refresh();
    if (!mounted) return;
    final external = widget.onClose;
    if (external != null) {
      external();
    } else {
      Navigator.of(context).maybePop();
    }
  }

  // ── 撤销 / 重做 ─────────────────────────────────────────────────────────

  void _undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_body.value);
    final v = _undoStack.removeLast();
    _applyingHistory = true;
    _body.value = v;
    _lastValue = v;
    _applyingHistory = false;
    _scheduleSave();
    setState(() {});
  }

  void _redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_body.value);
    final v = _redoStack.removeLast();
    _applyingHistory = true;
    _body.value = v;
    _lastValue = v;
    _applyingHistory = false;
    _scheduleSave();
    setState(() {});
  }

  // ── 工具栏动作 ──────────────────────────────────────────────────────────

  /// 插入本地媒体：选文件 → 复制进笔记目录 → 在光标处写一行 `![](相对路径)`。
  ///
  /// 只有「插入」这一个动作，因为这是用户唯一合理的期望：
  /// 他选了文件，就该看到东西出现在正文里。
  Future<void> _insertMedia(MediaKind kind) async {
    final state = context.read<AppState>();

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

    String rel;
    try {
      rel = MediaImporter.import(
        source: File(src),
        noteId: widget.noteId,
        imageRoot: state.db.imageRoot.path,
      );
    } catch (e) {
      _toast('导入失败：$e');
      return;
    }

    _withBody(
      () => MarkdownEditing.insertBlock(_activeBody, '![]($rel)'),
    );
    // insertBlock 改的是文字，而图片/视频段是**另外渲染**的，
    // 必须重建分段才会真的显示出来 —— 只改文字的话用户看到的是一行路径
    _rebuildSegments();
    if (mounted) setState(() {});
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  void _withBody(void Function() action) {
    final target = _activeBody;
    action();
    // 工具栏改的是"当前这一段"，改完要立刻拼回整体
    if (identical(target, _body)) {
      _bodyFocus.requestFocus();
    } else {
      _onSegmentChanged();
    }
    _scheduleSave();
    setState(() {});
  }

  void _cycleHeading() {
    final next = switch (_headingLevel) {
      0 => 1,
      1 => 2,
      2 => 3,
      _ => 0,
    };
    setState(() => _headingLevel = next);
    _withBody(() => MarkdownEditing.setHeading(_activeBody, next));
  }

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

    // 嵌入三栏布局：工具栏放顶部（桌面端顶部工具栏更顺手），
    // 且不套 Scaffold —— 外层面板已经提供了边框与背景。
    if (widget.embedded) {
      final body = widget.fullscreen
          // 全屏时把正文限宽居中：一行横跨 1900px 反而没法读
          ? Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 860),
                child: content,
              ),
            )
          : content;

      return CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          // Esc：从最外层往里退 —— 先退窗口全屏，再退占满页面，最后退编辑
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (widget.windowFullscreen) {
              widget.onToggleWindowFullscreen?.call();
            } else if (widget.fullscreen) {
              widget.onToggleFullscreen?.call();
            } else {
              _flushAndLeave();
            }
          },
        },
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          child: Column(
            children: [
              Container(
                height: 46,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: c.background,
                  border:
                      Border(bottom: BorderSide(color: c.separator, width: 0.5)),
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
                    const Spacer(),
                    _saveHint(c),
                    const SizedBox(width: 8),
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
              Expanded(child: body),
            ],
          ),
        ),
      );
    }

    return Scaffold(
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
            Expanded(child: content),
            // 手机上工具栏放底部：键盘弹起时会跟着抬起，手指够得着
            toolbar,
          ],
        ),
      ),
    );
  }

  /// 保存状态提示：让"有没有存上"这件事一眼可见。
  Widget _saveHint(AppColors c) {
    return AnimatedSwitcher(
      duration: AppMotion.fast,
      child: Text(
        _hasPendingSave ? '编辑中…' : '已自动保存',
        key: ValueKey<bool>(_hasPendingSave),
        style: AppText.caption1.copyWith(color: c.tertiaryLabel),
      ),
    );
  }

  bool get _hasPendingSave => _saveTimer?.isActive ?? false;

  // ── 编辑态 ──────────────────────────────────────────────────────────────

  Widget _buildEditor(AppColors c) {
    return ListView(
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
        for (var i = 0; i < _segments.length; i++) _segmentView(c, i),
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
      style: AppText.body.copyWith(color: c.label, height: 1.75),
      maxLines: null,
      keyboardType: TextInputType.multiline,
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

    if (MediaImporter.isVideoPath(seg.path)) {
      return MediaCard(path: abs, relPath: seg.path, index: index);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
            child: Image.file(
              File(abs),
              width: double.infinity,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => Container(
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

    return Container(
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
                  icon: Icons.title_rounded,
                  tooltip: _headingLevel == 0 ? '设为标题' : '标题 H$_headingLevel',
                  active: _headingLevel > 0,
                  badge: _headingLevel == 0 ? null : 'H$_headingLevel',
                  onTap: _cycleHeading,
                ),
                _ToolButton(
                  icon: Icons.format_bold_rounded,
                  tooltip: '加粗',
                  onTap: () => _withBody(() => MarkdownEditing.wrap(_activeBody, '**')),
                ),
                _ToolButton(
                  icon: Icons.format_italic_rounded,
                  tooltip: '斜体',
                  onTap: () => _withBody(() => MarkdownEditing.wrap(_activeBody, '*')),
                ),
                _ToolButton(
                  icon: Icons.format_strikethrough_rounded,
                  tooltip: '删除线',
                  onTap: () => _withBody(() => MarkdownEditing.wrap(_activeBody, '~~')),
                ),
                _ToolButton(
                  icon: Icons.code_rounded,
                  tooltip: '行内代码',
                  onTap: () => _withBody(() => MarkdownEditing.wrap(_activeBody, '`')),
                ),
                _Sep(c),
                _ToolButton(
                  icon: Icons.format_quote_rounded,
                  tooltip: '引用',
                  onTap: () =>
                      _withBody(() => MarkdownEditing.toggleLinePrefix(_activeBody, '> ')),
                ),
                _ToolButton(
                  icon: Icons.format_list_bulleted_rounded,
                  tooltip: '无序列表',
                  onTap: () =>
                      _withBody(() => MarkdownEditing.toggleLinePrefix(_activeBody, '- ')),
                ),
                _ToolButton(
                  icon: Icons.format_list_numbered_rounded,
                  tooltip: '有序列表',
                  onTap: () =>
                      _withBody(() => MarkdownEditing.toggleLinePrefix(_activeBody, '1. ')),
                ),
                _ToolButton(
                  icon: Icons.check_box_outlined,
                  tooltip: '待办',
                  onTap: () => _withBody(
                    () => MarkdownEditing.toggleLinePrefix(_activeBody, '- [ ] '),
                  ),
                ),
                _Sep(c),
                _ToolButton(
                  icon: Icons.link_rounded,
                  tooltip: '链接',
                  onTap: () => _withBody(() => MarkdownEditing.insertLink(_activeBody)),
                ),
                _ToolButton(
                  icon: Icons.horizontal_rule_rounded,
                  tooltip: '分割线',
                  onTap: () =>
                      _withBody(() => MarkdownEditing.insertBlock(_activeBody, '---')),
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
                    Icon(Icons.auto_awesome,
                        size: 10, color: c.quaternaryLabel),
                    const SizedBox(width: 4),
                    Text(
                      '输入即生效',
                      style: AppText.caption2.copyWith(color: c.quaternaryLabel),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
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
