/// stats_page.dart 的 part：卡片和小组件。
///
/// 拆出来只是为了让 stats_page.dart 回到能读的长度 —— 页面状态机那 2000 多行
/// 和这些二三十行的小组件混在一个文件里，找什么都不方便。
///
/// 用 part 而不是独立 library：这些类都是私有的（_Card / _MiniSelect …），
/// 拆成独立文件就得全部改成公开，等于为了排版把封装拆了。
part of 'stats_page.dart';

class _DragHandleScope extends InheritedWidget {
  const _DragHandleScope({required this.index, required super.child});

  final int index;

  static int? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_DragHandleScope>()
      ?.index;

  @override
  bool updateShouldNotify(_DragHandleScope oldWidget) =>
      oldWidget.index != index;
}

class _Card extends StatelessWidget {
  const _Card({
    required this.title,
    required this.child,
    this.trailing,
    this.controls,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  /// 标题右侧的一排控制项（下拉、图表类型切换等）
  final List<Widget>? controls;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
        decoration: BoxDecoration(
          color: c.secondaryBackground,
          borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
          border: Border.all(
            color: c.isDark
                ? c.separator.withValues(alpha: 0.4)
                : const Color(0x0D000000),
            width: 0.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // 拖拽把手：只有把手能起拖，卡片别处照常可以滚动/点击
                if (_DragHandleScope.maybeOf(context) != null)
                  ReorderableDragStartListener(
                    index: _DragHandleScope.maybeOf(context)!,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.grab,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 7, top: 2, bottom: 2),
                        child: Icon(
                          Icons.drag_indicator_rounded,
                          size: 17,
                          color: c.quaternaryLabel,
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: Text(
                    title,
                    style: AppText.headline.copyWith(
                      color: c.label,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            if (controls != null && controls!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: controls!),
            ],
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    super.key,
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
    this.unit,
  });

  final String label;
  final String value;
  final String? unit;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: c.isDark ? 0.16 : 0.09),
          borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 13, color: color),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: AppText.caption1.copyWith(color: c.secondaryLabel),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.title3.copyWith(color: c.label),
                  ),
                ),
                if (unit != null) ...[
                  const SizedBox(width: 2),
                  Text(
                    unit!,
                    style: AppText.caption1.copyWith(color: c.tertiaryLabel),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.items});
  final List<(String, String)> items;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Wrap(
      spacing: 18,
      runSpacing: 6,
      children: [
        for (final (label, value) in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: AppText.caption1.copyWith(color: c.tertiaryLabel),
              ),
              const SizedBox(width: 5),
              Text(
                value,
                style: AppText.footnote.copyWith(
                  color: c.label,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _RankRow extends StatelessWidget {
  const _RankRow({
    required this.index,
    required this.title,
    required this.value,
    required this.ratio,
    required this.color,
    required this.onTap,
  });

  final int index;
  final String title;
  final String value;
  final double ratio;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Pressable(
      onTap: onTap,
      scale: 0.99,
      opacity: 0.7,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              child: Text(
                '${index + 1}',
                style: AppText.caption1.copyWith(
                  color: index < 3 ? color : c.quaternaryLabel,
                  fontWeight: index < 3 ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title.isEmpty ? '无标题笔记' : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.footnote.copyWith(color: c.label),
                  ),
                  const SizedBox(height: 5),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0, end: ratio),
                      duration: AppMotion.normal,
                      curve: AppMotion.enter,
                      builder: (context, v, _) => LinearProgressIndicator(
                        value: v,
                        minHeight: 5,
                        backgroundColor: c.fill,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          color.withValues(alpha: 0.75),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              value,
              style: AppText.caption1.copyWith(color: c.tertiaryLabel),
            ),
          ],
        ),
      ),
    );
  }
}

/// 时间范围 / 文件夹用的小胶囊。
/// 文件夹多选对话框。返回选中的 id 列表（空 = 全部）。
class _CollectionPicker extends StatefulWidget {
  const _CollectionPicker({required this.collections, required this.selected});

  final List<Collection> collections;
  final List<int> selected;

  @override
  State<_CollectionPicker> createState() => _CollectionPickerState();
}

class _CollectionPickerState extends State<_CollectionPicker> {
  late final Set<int> _picked = <int>{...widget.selected};

