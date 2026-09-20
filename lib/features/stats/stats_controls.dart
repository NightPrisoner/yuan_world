/// 统计页顶部那一排控件：范围 / 文集筛选 / 缩放 / 显示选项 / 模块开关。
///
/// 这里是 `stats_page.dart` 的一部分（`part of`），拆分的理由见
/// stats_cards.dart 的说明。
part of 'stats_page.dart';

extension _StatsControls on _StatsPageState {
  Widget _header(AppColors c) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1120),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '统计',
                          style: AppText.largeTitle.copyWith(color: c.label),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _rangeSubtitle(),
                          style: AppText.footnote.copyWith(color: c.tertiaryLabel),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  GlassIconButton(
                    icon: Icons.tune_rounded,
                    size: 32,
                    iconSize: 17,
                    tooltip: '选择要显示的模块',
                    onTap: () => _showModuleSheet(c),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // 时间范围 + 文件夹：**都收成下拉，摆在同一行**。
              //
              // 六个 chip 铺一行既占地方，又和下面的文件夹下拉风格不一致，
              // 而真正常用的就那一两个。两个下拉一行放得下，
              // 窄屏自动折到两行。
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  Builder(
                    builder: (btnCtx) => _FilterButton(
                      icon: Icons.schedule_rounded,
                      label: _rangeLabel,
                      accent: _range == StatsRange.all
                          ? c.tint
                          : c.palette[4],
                      onTap: () => _pickRangeMenu(btnCtx),
                    ),
                  ),
                  Builder(
                    builder: (btnCtx) => _FilterButton(
                      icon: Icons.folder_rounded,
                      label: _folderLabel,
                      accent: _folderAccent(c),
                      onTap: () => _pickCollectionMenu(btnCtx),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 时间范围下拉。选「自定义」再弹日历。
  Future<void> _pickRangeMenu(BuildContext btnCtx) async {
    final picked = await showAppMenu<StatsRange>(
      btnCtx,
      anchor: AppMenuAnchor(context: btnCtx),
      header: '时间范围',
      items: <AppMenuItem<StatsRange>>[
        for (final r in StatsRange.values)
          AppMenuItem(
            value: r,
            label: r == StatsRange.custom && _range == r
                ? _rangeLabel
                : r.label,
            icon: _range == r
                ? Icons.check_circle_rounded
                : (r == StatsRange.custom
                      ? Icons.calendar_month_rounded
                      : Icons.circle_outlined),
            color: _range == r ? context.colors.tint : null,
          ),
      ],
    );
    if (picked == null || !mounted) return;
    if (picked == StatsRange.custom) {
      await _pickCustomRange();
    } else {
      _setRange(picked);
    }
  }

  /// 文件夹多选。
  ///
  /// 用带勾选的对话框而不是下拉菜单：菜单点一下就关，多选要反复点开，
  /// 那个来回太烦。对话框里能一次勾完再确定。
  Future<void> _pickCollectionMenu(BuildContext btnCtx) async {
    final collections = context.read<AppState>().collections;
    final picked = await showDialog<List<int>>(
      context: context,
      builder: (ctx) => _CollectionPicker(
        collections: collections,
        selected: _collectionIds,
      ),
    );
    if (picked == null || !mounted) return;
    _setCollections(picked);
  }

  String _fmtDay(DateTime? d) =>
      d == null ? '自定义' : '${d.year}.${d.month}.${d.day}';

  String _rangeSubtitle() {
    final stats = _stats;
    final o = _overview;
    if (stats == null || o == null) return '还没有数据';

    // **篇数必须是筛选后的**。以前这里永远显示全库总数 ——
    // 勾了 3 个文件夹之后摘要还写着"共 76 篇"，而下面的图只有 12 篇，
    // 用户会以为筛选坏了。趋势点的合计恰好就是范围内的篇数。
    final scoped = _trend.fold<int>(0, (s, p) => s + p.notes);
    if (scoped == 0) return '还没有数据';

    final scope = switch (_collectionIds.length) {
      0 => '',
      1 => ' · 只看「${_collectionName(_collectionIds.first)}」',
      final n => ' · 对比 $n 个文件夹',
    };
    if (_range == StatsRange.custom) {
      return '${_fmtDay(_from)} – ${_fmtDay(_to)} · 共 $scoped 篇$scope';
    }
    // 起止也跟着范围走：选了"近一年"，头一行就不该从 2014 年开始报
    final span = stats.dataSpan(query: _query);
    final first = span.first;
    final last = span.last;
    if (first == null || last == null) return '共 $scoped 篇$scope';
    String d(DateTime t) => '${t.year}.${t.month}';
    return '${d(first)} – ${d(last)} · 共 $scoped 篇$scope';
  }

  String _collectionName(int id) {
    for (final c in context.read<AppState>().collections) {
      if (c.id == id) return c.name;
    }
    return '文件夹';
  }

  Future<void> _showModuleSheet(AppColors c) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final inner = ctx.colors;

          // 关键：按**用户自己的顺序**渲染，而不是 _kModules 的固定顺序。
          // 否则在页面上拖完，打开这个面板看到的还是老顺序。
          final ordered = _orderedIds()
              .map((id) => _kModules.firstWhere((m) => m.id == id))
              .toList();

          void sync() {
            setLocal(() {});
            _setState(() {});
            _persist();
          }

          void toggle(String id, bool on) {
            if (on) {
              _hidden.remove(id);
            } else {
              _hidden.add(id);
            }
            sync();
          }

          void reorder(int oldIndex, int newIndex) {
            // 面板里 12 个模块全都列出来，所以 visible 就是全部
            final all = _orderedIds();
            _order = applyModuleReorder(
              full: all,
              visible: all,
              oldIndex: oldIndex,
              newIndex: newIndex,
            );
            sync();
          }

          return Dialog(
            backgroundColor: inner.secondaryBackground,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400, maxHeight: 640),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '显示哪些模块',
                      style: AppText.headline.copyWith(color: inner.label),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '左右拖动 ≡ 可以调顺序，开关控制显示',
                      style: AppText.caption1.copyWith(color: inner.tertiaryLabel),
                    ),
                    const SizedBox(height: 10),
                    Flexible(
                      child: ReorderableListView.builder(
                        shrinkWrap: true,
                        // 自己画把手，不用默认那套
                        buildDefaultDragHandles: false,
                        itemCount: ordered.length,
                        onReorderItem: reorder,
                        itemBuilder: (context, i) => _ModuleToggle(
                          key: ValueKey<String>(ordered[i].id),
                          spec: ordered[i],
                          index: i,
                          on: _show(ordered[i].id),
                          onChanged: (v) => toggle(ordered[i].id, v),
                        ),
                      ),
                    ),
                    const Divider(height: 20),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () {
                            // 「全部显示」只恢复可见性，不动用户排好的顺序
                            _hidden.clear();
                            sync();
                          },
                          child: const Text('全部显示'),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('完成'),
                        ),
                      ],
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

  int _stepIn(List<double> levels, double cur, int dir) =>
      (math.max(0, levels.indexOf(cur)) + dir).clamp(0, levels.length - 1);

  void _stepZoom(int dir) {
    final next = _stepIn(_StatsPageState._zoomLevels, _zoom, dir);
    if (_StatsPageState._zoomLevels[next] == _zoom) return;
    _setState(() {
      _zoom = _StatsPageState._zoomLevels[next];
      // 回到 1× 时窗口本来就是全量，不清掉的话下次放大位置会很怪
      if (_zoom <= 1) _viewStart = 0;
    });
    _persist();
  }

  /// 图表下方的**横轴**控制条。
  ///
  /// 放在图下面而不是塞进右上角的菜单里 —— 缩放是个要**反复拖**的操作，
  /// 藏进菜单会让它变成没人发现的功能。
  ///
  /// 只有横轴：纵轴现在完全自动，没有可调的东西。
  Widget _zoomBar(AppColors c, List<TrendPoint> axis) {
    final first = axis.isEmpty ? null : axis.first.label;
    final last = axis.isEmpty ? null : axis.last.label;
    final xText = _zoom <= 1
        ? '全部'
        : (first != null && last != null ? '$first – $last' : '—');

    return Padding(
      // 页面上别处也有"全部"字样（范围筛选），测试要能精确定位到这一条
      key: const Key('stats-zoom-bar'),
      padding: const EdgeInsets.only(top: 2),
      child: _zoomRow(
        c,
        '横轴',
        _zoom,
        _viewStart,
        () => _stepZoom(-1),
        () => _stepZoom(1),
        (v) => _setState(() => _viewStart = v),
        xText,
        'x',
      ),
    );
  }

  Widget _zoomRow(
    AppColors c,
    String name,
    double zoom,
    double viewStart,
    VoidCallback zoomOut,
    VoidCallback zoomIn,
    ValueChanged<double> onPan,
    String readout,
    String keyName,
  ) {
    final zoomed = zoom > 1;
    return Row(
      // 一行横轴一行纵轴，测试要能分清是哪一行
      key: Key('stats-zoom-$keyName'),
      children: <Widget>[
        SizedBox(
          width: 28,
          child: Text(
            name,
            style: AppText.caption2.copyWith(color: c.quaternaryLabel),
          ),
        ),
        _zoomBtn(c, Icons.remove_rounded, zoomed, zoomOut, '$name缩小'),
        SizedBox(
          width: 34,
          child: Text(
            '${zoom.toInt()}×',
            textAlign: TextAlign.center,
            style: AppText.caption1.copyWith(
              color: zoomed ? c.tint : c.tertiaryLabel,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        _zoomBtn(
          c,
          Icons.add_rounded,
          zoom < _StatsPageState._zoomLevels.last,
          zoomIn,
          '$name放大',
        ),
        const SizedBox(width: 6),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 13),
            ),
            child: Slider(
              value: viewStart.clamp(0.0, 1.0),
              // 没放大时整段就是全部，滑它没有意义 —— 置灰而不是隐藏，
              // 免得用户以为"这个图不能滑动"
              onChanged: zoomed ? onPan : null,
            ),
          ),
        ),
        const SizedBox(width: 4),
        // 窄屏上时段文字会很长（"2024年3月 – 2026年1月"），
        // 不夹住的话滑块会被挤成几像素宽，根本拖不动
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 112),
          child: Text(
            readout,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: AppText.caption2.copyWith(color: c.tertiaryLabel),
          ),
        ),
      ],
    );
  }

  Widget _zoomBtn(
    AppColors c,
    IconData icon,
    bool enabled,
    VoidCallback onTap,
    String tip,
  ) => Tooltip(
    message: tip,
    child: InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(7),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(
          icon,
          size: 17,
          color: enabled ? c.secondaryLabel : c.quaternaryLabel,
        ),
      ),
    ),
  );

  Widget _displayOptions(AppColors c) => Builder(
    builder: (btnCtx) => _IconMenuButton(
      icon: Icons.tune_rounded,
      tooltip: '显示选项',
      onTap: () async {
        final picked = await showAppMenu<String>(
          btnCtx,
          anchor: AppMenuAnchor(context: btnCtx),
          header: '显示选项',
          items: <AppMenuItem<String>>[
            AppMenuItem(
              value: 'dots',
              label: '显示数据点',
              icon: _showDots
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              color: _showDots ? c.tint : null,
            ),
            AppMenuItem(
              value: 'smooth',
              label: '平滑曲线',
              icon: _smooth
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              color: _smooth ? c.tint : null,
            ),
            AppMenuItem(
              value: 'grid',
              label: '显示网格线',
              icon: _showGrid
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              color: _showGrid ? c.tint : null,
            ),
          ],
        );
        if (picked == null || !mounted) return;
        _setState(() {
          switch (picked) {
            case 'dots':
              _showDots = !_showDots;
            case 'smooth':
              _smooth = !_smooth;
            case 'grid':
              _showGrid = !_showGrid;
          }
        });
        _persist();
      },
    ),
  );
}
