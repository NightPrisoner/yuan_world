/// 统计页的各个模块卡片。
///
/// 这里是 `stats_page.dart` 的一部分（`part of`）：这些卡片全是
/// `_StatsPageState` 的方法，拆出来只是**为了让单个文件别太长** ——
/// 之前一个文件 2200 多行，改一处要在里面翻半天。`part` 不引入任何新的
/// 抽象层，调用关系也不变（同一个 library，私有成员照样可见）。
///
/// 顺序：存储 / 对比 / 概览 / 趋势 / 累计 / 占比 / 热力 / 时段 /
/// 篇幅 / 连续 / 排行 / 标签 / 关键词 / 参数。
part of 'stats_page.dart';

extension _StatsCards on _StatsPageState {
  /// 存储与数据：笔记数、总字数、图片、视频、磁盘占用。
  ///
  /// 这些原来挤在设置页里，和"主题""字号"那些**偏好设置**混在一起；
  /// 它们其实是**数据**，放在统计页才顺。
  ///
  /// 图片和视频的**个数**直接数磁盘上的文件，而不是读 note.image_count：
  /// 那个字段是笔记侧的冗余统计，导入之外还可能包含已删笔记的图；
  /// 这里要给的是"存储里到底有多少东西"，以磁盘为准最实在。
  Widget _storageCard(AppColors c) {
    final media = _mediaStats;

    Widget row(String label, String value, {Color? accent}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: AppText.callout.copyWith(color: c.secondaryLabel),
            ),
          ),
          Text(
            value,
            style: AppText.callout.copyWith(
              color: accent ?? c.label,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );

    return _Card(
      title: '存储与数据',
      child: Column(
        children: [
          // 这张永远是整库口径（磁盘上的东西没法按文件夹切），
          // 但不用再写一行小字解释 —— 下面四行的标签已经说明了。
          row('图片', '${media.images} 张'),
          row('视频', '${media.videos} 个'),
          row('媒体占用', _StatsPageState._fmtBytes(media.bytes)),
          Divider(height: 1, color: c.separator),
          row('数据库大小', _StatsPageState._fmtBytes(_dbBytes), accent: c.tint),
        ],
      ),
    );
  }

  int _dbBytesOf(AppDatabase db) {
    try {
      var total = 0;
      // WAL 模式的库有三个文件：.db / -wal / -shm，加起来才是真实占用
      for (final suffix in <String>['', '-wal', '-shm']) {
        final f = File(
          '${db.rootDir.path}${Platform.pathSeparator}'
          'yuanworld.db$suffix',
        );
        if (f.existsSync()) total += f.lengthSync().round();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  Widget _allHiddenCard(AppColors c) => _Card(
    title: '全部模块都被隐藏了',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '统计模块可以随时开关、还能拖动排序，把你关心的留下来。',
          style: AppText.footnote.copyWith(color: c.secondaryLabel),
        ),
        const SizedBox(height: 12),
        _GhostButton(
          label: '恢复全部模块',
          icon: Icons.restart_alt_rounded,
          onTap: () {
            _setState(() => _hidden.clear());
            _persist();
          },
        ),
      ],
    ),
  );

