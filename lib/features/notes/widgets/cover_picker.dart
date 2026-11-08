/// 头图编辑器。
///
/// 一开始这里只能"选一张图"，比例和裁切是写死的 16:10 + 居中 —— 竖构图
/// 被裁掉一大半、长图只剩中间一条、人像的脸经常正好切在边上，用户没有
/// 任何办法。现在这个面板把「怎么显示」也交出来：
///
///   - **比例**：七档预设（21:9 … 9:16）+ 自定义 + 跟随图片
///   - **缩放**：0.1× 到 10×，两头都留够
///   - **取景**：直接在预览上拖动，决定露出来的是哪一边
///   - **换图**：正文里的其它图片横向排一条，点一下就用它
///
/// 面板始终显示**真的那一块头图**（用同一套 [CoverFrame]），所以调的时候
/// 看到什么，存下来就是什么。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart'
    show DragStartBehavior, PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../app_state.dart';
import '../../../core/motion/app_motion.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/local_image.dart';
import '../../../data/media/external_media.dart';
import '../../../data/media/media_importer.dart';
import '../../../data/models.dart';
import '../../../data/repositories/note_repository.dart';
import '../editor/body_segments.dart';
import 'cover_frame.dart';

/// 缩放的上下限。
///
/// 下限压到 0.1：把一张长图整张塞进一个扁框里，需要缩到很小才行；
/// 上限放到 10：一张远景截图里认一个人脸，只能靠放大。
const double kCoverZoomMin = 0.1;
const double kCoverZoomMax = 10.0;

/// 弹出头图编辑器。返回 true 表示有改动。
///
/// 用对话框而不是底部面板：桌面上从屏幕底下升起来的面板
/// 既不符合习惯，也会盖住正在看的内容。
Future<bool> showCoverPicker(BuildContext context, Note note) async {
  final changed = await showDialog<bool>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: ctx.colors.secondaryBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: _CoverPicker(note: note),
      ),
    ),
  );
  return changed ?? false;
}

class _CoverPicker extends StatefulWidget {
  const _CoverPicker({required this.note});
  final Note note;

  @override
  State<_CoverPicker> createState() => _CoverPickerState();
}

class _CoverPickerState extends State<_CoverPicker> {
  List<String> _images = const <String>[];
  String? _current;
  bool _busy = false;

  /// 每张候选图的原始宽高比（宽/高）。解码一次就记着 ——
  /// 「跟随图片」和缩略图都要用，而解码一张大图不便宜。
  final Map<String, double> _aspects = <String, double>{};

  // ── 正在编辑的显示参数 ──
  late double _ratio = widget.note.coverRatio;
  late double _zoom = widget.note.coverZoom;
  late double _fx = widget.note.coverFocusX;
  late double _fy = widget.note.coverFocusY;

  /// 比例是否跟着图片本身走（= 整张图完整显示，不裁）。
  bool _followImage = false;

  /// 「自定义比例」那行滑块展开着没有。
  bool _customOpen = false;

  /// 用户动过任何一项（用来决定"保存"要不要亮、关闭时要不要确认）。
  bool _dirty = false;

  /// 手指正按在预览上（拖动取景中）。
  ///
  /// 用它把外层滚动切成不可滚：否则一次拖动既改取景又翻页面。
  bool _dragging = false;

  @override
  void initState() {
    super.initState();
    final note = widget.note;
    // 正文里的图片就是候选：用同一套分段逻辑，保证和编辑器里看到的一致。
    //
    // **视频必须排除**：正文里视频和图片用的是同一套 `![](路径)` 语法，
    // 但 `Image.file` 打开一个 mp4 会失败，界面上就是一张灰图 ——
    // 用户看到"不存在的图"，其实那是一段视频。
    _images = splitBodySegments(note.content)
        .whereType<ImageSegment>()
        .map((s) => s.path)
        .where((path) => !MediaImporter.isVideoPath(path))
        // 文件真的存在才算候选，否则同样是灰图
        .where(
          (path) => File(
            ExternalMedia.resolve(imageRootOf(context), path),
          ).existsSync(),
        )
        .toSet()
        .toList();
    _current = note.coverImage;
    final visible = displayCover(_current, imageRootOf(context));
    if (visible != null) _loadAspect(visible);
  }

