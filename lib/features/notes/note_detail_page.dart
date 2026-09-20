/// 笔记详情 / 阅读页。
///
/// 阅读体验的关键处理：
///   1. 正文行高 1.85 —— 中文长文在 1.5 下会显得挤
///   2. 大标题随滚动淡出，进入阅读后把版面让给内容
///   3. 封面横幅与列表缩略图共用 Hero tag，转场时位置连续
///   4. 编辑交给独立的编辑器页（工具栏 / 预览 / 自动保存都在那边）
library;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../core/motion/app_motion.dart';
import '../../core/motion/apple_page_route.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/toc.dart';
import '../../core/widgets/app_menu.dart';
import '../../core/widgets/local_image.dart';
import '../../data/models.dart';
import '../tags/tag_sheets.dart';
import 'editor/body_segments.dart';
import 'editor/note_editor_page.dart';
import 'widgets/content_view.dart';
import 'widgets/toc_panel.dart';
import 'widgets/field_blocks.dart';
import 'widgets/note_actions.dart';

class NoteDetailPage extends StatefulWidget {
  const NoteDetailPage({
    super.key,
    required this.noteId,
    this.embedded = false,
    this.onRequestEdit,
    this.onClose,
    this.fullscreen = false,
    this.onToggleFullscreen,
    this.windowFullscreen = false,
    this.onToggleWindowFullscreen,
  });

  final int noteId;

  /// 嵌入三栏布局的右侧面板时置 true：
  /// 不套 Scaffold、不显示返回按钮、不触发 Hero。
  final bool embedded;

  /// 嵌入模式下由外部接管「去编辑」，而不是 push 一个新路由。
  final VoidCallback? onRequestEdit;

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
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _collapse.dispose();
    super.dispose();
  }

  Future<void> _openEditor() async {
    // 嵌入模式下交给外层面板切换内容，不要 push 新页面盖住整个三栏布局
    final external = widget.onRequestEdit;
    if (external != null) {
      external();
      return;
    }
    await Navigator.of(context).push(
      ApplePageRoute<void>(
        pageBuilder: (_) => NoteEditorPage(noteId: widget.noteId),
        // 编辑是「下钻」而不是「模态」，所以从右侧推入，
        // 与详情页的转场保持一致；桌面端从底部升起会很怪。
        fullscreenDialog: false,
      ),
    );
    // 编辑器里会自动保存，回来后重新读一遍
    if (mounted) setState(_load);
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
    final cover = note.coverImage;

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

    final scrollView = CustomScrollView(
      controller: _scroll,
      physics: const BouncingScrollPhysics(
        parent: AlwaysScrollableScrollPhysics(),
      ),
      slivers: <Widget>[
        SliverAppBar(
          pinned: true,
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
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 19),
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
              // 标签：以前界面上完全没有入口，标签功能等于不存在
              GlassIconButton(
                icon: Icons.label_outline_rounded,
                tooltip: note.tags.isEmpty
                    ? '标签'
                    : '标签（${note.tags.length}）',
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
              GlassIconButton(
                icon: Icons.edit_rounded,
                tooltip: '编辑',
                onTap: _openEditor,
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
              if (widget.onClose != null) ...[
                const SizedBox(width: 6),
                GlassIconButton(
                  icon: Icons.close_rounded,
                  tooltip: '收起正文栏',
                  onTap: widget.onClose!,
                ),
              ],
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
              const SizedBox(width: 16),
            ],
          ),

          // 封面横幅：与列表卡片缩略图共用 Hero tag（嵌入模式下不用 Hero）
          if (cover != null && cover.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 6, 20, 18),
                child: _coverBanner(c, imageRoot, cover, note.id),
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
                  const SizedBox(height: 10),
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
                              final changed =
                                  await showNoteTagEditor(context, note.id);
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

          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 44),
              child: state.tailFieldsEnabled
                  ? TailFieldsLine(noteId: note.id, editable: false)
                  : const SizedBox.shrink(),
            ),
          ),
        ],
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

    final body = showToc
        ? Row(
            children: [
              if (_tocSide == 'left') ...[
                tocPanel,
                TocResizer(onDrag: _resizeToc, onEnd: () {}),
              ],
              Expanded(child: scrollView),
              if (_tocSide == 'right') ...[
                TocResizer(onDrag: (d) => _resizeToc(-d), onEnd: () {}),
                tocPanel,
              ],
            ],
          )
        : scrollView;

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

  Widget _coverBanner(AppColors c, String imageRoot, String cover, int noteId) {
    final image = ClipRRect(
      borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
      child: AspectRatio(
        aspectRatio: 16 / 10,
        child: LocalImage(
          path: p.join(imageRoot, cover),
          fit: BoxFit.cover,
          fallbackColor: c.fill,
        ),
      ),
    );
    if (widget.embedded) return image;
    return Hero(tag: 'note-cover-$noteId', child: image);
  }


}