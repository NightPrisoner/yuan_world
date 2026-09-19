/// desktop_workspace.dart 的 part：拖拽、分隔条、导航行、笔记卡片这些零件。
///
/// 拆出来只是为了让主文件回到能读的长度 —— 三栏布局的状态机本身就有
/// 一千六百多行，再压上一千行零件，想找某个拖拽高亮是在哪画的得翻半天。
///
/// 用 part 而不是独立 library：这些类都是私有的，拆成独立文件就得
/// 全部改成公开 —— 为了排版把封装拆了不划算。
part of 'desktop_workspace.dart';

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
    final hasCover = effectiveCover(n.coverImage) != null;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      // 瀑布流卡片是"一张张看"的：抬得比列表行明显一点（2px + 1.2%），
      // 加上封面缓慢放大，鼠标扫过时整面墙是活的
      child: HoverLift(
        dy: -2,
        scale: 1.012,
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
                    : (_hover
                        ? c.separator.withValues(alpha: c.isDark ? 0.9 : 0.8)
                        : (c.isDark
                            ? c.separator.withValues(alpha: 0.4)
                            : const Color(0x0F000000))),
                width: widget.selected ? 1.5 : 0.5,
              ),
              // 悬停时给一点投影：只有"抬起来"配上影子才成立
              boxShadow: _hover && !widget.selected
                  ? <BoxShadow>[
                      BoxShadow(
                        color: Colors.black
                            .withValues(alpha: c.isDark ? 0.35 : 0.10),
                        blurRadius: 14,
                        offset: const Offset(0, 5),
                      ),
                    ]
                  : null,
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
                        child: ClipRect(
                          // 封面缓慢放大（比整卡的抬起慢一点）：
                          // 像镜头轻轻推近，是"活气"最省力的一招
                          child: AnimatedScale(
                            scale: _hover ? 1.04 : 1.0,
                            duration: AppMotion.normal,
                            curve: AppMotion.enter,
                            child: Image.file(
                              File(
                                p.join(
                                  widget.imageRoot,
                                  effectiveCover(n.coverImage)!,
                                ),
                              ),
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) =>
                                  ColoredBox(color: c.fill),
                            ),
                          ),
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
              //
              // 出现时淡入 + 从 0.8 放大到 1（SpringAnimatedValue 之外
              // 最省事的一招）；不在悬停态时树里是真没有它，
              // "只有悬停才出现"这条语义不变。
              if (_hover)
                Positioned(
                  top: 4,
                  right: 4,
                  child: _FadePopIn(
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
                ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

/// 出现时"淡入 + 微微放大"。
///
/// 悬停才露出来的小控件（⋯ 按钮）如果直接闪现，会显得很生硬；
/// 用 [AppMotion.pop] 这条带回弹的曲线，冒出来的时候有点"弹"出来。
class _FadePopIn extends StatefulWidget {
  const _FadePopIn({required this.child});

  final Widget child;

  @override
  State<_FadePopIn> createState() => _FadePopInState();
}

class _FadePopInState extends State<_FadePopIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: AppMotion.fast,
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduceMotion(context)) return widget.child;
    final curved = CurvedAnimation(
      parent: _c,
      curve: AppMotion.pop,
      reverseCurve: AppMotion.exit,
    );
    return FadeTransition(
      opacity: _c,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.8, end: 1).animate(curved),
        child: widget.child,
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
      // **列表行的悬停只做"淡色"变化，不放任何高饱和色块。**
      //
      // 两版教训都记在这：
      //   1. 加过 1px 上浮 + 1.002 缩放 → 文字在非整数缩放下反复重新
      //      栅格化，一行行变模糊；
      //   2. 加过一条纯色的蓝色小竖条（还带过冲曲线）→ 鼠标上下扫过时
      //      一行行弹进弹出，用户看到的是"很快的颜色变动"，刺眼。
      // 列表是文字为主、又要一行行扫读的地方：反馈用**低对比度的底色
      // 渐变**就够了，任何饱和元素都会变成闪烁源。
      child: Pressable(
        onTap: widget.onTap,
        onSecondaryTap: (pos) => widget.onActions(AppMenuAnchor.at(pos)),
        scale: 0.99,
        opacity: 0.85,
        child: AnimatedContainer(
          // **进快、出慢**：鼠标快速划过一排时，离场是慢慢淡出的，
          // 不会"啪"地一下弹回原色 —— 那种一行行开关式的明暗跳变
          // 就是用户说的"很快的颜色变动 / 闪眼"。
          duration: _hover ? AppMotion.instant : AppMotion.normal,
          curve: AppMotion.enter,
          margin: const EdgeInsets.only(bottom: 4),
          padding: const EdgeInsets.fromLTRB(11, 9, 8, 9),
          decoration: BoxDecoration(
            // 悬停底色用**极低透明度**的墨色/白色薄薄一层：
            // 以前用 secondaryBackground（一整块面板色），明暗差太大，
            // 鼠标扫过一排就是一遍明暗闪烁。反馈还在，但只是"掠过"的量级。
            color: widget.selected
                ? c.tint.withValues(alpha: c.isDark ? 0.20 : 0.12)
                : (_hover
                    ? c.label.withValues(alpha: c.isDark ? 0.07 : 0.04)
                    : Colors.transparent),
            borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
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
                              color: n.title.isEmpty
                                  ? c.tertiaryLabel
                                  : c.label,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (n.isFavorite)
                          Icon(Icons.star_rounded,
                              size: 12, color: c.palette[7]),
                        // **给 ⋯ 预留固定宽度**（21px），悬停时只做淡入。
                        //
                        // 以前是"出现时才占位"，于是鼠标扫过时标题会被
                        // 挤窄一下再弹回来 —— 一行行地挤，看起来就是闪。
                        // 位置恒定的槽位 + 只改透明度，标题一个字都不会动。
                        SizedBox(
                          width: 21,
                          child: _hover
                              ? _FadePopIn(
                                  child: Align(
                                    alignment: Alignment.centerRight,
                                    child: Builder(
                                      builder: (btnCtx) => GestureDetector(
                                        onTap: () => widget.onActions(
                                          AppMenuAnchor(context: btnCtx),
                                        ),
                                        behavior: HitTestBehavior.opaque,
                                        child: Icon(
                                          Icons.more_horiz_rounded,
                                          size: 15,
                                          color: c.tertiaryLabel,
                                        ),
                                      ),
                                    ),
                                  ),
                                )
                              : const SizedBox.shrink(),
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
            ],
          ),
        ),
      ),
    );
  }
}