  String imageRootOf(BuildContext context) =>
      context.read<AppState>().db.imageRoot.path;

  /// 当前真正该显示的头图（排掉 `__none__` 与文件已不在的）。
  String? get _visibleCover => displayCover(_current, imageRootOf(context));

  void _touch(VoidCallback fn) {
    setState(() {
      fn();
      _dirty = true;
    });
  }

  /// 解码出这张图的宽高比，顺手在"跟随图片"模式下把比例对齐过去。
  Future<void> _loadAspect(String rel) async {
    if (_aspects.containsKey(rel)) return;
    try {
      final file = File(ExternalMedia.resolve(imageRootOf(context), rel));
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      final aspect = frame.image.width / frame.image.height;
      frame.image.dispose();
      codec.dispose();
      if (!mounted) return;
      setState(() {
        _aspects[rel] = aspect;
        if (_followImage) _ratio = aspect.clamp(0.2, 6.0);
      });
    } catch (_) {
      // 解不出来就算了：只是没有"跟随图片"和缩略图尺寸，不影响手动调
    }
  }

  /// 选图 = 换一张，不立刻关闭：用户多半紧接着要调比例和取景。
  void _pick(String rel) {
    _touch(() => _current = rel);
    final visible = displayCover(rel, imageRootOf(context));
    if (visible != null) _loadAspect(visible);
  }

