/// 弹出菜单的路由栈卫生。
///
/// 菜单是模态路由，底下盖着一层看不见的遮罩 —— 遮罩要是没关干净，
/// 表现就是「页面还在动，但鼠标点什么都没反应」。
/// 这里盯的是：正常开关若干轮之后，路由栈必须是干净的。
///
/// 顺带记一笔：曾经加过一把"同时只允许一个菜单"的全局锁，后来撤了。
/// 它防的是到不了的场景（遮罩立刻盖住整屏，点不到按钮第二次），
/// 却会在某个菜单的 future 因路由被销毁而永不完成时**永久卡住**，
/// 之后所有菜单都打不开 —— 那才是真正的"点不动"。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/core/widgets/app_menu.dart';

void main() {
  late BuildContext ctx;

  Future<void> pumpHost(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<AppMenuItem<String>> items(List<String> labels) => <AppMenuItem<String>>[
    for (final l in labels)
      AppMenuItem<String>(value: l, label: l, icon: Icons.circle_outlined),
  ];

  NavigatorState nav(WidgetTester tester) =>
      tester.state<NavigatorState>(find.byType(Navigator).first);

  testWidgets('选中一项之后路由栈是干净的', (tester) async {
    await pumpHost(tester);
    expect(nav(tester).canPop(), isFalse);

    final f = showAppMenu<String>(ctx, items: items(<String>['甲']));
    await tester.pumpAndSettle();
    expect(find.text('甲'), findsOneWidget);
    expect(nav(tester).canPop(), isTrue);

    Navigator.of(ctx).pop('甲');
    await tester.pumpAndSettle();
    expect(await f, '甲');
    expect(nav(tester).canPop(), isFalse);
  });

  testWidgets('点空白取消之后路由栈也是干净的', (tester) async {
    await pumpHost(tester);

    final f = showAppMenu<String>(ctx, items: items(<String>['甲']));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(await f, isNull);
    expect(nav(tester).canPop(), isFalse, reason: '取消后留下了遮罩');
  });

  testWidgets('连开连关 20 轮，路由栈不会越积越多', (tester) async {
    await pumpHost(tester);
    final n = nav(tester);

    for (var i = 0; i < 20; i++) {
      final f = showAppMenu<String>(ctx, items: items(<String>['第 $i 项']));
      await tester.pumpAndSettle();
      expect(find.text('第 $i 项'), findsOneWidget);
      expect(n.canPop(), isTrue, reason: '第 $i 轮菜单没开出来');

      // 混着来：一半选中、一半点空白取消
      if (i.isEven) {
        Navigator.of(ctx).pop('第 $i 项');
      } else {
        await tester.tapAt(const Offset(4, 4));
      }
      await tester.pumpAndSettle();
      await f;
      expect(n.canPop(), isFalse, reason: '第 $i 轮留下了路由');
    }
  });

  testWidgets('一个菜单关掉之后，下一个照常能开', (tester) async {
    await pumpHost(tester);

    for (final label in <String>['甲', '乙', '丙']) {
      final f = showAppMenu<String>(ctx, items: items(<String>[label]));
      await tester.pumpAndSettle();
      expect(find.text(label), findsOneWidget, reason: '$label 那一轮开不出来');
      Navigator.of(ctx).pop(label);
      await tester.pumpAndSettle();
      expect(await f, label);
    }
  });
}