  /// 收起来的父节点。
  ///
  /// 文集一多（导入一堆文集之后很常见），全摊开会变成一条几十行的长列表，
  /// 想勾的那个要滚半天 —— 和外面左栏一样能收起来才找得到。
  final Set<int> _collapsed = <int>{};

  /// 把扁平列表还原成"深度优先"的顺序，附带层级。
  ///
  /// `allCollections()` 给的是按置顶/序号排的**扁平**列表，
  /// 直接铺出来会和左栏的树对不上 —— 统计里勾选的位置和外面的位置
  /// 不一致，用户要来回找。这里按父子关系重新走一遍。
  ///
  /// 收起来的节点**不往下走**，所以返回的就是当前该显示的那几行。
  List<({Collection col, int depth, bool hasKids, int pickedBelow})>
  get _tree {
    final byParent = <int?, List<Collection>>{};
    for (final c in widget.collections) {
      (byParent[c.parentId] ??= <Collection>[]).add(c);
    }
    final out = <({Collection col, int depth, bool hasKids, int pickedBelow})>[];
    void walk(int? parentId, int depth) {
      // 深度兜底：数据万一成环也不能把列表渲染卡死
      if (depth > 8) return;
      for (final c in byParent[parentId] ?? const <Collection>[]) {
        final kids = byParent[c.id] ?? const <Collection>[];
        out.add((
          col: c,
          depth: depth,
          hasKids: kids.isNotEmpty,
          pickedBelow: _countPickedBelow(c.id, byParent),
        ));
        if (kids.isNotEmpty && !_collapsed.contains(c.id)) walk(c.id, depth + 1);
      }
    }

    walk(null, 0);
    return out;
  }

