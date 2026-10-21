import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/core/motion/apple_page_route.dart';

void main() {
  for (final verticalOnly in [false, true]) {
    testWidgets('正文边界与头图同帧同步且包住头图，开合方向=$verticalOnly', (tester) async {
      tester.view.physicalSize = const Size(430, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final navigator = GlobalKey<NavigatorState>();
      final sourceCard = GlobalKey();
      final sourceHero = GlobalKey();
      final destinationHero = GlobalKey();
      final coverPaint = UniqueKey();
      final sourcePaint = UniqueKey();
      Rect? rect(GlobalKey key) {
        final box = key.currentContext?.findRenderObject();
        final overlay =
            navigator.currentState!.overlay!.context.findRenderObject()!
                as RenderBox;
        if (box is! RenderBox || !box.hasSize) return null;
        return MatrixUtils.transformRect(
          box.getTransformTo(overlay),
          Offset.zero & box.size,
        );
      }

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  left: 230,
                  top: 480,
                  width: 170,
                  height: 190,
                  child: SizedBox(
                    key: sourceCard,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: Hero(
                        key: sourceHero,
                        tag: 'cover',
                        child: SizedBox(
                          key: sourcePaint,
                          width: 170,
                          height: 110,
                          child: const ColoredBox(color: Colors.blue),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final startCard = rect(sourceCard)!;
      final startCover = rect(sourceHero)!;
      final route = CardExpandPageRoute<void>(
        sourceRect: startCard,
        sourceRectBuilder: () => rect(sourceCard),
        sourceCoverRectBuilder: () => rect(sourceHero),
        coverKey: destinationHero,
        verticalOnly: verticalOnly,
        pageBuilder: (_) => Scaffold(
          body: Stack(
            children: [
              Positioned(
                left: 20,
                top: 112,
                width: 390,
                height: 244,
                child: Hero(
                  key: destinationHero,
                  tag: 'cover',
                  child: SizedBox(
                    key: coverPaint,
                    child: const ColoredBox(color: Colors.blue),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
      navigator.currentState!.push(route);
      await tester.pump();
      await tester.pump();
      Rect surface() {
        final clip = tester.widget<ClipPath>(
          find.byKey(const ValueKey('note-expand-surface')),
        );
        return clip.clipper!.getClip(const Size(430, 900)).getBounds();
      }

      void expectInSync() {
        final finder = find.byKey(coverPaint).evaluate().isNotEmpty
            ? find.byKey(coverPaint)
            : find.byKey(sourcePaint);
        final flight = tester.getRect(finder);
        final boundary = surface();
        expect(
          boundary.inflate(0.6).contains(flight.topLeft),
          isTrue,
          reason: '头图飞出了正文上边界：$flight / $boundary',
        );
        expect(
          boundary.inflate(0.6).contains(flight.bottomRight),
          isTrue,
          reason: '头图飞出了正文下边界：$flight / $boundary',
        );
      }

      for (var i = 0; i < 9; i++) {
        await tester.pump(const Duration(milliseconds: 38));
        expectInSync();
        final progress = Curves.fastOutSlowIn.transform(route.animation!.value);
        final begin = verticalOnly
            ? Rect.fromLTRB(0, startCard.top, 430, startCard.bottom)
            : startCard;
        final base = Rect.lerp(
          begin,
          const Rect.fromLTWH(0, 0, 430, 900),
          progress,
        )!;
        final expectedCover = MaterialRectArcTween(
          begin: startCover,
          end: const Rect.fromLTWH(20, 112, 390, 244),
        ).transform(progress)!;
        final expected = base.expandToInclude(expectedCover);
        final actual = surface();
        for (final pair in [
          (actual.left, expected.left),
          (actual.top, expected.top),
          (actual.right, expected.right),
          (actual.bottom, expected.bottom),
        ]) {
          expect(pair.$1, closeTo(pair.$2, 0.001), reason: '正文不能使用比头图更快的另一条曲线');
        }
      }
      expect(
        find.ancestor(
          of: find.byKey(const ValueKey('note-expand-surface')),
          matching: find.byType(FadeTransition),
        ),
        findsNothing,
      );
      await tester.pumpAndSettle();
      navigator.currentState!.pop();
      await tester.pump();
      for (var i = 0; i < 9; i++) {
        await tester.pump(const Duration(milliseconds: 38));
        expectInSync();
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('note-expand-surface')), findsNothing);
      expect(find.byKey(sourceHero), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('打开中途返回正文边界不跳到另一条曲线', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const Scaffold()),
    );
    final route = CardExpandPageRoute<void>(
      sourceRect: const Rect.fromLTWH(240, 400, 150, 120),
      pageBuilder: (_) => const Scaffold(),
    );
    navigator.currentState!.push(route);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 130));
    Rect surface() {
      final clip = tester.widget<ClipPath>(
        find.byKey(const ValueKey('note-expand-surface')),
      );
      return clip.clipper!
          .getClip(
            tester.getSize(find.byKey(const ValueKey('note-expand-surface'))),
          )
          .getBounds();
    }

    final before = surface();
    navigator.currentState!.pop();
    await tester.pump();
    expect(surface(), before);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  for (final closeDuringOpening in [false, true]) {
    testWidgets('真实头图飞行被反向或阅读滚动后关闭仍同步 $closeDuringOpening', (tester) async {
      tester.view.physicalSize = const Size(430, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final navigator = GlobalKey<NavigatorState>();
      final sourceKey = GlobalKey();
      final destinationKey = GlobalKey();
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      final sourcePaint = UniqueKey();
      final destinationPaint = UniqueKey();
      Rect? rect(GlobalKey key) {
        final box = key.currentContext?.findRenderObject();
        if (box is! RenderBox || !box.hasSize) return null;
        final overlay = navigator.currentState!.overlay!.context
            .findRenderObject()!;
        return MatrixUtils.transformRect(
          box.getTransformTo(overlay),
          Offset.zero & box.size,
        );
      }

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomRight,
              child: Hero(
                key: sourceKey,
                tag: 'scroll-cover',
                child: SizedBox(
                  key: sourcePaint,
                  width: 180,
                  height: 140,
                  child: const ColoredBox(color: Colors.blue),
                ),
              ),
            ),
          ),
        ),
      );
      final route = CardExpandPageRoute<void>(
        sourceRect: rect(sourceKey),
        sourceRectBuilder: () => rect(sourceKey),
        sourceCoverRectBuilder: () => rect(sourceKey),
        coverKey: destinationKey,
        pageBuilder: (_) => Scaffold(
          body: SingleChildScrollView(
            controller: scroll,
            child: Column(
              children: [
                const SizedBox(height: 110),
                Hero(
                  key: destinationKey,
                  tag: 'scroll-cover',
                  child: SizedBox(
                    key: destinationPaint,
                    width: 390,
                    height: 250,
                    child: const ColoredBox(color: Colors.blue),
                  ),
                ),
                const SizedBox(height: 1300),
              ],
            ),
          ),
        ),
      );
      navigator.currentState!.push(route);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 135));
      Rect surface() {
        final clip = tester.widget<ClipPath>(
          find.byKey(const ValueKey('note-expand-surface')),
        );
        return clip.clipper!.getClip(const Size(430, 900)).getBounds();
      }

      if (!closeDuringOpening) {
        await tester.pumpAndSettle();
        scroll.jumpTo(80);
        await tester.pump();
      }
      final before = surface();
      navigator.currentState!.pop();
      await tester.pump();
      expect(surface(), before);
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 30));
        if (find
            .byKey(const ValueKey('note-expand-surface'))
            .evaluate()
            .isEmpty) {
          break;
        }
        final flightFinder = find.byKey(destinationPaint).evaluate().isNotEmpty
            ? find.byKey(destinationPaint)
            : find.byKey(sourcePaint);
        final flight = tester.getRect(flightFinder);
        final boundary = surface().inflate(0.5);
        expect(boundary.contains(flight.topLeft), isTrue);
        expect(boundary.contains(flight.bottomRight), isTrue);
      }
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