  Widget _compareCard(AppColors c) {
    if (_comparisons.length < 2) {
      // 只勾了一个文件夹时，问题不是"库里没有两个文件夹"，
      // 而是"你还差一个没勾" —— 同一句话会把人指错方向
      final msg = _collectionIds.length == 1 ? '再选一个文件夹就能对比' : '至少要有两个文件夹才能对比';
      return _Card(title: '文件夹对比', child: _empty(c, msg));
    }

    final maxNotes = _comparisons.map((e) => e.notes).reduce(math.max);

    return _Card(
      title: '文件夹对比',
      trailing: Text(
        '共 ${_comparisons.length} 个',
        style: AppText.caption1.copyWith(color: c.tertiaryLabel),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 表头
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                const SizedBox(width: 104),
                Expanded(
                  child: Text(
                    '篇数',
                    style: AppText.caption2.copyWith(color: c.quaternaryLabel),
                  ),
                ),
                SizedBox(
                  width: 58,
                  child: Text(
                    '总字数',
                    textAlign: TextAlign.right,
                    style: AppText.caption2.copyWith(color: c.quaternaryLabel),
                  ),
                ),
                SizedBox(
                  width: 62,
                  child: Text(
                    '篇均',
                    textAlign: TextAlign.right,
                    style: AppText.caption2.copyWith(color: c.quaternaryLabel),
                  ),
                ),
                SizedBox(
                  width: 52,
                  child: Text(
                    '最近',
                    textAlign: TextAlign.right,
                    style: AppText.caption2.copyWith(color: c.quaternaryLabel),
                  ),
                ),
              ],
            ),
          ),
          for (final it in _comparisons)
            Pressable(
              onTap: () => _setCollection(
                _collectionId == it.id ? null : (it.id < 0 ? null : it.id),
              ),
              scale: 0.99,
              haptic: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 104,
                      child: Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: Color(it.color),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              it.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.footnote.copyWith(
                                color: _collectionId == it.id
                                    ? c.tint
                                    : c.label,
                                fontWeight: _collectionId == it.id
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: TweenAnimationBuilder<double>(
                          tween: Tween<double>(
                            begin: 0,
                            end: maxNotes == 0 ? 0 : it.notes / maxNotes,
                          ),
                          duration: AppMotion.respecting(context, AppMotion.normal),
                          curve: AppMotion.enter,
                          builder: (context, v, _) => LinearProgressIndicator(
                            value: v,
                            minHeight: 7,
                            backgroundColor: c.fill,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              Color(it.color),
                            ),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 58,
                      child: Text(
                        '${it.notes}',
                        textAlign: TextAlign.right,
                        style: AppText.caption1.copyWith(
                          color: c.label,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 58,
                      child: Text(
                        fmtNum(it.chars),
                        textAlign: TextAlign.right,
                        style: AppText.caption1.copyWith(
                          color: c.secondaryLabel,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 62,
                      child: Text(
                        fmtNum(it.avgChars),
                        textAlign: TextAlign.right,
                        style: AppText.caption1.copyWith(
                          color: c.tertiaryLabel,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 52,
                      child: Text(
                        it.lastAt == null ? '—' : _fmtDay(it.lastAt),
                        textAlign: TextAlign.right,
                        style: AppText.caption1.copyWith(
                          color: c.quaternaryLabel,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 6),
          Text(
            '点一行可以只看该文件夹的数据',
            style: AppText.caption2.copyWith(color: c.quaternaryLabel),
          ),
        ],
      ),
    );
  }

  Widget _overviewCard(AppColors c) {
    final o = _overview;
    if (o == null) return const SizedBox.shrink();

    final avg = o.noteCount == 0 ? 0 : o.totalChars ~/ o.noteCount;

    // 数据项按 id 备好，显示哪些由用户在右上角挑。
    //
    // 「词数」不在这里：中文的词数靠空格切不出来，和字数的口径容易
    // 被误当成同一件事，用户明确说去掉 —— 概览只留数得准的。
    final tiles = <String, Widget>{
      'notes': _Stat(
        // key 是给测试用的：筛选一变，这个数字就得跟着变，
        // 之前漏了 _overview 的重算，它一直挂着旧值
        key: const Key('ov-notes'),
        label: '笔记',
        value: '${o.noteCount}',
        unit: '篇',
        color: c.tint,
        icon: Icons.article_rounded,
      ),
      'chars': _Stat(
        key: const Key('ov-chars'),
        label: '总字数',
        value: fmtNum(o.totalChars),
        color: c.palette[4],
        icon: Icons.text_fields_rounded,
      ),
      'images': _Stat(
        key: const Key('ov-images'),
        label: '图片',
        value: fmtNum(o.imageCount),
        color: c.palette[5],
        icon: Icons.image_rounded,
      ),
      'videos': _Stat(
        key: const Key('ov-videos'),
        label: '视频',
        value: fmtNum(o.videoCount),
        color: c.palette[5],
        icon: Icons.videocam_rounded,
      ),
      'collections': _Stat(
        key: const Key('ov-collections'),
        label: '文集',
        value: '${o.collectionCount}',
        unit: '个',
        color: c.palette[0],
        icon: Icons.folder_rounded,
      ),
      'tags': _Stat(
        key: const Key('ov-tags'),
        label: '标签',
        value: '${o.tagCount}',
        unit: '个',
        color: c.palette[1],
        icon: Icons.sell_rounded,
      ),
      'favorites': _Stat(
        key: const Key('ov-favorites'),
        label: '收藏',
        value: '${o.favoriteCount}',
        unit: '篇',
        color: c.palette[7],
        icon: Icons.star_rounded,
      ),
      'activeDays': _Stat(
        key: const Key('ov-active-days'),
        label: '活跃天数',
        value: '${_streak?.activeDays ?? 0}',
        unit: '天',
        color: c.palette[3],
        icon: Icons.event_available_rounded,
      ),
    };

    final visible = <Widget>[
      for (final spec in _kOverviewStats)
        if (_showOverviewStat(spec.id)) tiles[spec.id]!,
    ];

    // 固定两列：关掉一项时，同行的另一项不会被拉成整行宽，
    // 开关来回切的时候整张卡片不会忽胖忽瘦。
    final rows = <Widget>[];
    for (var i = 0; i < visible.length; i += 2) {
      final pair = visible.sublist(i, math.min(i + 2, visible.length));
      rows.add(
        Row(
          children: [
            pair.first,
            if (pair.length > 1) pair[1] else const Spacer(),
          ],
        ),
      );
      if (i + 2 < visible.length) rows.add(const SizedBox(height: 10));
    }

    return _Card(
      title: '概览',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '平均每篇 ${fmtNum(avg)} 字',
            style: AppText.caption1.copyWith(color: c.tertiaryLabel),
          ),
          _IconMenuButton(
            icon: Icons.dashboard_customize_rounded,
            tooltip: '概览里显示哪些数据',
            onTap: () => _showOverviewSheet(c),
          ),
        ],
      ),
      child: visible.isEmpty
          ? _empty(c, '概览的数据项都被关掉了，点右上角按钮挑几个显示')
          : Column(children: rows),
    );
  }

  Widget _trendCard(AppColors c) {
    // 空数据时不要去取序列 —— 那是真查库的
    final ({List<TrendPoint> axis, List<TrendSeries> series}) win =
        _trend.isEmpty
        ? (axis: _trend, series: const <TrendSeries>[])
        : _windowTrend(_trend, _trendSeries);
    return _Card(
      title: '发布趋势',
      controls: <Widget>[
        _MiniSelect<StatsGranularity>(
          value: _granularity,
          options: StatsGranularity.values,
          labelOf: (v) => v.label,
          onChanged: _setGranularity,
        ),
        _MiniSelect<TrendMetric>(
          value: _metric,
          options: TrendMetric.values,
          labelOf: (v) => v.label,
          onChanged: (v) {
            _setState(() => _metric = v);
            _persist();
          },
        ),
        _ChartStyleButton<TrendStyle>(
          value: _trendStyle,
          options: TrendStyle.values,
          labelOf: (v) => v.label,
          iconOf: (v) => switch (v) {
            TrendStyle.bar => Icons.bar_chart_rounded,
            TrendStyle.line => Icons.show_chart_rounded,
            TrendStyle.area => Icons.area_chart_rounded,
          },
          onChanged: (v) {
            _setState(() => _trendStyle = v);
            _persist();
          },
        ),
        _displayOptions(c),
      ],
      child: _trend.isEmpty
          ? _empty(c, '这个时间范围内还没有数据')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '按发布时间统计，未设置时使用创建时间；字数取笔记当前内容。',
                  style: AppText.caption1.copyWith(color: c.tertiaryLabel),
                ),
                if (_collectionIds.length > 1)
                  Text(
                    '各系列含子文件夹，父子同时选择时范围可能重叠；合计按笔记去重。',
                    style: AppText.caption1.copyWith(color: c.tertiaryLabel),
                  ),
                const SizedBox(height: 10),
                _Summary(
                  items: <(String, String)>[
                    ('合计', fmtNum(_trend.fold<int>(0, (s, p) => s + p.notes))),
                    ('字数', fmtNum(_trend.fold<int>(0, (s, p) => s + p.chars))),
                    ('峰值', _peakLabel()),
                  ],
                ),
                const SizedBox(height: 14),
                SizedBox(
                  // 多线对比时图例要占地方，配高一点
                  height: _trendSeries.length > 1 ? 250 : 210,
                  child: TrendChart(
                    points: win.axis,
                    metric: _metric,
                    style: _trendStyle,
                    // 选了多个文件夹时画多条线
                    series: win.series,
                    showDots: _showDots,
                    smooth: _smooth,
                    showGrid: _showGrid,
                  ),
                ),
                _zoomBar(c, win.axis),
              ],
            ),
    );
  }

