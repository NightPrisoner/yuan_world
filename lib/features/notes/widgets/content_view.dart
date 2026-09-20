/// 正文渲染器。详情页的阅读态和编辑器的预览态共用这一份实现。
///
/// 排版要点（中文长文的可读性）：
///   - 正文行高 1.85：1.5 在中文下会显得挤
///   - 段间距 14，标题上下留白按级别递减
///   - 引用块带左侧主题色竖线 + 淡底
///   - 图片圆角 16，点击进入全屏预览（可下拉关闭）
library;

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../app_state.dart';
import '../../../core/motion/app_motion.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/local_image.dart';
import '../../../data/media/media_importer.dart';
import 'media_card.dart';
import '../../../core/utils/text_stats.dart';

class ContentView extends StatelessWidget {
  const ContentView({
    super.key,
    required this.markdown,
    required this.imageRoot,
    this.padding = const EdgeInsets.fromLTRB(20, 0, 20, 60),
    this.blockKeys,
    this.noteId,
  });

  final String markdown;
  final String imageRoot;
  final EdgeInsets padding;

  /// 按 block 下标指定的 key，目录跳转靠它定位。
  final Map<int, GlobalKey>? blockKeys;

  /// 传了就在看图时多一个「设为头图」。
  final int? noteId;

  @override
  Widget build(BuildContext context) {
    final blocks = parseContent(markdown);

    // 把正文里的图片收集起来，点任意一张都能**左右翻看其余几张**。
    // 视频不算 —— 它有自己的播放器，塞进图片轮播里没意义。
    final gallery = <String>[
      for (final b in blocks)
        if (b.type == ContentBlockType.image &&
            !MediaImporter.isVideoPath(b.text.trim()))
          p.join(imageRoot, b.text.trim()),
    ];

    return SliverPadding(
      padding: padding,
      sliver: SliverList.builder(
        itemCount: blocks.length,
        itemBuilder: (context, i) {
          final view = ContentBlockView(
            block: blocks[i],
            imageRoot: imageRoot,
            onImageTap: (path) {
              final idx = gallery.indexOf(path);
              showImageViewer(
                context,
                images: gallery.isEmpty ? <String>[path] : gallery,
                initialIndex: idx < 0 ? 0 : idx,
                noteId: noteId,
              );
            },
          );
          final k = blockKeys?[i];
          // 有 key 的 block 包一层，Scrollable.ensureVisible 才能找到它
          return k == null ? view : KeyedSubtree(key: k, child: view);
        },
      ),
    );
  }
}

/// 非 Sliver 场景（编辑器预览）用的版本。
class ContentViewBox extends StatelessWidget {
  const ContentViewBox({
    super.key,
    required this.markdown,
    required this.imageRoot,
    this.padding = const EdgeInsets.fromLTRB(20, 0, 20, 60),
  });

  final String markdown;
  final String imageRoot;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final blocks = parseContent(markdown);
    final gallery = <String>[
      for (final b in blocks)
        if (b.type == ContentBlockType.image &&
            !MediaImporter.isVideoPath(b.text.trim()))
          p.join(imageRoot, b.text.trim()),
    ];
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final b in blocks)
            ContentBlockView(
              block: b,
              imageRoot: imageRoot,
              onImageTap: (path) {
                final idx = gallery.indexOf(path);
                showImageViewer(
                  context,
                  images: gallery.isEmpty ? <String>[path] : gallery,
                  initialIndex: idx < 0 ? 0 : idx,
                );
              },
            ),
        ],
      ),
    );
  }
}

class ContentBlockView extends StatelessWidget {
  const ContentBlockView({
    super.key,
    required this.block,
    required this.imageRoot,
    required this.onImageTap,
  });

  final ContentBlock block;
  final String imageRoot;
  final ValueChanged<String> onImageTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    switch (block.type) {
      case ContentBlockType.heading:
        final size = switch (block.level) {
          1 => 24.0,
          2 => 21.0,
          3 => 19.0,
          _ => 17.0,
        };
        return Padding(
          padding: EdgeInsets.only(top: block.level <= 2 ? 20 : 14, bottom: 8),
          child: Text(
            block.text,
            style: AppText.title3.copyWith(
              fontSize: size,
              color: c.label,
              height: 1.4,
            ),
          ),
        );

      case ContentBlockType.paragraph:
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: RichParagraph(text: block.text),
        );

