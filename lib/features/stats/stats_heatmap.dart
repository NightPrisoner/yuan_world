/// 发布密度热力图（含两个 CustomPainter）。
///
/// 这里是 `stats_charts.dart` 的一部分（`part of`），理由见
/// stats_trend_chart.dart 的说明。
part of 'stats_charts.dart';

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
    var cursor = DateTime(
      _firstDay.year,
      _firstDay.month,
      _firstDay.day - _firstDay.weekday % 7,
    );
    final out = <List<DateTime>>[];
    while (!cursor.isAfter(_lastDay)) {
      out.add(<DateTime>[
        for (var d = 0; d < 7; d++)
          DateTime(cursor.year, cursor.month, cursor.day + d),
      ]);
      cursor = DateTime(cursor.year, cursor.month, cursor.day + 7);
    }
    return out;
  }

  bool _inWindow(DateTime d) => !d.isBefore(_firstDay) && !d.isAfter(_lastDay);

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
            Text(
              '少',
              style: AppText.caption2.copyWith(color: c.quaternaryLabel),
            ),
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
            Text(
              '多',
              style: AppText.caption2.copyWith(color: c.quaternaryLabel),
            ),
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
      tp.paint(
        canvas,
        Offset(entry.key * pitch, (size.height - tp.height) / 2),
      );
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
