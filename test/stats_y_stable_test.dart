/// 横轴缩放/拖动时，**Y 轴比例尺不该跟着变**。
///
/// 用户的反馈：「写作趋势和累计增长，横轴放大后一拖动，那个曲线图一直在变化，
/// 感觉怪怪的」。
///
/// 原因：Y 轴范围以前是照着"收到的这段数据"算的，而缩放/拖动正是**换一段
/// 数据**喂进来 —— 每拖一下 Y 轴都重新定范围，整条曲线跟着上下跳还被重新
/// 拉伸。拖动本该只是移动视窗。
///
/// 现在缩放/拖动时调用方传**完整数据**算出来的 yRange，比例尺就固定了。
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/data/repositories/stats_repository.dart';
import 'package:yuan_world/features/stats/stats_charts.dart';

TrendPoint pt(String bucket, int chars) => TrendPoint(
  bucket: bucket,
  label: bucket,
  notes: 1,
  chars: chars,
  words: 0,
  images: 0,
);

final List<TrendPoint> all = <TrendPoint>[
  pt('1月', 10),
  pt('2月', 20),
  pt('3月', 30),
  pt('4月', 900),
];

final List<TrendPoint> window = all.sublist(0, 3); // 放大后看到的前三个月

Future<void> pumpChart(
  WidgetTester tester,
  List<TrendPoint> points, {
  ({double lo, double hi})? yRange,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 220,
          child: TrendChart(
            points: points,
            metric: TrendMetric.chars,
            style: TrendStyle.line,
            yRange: yRange,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

double maxYOf(WidgetTester tester) =>
    tester.widget<LineChart>(find.byType(LineChart)).data.maxY;

void main() {
  testWidgets('给了 yRange：换窗口数据，Y 轴上限纹丝不动', (tester) async {
    const range = (lo: 0.0, hi: 1062.0);

    await pumpChart(tester, all, yRange: range);
    final full = maxYOf(tester);

    await pumpChart(tester, window, yRange: range);
    final zoomed = maxYOf(tester);

    expect(full, 1062);
    expect(zoomed, full, reason: '拖动只是移动视窗，比例尺不能跟着数据的多少变');
  });

  testWidgets('不给 yRange（旧行为）：Y 轴会被窗口重新拉伸 —— 所以必须传', (tester) async {
    await pumpChart(tester, all);
    final full = maxYOf(tester);

    await pumpChart(tester, window);
    final zoomed = maxYOf(tester);

    expect(zoomed, isNot(full),
        reason: '这条是在说明"不传 yRange 就会出现用户看到的那种一直变"');
  });

  test('完整数据的 Y 范围覆盖窗口里的极值', () {
    final r = trendYRange(<double>[
      for (final p in all) p.valueOf(TrendMetric.chars).toDouble(),
    ]);
    expect(r.hi, greaterThanOrEqualTo(900 * 1.18 - 0.001));
  });
}
