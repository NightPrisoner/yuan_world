/// 本地图片**按显示尺寸解码**。
///
/// 为什么值得单独钉住：不加 `cacheWidth` 时 Flutter 会把整张图解进内存。
/// 用户库里有 9MB 的 1920×1080 PNG，一屏十几个缩略图就是十几份全尺寸
/// 位图（每份 ~8MB），直接顶穿默认 100MB 的图片缓存 —— 表现是"滚动卡"，
/// 而且**功能全都正常**，很难看出是解码尺寸的问题。
///
/// 这里用 `Image.image` 是不是 [ResizeImage]、宽度是多少来验证，
/// 不需要真的把图渲染出来（测试里也解不出真图）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/core/widgets/local_image.dart';

/// 1×1 的合法 PNG。
const List<int> kPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];

void main() {
  late Directory dir;
  late String file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('yw_img');
    file = '${dir.path}${Platform.pathSeparator}a.png';
    File(file).writeAsBytesSync(kPng);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  /// 把 [LocalImage] 放进一个固定宽度的盒子里，取回它实际用的 image provider。
  Future<ImageProvider> providerIn(
    WidgetTester tester,
    double width, {
    double dpr = 1.0,
    int? maxDecodeWidth,
    bool fullResolution = false,
    bool bounded = true,
  }) async {
    tester.view.devicePixelRatio = dpr;
    tester.view.physicalSize = const Size(2000, 2000);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: bounded
                ? SizedBox(
                    width: width,
                    height: width,
                    child: LocalImage(
                      path: file,
                      maxDecodeWidth: maxDecodeWidth,
                      fullResolution: fullResolution,
                    ),
                  )
                // 横向滚动 = 宽度没有约束，取不到显示尺寸
                : SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: LocalImage(path: file),
                  ),
          ),
        ),
      ),
    );
    await tester.pump();

    final img = tester.widget<Image>(find.byType(Image));
    return img.image;
  }

  int? decodeWidthOf(ImageProvider p) => p is ResizeImage ? p.width : null;

  testWidgets('列表缩略图：按显示尺寸解码，不是整张图', (tester) async {
    final p = await providerIn(tester, 96, dpr: 2);
    // 96 × 2 = 192 → 取整到 64 的倍数 = 192
    expect(decodeWidthOf(p), 192,
        reason: '96 逻辑像素、2 倍屏只需要 192 物理像素的位图');
  });

  testWidgets('大图位置就解大一点（同一张图、不同显示尺寸）', (tester) async {
    final thumb = await providerIn(tester, 96, dpr: 1);
    final hero = await providerIn(tester, 900, dpr: 1);
    final thumbW = decodeWidthOf(thumb)!;
    final heroW = decodeWidthOf(hero)!;
    expect(heroW, greaterThan(thumbW),
        reason: '解码尺寸要跟着显示尺寸走，不能一个数字用到底');
    expect(heroW, 960); // 900 → 取整到 64 的倍数
  });

  testWidgets('解码宽度向上取整到 64 的倍数（避免缓存碎片）', (tester) async {
    final p = await providerIn(tester, 100, dpr: 1);
    expect(decodeWidthOf(p)! % 64, 0);
    expect(decodeWidthOf(p), 128, reason: '100 要向上取到 128，不能截断成 64');
  });

  testWidgets('maxDecodeWidth 优先（封面横幅这种说不清宽度的）', (tester) async {
    final p = await providerIn(tester, 300, maxDecodeWidth: 1600);
    expect(decodeWidthOf(p), 1600);
  });

  testWidgets('看图页那种要放大的：原图，不做降采样', (tester) async {
    final p = await providerIn(tester, 300, fullResolution: true);
    expect(decodeWidthOf(p), isNull,
        reason: 'InteractiveViewer 能放大 5 倍，降采样之后放大就是马赛克');
  });

  testWidgets('宽度没有约束时不瞎猜：不设 cacheWidth', (tester) async {
    final p = await providerIn(tester, 300, bounded: false);
    expect(decodeWidthOf(p), isNull);
  });

  testWidgets('文件不存在：走兜底，不抛异常', (tester) async {
    File(file).deleteSync();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 100,
            height: 100,
            child: LocalImage(path: file, fallbackColor: Colors.red),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(Image), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