      case ContentBlockType.quote:
        return Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            decoration: BoxDecoration(
              color: c.fill.withValues(alpha: 0.5),
              borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
              border: Border(left: BorderSide(color: c.tint, width: 3)),
            ),
            child: RichParagraph(
              text: block.text,
              base: AppText.body.copyWith(color: c.secondaryLabel, height: 1.75),
            ),
          ),
        );

      case ContentBlockType.bullet:
      case ContentBlockType.ordered:
        return Padding(
          padding: const EdgeInsets.only(bottom: 8, left: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 9, right: 10),
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: c.tint,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Expanded(child: RichParagraph(text: block.text)),
            ],
          ),
        );

      case ContentBlockType.divider:
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 18),
          child: Container(height: 0.5, color: c.separator),
        );

      case ContentBlockType.code:
        return Container(
          width: double.infinity,
          margin: const EdgeInsets.only(bottom: 14),
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: c.fill,
            borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
          ),
          child: Text(
            block.text,
            style: AppText.footnote.copyWith(
              color: c.label,
              fontFamily: 'Consolas',
              height: 1.6,
            ),
          ),
        );

      case ContentBlockType.image:
        final full = p.join(imageRoot, block.text);
        final file = File(full);
        // 视频在正文里也写成 `![](路径)`，但按扩展名走播放卡片 ——
        // 丢给 Image.file 只会得到一个加载失败的灰块
        if (MediaImporter.isVideoPath(block.text)) {
          // key 见编辑器那边的说明：列表重建时把播放器保住，
          // 否则视频会被销毁重建、回到 00:00 暂停
          return MediaCard(
            key: ValueKey<String>('media-${block.text}'),
            path: full,
            relPath: block.text,
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 18),
          child: Pressable(
            scale: 0.985,
            onTap: () => onImageTap(full),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
              child: file.existsSync()
                  ? LocalImage(
                      path: full,
                      fit: BoxFit.contain,
                      errorBuilder: (_) => _brokenImage(c),
                    )
                  : _brokenImage(c),
            ),
          ),
        );
    }
  }

  Widget _brokenImage(AppColors c) => Container(
    height: 120,
    decoration: BoxDecoration(
      color: c.fill,
      borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
    ),
    child: Center(
      child: Icon(Icons.image_not_supported_outlined,
          color: c.tertiaryLabel, size: 22),
    ),
  );
}

/// 段落富文本：支持 **加粗**、*斜体*、`代码`。
///
/// 没有引入完整的 Markdown 渲染库：文集正文里用到的最多就是加粗，
/// 自己解析两三种标记足够，而且能精确控制字号、行高与中文字间距。
class RichParagraph extends StatelessWidget {
  const RichParagraph({super.key, required this.text, this.base});

