/// 趋势折线图与它的数据模型。
///
/// 这里是 `stats_charts.dart` 的一部分（`part of`）：拆开只是为了让单个
/// 文件别太长（原来 1400 行，四类图表挤在一起）。同一个 library，私有
/// 类型照样可见，**调用方的 import 一行都不用改**。
part of 'stats_charts.dart';
/// 大数字缩写：12345 → 1.2万
String fmtNum(num n) {
  final v = n.round();
  if (v >= 100000000) return '${(v / 100000000).toStringAsFixed(1)}亿';
  if (v >= 10000) return '${(v / 10000).toStringAsFixed(1)}万';
  if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}k';
  return '$v';
}

// ── 趋势图：柱状 / 折线 / 面积 ────────────────────────────────────────────

/// 一条对比曲线：一个文件夹一条。
///
/// 多选文件夹时趋势图会画出多条，方便横向比较"哪个文件夹写得更多"。
/// 颜色由调用方给（优先用文件夹自己的颜色），这里不猜。
class TrendSeries {
  const TrendSeries({
    required this.label,
    required this.color,
    required this.points,
  });

  final String label;
  final Color color;
  final List<TrendPoint> points;
}

/// 按缩放倍数算出可视窗口的下标区间。
///
/// **裁在调用方做，不在这里**：切完之后 `TrendChart` 收到的就是一段普通数据，
/// X 轴刻度、Y 轴范围全都是照常算的 —— 放大看某一小段时 Y 轴会自动重新
/// 撑开，那一段的高低差才看得出来。图表本身不用知道有"缩放"这回事。
({int start, int end}) trendWindow(int n, double zoom, double viewStart) {
  if (n <= 2 || zoom <= 1) return (start: 0, end: n);
  // 至少留 2 个点，否则画不出线
  final span = math.max(2, (n / zoom).ceil());
  final maxStart = math.max(0, n - span);
  final start = (viewStart * maxStart).round().clamp(0, maxStart);
  return (start: start, end: math.min(n, start + span));
}

/// 按下标区间切片；越界就返回能取到的部分。
List<T> sliceRange<T>(List<T> src, int start, int end) {
  final s = math.min(math.max(start, 0), src.length);
  final e = math.min(math.max(end, s), src.length);
  return s >= e ? <T>[] : src.sublist(s, e);
}

/// 算出 Y 轴的显示范围。**全自动，没有旋钮**。
///
/// 规则只有一条：数据整体离 0 很远时贴着数据画，否则老老实实从 0 起。
/// - 三条线都在 5000–6000 之间时，从 0 起就是三条贴在顶上的平线，
///   什么差异都看不出来 —— 这时候贴着数据画。
/// - 数据本来就够到 0 附近（比如 0–100），截断基线只会把差异放大成假象 ——
///   这时候从 0 起。
///
/// 以前这是个开关（"Y 轴从 0 开始"），但没人是来看开关的，
/// 该贴着画还是该从 0 起，数据自己知道。
///
/// [forceZeroBase] 给柱状图用：柱子的长度就是它的语义，
/// 截断基线等于撒谎，所以必须从 0 起。
({double lo, double hi}) trendYRange(
  Iterable<double> values, {
  bool forceZeroBase = false,
}) {
  var maxV = 0.0;
  var minV = double.infinity;
  var any = false;
  for (final v in values) {
    any = true;
    if (v > maxV) maxV = v;
    if (v < minV) minV = v;
  }
  if (!any) {
    maxV = 1;
    minV = 0;
  }
  if (maxV <= 0) maxV = 1;

  // 上限留 18% 余量，免得线贴着顶边
  final hi = maxV * 1.18;
  final hugsData = !forceZeroBase && minV > 0 && minV > maxV * 0.25;
  return (lo: hugsData ? minV * 0.92 : 0.0, hi: hi);
}

class TrendChart extends StatelessWidget {
  const TrendChart({
    super.key,
    required this.points,
    required this.metric,
    required this.style,
    this.series = const <TrendSeries>[],
    this.showDots = true,
    this.smooth = true,
    this.showGrid = true,
  });

  final List<TrendPoint> points;
  final TrendMetric metric;
  final TrendStyle style;

  /// 多文件夹对比：每条一个文件夹。
  ///
  /// 传了 2 条以上就走**多线模式**，[points] 那时只用来定 X 轴刻度。
  final List<TrendSeries> series;

