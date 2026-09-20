/// 视频封面态：**没点播放之前不建播放器**。
///
/// 以前每个可见的视频卡一进来就建一个 `Player`（为了拿首帧画面），
/// 一屏里放三个视频就是三个 libmpv 实例，各自带解码器和纹理。
/// 现在改成显示导入时生成的首帧图 `<视频名>_first_frame.png`，
/// 点下去才真的 `Player()`。
///
/// 这一组测的就是这条边界：没点之前**不能有 Video 控件**，
/// 但界面上要看得见封面和播放键；点了之后必须有变化（不能静默无反应）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart' show Video;
import 'package:yuan_world/core/media/poster_maker.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/features/notes/widgets/media_card.dart';

/// 1×1 的合法 PNG（`Image.file` 能真的解出来）。
const List<int> kPng1x1 = <int>[
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
  setUp(() {
    // 测试环境没有 libmpv：自动补首帧那条路必须关掉，
    // 否则每个"没有首帧图"的用例都会去建播放器白等 20 秒超时。
    PosterMaker.enabled = false;
    PosterMaker.resetForTest();
  });

  tearDown(() => PosterMaker.enabled = true);

  group('首帧图的名字是纯函数算出来的', () {
    test('x.mp4 → x_first_frame.png', () {
      expect(MediaCard.posterNameFor('images/7/x.mp4'),
          'images/7/x_first_frame.png');
    });

    test('只切最后一个点（文件名里有好几个点也不会切错）', () {
      expect(MediaCard.posterNameFor('images/7/a.b.c.mov'),
          'images/7/a.b.c_first_frame.png');
    });

    test('没有扩展名也不炸', () {
      expect(MediaCard.posterNameFor('images/7/raw'), 'images/7/raw_first_frame.png');
    });

    test('点开头（隐藏文件）不当作扩展名', () {
      expect(MediaCard.posterNameFor('images/7/.hidden'),
          'images/7/.hidden_first_frame.png');
    });
  });

  group('封面态', () {
    late Directory dir;
    late String videoPath;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('yw_poster');
      videoPath = '${dir.path}${Platform.pathSeparator}clip.mp4';
      File(videoPath).writeAsBytesSync(const <int>[0, 0, 0, 0]);
    });

    tearDown(() => dir.deleteSync(recursive: true));

    void writePoster() {
      File('${dir.path}${Platform.pathSeparator}clip_first_frame.png')
          .writeAsBytesSync(kPng1x1);
    }

    Future<void> pumpCard(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: MediaCard(path: videoPath, relPath: 'images/7/clip.mp4'),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('没点之前一个 Video 控件都没有（播放器没建）', (tester) async {
      writePoster();
      await pumpCard(tester);
      expect(find.byType(Video), findsNothing,
          reason: '懒加载的意义就在这：没点之前不能有播放器');
    });

    testWidgets('有首帧图就显示它当封面', (tester) async {
      writePoster();
      await pumpCard(tester);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('没有首帧图退化成深色占位块，一样有播放键（不是空白）', (tester) async {
      await pumpCard(tester);
      expect(find.byType(Image), findsNothing);
      // 播放键还在：用户看到的是一个能点的封面，不是一块死黑
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
    });

    testWidgets('视频文件没了：说明原因，不给播放键', (tester) async {
      File(videoPath).deleteSync();
      await pumpCard(tester);
      expect(find.textContaining('视频找不到了'), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    });

    testWidgets('点封面之后必须有变化：要么起播放器，要么把失败原因说出来', (tester) async {
      writePoster();
      await pumpCard(tester);

      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // 测试环境里通常没有 libmpv-2.dll，所以这里**不假定**能播起来：
      // 有播放器就对了，没播放器就必须有错误提示 —— 两者都没有才是 bug
      // （用户看到的"点了没反应"）。
      final hasPlayer = find.byType(Video).evaluate().isNotEmpty;
      final hasError = find.textContaining('播放失败').evaluate().isNotEmpty;
      expect(hasPlayer || hasError, isTrue,
          reason: '点了封面却既没起播放器也没有任何提示 = 静默失败');
      expect(tester.takeException(), isNull);
    });

    testWidgets('没有首帧图时会去排一次"抓首帧"的队', (tester) async {
      await pumpCard(tester);
      expect(PosterMaker.wasRequested(videoPath), isTrue,
          reason: '老视频（下载工具没给首帧图）应该自动补一张，'
              '否则封面永远是一块深色');
    });

    testWidgets('已经有首帧图就不抓了（抓一次就够了）', (tester) async {
      writePoster();
      await pumpCard(tester);
      expect(PosterMaker.wasRequested(videoPath), isFalse);
    });

    testWidgets('用户已经点了播放就不抓了（他自己在看画面）', (tester) async {
      await pumpCard(tester);
      // 先点一下让卡片进入播放器态，再重排一次（模拟列表回收重建）
      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      PosterMaker.resetForTest();
      await pumpCard(tester);
      expect(PosterMaker.wasRequested(videoPath), isFalse);
    });
  });
}