  /// 这个节点下面（不含自己）勾了几个。
  ///
  /// 收起来之后底下勾着什么是看不见的，不提示的话用户会以为白勾了。
  int _countPickedBelow(int id, Map<int?, List<Collection>> byParent) {
    var n = 0;
    void walk(int pid, int depth) {
      if (depth > 8) return;
      for (final c in byParent[pid] ?? const <Collection>[]) {
        if (_picked.contains(c.id)) n++;
        walk(c.id, depth + 1);
      }
    }

    walk(id, 0);
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final all = widget.collections;
    final tree = _tree;

    return Dialog(
      backgroundColor: c.secondaryBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 520),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '选择文件夹',
                style: AppText.headline.copyWith(color: c.label),
              ),
              const SizedBox(height: 3),
              Text(
                '选两个以上就能在趋势、累计里互相对比',
                style: AppText.caption1.copyWith(color: c.tertiaryLabel),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _mini(c, '全部（不筛选）', () => setState(_picked.clear)),
                  const SizedBox(width: 8),
                  _mini(
                    c,
                    '全选',
                    () => setState(
                      () => _picked
                        ..clear()
                        ..addAll(all.map((x) => x.id)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _mini(
                    c,
                    '反选',
                    () => setState(() {
                      final next =
                          all.map((x) => x.id).toSet().difference(_picked);
                      _picked
                        ..clear()
                        ..addAll(next);
                    }),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Flexible(
                child: all.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Text(
                          '还没有文件夹',
                          textAlign: TextAlign.center,
                          style:
                              AppText.caption1.copyWith(color: c.tertiaryLabel),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: tree.length,
                        itemBuilder: (context, i) {
                          final node = tree[i];
                          final col = node.col;
                          final collapsed = _collapsed.contains(col.id);
                          final on = _picked.contains(col.id);
                          return Pressable(
                            onTap: () => setState(() {
                              if (!_picked.remove(col.id)) _picked.add(col.id);
                            }),
                            scale: 0.995,
                            haptic: false,
                            child: Padding(
                              // 按层级缩进，嵌套关系和外面一致
                              padding: EdgeInsets.fromLTRB(
                                0,
                                6,
                                0,
                                6,
                              ).add(EdgeInsets.only(left: node.depth * 16)),
                              child: Row(
                                children: [
                                  // 展开/收起的三角。没有子文件夹时留同样的空位，
                                  // 否则同级之间会错开一格
                                  SizedBox(
                                    width: 20,
                                    child: node.hasKids
                                        ? Pressable(
                                            onTap: () => setState(() {
                                              if (!_collapsed.remove(col.id)) {
                                                _collapsed.add(col.id);
                                              }
                                            }),
                                            scale: 0.85,
                                            haptic: false,
                                            child: Icon(
                                              collapsed
                                                  ? Icons
                                                        .chevron_right_rounded
                                                  : Icons.expand_more_rounded,
                                              size: 18,
                                              color: c.tertiaryLabel,
                                            ),
                                          )
                                        : null,
                                  ),
                                  Icon(
                                    on
                                        ? Icons.check_box_rounded
                                        : Icons.check_box_outline_blank_rounded,
                                    size: 18,
                                    color: on ? c.tint : c.quaternaryLabel,
                                  ),
                                  const SizedBox(width: 10),
                                  Icon(
                                    node.depth > 0
                                        ? Icons.subdirectory_arrow_right_rounded
                                        : Icons.folder_rounded,
                                    size: 16,
                                    color: Color(col.color),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      col.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppText.callout
                                          .copyWith(color: c.label),
                                    ),
                                  ),
                                  // 收起来时底下还勾着什么，得说出来
                                  if (collapsed && node.pickedBelow > 0)
                                    Text(
                                      '含 ${node.pickedBelow} 个已选',
                                      style: AppText.caption2.copyWith(
                                        color: c.tint,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _picked.isEmpty ? '当前：全部' : '已选 ${_picked.length} 个',
                      style: AppText.caption1.copyWith(
                        color: _picked.isEmpty ? c.tertiaryLabel : c.tint,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () =>
                        Navigator.pop(context, _picked.toList()),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mini(AppColors c, String label, VoidCallback onTap) => Pressable(
    onTap: onTap,
    scale: 0.95,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: c.fill,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        label,
        style: AppText.caption1.copyWith(color: c.secondaryLabel),
      ),
    ),
  );
}

/// 筛选下拉按钮。比一排 chip 省地方，也不会随选项增多而溢出。
class _FilterButton extends StatefulWidget {
  const _FilterButton({
    required this.icon,
    required this.label,
    required this.accent,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color accent;
  final VoidCallback onTap;

  @override
  State<_FilterButton> createState() => _FilterButtonState();
}

class _FilterButtonState extends State<_FilterButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Pressable(
        onTap: widget.onTap,
        scale: 0.97,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          padding: const EdgeInsets.fromLTRB(11, 6, 8, 6),
          decoration: BoxDecoration(
            color: _hover
                ? c.fill
                : widget.accent.withValues(alpha: c.isDark ? 0.20 : 0.11),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 14, color: widget.accent),
              const SizedBox(width: 6),
              ConstrainedBox(
                // 名字太长时截断，别把整行撑破
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.footnote.copyWith(
                    color: widget.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.expand_more_rounded, size: 15, color: widget.accent),
            ],
          ),
        ),
      ),
    );
  }
}


/// 卡片里的小分段选择（两三个选项）。
///
/// 和 [_MiniSelect] 的区别是**不弹菜单**：选项少的时候摊开更好 ——
/// 一次点击就能切，不用"点开→再点一下"，而且**不涉及弹出路由**。
/// 弹出菜单是模态的，底下一层遮罩；控制项少的时候为它付这个代价不值得，
/// 遮罩一旦留下没关干净，整页就点不动了。
class _Segmented<T> extends StatelessWidget {
  const _Segmented({
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onChanged,
    this.keyOf,
  });

  final T value;
  final List<T> options;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  /// 给每段一个稳定的 key，测试能直接点某一段。
  final String Function(T)? keyOf;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: c.fill,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (final o in options)
            Pressable(
              key: keyOf == null ? null : Key(keyOf!(o)),
              // 已经是当前项就不要再回调：省一次无意义的重算
              onTap: o == value ? null : () => onChanged(o),
              scale: 0.95,
              haptic: false,
              child: AnimatedContainer(
                duration: AppMotion.fast,
                curve: AppMotion.enter,
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: o == value ? c.tint : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  labelOf(o),
                  style: AppText.caption1.copyWith(
                    color: o == value ? Colors.white : c.secondaryLabel,
                    fontWeight: o == value ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 卡片里的小下拉（粒度、指标）。
class _MiniSelect<T> extends StatelessWidget {
  const _MiniSelect({
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onChanged,
  });

  final T value;
  final List<T> options;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Pressable(
      onTap: () async {
        final picked = await showAppMenu<T>(
          context,
          anchor: AppMenuAnchor(context: context),
          items: <AppMenuItem<T>>[
            for (final o in options)
              AppMenuItem(
                value: o,
                label: labelOf(o),
                icon: o == value
                    ? Icons.check_circle_rounded
                    : Icons.circle_outlined,
                color: o == value ? c.tint : null,
              ),
          ],
        );
        // 等菜单关掉的这段时间里，这张卡片可能已经被滚出屏幕
        // （模块列表是懒加载的 sliver），那就别再往下走
        if (picked != null && context.mounted) onChanged(picked);
      },
      scale: 0.96,
      child: Container(
        padding: const EdgeInsets.fromLTRB(11, 6, 8, 6),
        decoration: BoxDecoration(
          color: c.fill,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              labelOf(value),
              style: AppText.caption1.copyWith(
                color: c.label,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 3),
            Icon(Icons.expand_more_rounded, size: 14, color: c.tertiaryLabel),
          ],
        ),
      ),
    );
  }
}

/// 图表画法切换按钮。
/// 卡片标题右侧的纯图标按钮（点了自己开菜单）。
class _IconMenuButton extends StatelessWidget {
  const _IconMenuButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: tooltip,
      child: Pressable(
        onTap: onTap,
        scale: 0.92,
        child: Container(
          width: 26,
          height: 26,
          margin: const EdgeInsets.only(left: 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: c.fill,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Icon(icon, size: 14, color: c.secondaryLabel),
        ),
      ),
    );
  }
}

class _ChartStyleButton<T> extends StatelessWidget {
  const _ChartStyleButton({
    required this.value,
    required this.options,
    required this.labelOf,
    required this.iconOf,
    required this.onChanged,
  });

  final T value;
  final List<T> options;
  final String Function(T) labelOf;
  final IconData Function(T) iconOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Pressable(
      onTap: () async {
        final picked = await showAppMenu<T>(
          context,
          anchor: AppMenuAnchor(context: context),
          items: <AppMenuItem<T>>[
            for (final o in options)
              AppMenuItem(
                value: o,
                label: labelOf(o),
                icon: o == value ? Icons.check_circle_rounded : iconOf(o),
                color: o == value ? c.tint : null,
              ),
          ],
        );
        // 同 _MiniSelect：卡片可能已经不在树上了
        if (picked != null && context.mounted) onChanged(picked);
      },
      scale: 0.9,
      child: Tooltip(
        message: '切换图表类型（当前：${labelOf(value)}）',
        child: Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: c.fill,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(iconOf(value), size: 15, color: c.secondaryLabel),
        ),
      ),
    );
  }
}

/// 模块开关行。
class _ModuleToggle extends StatelessWidget {
  const _ModuleToggle({
    super.key,
    required this.spec,
    required this.on,
    required this.onChanged,
    this.index,
  });

  final _ModuleSpec spec;
  final bool on;
  final ValueChanged<bool> onChanged;

  /// 在可拖拽列表里的下标。为空则不显示拖拽把手。
  final int? index;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return Row(
      children: [
        // 把手放在 Pressable **外面**：它是纯拖拽用的，
        // 放进可点击区域里会变成"点一下就切换开关"，很烦。
        if (index != null)
          ReorderableDragStartListener(
            index: index!,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Padding(
                padding: const EdgeInsets.only(right: 6, top: 10, bottom: 10),
                child: Icon(
                  Icons.drag_indicator_rounded,
                  size: 18,
                  color: c.quaternaryLabel,
                ),
              ),
            ),
          ),
        Expanded(
          child: Pressable(
            onTap: () => onChanged(!on),
            scale: 0.99,
            haptic: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: [
                  Icon(
                    spec.icon,
                    size: 17,
                    color: on ? c.tint : c.quaternaryLabel,
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          spec.title,
                          style: AppText.footnote.copyWith(
                            color: on ? c.label : c.tertiaryLabel,
                          ),
                        ),
                        Text(
                          spec.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              AppText.caption2.copyWith(color: c.quaternaryLabel),
                        ),
                      ],
                    ),
                  ),
                  Switch.adaptive(
                    value: on,
                    onChanged: onChanged,
                    activeTrackColor: c.tint,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GhostButton extends StatelessWidget {
  const _GhostButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Pressable(
      onTap: onTap,
      scale: 0.97,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: c.tint.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: c.tint),
            const SizedBox(width: 7),
            Text(
              label,
              style: AppText.footnote.copyWith(
                color: c.tint,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
