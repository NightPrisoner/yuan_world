/// 统计页用的各种图表。
///
/// 全部基于 fl_chart 自绘，不引入额外依赖。
/// 每个图表都尽量提供多种画法，让用户自己挑顺眼的。
library;

import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart' show mapEquals;
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

class ShareChart extends StatelessWidget {
  const ShareChart({
    super.key,
    required this.items,
    required this.style,
  });

  final List<ShareItem> items;
  final ShareStyle style;

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
            Padding(
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
                Padding(
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
            ],
          ),
        ),
      ],
    );
  }
}

// ── 发布密度热力图 ────────────────────────────────────────────────────────

/// 算出热力图的窗口。
///
/// 有明确的时间范围就用它（"近三个月"就画三个月）；"全部"时用数据的实际跨度
/// ——总得有个头尾才能排格子，画到今天会拖出一条空长尾。
/// 实在什么都没有就退回最近一年。
({DateTime from, DateTime to}) heatWindow({
  DateTime? rangeFrom,
  DateTime? rangeTo,
  DateTime? dataFrom,
  DateTime? dataTo,
  required DateTime now,
}) {
  DateTime day(DateTime t) => DateTime(t.year, t.month, t.day);
  final today = day(now);
  final from = rangeFrom ?? dataFrom;
  final to = rangeTo ?? dataTo;
  if (from == null || to == null || from.isAfter(to)) {
    return (from: today.subtract(const Duration(days: 364)), to: today);
  }
  return (from: day(from), to: day(to));
}

