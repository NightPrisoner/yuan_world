/// 笔记详情 / 阅读页。
///
/// 阅读体验的关键处理：
///   1. 正文行高 1.85 —— 中文长文在 1.5 下会显得挤
///   2. 大标题随滚动淡出，进入阅读后把版面让给内容
///   3. 封面横幅与列表缩略图共用 Hero tag，转场时位置连续
///   4. 编辑交给独立的编辑器页（工具栏 / 预览 / 自动保存都在那边）
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../core/motion/app_motion.dart';
import '../../core/motion/apple_page_route.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/toc.dart';
import '../../core/widgets/app_menu.dart';
import '../../data/media/external_media.dart';
import '../../data/models.dart';
import '../tags/tag_sheets.dart';
import 'editor/body_segments.dart';
import 'editor/note_editor_page.dart';
import 'widgets/content_view.dart';
import 'widgets/cover_frame.dart';
import 'widgets/cover_picker.dart';
import 'widgets/toc_panel.dart';
import 'widgets/field_blocks.dart';
import 'widgets/note_actions.dart';
import 'widgets/note_card.dart' show formatRelative;
import '../../data/repositories/note_repository.dart';

class NoteDetailPage extends StatefulWidget {
  const NoteDetailPage({
    super.key,
    required this.noteId,
    this.embedded = false,
    this.onRequestEdit,
    this.onEditAtLine,
    this.onClose,
    this.fullscreen = false,
    this.onToggleFullscreen,
    this.windowFullscreen = false,
    this.onToggleWindowFullscreen,
    this.coverKey,
  });

  final int noteId;

  /// 嵌入三栏布局的右侧面板时置 true：
  /// 不套 Scaffold、不显示返回按钮、不触发 Hero。
  final bool embedded;

  /// 嵌入模式下由外部接管「去编辑」，而不是 push 一个新路由。
  final VoidCallback? onRequestEdit;

  /// 嵌入模式下要「从当前读到的那一行开始编辑」时用这个。
  ///
  /// [onRequestEdit] 只告诉外层"切成编辑器"，带不出行号 —— 三栏布局里
  /// 编辑器是同一棵子树换内容，拿不到行号就会从头开始，长文里等于
  /// 每次点编辑都把人扔回标题。传了本回调时优先用它。
  final ValueChanged<int?>? onEditAtLine;

  /// 嵌入三栏布局时，点右上角的 × 收起正文栏。
  /// 为空则不显示关闭按钮（比如手机上是整页，没有"收起"的概念）。
  final VoidCallback? onClose;

  /// 是否已"占满页面"（三栏收起）。**不影响窗口**。
  final bool fullscreen;

  /// 切换"占满页面"。由外部接管，因为它要改的是外层的版式。
  final VoidCallback? onToggleFullscreen;

  /// 是否处于**窗口**无边框全屏。
  final bool windowFullscreen;

  /// 切换窗口全屏（⛶）。和 [onToggleFullscreen] 是两件独立的事。
  final VoidCallback? onToggleWindowFullscreen;
  final GlobalKey? coverKey;

  @override
  State<NoteDetailPage> createState() => _NoteDetailPageState();
}

/// 目录栏与正文之间的拖拽分隔条。
/// 目录侧栏（实现见 `widgets/toc_panel.dart`，编辑器共用同一个）。
class _NoteDetailPageState extends State<NoteDetailPage> {
  final ScrollController _scroll = ScrollController();
  final ValueNotifier<double> _collapse = ValueNotifier<double>(0);

  Note? _note;
  String _content = '';

  /// 目录条目，以及每个标题所在 block 的 GlobalKey（跳转靠它定位）。
  List<TocEntry> _toc = const <TocEntry>[];

  /// 反向链接：哪些笔记的正文里链到了这一篇。
  List<Note> _backlinks = const <Note>[];
  final Map<int, GlobalKey> _blockKeys = <int, GlobalKey>{};

  bool _tocOpen = false;

  /// 目录栏的宽度与停靠侧，跟着设置走。
  double _tocWidth = 220;
  String _tocSide = 'right';