  final String text;
  final TextStyle? base;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final style = base ?? AppText.reading.copyWith(color: c.label);
    final spans = _parseInline(context, text, style, c);
    return SelectableText.rich(TextSpan(children: spans), style: style);
  }

  static List<InlineSpan> _parseInline(
    BuildContext context,
    String input,
    TextStyle base,
    AppColors c,
  ) {
    final spans = <InlineSpan>[];
    // 链接放在最前面：`[文字](url)` 里的方括号可能还包着别的标记，
    // 先切出来才不会和 `**` 的正则互相咬。
    //
    // **裸链接也要认**：Word 文档导入后常常是一串 https://… 直接躺在正文里，
    // 不是 markdown 的 `[文字](url)`。只认后者的话，用户点它毫无反应。
    final re = RegExp(
      r'(\[[^\]]+\]\([^)]+\)|https?://[^\s<>()（）【】]+'
      r'|\*\*[^*]+\*\*|\*[^*]+\*|`[^`]+`)',
    );
    var last = 0;
    for (final m in re.allMatches(input)) {
      if (m.start > last) {
        spans.add(TextSpan(text: input.substring(last, m.start)));
      }
      final token = m.group(0)!;
      if (token.startsWith('[')) {
        spans.add(_linkSpan(context, token, base, c));
      } else if (token.startsWith('http')) {
        spans.add(_bareLinkSpan(context, token, base, c));
      } else if (token.startsWith('**')) {
        spans.add(TextSpan(
          text: token.substring(2, token.length - 2),
          style: base.copyWith(fontWeight: FontWeight.w700),
        ));
      } else if (token.startsWith('`')) {
        spans.add(TextSpan(
          text: token.substring(1, token.length - 1),
          style: base.copyWith(fontFamily: 'Consolas', backgroundColor: c.fill),
        ));
      } else {
        spans.add(TextSpan(
          text: token.substring(1, token.length - 1),
          style: base.copyWith(fontStyle: FontStyle.italic),
        ));
      }
      last = m.end;
    }
    if (last < input.length) {
      spans.add(TextSpan(text: input.substring(last)));
    }
    return spans;
  }

  /// 裸链接（正文里直接躺着一串 https://…）。
  ///
  /// Word 文档导进来常常是这种形态，不认它用户就会觉得"链接点了没反应"。
  static InlineSpan _bareLinkSpan(
    BuildContext context,
    String url,
    TextStyle base,
    AppColors c,
  ) {
    // 结尾的标点多半是句子的一部分，不该算进链接
    var clean = url;
    while (clean.isNotEmpty && '.,;:!?、。，；：！？）)】」”.'.contains(clean.characters.last)) {
      clean = clean.substring(0, clean.length - 1);
    }
    if (clean.isEmpty) return TextSpan(text: url);

    final tail = url.substring(clean.length);
    return TextSpan(
      children: <InlineSpan>[
        TextSpan(
          text: clean,
          style: base.copyWith(
            color: c.tint,
            decoration: TextDecoration.underline,
            decorationColor: c.tint.withValues(alpha: 0.4),
          ),
          recognizer: TapGestureRecognizer()
            ..onTap = () => _confirmOpen(context, clean),
        ),
        if (tail.isNotEmpty) TextSpan(text: tail),
      ],
    );
  }

  /// 把 `[文字](url)` 变成一个可点的 span。
  ///
  /// 用 `TapGestureRecognizer` 而不是 WidgetSpan：后者会打断
  /// `SelectableText` 的选区，链接所在段落就没法整段复制了。
  static InlineSpan _linkSpan(
    BuildContext context,
    String token,
    TextStyle base,
    AppColors c,
  ) {
    final m = RegExp(r'^\[([^\]]+)\]\(([^)]+)\)$').firstMatch(token);
    if (m == null) return TextSpan(text: token);

    final label = m.group(1)!;
    final url = m.group(2)!.trim();
    if (!url.startsWith('http')) {
      // 相对链接（比如指向本地文件）打不开，当普通文字显示
      return TextSpan(text: label);
    }

    return TextSpan(
      text: label,
      style: base.copyWith(
        color: c.tint,
        decoration: TextDecoration.underline,
        decorationColor: c.tint.withValues(alpha: 0.4),
      ),
      recognizer: TapGestureRecognizer()
        ..onTap = () => _confirmOpen(context, url),
    );
  }

  /// 点链接先问一句再跳 —— 正文里的链接可能是误触，
  /// 而且一旦跳到浏览器，回来还得重新找位置。
  static Future<void> _confirmOpen(BuildContext context, String url) async {
    final c = context.colors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('打开链接？'),
        content: SizedBox(
          width: 380,
          child: SelectableText(
            url,
            style: AppText.footnote.copyWith(color: c.tint, height: 1.5),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('打开'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    final uri = Uri.tryParse(url);
    if (uri == null) return;
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('打不开这个链接')),
      );
    }
  }
}

/// 全屏图片预览：左右翻看同一篇里的其它图 + 双指缩放 + 下拉关闭。
///
/// [images] 是这篇笔记里的全部图片（绝对路径），[initialIndex] 是当前这张。
/// 只传一张也能用，那时候左右按钮不显示。
///
/// [noteId] 非空时多一个「设为头图」——把某张图设成封面，
/// 就放在看图这一步做，比另开一个选择器直观。
Future<void> showImageViewer(
  BuildContext context, {
  required List<String> images,
  int initialIndex = 0,
  int? noteId,
}) {
  if (images.isEmpty) return Future<void>.value();
  final start = initialIndex.clamp(0, images.length - 1);
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      opaque: false,
      barrierColor: Colors.black,
      transitionDuration: AppMotion.normal,
      reverseTransitionDuration: AppMotion.fast,
      pageBuilder: (ctx, a, s) =>
          ImageViewer(images: images, initialIndex: start, noteId: noteId),
      transitionsBuilder: (ctx, a, s, child) => FadeTransition(
        opacity: CurvedAnimation(parent: a, curve: AppMotion.enter),
        child: child,
      ),
    ),
  );
}

class ImageViewer extends StatefulWidget {
  const ImageViewer({
    super.key,
    required this.images,
    this.initialIndex = 0,
    this.noteId,
  });

  final List<String> images;
  final int initialIndex;
  final int? noteId;

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> {
  double _drag = 0;
  late int _index = widget.initialIndex;
  late final PageController _pages = PageController(initialPage: _index);

  /// 控件是否可见。
  ///
  /// 看图时最想看的是图本身 —— 点一下空白就把箭头、页码、关闭、设为头图
  /// 全收掉，再点一下回来。这是所有看图工具的通用手势。
  bool _uiVisible = true;

  /// 当前这张图的绝对路径。头图等操作都以它为准。
  String get _path => widget.images[_index];

  bool get _hasMultiple => widget.images.length > 1;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _go(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.images.length) return;
    _pages.animateToPage(
      next,
      duration: AppMotion.normal,
      curve: AppMotion.enter,
    );
  }