  /// 是否画数据点。点多的时候关掉更清爽。
  final bool showDots;

  /// 曲线是否平滑。折线数据用平滑曲线有时会失真（凭空造出中间值），
  /// 所以给用户一个关掉的开关。
  final bool smooth;

  final bool showGrid;

  bool get _multi => series.length > 1;

  /// X 轴两端各留的余量（单位是"一个刻度"）。
  ///
  /// 数据点是有半径的圆点/圆角柱：X 轴正好收在首尾点上时，**最后一个点会被
  /// 画在边界上、裁掉一半** —— 用户看到的就是"最后一个数据点显示不全"。
  /// 留一点余量，两端的点也能完整画出来。
  double get _padX => points.length <= 1 ? 0 : 0.35;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final values = points.map<double>((p) => p.valueOf(metric).toDouble()).toList();

    // 多线模式下 Y 轴要按**所有线**定范围，否则某条会被截断。
    // 到底从 0 起还是贴着数据，由 trendYRange 自己判断
    final y = trendYRange(<double>[
      ...values,
      if (_multi)
        for (final s in series)
          for (final p in s.points) p.valueOf(metric).toDouble(),
    ]);

    // 点位太密时只画一部分标签，否则轴会糊成一片
    final labelStep = points.length > 18 ? (points.length / 8).ceil() : 1;