  String _peakLabel() {
    if (_trend.isEmpty) return '—';
    var best = _trend.first;
    for (final p in _trend) {
      if (p.valueOf(_metric) > best.valueOf(_metric)) best = p;
    }
    return '${best.label} ${fmtNum(best.valueOf(_metric))}';
  }

  Widget _cumulativeCard(AppColors c) {
    if (_cumulative.length < 2) {
      return _Card(title: '累计增长', child: _empty(c, '数据太少，画不出增长曲线'));
    }
    final last = _cumulative.last;
    // 累计是单调递增的，放大看某一段同样有意义（看那段时间涨了多少）
    final cumPoints = <TrendPoint>[
      for (final p in _cumulative)
        TrendPoint(
          bucket: p.label,
          label: p.label,
          notes: p.notes,
          chars: p.chars,
          words: p.words,
          images: p.images,
          videos: p.videos,
        ),
    ];
    final ({List<TrendPoint> axis, List<TrendSeries> series}) win =
        _windowTrend(cumPoints, _cumulativeSeries, cumulative: true);
    return _Card(
      title: '累计增长',
      controls: <Widget>[
        // 之前累计只能看字数、只能画面积 —— 和趋势比可调的东西太少
        _MiniSelect<StatsGranularity>(
          value: _granularity,
          options: StatsGranularity.values,
          labelOf: (v) => v.label,
          onChanged: _setGranularity,
        ),
        _MiniSelect<TrendMetric>(
          value: _cumMetric,
          // 累计是单调递增的，词数/图片同样能累积，一并给出来
          options: const <TrendMetric>[
            TrendMetric.chars,
            TrendMetric.notes,
            TrendMetric.words,
            TrendMetric.images,
            TrendMetric.videos,
          ],
          labelOf: (v) => v.label,
          onChanged: (v) {
            _setState(() => _cumMetric = v);
            _persist();
          },
        ),
        _ChartStyleButton<TrendStyle>(
          value: _cumStyle,
          options: const <TrendStyle>[TrendStyle.area, TrendStyle.line],
          labelOf: (v) => v.label,
          iconOf: (v) => v == TrendStyle.area
              ? Icons.area_chart_rounded
              : Icons.show_chart_rounded,
          onChanged: (v) {
            _setState(() => _cumStyle = v);
            _persist();
          },
        ),
        _displayOptions(c),
      ],
      trailing: Text(
        '区间内累计 · 截至 ${last.label}',
        style: AppText.caption1.copyWith(color: c.tertiaryLabel),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Summary(
            items: <(String, String)>[
              ('累计篇数', '${last.notes}'),
              ('累计字数', fmtNum(last.chars)),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: _cumulativeSeries.length > 1 ? 250 : 210,
            child: TrendChart(
              points: win.axis,
              metric: _cumMetric,
              style: _cumStyle,
              series: win.series,
              showDots: _showDots,
              smooth: _smooth,
              showGrid: _showGrid,
            ),
          ),
          _zoomBar(c, win.axis),
        ],
      ),
    );
  }