  /// 把当前这张图设为头图。
  ///
  /// 库里存的是**相对图片根目录**的路径，而这里拿到的是绝对路径，
  /// 所以要按根目录截一下。
  void _setAsCover() {
    final id = widget.noteId;
    if (id == null) return;

    final state = context.read<AppState>();
    final root = state.db.imageRoot.path;
    final rel = p.isWithin(root, _path) ? p.relative(_path, from: root) : _path;

    state.repo.updateNote(id: id, coverImage: rel);
    state.refreshListOnly();
    Navigator.of(context).maybePop();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已设为头图'), duration: Duration(seconds: 2)),
    );
  }

  Widget _coverButton() {
    return Pressable(
      onTap: _setAsCover,
      scale: 0.95,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white24, width: 0.5),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wallpaper_rounded, size: 16, color: Colors.white),
            SizedBox(width: 7),
            Text(
              '设为头图',
              style: TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onVerticalDragUpdate: (d) => setState(() => _drag += d.delta.dy),
      onVerticalDragEnd: (d) {
        if (_drag.abs() > 110) {
          Navigator.of(context).maybePop();
        } else {
          setState(() => _drag = 0);
        }
      },
      child: Stack(
        children: [
          Positioned.fill(
            child: Transform.translate(
              offset: Offset(0, _drag),
              child: Transform.scale(
                scale: (1 - (_drag.abs() / 1400)).clamp(0.85, 1.0),
                // 点一下图片 → 收起/展开控件。
                // 用 translucent 而不是 opaque：横滑手势要照常传给 PageView，
                // 只有"没怎么动就抬手"才算点击。
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: () => setState(() => _uiVisible = !_uiVisible),
                  // 横滑翻页：手机上直接左右划，桌面上也可以用触控板
                  child: PageView.builder(
                    controller: _pages,
                    itemCount: widget.images.length,
                    onPageChanged: (i) => setState(() => _index = i),
                    itemBuilder: (context, i) => InteractiveViewer(
                      minScale: 1,
                      maxScale: 5,
                      child: Center(
                        // **这里故意不解码缩放**：看图页能放大到 5 倍，
                        // 降采样之后再放大就是一坨马赛克（见 local_image.dart）
                        child: Image.file(
                          File(widget.images[i]),
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.broken_image_outlined,
                            color: Colors.white38,
                            size: 40,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // ── 控件层 ──
          // 统一淡入淡出，并且**收起时不吃事件** ——
          // 只在视觉上消失但还能点的话，用户会在"空白处"误触到关闭。
          Positioned.fill(
            child: IgnorePointer(
              ignoring: !_uiVisible,
              child: AnimatedOpacity(
                opacity: _uiVisible ? 1 : 0,
                duration: AppMotion.normal,
                curve: AppMotion.enter,
                child: Stack(
                  children: [
                    // 左右切换：手机靠横滑，桌面靠这两个按钮
                    // —— 鼠标拖不动 PageView。
                    if (_hasMultiple) ...[
                      _arrow(
                        left: true,
                        enabled: _index > 0,
                        onTap: () => _go(-1),
                      ),
                      _arrow(
                        left: false,
                        enabled: _index < widget.images.length - 1,
                        onTap: () => _go(1),
                      ),
                      // 页码：不显示的话用户不知道一共几张、自己在第几张
                      Positioned(
                        top: MediaQuery.paddingOf(context).top + 16,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.45),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              '${_index + 1} / ${widget.images.length}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                    Positioned(
                      top: MediaQuery.paddingOf(context).top + 8,
                      right: 12,
                      child: IconButton(
                        icon: const Icon(Icons.close_rounded, color: Colors.white),
                        onPressed: () => Navigator.of(context).maybePop(),
                      ),
                    ),
                    if (widget.noteId != null)
                      Positioned(
                        bottom: MediaQuery.paddingOf(context).bottom + 28,
                        left: 0,
                        right: 0,
                        child: Center(child: _coverButton()),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 左右箭头。到头了就淡掉并且不可点 —— 让用户知道"没有更多了"，
  /// 比点了没反应清楚。
  Widget _arrow({
    required bool left,
    required bool enabled,
    required VoidCallback onTap,
  }) => Positioned(
    left: left ? 12 : null,
    right: left ? null : 12,
    top: 0,
    bottom: 0,
    child: Center(
      child: Opacity(
        opacity: enabled ? 1 : 0.25,
        child: Pressable(
          onTap: enabled ? onTap : null,
          scale: 0.9,
          child: Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              shape: BoxShape.circle,
            ),
            child: Icon(
              left
                  ? Icons.chevron_left_rounded
                  : Icons.chevron_right_rounded,
              size: 26,
              color: Colors.white,
            ),
          ),
        ),
      ),
    ),
  );
}
