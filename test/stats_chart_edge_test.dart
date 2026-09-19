/// 图表边缘的留白：最后一个数据点与提示气泡不能被裁掉。
///
/// 用户反馈：「最后一个数据点在边缘时显示不全」—— 截图里最右侧的圆点被边界
/// 切掉一半，悬停气泡也顶出图表、文字少了一截。
///
/// 两条规则分别钉在这里：
///   · X 轴两端各留一点余量（点是有半径的，贴着边画就会被裁）；
///   · 提示气泡 `fitInsideHorizontally/Vertically`，保证收在图内。
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

Future<void> pump(WidgetTester tester, TrendStyle style, int n) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 220,
          child: TrendChart(
            points: <TrendPoint>[
              for (var i = 0; i < n; i++) pt('${i + 1}月', 100 + i * 10),
            ],
            metric: TrendMetric.chars,
            style: style,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('折线图：X 轴两端留出余量（两端圆点才画得全）', (tester) async {
    await pump(tester, TrendStyle.line, 4);
    final d = tester.widget<LineChart>(find.byType(LineChart)).data;
    expect(d.minX, lessThan(0), reason: '最左边那个点也要留出半径');
    expect(d.maxX, greaterThan(3),
        reason: '最后一个点的 x 是 3，轴必须再宽一点，否则它被边界切掉');
  });

  testWidgets('折线图提示气泡收在图内', (tester) async {
    await pump(tester, TrendStyle.line, 4);
    final d = tester.widget<LineChart>(find.byType(LineChart)).data;
    expect(d.lineTouchData.touchTooltipData.fitInsideHorizontally, isTrue);
    expect(d.lineTouchData.touchTooltipData.fitInsideVertically, isTrue);
  });

  testWidgets('柱状图提示气泡也收在图内', (tester) async {
    await pump(tester, TrendStyle.bar, 4);
    final d = tester.widget<BarChart>(find.byType(BarChart)).data;
    expect(d.barTouchData.touchTooltipData.fitInsideHorizontally, isTrue);
    expect(d.barTouchData.touchTooltipData.fitInsideVertically, isTrue);
  });

  testWidgets('只有一个点时不会把轴拉成负数区间', (tester) async {
    await pump(tester, TrendStyle.line, 1);
    final d = tester.widget<LineChart>(find.byType(LineChart)).data;
    expect(d.minX, 0);
    expect(d.maxX, greaterThan(0));
  });
}
