/// 小图表：时段 / 星期 / 篇幅 / 关键词。
///
/// 这里是 `stats_charts.dart` 的一部分（`part of`），理由见
/// stats_trend_chart.dart 的说明。
part of 'stats_charts.dart';
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
