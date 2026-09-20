/// 占比图：环形 / 饼图 / 条形。
///
/// 这里是 `stats_charts.dart` 的一部分（`part of`），理由见
/// stats_trend_chart.dart 的说明。
part of 'stats_charts.dart';
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