    AxisTitles bottomTitles() => AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 26,
        interval: 1,
        getTitlesWidget: (value, meta) {
          final i = value.toInt();
          if (i < 0 || i >= points.length) return const SizedBox.shrink();
          if (i % labelStep != 0 && i != points.length - 1) {
            return const SizedBox.shrink();
          }
          return Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              points[i].label,
              style: AppText.caption2.copyWith(color: c.quaternaryLabel),
            ),
          );
        },
      ),
    );

    AxisTitles leftTitles() => AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 42,
        getTitlesWidget: (value, meta) {
          if (value == 0) return const SizedBox.shrink();
          return Padding(
            padding: const EdgeInsets.only(right: 6),
            child: Text(
              fmtNum(value),
              style: AppText.caption2.copyWith(color: c.quaternaryLabel),
            ),
          );
        },
      ),
    );

    FlGridData grid() => FlGridData(
      show: true,
      drawVerticalLine: false,
      // 间隔按**可见范围**算：放大之后还按原来的跨度分三格，
      // 网格线会全跑到画面外，看起来像网格被关掉了
      horizontalInterval: (y.hi - y.lo) / 3,
      getDrawingHorizontalLine: (_) => FlLine(
        color: c.separator.withValues(alpha: 0.4),
        strokeWidth: 0.5,
        dashArray: const [3, 4],
      ),
    );

    // fl_chart 的 tooltip children 只收 TextSpan（放不下 WidgetSpan），
    // 所以标题和数值都用带样式的 TextSpan 拼。
    TextStyle tipTitleStyle() =>
        AppText.caption2.copyWith(color: Colors.white70);
    TextStyle tipValueStyle() => AppText.footnote.copyWith(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        );

    if (style == TrendStyle.bar) {
      // 多文件夹时**一个 x 位置上并排几根柱子**（分组柱）。
      // 不能用"一根柱子叠一条线"那种做法 —— 柱状图的语义就是比高低，
      // 并排才看得出同一时期谁写得更多。
      final rodWidth = points.length > 20
          ? 6.0
          : (points.length > 12 ? 9.0 : 13.0) / (_multi ? series.length : 1);
      final chart = BarChart(
        BarChartData(
          minY: y.lo,
          maxY: y.hi,
          alignment: BarChartAlignment.spaceAround,
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              // 两端的柱子一悬停，气泡也会顶出图表被裁掉
              fitInsideHorizontally: true,
              fitInsideVertically: true,
              getTooltipColor: (_) => c.isDark
                  ? const Color(0xFF2C2C2E)
                  : const Color(0xFF1C1C1E),
              getTooltipItem: (group, gi, rod, ri) {
                // 多序列时标题要带上是哪个文件夹，否则分不清
                final title = _multi
                    ? '${points[group.x].bucket} · ${series[ri].label}\n'
                    : '${points[group.x].bucket}\n';
                return BarTooltipItem(
                  title,
                  tipTitleStyle(),
                  children: <TextSpan>[
                    TextSpan(
                      text: '${fmtNum(rod.toY)} ${metric.label}',
                      style: tipValueStyle(),
                    ),
                  ],
                );
              },
            ),
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: leftTitles(),
            bottomTitles: bottomTitles(),
          ),
          gridData: showGrid ? grid() : const FlGridData(show: false),
          borderData: FlBorderData(show: false),
          barGroups: <BarChartGroupData>[
            for (var i = 0; i < points.length; i++)
              BarChartGroupData(
                x: i,
                barsSpace: _multi ? 2 : 0,
                barRods: <BarChartRodData>[
                  if (!_multi)
                    BarChartRodData(
                      toY: values[i],
                      width: rodWidth,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(4),
                      ),
                      gradient: LinearGradient(
                        begin: Alignment.bottomCenter,
                        end: Alignment.topCenter,
                        colors: [c.tint.withValues(alpha: 0.55), c.tint],
                      ),
                    )
                  else
                    for (final s in series)
                      BarChartRodData(
                        toY: i < s.points.length
                            ? s.points[i].valueOf(metric).toDouble()
                            : 0,
                        width: rodWidth,
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(3),
                        ),
                        // 用文件夹自己的颜色，和折线模式保持一致
                        color: s.color,
                      ),
                ],
              ),
          ],
        ),
        duration: AppMotion.normal,
      );

      if (!_multi) return chart;
      // 多序列要配图例，否则不知道哪根柱子是哪个文件夹
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Expanded(child: chart),
          const SizedBox(height: 10),
          _legend(c),
        ],
      );
    }

    if (_multi) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // **用 Expanded 而不是写死高度**：外面给的高度是调用方定的，
          // 写死 200 的话加上图例就会超出、出现溢出条纹。
          Expanded(
            child: LineChart(
              LineChartData(
                minY: y.lo,
                maxY: y.hi,
                minX: -_padX,
                maxX: math.max(1, points.length - 1) + _padX,
                lineTouchData: LineTouchData(
                  // **悬停容差给大一点**：按年/按季这种稀疏数据点与点隔得远，
                  // 默认容差下必须精确压中那个点才出提示，用户会觉得"移到图上没反应"。
                  touchSpotThreshold: 40,
                  touchTooltipData: LineTouchTooltipData(
                    // 气泡要**收在图内**：默认是不收的，靠右边的点一悬停，
                    // 气泡就顶出图表、被裁掉半截（用户截图里就是这样）
                    fitInsideHorizontally: true,
                    fitInsideVertically: true,
                    getTooltipColor: (_) => c.isDark
                        ? const Color(0xFF2C2C2E)
                        : const Color(0xFF1C1C1E),
                    // **一项对一个触点**，数量必须严格相等。
                    // 之前多塞了一行时间，长度对不上，fl_chart 按索引取就整个
                    // 渲染不出来 —— 表现是"鼠标移上去什么都没有"。
                    // 时间并进**第一项**，既在最上面又不破坏数量。
                    getTooltipItems: (touched) {
                      if (touched.isEmpty) return <LineTooltipItem>[];
                      final xi = touched.first.x.toInt();
                      final bucket =
                          xi >= 0 && xi < points.length ? points[xi].bucket : '';
                      return <LineTooltipItem>[
                        for (var i = 0; i < touched.length; i++)
                          LineTooltipItem(
                            '${i == 0 && bucket.isNotEmpty ? '$bucket\n' : ''}'
                            '${series[touched[i].barIndex].label}'
                            '  ${fmtNum(touched[i].y)} ${metric.label}\n',
                            AppText.footnote.copyWith(
                              color: series[touched[i].barIndex].color,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ];
                    },
                  ),
                ),
                titlesData: FlTitlesData(
                  topTitles:
                      const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  rightTitles:
                      const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  leftTitles: leftTitles(),
                  bottomTitles: bottomTitles(),
                ),
                gridData: showGrid ? grid() : const FlGridData(show: false),
                borderData: FlBorderData(show: false),
                lineBarsData: <LineChartBarData>[
                  for (final s in series)
                    LineChartBarData(
                      spots: <FlSpot>[
                        for (var i = 0; i < s.points.length; i++)
                          FlSpot(
                            i.toDouble(),
                            s.points[i].valueOf(metric).toDouble(),
                          ),
                      ],
                      isCurved: smooth,
                      curveSmoothness: 0.28,
                      barWidth: 2.2,
                      color: s.color,
                      // 多线默认不画点（会糊成一团），但用户要的话就给
                      dotData: FlDotData(
                        show: showDots && s.points.length <= 30,
                        // 半径 3 太秀气 —— 线宽 2.2 直接把它盖住了，
                        // 用户的原话是"显示数据点好像没什么变化"。
                        // 加粗 + 描边，点才真的看得见。
                        getDotPainter: (spot, _, _, _) => FlDotCirclePainter(
                          radius: 3.8,
                          color: s.color,
                          strokeWidth: 2,
                          strokeColor: c.secondaryBackground,
                        ),
                      ),
                      // 多序列**不填色**：几条半透明色块叠在一起会糊成一团，
                      // 反而看不清各自走势
                      belowBarData: BarAreaData(show: false),
                    ),
                ],
              ),
              duration: AppMotion.normal,
            ),
          ),
          const SizedBox(height: 10),
          _legend(c),
        ],
      );
    }

    // 折线 / 面积
    final spots = <FlSpot>[
      for (var i = 0; i < values.length; i++) FlSpot(i.toDouble(), values[i]),
    ];

    return LineChart(
      LineChartData(
        minY: y.lo,
        maxY: y.hi,
        minX: -_padX,
        maxX: math.max(1, points.length - 1) + _padX,
        lineTouchData: LineTouchData(
          // 稀疏数据下要放宽容差，否则必须精确压中数据点才出提示
          touchSpotThreshold: 40,
          touchTooltipData: LineTouchTooltipData(
            // 靠右边的点一悬停，气泡会顶出图表被裁掉 —— 收在图内
            fitInsideHorizontally: true,
            fitInsideVertically: true,
            getTooltipColor: (_) => c.isDark
                ? const Color(0xFF2C2C2E)
                : const Color(0xFF1C1C1E),
            getTooltipItems: (touched) => touched
                .map((t) => LineTooltipItem(
                      // 第一行给时间，第二行才是数值 ——
                      // 只有"多少字"而没有"哪一期"，信息是不完整的
                      '${t.x.toInt() >= 0 && t.x.toInt() < points.length ? points[t.x.toInt()].bucket : ''}\n',
                      tipTitleStyle(),
                      children: <TextSpan>[
                        TextSpan(
                          text: '${fmtNum(t.y)} ${metric.label}',
                          style: tipValueStyle(),
                        ),
                      ],
                    ))
                .toList(),
          ),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: leftTitles(),
          bottomTitles: bottomTitles(),
        ),
        gridData: showGrid ? grid() : const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        lineBarsData: <LineChartBarData>[
          LineChartBarData(
            spots: spots,
            isCurved: smooth,
            curveSmoothness: 0.28,
            barWidth: 2.4,
            color: c.tint,
            dotData: FlDotData(
              show: showDots && points.length <= 30,
              // 线宽 2.4、点半径 3 的时候点几乎被线吃掉，
              // 加粗描边之后才有"数据点"的样子
              getDotPainter: (spot, _, _, _) => FlDotCirclePainter(
                radius: 4,
                color: c.tint,
                strokeWidth: 2,
                strokeColor: c.secondaryBackground,
              ),
            ),
            belowBarData: BarAreaData(
              show: style == TrendStyle.area,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  c.tint.withValues(alpha: 0.30),
                  c.tint.withValues(alpha: 0.02),
                ],
              ),
            ),
          ),
        ],
      ),
      duration: AppMotion.normal,
    );
  }

  /// 图例：多线时不给图例就分不清哪条是哪个文件夹。
  Widget _legend(AppColors c) {
    // 选得多了会换行，不设上限 —— 用户想比 8 个文件夹也随他
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: <Widget>[
        for (final s in series)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 9,
                height: 9,
                decoration: BoxDecoration(
                  color: s.color,
                  borderRadius: BorderRadius.circular(2.5),
                ),
              ),
              const SizedBox(width: 5),
              Text(
                s.label,
                style: AppText.caption2.copyWith(color: c.secondaryLabel),
              ),
            ],
          ),
      ],
    );
  }
}

// ── 占比图：环形 / 饼图 / 条形 ────────────────────────────────────────────
