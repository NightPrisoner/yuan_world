/// 悬停微动：列表和瀑布流共用的那一层"轻轻抬起"。
///
/// 钉住三件事：
///   · 悬停时真的动了（不是只有颜色变）；
///   · 幅度很小（超过 4px 就晃眼，用户要的是"微小"）；
///   · 系统开了「减弱动态效果」时完全不动。
library;

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/core/motion/app_motion.dart';

bool get hasMouse => Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// 直接量**屏幕上的矩形**：比去翻 Transform 矩阵更贴近"看起来动了没"。
Rect boxOf(WidgetTester tester) => tester.getRect(find.byType(SizedBox));

Future<TestGesture> hover(WidgetTester tester) async {
  final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: Offset.zero);
  addTearDown(g.removePointer);
  await tester.pumpAndSettle();
  await g.moveTo(tester.getCenter(find.byType(HoverLift)));
  await tester.pumpAndSettle();
  return g;
}

void main() {
  testWidgets('悬停时轻轻抬起，幅度很小', (tester) async {
    if (!hasMouse) return;
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: HoverLift(
              dy: -2,
              scale: 1.012,
              child: SizedBox(width: 200, height: 60),
            ),
          ),
        ),
      ),
    );

    final base = boxOf(tester);
    await hover(tester);
    final lifted = boxOf(tester);

    final rise = base.top - lifted.top;
    expect(rise, greaterThan(0.5), reason: '悬停要往上抬（不能只是变个颜色）');
    expect(rise, lessThan(4), reason: '幅度必须很小，不然扫读时晃眼');
    expect(lifted.width, greaterThan(base.width), reason: '同时要有一点点放大');
    expect(lifted.width / base.width, lessThan(1.05), reason: '放大也要克制');
  });

  testWidgets('移开鼠标会回到原位', (tester) async {
    if (!hasMouse) return;
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: HoverLift(dy: -2, child: SizedBox(width: 200, height: 60)),
          ),
        ),
      ),
    );

    final base = boxOf(tester);
    final g = await hover(tester);
    expect(boxOf(tester).top, lessThan(base.top));

    await g.moveTo(const Offset(5, 5));
    await tester.pumpAndSettle();
    // 弹簧收尾会留一点点残差，给个宽容度
    expect((boxOf(tester).top - base.top).abs(), lessThan(0.5),
        reason: '移开要回原位');
  });

  testWidgets('开启「减弱动态效果」后完全不动', (tester) async {
    if (!hasMouse) return;
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: Scaffold(
            body: Center(
              child: HoverLift(dy: -2, child: SizedBox(width: 200, height: 60)),
            ),
          ),
        ),
      ),
    );

    final base = boxOf(tester);
    await hover(tester);
    expect((boxOf(tester).top - base.top).abs(), lessThan(0.01),
        reason: '减弱动态效果时必须安静');
  });
}