String heatDayKey(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// 发布密度热力图。
///
/// **整张图用一个 CustomPaint 画，不给每格建 widget。**
///
/// 以前每格是 `SizedBox > Tooltip > Center > Container` 四个 widget：
/// 时间范围一放开（"全部"可能是两三年），一屏就是七百多格 ≈ 三千个
/// widget，全在一帧里建出来 —— 滚到它卡一下，页面上任何一次 setState
/// （比如换篇幅分档）也跟着卡一下。现在只有 1 个 paint 节点。
///
/// 代价是悬停提示得自己算：指针坐标除以格距就知道是哪一格。
/// 好处是不用为七百个格子各挂一个 Tooltip。
class DensityHeatmap extends StatefulWidget {
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

  @override
  State<DensityHeatmap> createState() => _DensityHeatmapState();
}

class _DensityHeatmapState extends State<DensityHeatmap> {
  /// 当前指着的那一格。
  ({String day, int count})? _hover;

  static const double _gap = 2;
  static const double _labelHeight = 16;

  DateTime get _firstDay =>
      DateTime(widget.from.year, widget.from.month, widget.from.day);
  DateTime get _lastDay =>
      DateTime(widget.to.year, widget.to.month, widget.to.day);

  /// 每一列（周）的七天。从第一个格子所在那周的周日开始，
  /// 保证每一列都是完整的一周。
  List<List<DateTime>> get _weeks {
    var cursor = _firstDay.subtract(Duration(days: _firstDay.weekday % 7));
    final out = <List<DateTime>>[];
    while (!cursor.isAfter(_lastDay)) {
      out.add(<DateTime>[
        for (var d = 0; d < 7; d++) cursor.add(Duration(days: d)),
      ]);
      cursor = cursor.add(const Duration(days: 7));
    }
    return out;
  }

  bool _inWindow(DateTime d) =>
      !d.isBefore(_firstDay) && !d.isAfter(_lastDay);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final weeks = _weeks;
    final n = weeks.length;

    // 色阶按**窗口内**的最大值定。用整库最大值的话，
    // 一年只写 2 篇的窗口会淡成一片白，等于没画。
    var maxCount = 0;
    var total = 0;
    for (final week in weeks) {
      for (final day in week) {
        if (!_inWindow(day)) continue;
        final v = widget.data[heatDayKey(day)] ?? 0;
        total += v;
        if (v > maxCount) maxCount = v;
      }
    }
    if (maxCount == 0) maxCount = 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // **格子尺寸跟着宽度走**。
        //
        // 窗口可能是三个月（十几列）也可能是好几年（几百列）：
        // 写死尺寸的话短窗口会稀稀拉拉、长窗口要横向滚半天；
        // 均分（Expanded）又会在短窗口把格子拉成一根根粗条。
        // 按可用宽度算、并且**只夹上限**：下限一设就会把行撑破
        // （窄屏 + 三年跨度实际抓到过 164px 溢出）。格子细一点没关系，
        // 密度图看的是疏密。
        LayoutBuilder(
          builder: (context, box) {
            final pitch = math.min(22.0, box.maxWidth / n);
            final gap = pitch >= 8 ? _gap : 0.6;
            final cell = math.max(0.5, pitch - gap);
            final radius = math.min(2.0, cell / 3);
            final gridHeight = 7 * pitch;

            // 标签挤在一起不如不标：至少隔 34px 才放一个
            final labels = <int, String>{};
            var lastLabelX = -1e9;
            int? prevMonth;
            for (var i = 0; i < n; i++) {
              final m = weeks[i].first.month;
              if (m == prevMonth) continue;
              prevMonth = m;
              final x = i * pitch;
              if (x - lastLabelX < 34) continue;
              labels[i] = m == 1 ? '${weeks[i].first.year}年' : '$m月';
              lastLabelX = x;
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: _labelHeight,
                  child: CustomPaint(
                    size: Size(box.maxWidth, _labelHeight),
                    painter: _HeatLabelPainter(
                      labels: labels,
                      pitch: pitch,
                      color: c.quaternaryLabel,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                SizedBox(
                  height: gridHeight,
                  child: MouseRegion(
                    onHover: (e) => _updateHover(e.localPosition, weeks, pitch),
                    onExit: (_) {
                      if (_hover != null) setState(() => _hover = null);
                    },
                    child: GestureDetector(
                      // 手机上没有鼠标，点一下也能看数值
                      onTapDown: (d) =>
                          _updateHover(d.localPosition, weeks, pitch),
                      child: CustomPaint(
                        size: Size(box.maxWidth, gridHeight),
                        painter: _HeatGridPainter(
                          weeks: weeks,
                          data: widget.data,
                          maxCount: maxCount,
                          empty: _emptyColor(c),
                          tint: c.tint,
                          pitch: pitch,
                          cell: cell,
                          radius: radius,
                          firstDay: _firstDay,
                          lastDay: _lastDay,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
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
                  color: i == 0
                      ? _emptyColor(c)
                      : c.tint.withValues(alpha: 0.18 + 0.2 * i),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            const SizedBox(width: 2),
            Text('多', style: AppText.caption2.copyWith(color: c.quaternaryLabel)),
            const Spacer(),
            // 指着哪一格就在这儿报出来。以前是每格一个 Tooltip，
            // 七百多个 Tooltip 的代价比这个提示本身大得多。
            Text(
              _hover == null
                  ? '共 $total 篇有发布记录'
                  : '${_hover!.day}  ${_hover!.count == 0 ? '无' : '${_hover!.count} 篇'}',
              style: AppText.caption2.copyWith(
                color: _hover == null ? c.quaternaryLabel : c.secondaryLabel,
              ),
            ),
          ],
        ),
      ],
    );
  }

  void _updateHover(Offset pos, List<List<DateTime>> weeks, double pitch) {
    final col = (pos.dx / pitch).floor();
    final row = (pos.dy / pitch).floor();
    if (col < 0 || col >= weeks.length || row < 0 || row >= 7) {
      if (_hover != null) setState(() => _hover = null);
      return;
    }
    final day = weeks[col][row];
    if (!_inWindow(day)) {
      if (_hover != null) setState(() => _hover = null);
      return;
    }
    final key = heatDayKey(day);
    final count = widget.data[key] ?? 0;
    if (_hover?.day == key) return;
    setState(() => _hover = (day: key, count: count));
  }

  static Color _emptyColor(AppColors c) =>
      c.isDark ? const Color(0xFF1F1F22) : const Color(0xFFE2E2E8);
}

/// 画所有格子。一次 paint 画完，没有 per-cell widget。
class _HeatGridPainter extends CustomPainter {
  _HeatGridPainter({
    required this.weeks,
    required this.data,
    required this.maxCount,
    required this.empty,
    required this.tint,
    required this.pitch,
    required this.cell,
    required this.radius,
    required this.firstDay,
    required this.lastDay,
  });

  final List<List<DateTime>> weeks;
  final Map<String, int> data;
  final int maxCount;
  final Color empty;
  final Color tint;
  final double pitch;
  final double cell;
  final double radius;
  final DateTime firstDay;
  final DateTime lastDay;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    // 格子小于 3px 时圆角没意义，还多一次 drawRRect
    final rounded = radius > 0.8;
    // 一个格子都没画的时候，细格子仍有 0.6px 的缝，看起来像竖条。
    // 小于这个尺寸就直接铺满，反而更像密度图。
    final inset = (pitch - cell) / 2;

    for (var col = 0; col < weeks.length; col++) {
      final week = weeks[col];
      final x = col * pitch + inset;
      if (x > size.width) break;
      for (var row = 0; row < 7; row++) {
        final day = week[row];
        if (day.isBefore(firstDay) || day.isAfter(lastDay)) continue;
        final count = data[heatDayKey(day)] ?? 0;
        paint.color = count == 0
            ? empty
            : tint.withValues(
                alpha: 0.2 + 0.8 * (count / maxCount).clamp(0.0, 1.0),
              );
        final rect = Rect.fromLTWH(x, row * pitch + inset, cell, cell);
        if (rounded) {
          canvas.drawRRect(
            RRect.fromRectAndRadius(rect, Radius.circular(radius)),
            paint,
          );
        } else {
          canvas.drawRect(rect, paint);
        }
      }
    }
  }

  @override
  bool shouldRepaint(_HeatGridPainter old) =>
      old.weeks.length != weeks.length ||
      old.pitch != pitch ||
      old.maxCount != maxCount ||
      old.data != data ||
      old.firstDay != firstDay ||
      old.lastDay != lastDay ||
      old.tint != tint ||
      old.empty != empty;
}

/// 画月份标签。也就十来个，单独一个 paint 省得和格子互相拖累。
class _HeatLabelPainter extends CustomPainter {
  _HeatLabelPainter({
    required this.labels,
    required this.pitch,
    required this.color,
  });

  final Map<int, String> labels;
  final double pitch;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    for (final entry in labels.entries) {
      final tp = TextPainter(
        text: TextSpan(
          text: entry.value,
          style: AppText.caption2.copyWith(color: color),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      // 不裁剪：格子只有十几像素宽，标签本来就该溢出到右边
      tp.paint(canvas, Offset(entry.key * pitch, (size.height - tp.height) / 2));
    }
  }

  @override
  bool shouldRepaint(_HeatLabelPainter old) =>
      old.pitch != pitch ||
      old.color != color ||
      // **不能只比长度**：同长度的两个窗口（比如都是 12 个月）换了年份之后
      // 标签内容变了、长度没变，只比长度就会一直画着旧的「2024年」。
      !mapEquals(old.labels, labels);
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
              fitInsideHorizontally: true,
              fitInsideVertically: true,
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
  const LengthHistogram({super.key, required this.buckets});

  final List<LengthBucket> buckets;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final total = buckets.fold<int>(0, (s, b) => s + b.count);

    // 柱子必须从 0 起：柱长就是它的语义，截断基线等于撒谎
    final y = trendYRange(
      <double>[for (final b in buckets) b.count.toDouble()],
      forceZeroBase: true,
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
              fitInsideHorizontally: true,
              fitInsideVertically: true,
              getTooltipColor: (_) => c.isDark
                  ? const Color(0xFF2C2C2E)
                  : const Color(0xFF1C1C1E),
              getTooltipItem: (group, gi, rod, ri) => BarTooltipItem(
                '${buckets[group.x].label}\n',
                AppText.caption2.copyWith(color: Colors.white70),
                children: [
                  TextSpan(
                    text: '${buckets[group.x].count} 篇'
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
                reservedSize: 30,
                getTitlesWidget: (value, meta) {
                  if (value == 0) return const SizedBox.shrink();
                  return Text(
                    fmtNum(value),
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
                    toY: buckets[i].count.toDouble(),
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
