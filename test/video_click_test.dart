/// "点视频中间播放不了" —— 两处机制测试。
///
/// 用户截图里正中的播放键明明在、点了却毫无反应，而**下面那一排控件好使**。
/// 查下来是两个原因叠加：
///
///   1. 底部控制条的外壳：`Column` 默认 `mainAxisSize: max`，把外壳撑到了
///      **整个视频那么高** —— 画面上的点击全被它吃掉，正中那个按钮
///      永远收不到。它自己的按钮倒是好的，因为那些本来就在这一层里。
///      所以这条测的就是"外壳只占自己那一截"。
///   2. 画面那一层以前用手势识别（要过竞技场），任何一层别的识别器赢了
///      就收不到 onTap，而外观毫无异常。现在改成 Listener 收裸指针事件。
///
/// 两条都不需要真的播放器。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/features/notes/widgets/media_card.dart';

void main() {
  group('底部控制条不能吃掉画面上的点击', () {
    /// 复刻控件层的叠放：画面手势层 + 正中按钮 + 底部控制条。
    Future<({int video, int bar})> pumpAndTap(
      WidgetTester tester,
      double height, {
      required bool tapCenter,
    }) async {
      var videoHits = 0;
      var barHits = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: height,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerUp: (_) => videoHits++,
                      child: const SizedBox.expand(),
                    ),
                    GestureDetector(
                      onTap: () => videoHits++,
                      child: const Center(
                        child: SizedBox(width: 58, height: 58),
                      ),
                    ),
                    // 真的控制条外壳（不是复刻）
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: IgnorePointer(
                        ignoring: false,
                        child: AnimatedOpacity(
                          opacity: 1,
                          duration: const Duration(milliseconds: 100),
                          child: GestureDetector(
                            onTap: () => barHits++,
                            child: VideoControlBarShell(
                              children: [
                                Slider(value: 0, onChanged: (_) {}),
                                const Row(children: [Text('00:00 / 00:12')]),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

      final box = tester.getRect(find.byType(SizedBox).first);
      await tester.tapAt(tapCenter ? box.center : Offset(box.center.dx, box.bottom - 20));
      await tester.pump();
      return (video: videoHits, bar: barHits);
    }

    testWidgets('点画面正中：这一下必须落到画面上（不能被控制条截走）', (tester) async {
      // 真实视频比这条控制条高得多，400 高才谈得上"中间"和"底部"是两回事
      final r = await pumpAndTap(tester, 400, tapCenter: true);
      expect(r.video, greaterThan(0),
          reason: '控制条外壳撑高了的话，这下面永远收不到点击 —— '
              '用户的"点中间没反应"就是这么来的');
      expect(r.bar, 0, reason: '画面中间不该由控制条接');
    });

    testWidgets('点底部那一条：控制条接（它自己的按钮仍然好用）', (tester) async {
      final r = await pumpAndTap(tester, 400, tapCenter: false);
      expect(r.bar, greaterThan(0));
    });

    testWidgets('外壳高度明显小于视频高度（只占自己那一截）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: 400,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: VideoControlBarShell(
                        children: [
                          Slider(value: 0, onChanged: (_) {}),
                          const Row(children: [Text('00:00 / 00:12')]),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final h = tester.getSize(find.byType(VideoControlBarShell)).height;
      expect(h, lessThan(200),
          reason: '外壳撑满整个视频高度是这次 bug 的根因');
    });
  });

  group('画面上的点击不走手势竞技场', () {
    testWidgets('上层有抢手势的识别器时，Listener 仍然收得到', (tester) async {
      var viaListener = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 300,
                height: 170,
                // 上层也想要这个点击（滚动、选择、别的 detector）
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (_) {},
                  onTap: () {},
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerUp: (_) => viaListener++,
                        child: const SizedBox.expand(),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tapAt(tester.getCenter(find.byType(SizedBox).first));
      await tester.pump();
      expect(viaListener, 1,
          reason: 'Listener 不进竞技场，必须收到这次点击');
    });
  });
}