  Widget _shareCard(AppColors c) {
    return _Card(
      title: '文集分布',
      controls: <Widget>[
        _ChartStyleButton<ShareStyle>(
          value: _shareStyle,
          options: ShareStyle.values,
          labelOf: (v) => v.label,
          iconOf: (v) => switch (v) {
            ShareStyle.donut => Icons.donut_large_rounded,
            ShareStyle.pie => Icons.pie_chart_rounded,
            ShareStyle.bar => Icons.bar_chart_rounded,
          },
          onChanged: (v) {
            _setState(() => _shareStyle = v);
            _persist();
          },
        ),
      ],
      child: _share.isEmpty
          ? _empty(c, '还没有笔记')
          : ShareChart(items: _share, style: _shareStyle),
    );
  }

  Widget _heatmapCard(AppColors c) {
    // 窗口跟着页面顶部的时间范围走，卡片上只如实报出实际画的是哪一段
    final win = heatWindow(
      rangeFrom: _query.from,
      rangeTo: _query.to,
      dataFrom: _densityFrom,
      dataTo: _densityTo,
      now: DateTime.now(),
    );
    String d(DateTime t) => '${t.year}.${t.month}';
    return _Card(
      title: '发布热力图',
      trailing: Text(
        '${d(win.from)} – ${d(win.to)}',
        style: AppText.caption1.copyWith(color: c.tertiaryLabel),
      ),
      child: DensityHeatmap(data: _density, from: win.from, to: win.to),
    );
  }