  /// 从本地传一张进来，拷到这篇笔记的图片目录下再设为头图。
  Future<void> _upload() async {
    final state = context.read<AppState>();
    // file_picker 12.x：静态方法，返回 PlatformFile（不是 FilePickerResult）
    final picked = await FilePicker.pickFile(
      dialogTitle: '选择一张图片作为头图',
      type: FileType.image,
    );
    final path = picked?.path;
    if (path == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final root = state.db.imageRoot.path;
      final dir = Directory(p.join(root, '${widget.note.id}'));
      if (!dir.existsSync()) dir.createSync(recursive: true);

      // 用时间戳命名，避免和已有的同名文件撞上
      final ext = p.extension(path).isEmpty ? '.png' : p.extension(path);
      final fileName = 'cover_${DateTime.now().millisecondsSinceEpoch}$ext';
      File(path).copySync(p.join(dir.path, fileName));

      if (!mounted) return;
      setState(() {
        _busy = false;
        _current = '${widget.note.id}/$fileName';
        _dirty = true;
      });
      _loadAspect('${widget.note.id}/$fileName');
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('上传失败：$e')));
    }
  }

  void _resetFrame() {
    _touch(() {
      _ratio = Note.defaultCoverRatio;
      _zoom = 1;
      _fx = 0;
      _fy = 0;
      _followImage = false;
      _customOpen = false;
    });
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    state.repo.updateNote(
      id: widget.note.id,
      // 这里必须显式传，哪怕是 null 的情况也由 `_pick('')` 决定；
      // 传 null 表示"别动这一列"，那就丢掉用户刚选的图了。
      coverImage: _current ?? '',
      coverRatio: _ratio,
      coverZoom: _zoom,
      coverFocusX: _fx,
      coverFocusY: _fy,
    );
    // **dataChanged: true**：头图参数也算数据变了。
    //
    // 只调 `refreshListOnly()` 的话列表对象会换新，但别处（详情页、统计）
    // 靠 `dataRevision` 判断"要不要重读"，版本号不动就收不到通知 ——
    // 手机上保存完回不到最新状态，就是这么来的。
    state.refreshListOnly(dataChanged: true);
    if (mounted) Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final root = context.read<AppState>().db.imageRoot.path;
    final cover = _visibleCover;

    // 面板永远不许超出屏幕。
    //
    // 以前内容是 `Column(mainAxisSize: min)` 一路往下排，中间那块网格
    // 用 `Flexible` 抢剩余高度 —— 手机上一共就那么高，预览 + 网格 +
    // 比例 + 滑块 + 三个按钮叠起来必然超，于是按钮被顶到屏幕外面，
    // 用户根本点不到"保存"。现在：高度由屏幕决定，中间整段可以滚动。
    final size = MediaQuery.sizeOf(context);
    final maxHeight = math.max(
      240.0,
      size.height - MediaQuery.paddingOf(context).vertical - 40,
    );

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 560, maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
              child: Text(
                '头图',
                style: AppText.headline.copyWith(color: c.label),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: Text(
                cover == null ? '先选一张图，再调比例和取景' : '拖动预览可以调整取景，下面换比例和缩放',
                style: AppText.caption1.copyWith(color: c.tertiaryLabel),
              ),
            ),

            // 中间整段可滚：内容再多也只是滚，不会把按钮挤出屏幕
            Flexible(
              child: ScrollConfiguration(
                // 同样把鼠标算进拖动设备：桌面端可以直接按住往上拖。
                behavior: ScrollConfiguration.of(context).copyWith(
                  dragDevices: const <PointerDeviceKind>{
                    PointerDeviceKind.touch,
                    PointerDeviceKind.mouse,
                    PointerDeviceKind.trackpad,
                    PointerDeviceKind.stylus,
                    PointerDeviceKind.invertedStylus,
                    PointerDeviceKind.unknown,
                  },
                ),
                child: SingleChildScrollView(
                // **在预览上拖动取景时，整段不许跟着上下滚。**
                //
                // 否则手指一动，画面既在挪取景又在翻页面，两个都做不准；
                // 手机上一拖就滑到别处去了。用 Listener 的按下/抬起把
                // 物理量切成"不可滚"——它在手势竞技场之前就触发，父级
                // 滚动连参赛资格都没有，pan 一定归预览。
                physics: _dragging
                    ? const NeverScrollableScrollPhysics()
                    : const ClampingScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── 预览 ──
                    if (cover != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                        child: _preview(c, root, cover),
                      ),

                    // ── 正文里的其它图片 ──
                    if (_images.isNotEmpty) _imageStrip(c, root),

                    // 比例与缩放**紧跟在预览后面**，不压到面板最底下。
                    //
                    // 之前它们排在候选图之后：手机上一屏放不下，「缩放」
                    // 直接被滚到看不见的地方，用户以为功能没了。现在的
                    // 顺序按"看 → 换 → 调"排，而且整套尺寸压到一屏能装下
                    // （预览 180、图片条 72、行距收紧），正常手机上不用滚
                    // 就能看全；只有窗口特别矮（比如键盘弹起）才需要滚。
                    if (cover != null) ...[
                      const SizedBox(height: 8),
                      _ratioRow(c),
                      if (_customOpen) _customRatioRow(c),
                      _zoomRow(c),
                    ],
                  ],
                ),
                ),
              ),
            ),

            // 「恢复默认显示」放在固定区，不塞进滚动区。
            //
            // 之前它在滚动区最底下：手机上内容一多就被滚出视野，
            // 用户改坏了想复原，得先猜"这东西在下面"再往下翻 ——
            // 一个救急的按钮不该需要找。
            if (cover != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
                child: Row(
                  children: [
                    TextButton.icon(
                      onPressed: _dirty ? _resetFrame : null,
                      icon: const Icon(Icons.restart_alt_rounded, size: 16),
                      label: const Text('恢复默认显示'),
                    ),
                    const Spacer(),
                    if (_dirty)
                      Text(
                        '有改动未保存',
                        style: AppText.caption2.copyWith(color: c.tertiaryLabel),
                      ),
                  ],
                ),
              ),

            const SizedBox(height: 8),
            Divider(height: 1, color: c.separator),
            _action(
              c,
              icon: Icons.upload_file_rounded,
              label: _busy ? '正在上传…' : '从本地选择图片',
              onTap: _busy ? null : _upload,
            ),
            // ── 三种状态各给一个明确的入口，别让一句话兼两件事 ──
            //
            // 以前只有一个「移除头图（回到默认：正文第一张图）」，可它做的
            // 其实是"彻底不要头图"（写空串），文字和行为对不上：用户想
            // "恢复成自动取第一张图"会点它，结果是头图没了。
            // 而且空串还会被自动派生逻辑当成"没设过"给补回来 ——
            // 编辑一下正文头图就自己回来了。
            if (!isCoverDisabled(_current))
              _action(
                c,
                icon: Icons.block_rounded,
                label: '不设置头图',
                onTap: () => _pick(kCoverNone),
              ),
            if (_current != null && _current!.isNotEmpty)
              _action(
                c,
                icon: Icons.auto_awesome_rounded,
                label: '改用正文第一张图',
                onTap: () => _pick(''),
              ),
            const SizedBox(height: 4),
            Divider(height: 1, color: c.separator),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _dirty ? _save : null,
                    child: const Text('保存'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _preview(AppColors c, String root, String cover) {
    // 预览区最高就这么高。
    //
    // 以前这里是裸的 `CoverFrame`，高度完全由比例决定 —— 一选 3:4，
    // 520 宽就撑出 693 高，整个面板立刻超出屏幕，控件被顶到看不见的
    // 地方。现在给它一个上限：超了就缩窄宽度（竖构图变成居中的一条），
    // 面板本身的高度不随比例变。
    //
    // 上限从 240 收到 170：手机上一屏还要装下比例行、缩放行和三行
    // action，预览占太多就得靠滚动，"缩放"又被滚出去了。
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 170),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // **拖动要让"手指按住的那个点"待在原地。**
          //
          // 以前是 `_fx + sign * delta / 面板宽度 * 2`：拿整个面板的宽度
          // 当基准、系数写死 2，既不管图片原始宽高比、也不管放大倍数。
          // 结果是"图在手指底下打滑"——按住某个点往右拖，那个点跑掉了。
          //
          // 正确的量法：把取景中心挪一格，画面到底走多远。
          // 图片先按 BoxFit.cover 铺满框（多出来的一边被裁），再以取景点
          // 为轴放大 zoom 倍。设框宽 W、cover 后图片宽 I、放大 z，可以解出
          // 画面上某个点相对取景中心的位移对 fx 的导数，反解得到：
          //
          //     dfx = 2 * 拖动距离 / (W - I * z)
          //
          // 分母是"还能往两边挪的总量"：放大到刚好铺满时它趋近 0（没得挪，
          // 拖了也不该动）；缩到比框小时它为正（拖的是图本身，方向相反）。
          // 一个公式同时覆盖放大、缩小两种情况，不用再靠 sign 猜。
          final maxW = constraints.maxWidth.clamp(1.0, 4000.0);
          final maxH = constraints.maxHeight.clamp(1.0, 4000.0);
          // 预览有高度上限，框的真实宽度可能比可用宽度小（竖构图就是这样）。
          final frameW = math.min(maxW, maxH * _ratio);
          final frameH = frameW / _ratio;
          final aspect = _aspects[cover] ?? _ratio;
          final double imgW;
          final double imgH;
          if (aspect > _ratio) {
            // 图片比框"宽"：cover 以高度为准，宽度溢出
            imgH = frameH;
            imgW = frameH * aspect;
          } else {
            // 图片比框"高"：cover 以宽度为准，高度溢出
            imgW = frameW;
            imgH = frameW / aspect;
          }
          final denX = frameW - imgW * _zoom;
          final denY = frameH - imgH * _zoom;
          return Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) {
              if (!_dragging) setState(() => _dragging = true);
            },
            onPointerMove: (e) {
              _touch(() {
                if (denX.abs() > 0.5) {
                  _fx = (_fx + e.delta.dx * 2 / denX).clamp(-1.0, 1.0);
                }
                if (denY.abs() > 0.5) {
                  _fy = (_fy + e.delta.dy * 2 / denY).clamp(-1.0, 1.0);
                }
              });
            },
            onPointerUp: (_) {
              if (_dragging) setState(() => _dragging = false);
            },
            onPointerCancel: (_) {
              if (_dragging) setState(() => _dragging = false);
            },
            child: MouseRegion(
              cursor: SystemMouseCursors.move,
              // **内层再挂一个空的拖动手势，专门用来"赢"外层滚动。**
              //
              // 光靠 Listener 不够：Listener 不参与手势竞技场，取景是跟着
              // 动了，可外层 Scrollable 也照样在滚 —— 一拖两用，页面跟着
              // 跑。这里用内层的 vertical/horizontal 识别器把竞技场赢下来
              // （同类型竞技场里越靠里越优先），外层滚动就拿不到这次拖动，
              // 而 Listener 依旧照收每一个 move，取景不受影响。
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragUpdate: (_) {},
                onHorizontalDragUpdate: (_) {},
                child: Stack(
                children: [
                  Center(
                    child: CoverFrame(
                      key: const ValueKey<String>('cover-preview'),
                      path: p.join(root, cover),
                      ratio: _ratio,
                      zoom: _zoom,
                      focusX: _fx,
                      focusY: _fy,
                      fallbackColor: c.fill,
                      borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
                      animate: true,
                    ),
                  ),
                  // 取景读数：只在动过之后显示，不然默认状态挂一堆数字很吵
                  if (_fx.abs() > 0.01 || _fy.abs() > 0.01)
                    Positioned(
                      left: 8,
                      bottom: 8,
                      child: IgnorePointer(
                        child: _badge(
                          '${(_fx * 100).round()}, ${(_fy * 100).round()}',
                        ),
                      ),
                    ),
                  if (_zoom != 1)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: IgnorePointer(
                        child: _badge('${_zoom.toStringAsFixed(2)}×'),
                      ),
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

  Widget _badge(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(text, style: AppText.caption2.copyWith(color: Colors.white)),
  );

  /// 正文里的其它图片：横向一条，点一下就用它当头图。
  ///
  /// 桌面端原来是一个四列网格，被 `Flexible` 挤在预览和按钮之间，
  /// 只露出上面一行的一半 —— 明明有十张候选图，能看到的不到三张。
  /// 换成横向滚动条：高度固定 96，张数再多也只是往右滚。
  Widget _imageStrip(AppColors c, String root) {
    // 图片多了要能滑到底：光有横向 ListView 不够。
    //
    // 手机上的问题是这条横向列表整段嵌在纵向滚动里，手指一斜就被
    // 纵向滚动抢走，看着像"滑不动"。所以：①显式给 `BouncingScrollPhysics`
    // 并把 `dragStartBehavior` 设成 down（手指一落就认定要拖，不等
    // 手势判定）；②标题后面挂一句"左右滑"，让人知道这儿能滑；
    // ③末尾留一格空白，最后一张不会贴在边框上。
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
          child: Row(
            children: [
              Text(
                '正文里的图片（${_images.length}）',
                style: AppText.caption1.copyWith(color: c.secondaryLabel),
              ),
              if (_images.length > 3) ...[
                const SizedBox(width: 8),
                Icon(
                  Icons.swipe_rounded,
                  size: 13,
                  color: c.quaternaryLabel,
                ),
                const SizedBox(width: 4),
                Text(
                  '左右滑',
                  style: AppText.caption2.copyWith(color: c.quaternaryLabel),
                ),
              ],
            ],
          ),
        ),
        SizedBox(
          height: 88,
          // **桌面端要能把鼠标算进"拖动设备"。**
          //
          // Flutter 默认的 ScrollBehavior 在桌面/网页上只把触摸和触控笔
          // 当拖动设备，鼠标不在列表里 —— 于是这条横向列表在 Windows 上
          // 鼠标按住拖不动，只能拨滚轮（还得是横向滚轮）。手机上看着没
          // 问题，桌面端就像"滑不了"。这里显式放开鼠标。
          child: ScrollConfiguration(
            behavior: ScrollConfiguration.of(context).copyWith(
              dragDevices: const <PointerDeviceKind>{
                PointerDeviceKind.touch,
                PointerDeviceKind.mouse,
                PointerDeviceKind.trackpad,
                PointerDeviceKind.stylus,
                PointerDeviceKind.invertedStylus,
                PointerDeviceKind.unknown,
              },
            ),
            child: ListView.separated(
              key: const ValueKey<String>('cover-strip'),
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              dragStartBehavior: DragStartBehavior.down,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _images.length,
              separatorBuilder: (_, _) => const SizedBox(width: 8),
              itemBuilder: (context, i) => SizedBox(
                // 给测试一个抓手：滑到没滑到，靠这层量位置
                key: ValueKey<String>(_images[i]),
                width: 88,
                child: _thumb(c, root, _images[i]),
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),
      ],
    );
  }

  Widget _ratioRow(AppColors c) {
    final aspect = _aspects[_visibleCover ?? ''];
    return Padding(
      key: const ValueKey<String>('cover-ratio-row'),
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final r in Note.coverRatioPresets)
            _chip(
              c,
              label: _ratioLabel(r),
              selected: !_followImage && (_ratio - r).abs() < 0.01,
              onTap: () => _touch(() {
                _followImage = false;
                _customOpen = false;
                _ratio = r;
              }),
            ),
          // 跟随图片：把框型直接设成图片本身的比例。
          //
          // 这时候 `BoxFit.cover` 恰好不裁任何东西 —— 整张图完整显示，
          // 这是"我就想看图，别给我裁"的唯一正解。没有这个开关时，
          // 用户只能一档档试，试到看起来"差不多没裁"为止。
          if (aspect != null)
            _chip(
              c,
              label: '跟随图片',
              selected: _followImage,
              onTap: () => _touch(() {
                _followImage = true;
                _customOpen = false;
                _ratio = aspect.clamp(0.2, 6.0);
                // 缩放也必须回到 1：框型和图片一样大时，只有 1 才是
                // "一点没裁"。留着放大倍数就等于又裁了一刀。
                _zoom = 1;
              }),
            ),
          _chip(
            c,
            label: '自定义',
            selected: _customOpen,
            onTap: () => _touch(() {
              _followImage = false;
              _customOpen = !_customOpen;
            }),
          ),
        ],
      ),
    );
  }

  /// 自定义比例：一根滑块，范围 0.3（很竖）到 3.0（很宽）。
  Widget _customRatioRow(AppColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
      child: Row(
        children: [
          Text(
            '自定义比例',
            style: AppText.caption1.copyWith(color: c.secondaryLabel),
          ),
          Expanded(
            child: Slider(
              value: _ratio.clamp(0.3, 3.0),
              min: 0.3,
              max: 3.0,
              divisions: 54,
              label: _ratioText(_ratio),
              onChanged: (v) => _touch(() {
                _followImage = false;
                _ratio = v;
              }),
            ),
          ),
          SizedBox(
            width: 64,
            child: Text(
              _ratioText(_ratio),
              textAlign: TextAlign.right,
              style: AppText.caption1.copyWith(color: c.tertiaryLabel),
            ),
          ),
        ],
      ),
    );
  }

  /// 把宽高比写成 `16:10` 这种一眼能懂的分数；不是常见档位就写 `1.85:1`。
  static String _ratioText(double r) {
    for (final preset in Note.coverRatioPresets) {
      if ((r - preset).abs() < 0.01) return _ratioLabel(preset);
    }
    if (r >= 1) return '${r.toStringAsFixed(2)}:1';
    return '1:${(1 / r).toStringAsFixed(2)}';
  }

  /// 预设的显示名。用分数写法而不是小数：`16:10` 一眼能懂，
  /// `1.6` 还得在脑子里换算。
  static String _ratioLabel(double r) {
    if ((r - 2.4).abs() < 0.01) return '21:9';
    if ((r - 1.7778).abs() < 0.01) return '16:9';
    if ((r - 1.6).abs() < 0.01) return '16:10';
    if ((r - 1.3333).abs() < 0.01) return '4:3';
    if ((r - 1.0).abs() < 0.01) return '1:1';
    if ((r - 0.75).abs() < 0.01) return '3:4';
    if ((r - 0.5625).abs() < 0.01) return '9:16';
    return r.toStringAsFixed(2);
  }

  Widget _chip(
    AppColors c, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Pressable(
      onTap: onTap,
      scale: 0.94,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? c.tint : c.fill,
          borderRadius: BorderRadius.circular(AppMetrics.radiusSm),
        ),
        child: Text(
          label,
          style: AppText.caption1.copyWith(
            color: selected ? Colors.white : c.secondaryLabel,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _zoomRow(AppColors c) {
    // 滑块走**对数刻度**。
    //
    // 线性的话 0.1…10 里最常用的 0.8…2 只占中间一小段，想精确调到
    // "刚好铺满"几乎不可能；对数刻度下每一档手感一样，两头都能用。
    final t = _zoomToSlider(_zoom);
    return Padding(
      key: const ValueKey<String>('cover-zoom'),
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
      child: Row(
        children: [
          Text('缩放', style: AppText.caption1.copyWith(color: c.secondaryLabel)),
          Expanded(
            child: Slider(
              value: t,
              min: 0,
              max: 1,
              divisions: 200,
              label: '${_zoom.toStringAsFixed(2)}×',
              onChanged: (v) => _touch(() {
                _zoom = _sliderToZoom(v);
                // 拖动时方向随缩放翻转，这里同步清掉横向取景会让手感
                // 突变，所以不动 _fx/_fy —— 用户自己接着调就行。
              }),
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              '${_zoom.toStringAsFixed(2)}×',
              textAlign: TextAlign.right,
              style: AppText.caption1.copyWith(color: c.tertiaryLabel),
            ),
          ),
        ],
      ),
    );
  }

  static double _zoomToSlider(double zoom) =>
      (math.log(zoom / kCoverZoomMin) / math.log(kCoverZoomMax / kCoverZoomMin))
          .clamp(0.0, 1.0);

  static double _sliderToZoom(double t) =>
      (kCoverZoomMin * math.pow(kCoverZoomMax / kCoverZoomMin, t)).toDouble();

  Widget _thumb(AppColors c, String root, String rel) {
    final selected = _current == rel;
    return Pressable(
      onTap: () => _pick(rel),
      scale: 0.96,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
          border: Border.all(
            color: selected ? c.tint : Colors.transparent,
            width: 2,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            LocalImage(
              path: p.join(root, rel),
              fit: BoxFit.cover,
              fallbackColor: c.fill,
              errorBuilder: (_) => ColoredBox(
                color: c.fill,
                child: Icon(
                  Icons.broken_image_outlined,
                  size: 20,
                  color: c.quaternaryLabel,
                ),
              ),
            ),
            if (selected)
              Positioned(
                right: 4,
                top: 4,
                child: Container(
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: c.tint,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    size: 12,
                    color: Colors.white,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _action(
    AppColors c, {
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
  }) => Pressable(
    onTap: onTap,
    scale: 0.99,
    opacity: 0.6,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: onTap == null ? c.quaternaryLabel : c.label,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: AppText.callout.copyWith(
                color: onTap == null ? c.quaternaryLabel : c.label,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
