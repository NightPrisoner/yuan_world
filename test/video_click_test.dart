/// "点视频中间播放不了" —— 修法的机制测试。
///
/// 用户截图里按钮明明在那儿却点不动，而同一排的底部控件好使。
/// 差别在于：底部控件走的是手势识别（竞技场），中间那个也是 —— 只要
/// 树里**任何一层**别的识别器在竞技场里赢了，onTap 就永远不来，
/// 但外观毫无异常。所以改成 Listener 收裸指针事件：它不进竞技场，
/// 谁都抢不走。
///
/// 这条测试就是把那个结论钉住（不需要真的播放器）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('上层有抢手势的识别器时，Listener 仍然收得到指针', (tester) async {
    var viaGesture = 0;
    var viaListener = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 170,
              // 模拟"上层有人也要这个点击"（滚动、选择、别的 detector）
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (_) {},
                onTap: () => viaGesture++,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // 视频那一层：裸指针事件
                    Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerUp: (_) => viaListener++,
                      child: const SizedBox.expand(),
                    ),
                    // 正中那个"纯视觉"的播放键：不能自己抢手势
                    IgnorePointer(
                      child: Center(
                        child: Container(
                          width: 58,
                          height: 58,
                          decoration: const BoxDecoration(
                            color: Colors.black26,
                            shape: BoxShape.circle,
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
      ),
    );

    await tester.tapAt(tester.getCenter(find.byType(SizedBox).first));
    await tester.pump();

    expect(viaListener, 1,
        reason: 'Listener 不进竞技场，必须收到这次点击（否则就是"点了没反应"）');
  });

  testWidgets('点在正中的按钮上和点在空白处，效果一致', (tester) async {
    final hits = <Offset>[];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              height: 170,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerUp: (e) => hits.add(e.position),
                    child: const SizedBox.expand(),
                  ),
                  IgnorePointer(
                    child: Center(
                      child: Container(
                        width: 58,
                        height: 58,
                        decoration: const BoxDecoration(
                          color: Colors.black26,
                          shape: BoxShape.circle,
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
    await tester.tapAt(box.center); // 正中（按钮上）
    await tester.pump();
    await tester.tapAt(Offset(box.left + 20, box.top + 20)); // 空白处
    await tester.pump();

    expect(hits.length, 2, reason: '两处都该收到，不再依赖"点在哪一层"');
  });
}