  Widget _hourlyCard(AppColors c) {
    final peak = _peakHour();
    return _Card(
      title: '发布时段',
      trailing: Text(
        peak < 0 ? '' : '最常在 $peak 点',
        style: AppText.caption1.copyWith(color: c.tertiaryLabel),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: 150, child: HourlyChart(hours: _hourly)),
          const SizedBox(height: 16),
          Text(
            '星期分布',
            style: AppText.footnote.copyWith(
              color: c.secondaryLabel,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          WeekdayChart(days: _weekday),
        ],
      ),
    );
  }

  int _peakHour() {
    if (_hourly.isEmpty) return -1;
    var best = 0;
    for (var i = 1; i < _hourly.length; i++) {
      if (_hourly[i] > _hourly[best]) best = i;
    }
    return _hourly[best] == 0 ? -1 : best;
  }

  Widget _lengthCard(AppColors c) {
    final total = _lengths.fold<int>(0, (s, b) => s + b.count);
    return _Card(
      title: '篇幅分布',
      controls: <Widget>[
        // **X 轴分档做成平铺的分段选择，不弹菜单。**
        //
        // 三个选项用下拉是双重浪费：点开再点一下，还平白多出一个模态路由。
        // 而这个控件的路由一旦留下没关干净的遮罩，整页就"点什么都没反应"了
        // —— 用户报的正是这个。分段控件连路由都没有，顺带一次点击就能切。
        // 纵轴不给任何调节：柱状图从 0 起是它唯一的诚实画法。
        Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '分档',
              style: AppText.caption2.copyWith(color: c.quaternaryLabel),
            ),
            const SizedBox(width: 6),
            _Segmented<LengthScale>(
              value: _lenScale,
              options: LengthScale.values,
              labelOf: (v) => v.label,
              keyOf: (v) => 'len-scale-${v.name}',
              onChanged: (v) {
                if (v == _lenScale) return;
                _setState(() => _lenScale = v);
                _persist();
                // **只重算这一个直方图**。
                //
                // 以前这里调的是 _reload() —— 换个分档把整页十来个聚合全跑一遍
                // （含全库词频和文件夹逐条取数），在真实库上就是一段明显的
                // 同步卡顿：点完界面不动了，还以为死了。分档只影响这一张图。
                _reloadLengths();
              },
            ),
          ],
        ),
      ],
      trailing: Text(
        '$total 篇',
        style: AppText.caption1.copyWith(color: c.tertiaryLabel),
      ),
      child: LengthHistogram(buckets: _lengths),
    );
  }

  Widget _streakCard(AppColors c) {
    final s = _streak;
    if (s == null) return const SizedBox.shrink();
    return _Card(
      title: '连续发布',
      child: Column(
        children: [
          Row(
            children: [
              _Stat(
                label: '当前连续',
                value: '${s.current}',
                unit: '天',
                color: c.palette[1],
                icon: Icons.local_fire_department_rounded,
              ),
              _Stat(
                label: '最长连续',
                value: '${s.longest}',
                unit: '天',
                color: c.palette[4],
                icon: Icons.emoji_events_rounded,
              ),
            ],
          ),
          const SizedBox(height: 14),
          // 活跃密度：有发布记录的天数 / 总跨度
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '活跃密度',
                    style: AppText.footnote.copyWith(color: c.secondaryLabel),
                  ),
                  const Spacer(),
                  Text(
                    '${(s.density * 100).toStringAsFixed(1)}%'
                    '（${s.activeDays}/${s.totalDays} 天）',
                    style: AppText.caption1.copyWith(color: c.tertiaryLabel),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: s.density),
                  duration: AppMotion.respecting(context, AppMotion.sheet),
                  curve: AppMotion.enter,
                  builder: (context, v, _) => LinearProgressIndicator(
                    value: v,
                    minHeight: 9,
                    backgroundColor: c.fill,
                    valueColor: AlwaysStoppedAnimation<Color>(c.palette[1]),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _topCard(AppColors c) {
    if (_top.isEmpty) {
      return _Card(title: '长文排行', child: _empty(c, '还没有笔记'));
    }
    final maxV = _top.first.chars;
    return _Card(
      title: '长文排行',
      trailing: Text(
        'Top ${_top.length}',
        style: AppText.caption1.copyWith(color: c.tertiaryLabel),
      ),
      child: Column(
        children: [
          for (var i = 0; i < _top.length; i++)
            _RankRow(
              index: i,
              title: _top[i].title,
              value: '${fmtNum(_top[i].chars)} 字',
              ratio: maxV == 0 ? 0 : _top[i].chars / maxV,
              color: _top[i].color == null ? c.tint : Color(_top[i].color!),
              onTap: () => _openNote(_top[i].id),
            ),
        ],
      ),
    );
  }

  void _openNote(int id) {
    Navigator.of(context).push(
      ApplePageRoute<void>(pageBuilder: (_) => NoteDetailPage(noteId: id)),
    );
  }

  Widget _tagsCard(AppColors c) {
    if (_tags.isEmpty) {
      return _Card(title: '标签分布', child: _empty(c, '还没有打过标签'));
    }
    final total = _tags.fold<int>(0, (s, t) => s + t.count);
    return _Card(
      title: '标签分布',
      trailing: Text(
        '$total 次使用',
        style: AppText.caption1.copyWith(color: c.tertiaryLabel),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final t in _tags)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
              decoration: BoxDecoration(
                color: Color(t.color).withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '#${t.name}',
                    style: AppText.footnote.copyWith(color: Color(t.color)),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    '${t.count}',
                    style: AppText.caption2.copyWith(color: c.tertiaryLabel),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _keywordsCard(AppColors c) {
    return _Card(
      title: '高频词',
      trailing: Text(
        '来自标题与摘要',
        style: AppText.caption1.copyWith(color: c.tertiaryLabel),
      ),
      child: KeywordBars(keywords: _keywords),
    );
  }

  /// 参数统计。数据由卡片自己加载，这里只负责套上统一的卡片外壳。
  Widget _fieldsCard(AppColors c) => _Card(
    title: '参数统计',
    trailing: Text(
      '数值型可求和求均值',
      style: AppText.caption1.copyWith(color: c.tertiaryLabel),
    ),
    child: FieldStatsCard(query: _query, revision: _lastRevision),
  );

  Widget _empty(AppColors c, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 18),
    child: Text(text, style: AppText.footnote.copyWith(color: c.tertiaryLabel)),
  );
}