  static const double _expanded = 96;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _tocWidth = state.tocWidth;
    _tocSide = state.tocSide;
    _load(recordOpen: true);
    _scroll.addListener(_onScroll);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final t = (_scroll.offset / (_expanded - kToolbarHeight)).clamp(0.0, 1.0);
    if ((t - _collapse.value).abs() > 0.004) _collapse.value = t;
  }

  void _load({bool recordOpen = false}) {
    final state = context.read<AppState>();
    final note = state.repo.getNote(widget.noteId);
    if (note == null) return;
    _note = note;
    _content = note.content;
    // 打开事件用于「活跃度热力图」
    if (recordOpen) state.repo.logEvent(note.id, 'open');

    // 目录：正文变了就重算，并把旧的 key 换掉 ——
    // 复用旧 key 会让 ensureVisible 跳到上一篇文章的位置
    _toc = extractToc(_content);
    _blockKeys.clear();
    for (final e in _toc) {
      _blockKeys[e.blockIndex] = GlobalKey();
    }
    _tocOpen = false;
    // 反向链接：读取时现算（正文是唯一真源，见 core/utils/wiki_links.dart）
    _backlinks = state.repo.backlinksOf(note.id, hiddenOnly: state.privacyMode);
  }

  /// 「被引用」：列出链到这篇的笔记。
  ///
  /// 用 [NoteCard] 那套行样式会和列表太像（用户会以为是"这篇的下级"），
  /// 所以做成更轻的一栏标题 + 小行：它是**出口**，不是内容。
  Widget _backlinksSection(AppColors c, AppState state) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(height: 0.5, color: c.separator),
        const SizedBox(height: 14),
        Row(
          children: [
            Icon(Icons.link_rounded, size: 15, color: c.tertiaryLabel),
            const SizedBox(width: 6),
            Text(
              '被引用 ${_backlinks.length}',
              style: AppText.caption1.copyWith(
                color: c.tertiaryLabel,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final n in _backlinks)
          Pressable(
            onTap: () => _openNoteRoute(n.id),
            scale: 0.99,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      n.title.isEmpty ? '无标题笔记' : n.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.footnote.copyWith(color: c.tint),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    formatRelative(n.updatedAt),
                    style: AppText.caption2.copyWith(color: c.quaternaryLabel),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 18),
      ],
    );
  }

  /// 打开另一篇笔记（反向链接、双链跳转都用它）。
  ///
  /// 嵌入三栏时也 push 一个**独立页面**：三栏的右栏此刻正显示着当前这篇，
  /// 直接换掉内容会让用户"回不去"（没有历史）。
  void _openNoteRoute(int id) {
    Navigator.of(context).push(
      ApplePageRoute<void>(pageBuilder: (_) => NoteDetailPage(noteId: id)),
    );
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _collapse.dispose();
    super.dispose();
  }

  Future<void> _openEditor() async {
    // 从哪儿进来的就从哪儿接着改：把当前读到的那一行交给编辑器。
    final startLine = _currentLine();
    // 嵌入模式下交给外层面板切换内容，不要 push 新页面盖住整个三栏布局。
    // 行号也要一起交出去：只切内容不传行号，编辑器就会从开头显示。
    final atLine = widget.onEditAtLine;
    if (atLine != null) {
      atLine(startLine);
      return;
    }
    final external = widget.onRequestEdit;
    if (external != null) {
      external();
      return;
    }
    final route = MediaQuery.sizeOf(context).width < 1000
        ? EditorPageRoute<void>(
            pageBuilder: (_) =>
                NoteEditorPage(noteId: widget.noteId, initialLine: startLine),
          )
        : ApplePageRoute<void>(
            pageBuilder: (_) =>
                NoteEditorPage(noteId: widget.noteId, initialLine: startLine),
          );
    await Navigator.of(context).push(route);
    // 编辑器里会自动保存，回来后重新读一遍
    if (mounted) setState(_load);
  }

  /// 当前读到正文的第几行。
  ///
  /// 先试"视口上方最近的那个标题"—— 标题在正文里的位置是稳定的，
  /// 用它反查行号不会随字体大小、图片高度漂移；没有标题的纯文字笔记，
  /// 退化成按滚动比例估算（够用了：它的每一行高度都差不多）。
  int? _currentLine() {
    if (!_scroll.hasClients) return null;
    final lines = _content.split('\n');
    if (lines.isEmpty) return null;

    TocEntry? above;
    for (final e in _toc) {
      final box = _blockKeys[e.blockIndex]?.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      // 距离屏幕顶部还有一点点余量的都算"已经滚过去了"
      if (box.localToGlobal(Offset.zero).dy <= 120) above = e;
    }
    if (above != null) {
      final target = above.text.trim();
      final isHeading = RegExp(r'^\s{0,3}#{1,6}\s');
      for (var i = 0; i < lines.length; i++) {
        if (!isHeading.hasMatch(lines[i])) continue;
        if (lines[i].replaceFirst(isHeading, '').trim() == target) return i;
      }
    }

    final max = _scroll.position.maxScrollExtent;
    if (max <= 0) return 0;
    final ratio = (_scroll.offset / max).clamp(0.0, 1.0);
    return (ratio * (lines.length - 1)).round();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = context.colors;
    final note = _note;

    if (note == null) {
      return Scaffold(
        backgroundColor: c.background,
        appBar: AppBar(backgroundColor: c.background),
        body: Center(
          child: Text(
            '笔记不存在',
            style: AppText.callout.copyWith(color: c.tertiaryLabel),
          ),
        ),
      );
    }

    final imageRoot = state.db.imageRoot.path;
    // 用 displayCover 而不是原始字段：它同时排掉「用户明确不要头图」的
    // `__none__` 标记和**文件已经不在**的路径。后者以前会渲染成一整块
    // 灰色矩形顶在标题上方，用户只能看到一个说不清含义的灰块。
    final cover = displayCover(note.coverImage, imageRoot);

    // 只留文件夹归属、字数、图片与视频数。
    // 作者、发布时间、来源链接都不显示 —— 那些原本是从 Word 文档头
    // 解析出来的，而**不是每个文档都有文档头**，显示出来只会让
    // 有头的和没头的笔记长得不一样。原始文字仍然留在正文里。
    //
    // 媒体数**从正文现算**而不是读 note.imageCount：那个字段是导入时
    // 写死的，在编辑器里插了图不会变。现算才是实时的。
    final media = mediaBreakdown(note.content);
    final metaLine = <String>[
      // 文件夹归属：一眼看出这篇归在哪儿，不用回头看左栏选中了谁
      if ((note.collectionName ?? '').isNotEmpty) note.collectionName!,
      if (note.charCount > 0) '${note.charCount} 字',
      if (media.images > 0) '${media.images} 图',
      if (media.videos > 0) '${media.videos} 视频',
    ].join(' · ');

    // 整篇正文**只套一个** `SelectionArea`（外面那层）。
    //
    // 段落本身只画 `Text.rich`（见 content_view.dart 的说明）：一篇长文几百段，
    // 每段各套一个选区容器，进页面和滚动都发沉；整篇一个既能跨段落选中，
    // 又不会给每段都挂一套选区注册器/手势识别器。
    final scrollView = SelectionArea(
      child: CustomScrollView(
        controller: _scroll,
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: <Widget>[
          SliverAppBar(
            // 顶栏不再钉死：往下读时让位给正文，往上滑才回来。
            //
            // 长文里一直压着一条 96 高的栏，等于每屏少两行；而"往回滑"
            // 本身就是"我要找操作"的信号，那时候再出现刚刚好。
            floating: true,
            snap: true,
            expandedHeight: _expanded,
            backgroundColor: c.background.withValues(alpha: 0.92),
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            automaticallyImplyLeading: false,
            // 嵌进三栏布局时不显示返回按钮（面板里没有"返回"的概念）
            leading: widget.embedded
                ? null
                : IconButton(
                    icon: const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      size: 19,
                    ),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
            title: ValueListenableBuilder<double>(
              valueListenable: _collapse,
              builder: (context, t, _) => Opacity(
                opacity: ((t - 0.6) / 0.4).clamp(0.0, 1.0),
                child: Text(
                  note.title.isEmpty ? '无标题笔记' : note.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.headline.copyWith(color: c.label),
                ),
              ),
            ),
            actions: [
              // 编辑是这一页的主操作，放顶栏第一位。
              // 以前它在标题下方，得先滑过标题、封面才看得见 —— 长文里
              // 想改一句就得先往回滚。
              //
              // 图标按钮和标签/收藏长得一模一样时，用户会以为它们同等级。
              // 主操作要一眼看出来：实心强调色 + 白图标 + 比旁边大一圈。
              if (widget.onRequestEdit != null ||
                  widget.onEditAtLine != null ||
                  !widget.embedded) ...[
                GlassIconButton(
                  icon: Icons.edit_rounded,
                  tooltip: '编辑',
                  color: Colors.white,
                  background: c.tint,
                  size: 34,
                  iconSize: 18,
                  onTap: _openEditor,
                ),
                const SizedBox(width: 6),
              ],
              // 标签：以前界面上完全没有入口，标签功能等于不存在
              GlassIconButton(
                icon: Icons.label_outline_rounded,
                tooltip: note.tags.isEmpty ? '标签' : '标签（${note.tags.length}）',
                onTap: () async {
                  final changed = await showNoteTagEditor(context, note.id);
                  if (changed && mounted) setState(_load);
                },
              ),
              const SizedBox(width: 6),
              GlassIconButton(
                icon: note.isFavorite
                    ? Icons.star_rounded
                    : Icons.star_outline_rounded,
                color: note.isFavorite ? c.palette[7] : c.tint,
                tooltip: '收藏',
                onTap: () async {
                  await context.read<AppState>().toggleFavorite(note);
                  if (mounted) setState(_load);
                },
              ),
              const SizedBox(width: 6),
              Builder(
                // 用按钮自己的 context 做锚点，菜单才会贴着它弹；
                // 不传的话 showNoteActions 会退回底部面板
                builder: (btnCtx) => GlassIconButton(
                  icon: Icons.more_horiz_rounded,
                  tooltip: '更多',
                  onTap: () async {
                    // 删除后 popOnDelete 会把详情页一并关掉，回到列表
                    await showNoteActions(
                      context,
                      note,
                      popOnDelete: true,
                      anchor: AppMenuAnchor(context: btnCtx),
                    );
                    if (mounted) setState(_load);
                  },
                ),
              ),
              if (_toc.isNotEmpty && state.tocEnabled) ...[
                const SizedBox(width: 6),
                GlassIconButton(
                  icon: Icons.toc_rounded,
                  color: _tocOpen ? c.tint : null,
                  tooltip: _tocOpen ? '关闭目录' : '目录',
                  onTap: () => setState(() => _tocOpen = !_tocOpen),
                ),
              ],
              // 占满页面：收起三栏。**不碰窗口** ——
              // 窗口全屏是另一个按钮（⛶）的事，混在一起用户会以为点错了。
              if (widget.onToggleFullscreen != null) ...[
                const SizedBox(width: 6),
                GlassIconButton(
                  icon: widget.fullscreen
                      ? Icons.close_fullscreen_rounded
                      : Icons.open_in_full_rounded,
                  color: widget.fullscreen ? c.tint : null,
                  tooltip: widget.fullscreen ? '退出占满页面' : '占满页面',
                  onTap: widget.onToggleFullscreen!,
                ),
              ],
              if (widget.onToggleWindowFullscreen != null) ...[
                const SizedBox(width: 6),
                GlassIconButton(
                  icon: widget.windowFullscreen
                      ? Icons.fullscreen_exit_rounded
                      : Icons.fullscreen_rounded,
                  color: widget.windowFullscreen ? c.tint : null,
                  tooltip: widget.windowFullscreen ? '退出窗口全屏' : '窗口全屏',
                  onTap: widget.onToggleWindowFullscreen!,
                ),
              ],
              if (widget.onClose != null) ...[
                const SizedBox(width: 10),
                GlassIconButton(
                  icon: Icons.close_rounded,
                  size: 36,
                  iconSize: 20,
                  color: Colors.white,
                  background: c.tint,
                  tooltip: '收起正文栏',
                  onTap: widget.onClose!,
                ),
              ],
              const SizedBox(width: 16),
            ],
          ),

          // 封面横幅：与列表卡片缩略图共用 Hero tag（嵌入模式下不用 Hero）
          if (cover != null)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
                child: _coverBanner(c, imageRoot, cover, note),
              ),
            ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    note.title.isEmpty ? '无标题笔记' : note.title,
                    style: AppText.title1.copyWith(color: c.label, height: 1.3),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    metaLine,
                    style: AppText.footnote.copyWith(color: c.tertiaryLabel),
                  ),
                  // 标签：阅读时也要看得见（点这里也能改，不用去标题栏找）
                  if (note.tags.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 7,
                      runSpacing: 7,
                      children: [
                        for (final t in note.tags)
                          TagPill(
                            name: t,
                            onTap: () async {
                              final changed = await showNoteTagEditor(
                                context,
                                note.id,
                              );
                              if (changed && mounted) setState(_load);
                            },
                          ),
                      ],
                    ),
                  ],
                  if (state.headFieldsEnabled) ...[
                    const SizedBox(height: 12),
                    // 头参数：阅读时也要看得到，不只是编辑态
                    HeadFieldsBlock(noteId: note.id, editable: false),
                  ],
                  const SizedBox(height: 18),
                  Container(height: 0.5, color: c.separator),
                  const SizedBox(height: 18),
                ],
              ),
            ),
          ),

          ContentView(
            markdown: _content,
            imageRoot: imageRoot,
            blockKeys: _blockKeys,
            noteId: note.id,
          ),

          // 反向链接：谁的正文里写了 `[[这篇的标题]]`。
          // 放在正文之后 —— 它是"顺藤摸瓜"的出口，不该挤在开头。
          if (_backlinks.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                child: _backlinksSection(c, state),
              ),
            ),

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 44),
              child: state.tailFieldsEnabled
                  ? TailFieldsLine(noteId: note.id, editable: false)
                  : const SizedBox.shrink(),
            ),
          ),
        ],
      ),
    );

    // 目录**停靠**在正文旁边（对齐 Word 的导航窗格），不是浮在内容上的外挂件：
    // 正文该多宽就多宽，目录不遮字。位置可左右切换，宽度可拖。
    final showToc = _tocOpen && _toc.isNotEmpty;
    final tocPanel = TocPanel(
      entries: _toc,
      minLevel: minTocLevel(_toc),
      width: _tocWidth,
      side: _tocSide,
      onTap: _jumpTo,
      onFlipSide: () => setState(() {
        _tocSide = _tocSide == 'left' ? 'right' : 'left';
        context.read<AppState>().setTocSide(_tocSide);
      }),
      onClose: () => setState(() => _tocOpen = false),
    );

    // 手机上**不能停靠**：屏幕一共 390 宽，目录固定 220 留给正文只有 170，
    // 正文顶部那排按钮（返回 / 标签 / 收藏 / 编辑 / 更多 / 目录）立刻撑爆 ——
    // 真机上就是这么发现的：一开目录，页面中间出现一条
    // "RIGHT OVERFLOWED BY ..." 的条纹，目录还压到了顶栏上。
    //
    // 所以窄屏改成**浮层**：正文照旧占满宽度，目录盖在上面 + 一层可点的
    // 遮罩（点空白关掉）。这也是手机上放侧栏的常规做法。
    final narrow = MediaQuery.sizeOf(context).width < 700;

    final duration = AppMotion.respecting(context, AppMotion.normal);
    final animatedPanel = TocMotion(
      open: showToc,
      side: _tocSide,
      width: _tocWidth,
      duration: duration,
      child: tocPanel,
    );
    final body = narrow
        ? Stack(
            children: [
              scrollView,
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: !showToc,
                  child: AnimatedOpacity(
                    opacity: showToc ? 1 : 0,
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
                child: animatedPanel,
              ),
            ],
          )
        : Row(
            children: [
              if (_tocSide == 'left') ...[
                animatedPanel,
                if (showToc) TocResizer(onDrag: _resizeToc, onEnd: () {}),
              ],
              Expanded(child: scrollView),
              if (_tocSide == 'right') ...[
                if (showToc)
                  TocResizer(onDrag: (d) => _resizeToc(-d), onEnd: () {}),
                animatedPanel,
              ],
            ],
          );

    // 嵌入模式（三栏布局右侧面板）直接返回内容，
    // 不套 Scaffold，也不显示返回按钮——面板里没有"返回"这个概念。
    if (widget.embedded) return body;

    return Scaffold(backgroundColor: c.background, body: body);
  }

  /// 拖目录栏和正文之间的分隔条。
  void _resizeToc(double delta) {
    final app = context.read<AppState>();
    setState(() => _tocWidth = (_tocWidth + delta).clamp(160.0, 420.0));
    app.setTocWidth(_tocWidth);
  }

  /// 跳到某个标题。
  ///
  /// 正文用 `SliverList` 渲染，是**懒构建**的：靠后的标题此刻还没有
  /// RenderObject，直接 `ensureVisible` 会静默失败（表现就是"点了没反应"）。
  /// 交给 [revealTocTarget] 处理 —— 它会在没建出来时一屏一屏往后扫，
  /// 而不是只按比例猜一次（图片多、块高差别大时，比例估计能差出好几屏）。
  Future<void> _jumpTo(TocEntry entry) async {
    final key = _blockKeys[entry.blockIndex];
    if (key == null) return;
    await revealTocTarget(controller: _scroll, key: key);
  }

  Widget _coverBanner(AppColors c, String imageRoot, String cover, Note note) {
    // 比例 / 放大 / 取景都来自这一篇自己的设置。
    //
    // 以前这里写死 16:10 + 居中裁切，用户没法救一张竖构图或者长图；
    // 现在同一个 CoverFrame 也在编辑面板的预览里用，所见即所得。
    final image = CoverFrame(
      key: const ValueKey<String>('detail-cover'),
      path: ExternalMedia.resolve(imageRoot, cover),
      ratio: note.coverRatio,
      zoom: note.coverZoom,
      focusX: note.coverFocusX,
      focusY: note.coverFocusY,
      borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
      fallbackColor: c.fill,
      // **不要在这里钉死解码宽度。**
      //
      // 以前是 `decodeWidth: 1600` —— 听着合理（详情页的头图确实可能有
      // 那么宽），但它从**起飞第一帧**就生效：Hero 飞行时画的是目的地的
      // CoverFrame，那会儿框只有 66×66，却要按 1600 宽去解码一张本地大图。
      // 首次打开时这张 1600 的图还没进图片缓存，于是头几帧是空的、露出
      // 兜底色 —— 就是用户说的"第一次点开会闪一下"。第二次解码结果已经在
      // 缓存里，所以只有第一次看得到。
      //
      // 交给 LocalImage 按实际显示宽度算 cacheWidth（起飞时小、落定后大），
      // 再配合 gaplessPlayback：落定后换成大图时旧帧继续显示，不会闪。
      // 放大过 2 倍以上时按 2 倍解就够（再往上只是浪费内存）。
      decodeScale: note.coverZoom.clamp(1.0, 2.0),
    );

    // 点一下头图就能调比例和取景。
    //
    // 以前唯一的入口藏在「⋯ → 设置头图」里，改一个显示比例要翻两层菜单；
    // 而"这张图怎么显示"恰恰是看着它的时候最想改的东西。
    final editable = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        final state = context.read<AppState>();
        final full = state.repo.getNote(note.id);
        if (full == null || !mounted) return;
        final changed = await showCoverPicker(context, full);
        if (!mounted) return;
        if (changed) {
          // **必须重新读一遍这篇笔记**。
          //
          // 以前这里只调了 `refreshListOnly()` —— 它刷新的是列表里的
          // 那些 Note 对象，而详情页手里的 `_note` 还是打开时读的那一份，
          // 比例、放大、取景全都留在旧值上。表现就是"保存成功了，
          // 可头图一点没变"，用户会以为保存没生效。
          state.refreshListOnly();
          setState(_load);
        }
      },
      // **Hero 的直接子节点必须是头图本身。**
      //
      // Hero 飞行时会把目的地的子树塞进一个**紧约束**的盒子里。以前
      // Stack 整个在 Hero 里，而 Stack 给非定位子节点的是**松约束**，
      // 里面的 AspectRatio 就按宽度把高度算成 宽/比例 —— 起飞第一帧那
      // 66×66 的方框里，头图被压成 66×41 再一路长回去，用户看到的就是
      // "点开瞬间跳一下"。角标挪到 Hero 外面以后，紧约束直接落到
      // AspectRatio 上，首末帧都和静止时一模一样。
      child: image,
    );

    final badge = Positioned(
      right: 8,
      bottom: 8,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.38),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.crop_rounded, size: 12, color: Colors.white),
              const SizedBox(width: 4),
              Text(
                '调整',
                style: AppText.caption2.copyWith(color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );

    // 嵌入桌面栏不走 Hero（列表和正文同处一个路由）；独立详情页保留
    // 原来的 Hero，让移动端卡片展开和桌面独立页的封面过渡保持连续。
    if (!widget.embedded) {
      return Stack(
        children: [
          Hero(
            key: widget.coverKey,
            tag: 'note-cover-${note.id}',
            child: editable,
          ),
          badge,
        ],
      );
    }
    return Stack(children: [editable, badge]);
  }
}
