/// 统计页用的各种图表。
///
/// 全部基于 fl_chart 自绘，不引入额外依赖。
/// 每个图表都尽量提供多种画法，让用户自己挑顺眼的。
library;

import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/motion/app_motion.dart';
import '../../core/theme/app_theme.dart';
import '../../data/repositories/stats_repository.dart';

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

/// 算出 Y 轴的可见范围。
///
/// 图表本身和页面上那行「纵轴 1,200 – 8,400」都调这个函数 ——
/// 两处各算一遍的话迟早会算岔，标签报的范围就不是图上那条了。
///
/// [zoomY] > 1 时在 [fromZero] 定出的基础范围里再放大，
/// [viewYStart]（0..1）决定放大后停在哪一段。
({double lo, double hi}) trendYRange({
  required Iterable<double> values,
  required bool fromZero,
  double zoomY = 1,
  double viewYStart = 0,
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

  final hi0 = maxV * 1.18;
  // 从 0 起最诚实；关掉之后贴着数据走，多条线都挤在顶部时才看得出差异。
  // 留 8% 余量免得线贴边。
  final lo0 = fromZero ? 0.0 : (minV <= 0 ? 0.0 : minV * 0.92);

  var lo = lo0;
  var hi = hi0;
  final span = hi0 - lo0;
  if (zoomY > 1 && span > 0) {
    final visible = span / zoomY;
    final maxStart = span - visible;
    lo = lo0 + viewYStart.clamp(0.0, 1.0) * maxStart;
    hi = lo + visible;
  }
  return (lo: lo, hi: hi);
}

class TrendChart extends StatelessWidget {
  const TrendChart({
    super.key,
    required this.points,
    required this.metric,
    required this.style,
    this.series = const <TrendSeries>[],
    this.fromZero = true,
    this.showDots = true,
    this.smooth = true,
    this.showGrid = true,
    this.zoomY = 1,
    this.viewYStart = 0,
  });

  final List<TrendPoint> points;
  final TrendMetric metric;
  final TrendStyle style;

  /// 多文件夹对比：每条一个文件夹。
  ///
  /// 传了 2 条以上就走**多线模式**，[points] 那时只用来定 X 轴刻度。
  final List<TrendSeries> series;

  /// Y 轴从 0 起。
  ///
  /// 关掉之后按数据的最小值缩放下限 —— 多条线挤在顶部时，
  /// 从 0 起是看不出差异的。
  final bool fromZero;

  /// 是否画数据点。点多的时候关掉更清爽。
  final bool showDots;

  /// 曲线是否平滑。折线数据用平滑曲线有时会失真（凭空造出中间值），
  /// 所以给用户一个关掉的开关。
  final bool smooth;

  final bool showGrid;

  /// Y 轴放大倍数。1 = 看全部。
  final double zoomY;

  /// Y 轴可视范围的起点（0..1）。只在 [zoomY] > 1 时起作用。
  final double viewYStart;

  bool get _multi => series.length > 1;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final values = points.map<double>((p) => p.valueOf(metric).toDouble()).toList();

    // 多线模式下 Y 轴要按**所有线**定范围，否则某条会被截断
    final y = trendYRange(
      values: <double>[
        ...values,
        if (_multi)
          for (final s in series)
            for (final p in s.points) p.valueOf(metric).toDouble(),
      ],
      fromZero: fromZero,
      zoomY: zoomY,
      viewYStart: viewYStart,
    );

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
                minX: 0,
                maxX: math.max(1, points.length - 1).toDouble(),
                lineTouchData: LineTouchData(
                  // **悬停容差给大一点**：按年/按季这种稀疏数据点与点隔得远，
                  // 默认容差下必须精确压中那个点才出提示，用户会觉得"移到图上没反应"。
                  touchSpotThreshold: 40,
                  touchTooltipData: LineTouchTooltipData(
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
        minX: 0,
        maxX: math.max(1, points.length - 1).toDouble(),
        lineTouchData: LineTouchData(
          // 稀疏数据下要放宽容差，否则必须精确压中数据点才出提示
          touchSpotThreshold: 40,
          touchTooltipData: LineTouchTooltipData(
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

class ShareChart extends StatelessWidget {
  const ShareChart({
    super.key,
    required this.items,
    required this.style,
    this.onTapItem,
  });

  final List<ShareItem> items;
  final ShareStyle style;
  final void Function(ShareItem item)? onTapItem;

  int get _total => items.fold<int>(0, (s, e) => s + e.value);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (items.isEmpty) return const SizedBox.shrink();

    if (style == ShareStyle.bar) {
      final maxV = items.map((e) => e.value).reduce(math.max);
      return Column(
        children: [
          for (final it in items)
            Pressable(
              onTap: onTapItem == null ? null : () => onTapItem!(it),
              scale: 0.99,
              haptic: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    SizedBox(
                      width: 96,
                      child: Text(
                        it.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.footnote.copyWith(color: c.label),
                      ),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: TweenAnimationBuilder<double>(
                          tween: Tween<double>(
                            begin: 0,
                            end: maxV == 0 ? 0 : it.value / maxV,
                          ),
                          duration: AppMotion.normal,
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
                    const SizedBox(width: 10),
                    SizedBox(
                      width: 40,
                      child: Text(
                        '${it.value}',
                        textAlign: TextAlign.right,
                        style: AppText.caption1.copyWith(color: c.secondaryLabel),
                      ),
                    ),
                    SizedBox(
                      width: 54,
                      child: Text(
                        fmtNum(it.extra),
                        textAlign: TextAlign.right,
                        style: AppText.caption1.copyWith(color: c.quaternaryLabel),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );
    }

    final total = _total;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 132,
          height: 132,
          child: Stack(
            alignment: Alignment.center,
            children: [
              PieChart(
                PieChartData(
                  sectionsSpace: style == ShareStyle.donut ? 2 : 0,
                  centerSpaceRadius: style == ShareStyle.donut ? 42 : 0,
                  startDegreeOffset: -90,
                  sections: <PieChartSectionData>[
                    for (final it in items)
                      PieChartSectionData(
                        value: it.value.toDouble(),
                        color: Color(it.color),
                        radius: style == ShareStyle.donut ? 16 : 62,
                        showTitle: false,
                      ),
                  ],
                ),
              ),
              if (style == ShareStyle.donut)
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('$total', style: AppText.title2.copyWith(color: c.label)),
                    Text(
                      '篇',
                      style: AppText.caption2.copyWith(color: c.tertiaryLabel),
                    ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final it in items.take(7))
                Pressable(
                  onTap: onTapItem == null ? null : () => onTapItem!(it),
                  scale: 0.99,
                  haptic: false,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 7),
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
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            it.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: AppText.footnote.copyWith(color: c.label),
                          ),
                        ),
                        Text(
                          '${it.value}',
                          style: AppText.caption1.copyWith(color: c.tertiaryLabel),
                        ),
                        const SizedBox(width: 6),
                        SizedBox(
                          width: 46,
                          child: Text(
                            fmtNum(it.extra),
                            textAlign: TextAlign.right,
                            style:
                                AppText.caption1.copyWith(color: c.quaternaryLabel),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── 发布密度热力图 ────────────────────────────────────────────────────────

/// 热力图的时间窗口。
///
/// 以前写死"近一年"、一个字都改不了 —— 想看去年写了多少都做不到。
enum HeatWindow {
  m3('最近三个月'),
  m6('最近半年'),
  y1('最近一年'),
  ytd('今年'),
  lastYear('去年');

  const HeatWindow(this.label);
  final String label;

  /// 算出窗口的起止（都是**当天**，含首尾）。
  ({DateTime from, DateTime to}) resolve(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    return switch (this) {
      HeatWindow.m3 => (
        from: today.subtract(const Duration(days: 89)),
        to: today,
      ),
      HeatWindow.m6 => (
        from: today.subtract(const Duration(days: 181)),
        to: today,
      ),
      HeatWindow.y1 => (
        from: today.subtract(const Duration(days: 364)),
        to: today,
      ),
      HeatWindow.ytd => (from: DateTime(today.year, 1, 1), to: today),
      HeatWindow.lastYear => (
        from: DateTime(today.year - 1, 1, 1),
        to: DateTime(today.year - 1, 12, 31),
      ),
    };
  }
}

String heatDayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

class DensityHeatmap extends StatelessWidget {
  const DensityHeatmap({
    super.key,
    required this.data,
    required this.from,
    required this.to,
  });

  /// key 为 `yyyy-MM-dd`
  final Map<String, int> data;

  /// 窗口起止（含首尾）。
  final DateTime from;
  final DateTime to;

  /// 格子尺寸写死，**不再用 Expanded 均分**。
  ///
  /// 均分的话窗口一短（比如"最近三个月"只有 14 列），格子会被拉成
  /// 一根根粗条，完全不像热力图。写死 + 横向滚动，列数多少都不变形。
  static const double _cell = 12;
  static const double _gap = 2;
  static const double _pitch = _cell + _gap;

  static const double _height = 16 + 4 + 7 * _pitch;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final firstDay = DateTime(from.year, from.month, from.day);
    final lastDay = DateTime(to.year, to.month, to.day);

    // 从第一个格子所在的那一周的周日开始，保证每一列都是完整的一周
    var cursor = firstDay.subtract(Duration(days: firstDay.weekday % 7));
    final weeks = <List<DateTime>>[];
    while (!cursor.isAfter(lastDay)) {
      weeks.add(<DateTime>[
        for (var d = 0; d < 7; d++) cursor.add(Duration(days: d)),
      ]);
      cursor = cursor.add(const Duration(days: 7));
    }

    // 色阶按**窗口内**的最大值定。用整库最大值的话，
    // 一年只写 2 篇的窗口会淡成一片白，等于没画。
    var maxCount = 0;
    var total = 0;
    for (final week in weeks) {
      for (final day in week) {
        if (day.isBefore(firstDay) || day.isAfter(lastDay)) continue;
        final v = data[heatDayKey(day)] ?? 0;
        total += v;
        if (v > maxCount) maxCount = v;
      }
    }
    if (maxCount == 0) maxCount = 1;

    // 月份标签：月份一变就标一个。相邻标签至少隔 4 列（约 56px），
    // 不会撞在一起。
    final labels = <int, String>{};
    int? prevMonth;
    for (var i = 0; i < weeks.length; i++) {
      final m = weeks[i].first.month;
      if (m != prevMonth) {
        labels[i] = m == 1 ? '${weeks[i].first.year}年' : '$m月';
        prevMonth = m;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          height: _height,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 16,
                  child: Row(
                    children: <Widget>[
                      for (var i = 0; i < weeks.length; i++)
                        SizedBox(
                          width: _pitch,
                          child: labels[i] == null
                              ? null
                              : Text(
                                  labels[i]!,
                                  // 格子只有 14px 宽，标签要允许溢出到右边，
                                  // 否则会被裁成"1…"
                                  softWrap: false,
                                  overflow: TextOverflow.visible,
                                  style: AppText.caption2.copyWith(
                                    color: c.quaternaryLabel,
                                  ),
                                ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                SizedBox(
                  height: 7 * _pitch,
                  child: Row(
                    children: <Widget>[
                      for (final week in weeks)
                        SizedBox(
                          width: _pitch,
                          child: Column(
                            children: <Widget>[
                              for (final day in week)
                                _cellBox(c, day, firstDay, lastDay, maxCount),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text('少', style: AppText.caption2.copyWith(color: c.quaternaryLabel)),
            const SizedBox(width: 5),
            for (var i = 0; i <= 4; i++)
              Container(
                width: 9,
                height: 9,
                margin: const EdgeInsets.only(right: 3),
                decoration: BoxDecoration(
                  color: i == 0 ? _emptyColor(c) : c.tint.withValues(alpha: 0.18 + 0.2 * i),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            const SizedBox(width: 2),
            Text('多', style: AppText.caption2.copyWith(color: c.quaternaryLabel)),
            const Spacer(),
            Text(
              '共 $total 篇有发布记录',
              style: AppText.caption2.copyWith(color: c.quaternaryLabel),
            ),
          ],
        ),
      ],
    );
  }

  static Color _emptyColor(AppColors c) =>
      c.isDark ? const Color(0xFF1F1F22) : const Color(0xFFE2E2E8);

  /// 一个格子。
  ///
  /// 尺寸写死 + `Padding` 撑开，**不能**靠父级的 stretch ——
  /// 之前用 `Expanded` + 松宽度约束，格子会缩成 0 宽，整张热力图一片空白。
  Widget _cellBox(
    AppColors c,
    DateTime day,
    DateTime firstDay,
    DateTime lastDay,
    int maxCount,
  ) {
    // 首尾补出来的那几天不属于窗口，画成透明占位
    if (day.isBefore(firstDay) || day.isAfter(lastDay)) {
      return const SizedBox(width: _pitch, height: _pitch);
    }
    final key = heatDayKey(day);
    final count = data[key] ?? 0;

    return SizedBox(
      width: _pitch,
      height: _pitch,
      child: Tooltip(
        message: '$key  ${count == 0 ? '无' : '$count 篇'}',
        waitDuration: const Duration(milliseconds: 350),
        child: Padding(
          padding: const EdgeInsets.all(_gap / 2),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: count == 0
                  ? _emptyColor(c)
                  : c.tint.withValues(
                      alpha: 0.2 + 0.8 * (count / maxCount).clamp(0.0, 1.0),
                    ),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
      ),
    );
  }
}

// ── 一天 24 小时的分布 ────────────────────────────────────────────────────

class HourlyChart extends StatelessWidget {
  const HourlyChart({super.key, required this.hours});

  /// 下标 0..23
  final List<int> hours;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final maxV = hours.isEmpty ? 1 : hours.reduce(math.max);
    final maxY = maxV <= 0 ? 1.0 : maxV * 1.2;

    return SizedBox(
      height: 150,
      child: BarChart(
        BarChartData(
          maxY: maxY,
          alignment: BarChartAlignment.spaceAround,
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => c.isDark
                  ? const Color(0xFF2C2C2E)
                  : const Color(0xFF1C1C1E),
              getTooltipItem: (group, gi, rod, ri) => BarTooltipItem(
                '${group.x.toString().padLeft(2, '0')}:00\n',
                AppText.caption2.copyWith(color: Colors.white70),
                children: [
                  TextSpan(
                    text: '${rod.toY.round()} 篇',
                    style: AppText.footnote.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 24,
                getTitlesWidget: (value, meta) {
                  final h = value.toInt();
                  if (h % 6 != 0) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '$h时',
                      style: AppText.caption2.copyWith(color: c.quaternaryLabel),
                    ),
                  );
                },
              ),
            ),
          ),
          gridData: FlGridData(show: false),
          borderData: FlBorderData(show: false),
          barGroups: <BarChartGroupData>[
            for (var h = 0; h < 24; h++)
              BarChartGroupData(
                x: h,
                barRods: <BarChartRodData>[
                  BarChartRodData(
                    toY: h < hours.length ? hours[h].toDouble() : 0,
                    width: 7,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(3),
                    ),
                    // 深夜用冷色、白天用主题色，一眼能看出作息
                    color: (h < 6 || h >= 23)
                        ? c.palette[5]
                        : c.tint.withValues(alpha: 0.75),
                  ),
                ],
              ),
          ],
        ),
        duration: AppMotion.normal,
      ),
    );
  }
}

/// 七个星期的分布条。
class WeekdayChart extends StatelessWidget {
  const WeekdayChart({super.key, required this.days});

  /// 下标 0 = 周一 … 6 = 周日
  final List<int> days;

  static const _names = <String>['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final maxV = days.isEmpty ? 1 : days.reduce(math.max);
    final total = days.fold<int>(0, (s, v) => s + v);

    return Column(
      children: [
        for (var i = 0; i < 7; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 34,
                  child: Text(
                    '周${_names[i]}',
                    style: AppText.caption1.copyWith(
                      color: i >= 5 ? c.palette[2] : c.secondaryLabel,
                    ),
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(
                        begin: 0,
                        end: maxV == 0 ? 0 : days[i] / maxV,
                      ),
                      duration: AppMotion.normal,
                      curve: AppMotion.enter,
                      builder: (context, v, _) => LinearProgressIndicator(
                        value: v,
                        minHeight: 8,
                        backgroundColor: c.fill,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          i >= 5 ? c.palette[2] : c.tint,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 34,
                  child: Text(
                    '${days[i]}',
                    textAlign: TextAlign.right,
                    style: AppText.caption1.copyWith(color: c.secondaryLabel),
                  ),
                ),
                SizedBox(
                  width: 42,
                  child: Text(
                    total == 0 ? '' : '${(days[i] / total * 100).round()}%',
                    textAlign: TextAlign.right,
                    style: AppText.caption2.copyWith(color: c.quaternaryLabel),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

// ── 篇幅分布直方图 ────────────────────────────────────────────────────────

class LengthHistogram extends StatelessWidget {
  const LengthHistogram({
    super.key,
    required this.buckets,
    this.zoomY = 1,
    this.viewYStart = 0,
    this.asPercent = false,
  });

  final List<LengthBucket> buckets;

  /// Y 轴放大倍数与起点。柱子不比折线，不从 0 起会骗人，
  /// 所以默认就是 1× / 从 0 起 —— 放大是用户自己按下去的。
  final double zoomY;
  final double viewYStart;

  /// Y 轴显示占比而不是篇数。
  ///
  /// 换了分档之后各档的篇数完全不是一个量级，看"占多少"比看"几篇"有用。
  final bool asPercent;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final total = buckets.fold<int>(0, (s, b) => s + b.count);
    // 占比模式下 0 篇的档位也是 0%，不用特殊处理
    double valueOf(int i) => asPercent
        ? (total == 0 ? 0 : buckets[i].count / total * 100)
        : buckets[i].count.toDouble();

    final y = trendYRange(
      values: <double>[for (var i = 0; i < buckets.length; i++) valueOf(i)],
      fromZero: true,
      zoomY: zoomY,
      viewYStart: viewYStart,
    );

    return SizedBox(
      height: 170,
      child: BarChart(
        BarChartData(
          minY: y.lo,
          maxY: y.hi,
          alignment: BarChartAlignment.spaceAround,
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => c.isDark
                  ? const Color(0xFF2C2C2E)
                  : const Color(0xFF1C1C1E),
              getTooltipItem: (group, gi, rod, ri) => BarTooltipItem(
                '${buckets[group.x].label}\n',
                AppText.caption2.copyWith(color: Colors.white70),
                children: [
                  TextSpan(
                    // 两个数都给：光有占比不知道基数，光有篇数不好比档位
                    text: asPercent
                        ? '${rod.toY.toStringAsFixed(1)}%'
                              '（${buckets[group.x].count} 篇）'
                        : '${buckets[group.x].count} 篇'
                              '${total == 0 ? '' : '（${(buckets[group.x].count / total * 100).round()}%）'}',
                    style: AppText.footnote.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: asPercent ? 38 : 30,
                getTitlesWidget: (value, meta) {
                  if (value == 0) return const SizedBox.shrink();
                  return Text(
                    asPercent
                        ? '${value.toStringAsFixed(0)}%'
                        : fmtNum(value),
                    style: AppText.caption2.copyWith(color: c.quaternaryLabel),
                  );
                },
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                // 标签可能有三行（如「< 500 字」），预留高度要够，
                // 否则会撑破 —— 这是测试里实际抓到过的溢出
                reservedSize: 56,
                getTitlesWidget: (value, meta) {
                  final i = value.toInt();
                  if (i < 0 || i >= buckets.length) {
                    return const SizedBox.shrink();
                  }
                  // 标签较长，竖着排几行更省地方
                  final parts = buckets[i].label.split(' ');
                  return Padding(
                    padding: const EdgeInsets.only(top: 5),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final p in parts)
                          Text(
                            p,
                            style:
                                AppText.caption2.copyWith(color: c.quaternaryLabel),
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            // 按可见范围算，放大之后网格线才不会全跑到画面外
            horizontalInterval: (y.hi - y.lo) / 3,
            getDrawingHorizontalLine: (_) => FlLine(
              color: c.separator.withValues(alpha: 0.35),
              strokeWidth: 0.5,
              dashArray: const [3, 4],
            ),
          ),
          borderData: FlBorderData(show: false),
          barGroups: <BarChartGroupData>[
            for (var i = 0; i < buckets.length; i++)
              BarChartGroupData(
                x: i,
                barRods: <BarChartRodData>[
                  BarChartRodData(
                    toY: valueOf(i),
                    width: 22,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(5),
                    ),
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [c.palette[4].withValues(alpha: 0.5), c.palette[4]],
                    ),
                  ),
                ],
              ),
          ],
        ),
        duration: AppMotion.normal,
      ),
    );
  }
}

// ── 高频词 ────────────────────────────────────────────────────────────────

class KeywordBars extends StatelessWidget {
  const KeywordBars({super.key, required this.keywords});

  final List<KeywordStat> keywords;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (keywords.isEmpty) {
      return Text(
        '还没有足够的内容用于提取高频词',
        style: AppText.footnote.copyWith(color: c.tertiaryLabel),
      );
    }

    final maxV = keywords.map((k) => k.count).reduce(math.max);

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final k in keywords)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: c.tint.withValues(alpha: 0.06 + 0.24 * (k.count / maxV)),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  k.word,
                  style: AppText.footnote.copyWith(
                    color: c.isDark ? c.label : c.tint,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  '${k.count}',
                  style: AppText.caption2.copyWith(color: c.tertiaryLabel),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
