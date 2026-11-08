/// 正文里的「外部文件」在界面上的表现。
///
/// 开了「只引用原文件」之后，正文引用的是 `C:\素材\a.png` 这种绝对路径。
/// 阅读页必须做到两件事：
///   1. 正常时能显示，并且给一行小提示说明"这不是软件里的文件"——
///      否则用户备份完换台机器，完全不知道为什么会丢；
///   2. 原文件被挪走/删掉时，给一行"原文件找不到了"，而不是一块白。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/features/notes/widgets/content_view.dart';

/// 1×1 透明 PNG：`LocalImage` 只在文件存在时才画。
final List<int> kPng = <int>[
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

Widget host(Widget child) => MaterialApp(
  theme: AppTheme.light(),
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

Widget block(String markdown, String imageRoot) => host(
  ContentViewBox(markdown: markdown, imageRoot: imageRoot, padding: EdgeInsets.zero),
);

void main() {
  late Directory tmp;
  late String external;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yw_ext_ui');
    external = p.join(tmp.path, '素材.png');
    File(external).writeAsBytesSync(kPng);
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('外部图片能显示，并带一行「外部文件」提示', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(block('![]($external)', tmp.path));
    await tester.pump();

    expect(find.textContaining('外部文件'), findsOneWidget);
    expect(find.textContaining('原文件找不到了'), findsNothing);
    // 提示里带完整路径，用户才知道该去哪儿找
    expect(find.textContaining(external), findsOneWidget);
  });

  testWidgets('原文件被删掉：给「原文件找不到了」，不是一块白', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    File(external).deleteSync();
    await tester.pumpWidget(block('![]($external)', tmp.path));
    await tester.pump();

    expect(find.textContaining('原文件找不到了'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('内部图片（相对路径）不显示外部提示', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final root = Directory(p.join(tmp.path, 'images'))..createSync();
    File(p.join(root.path, 'a.png')).writeAsBytesSync(kPng);
    await tester.pumpWidget(block('![](a.png)', root.path));
    await tester.pump();

    expect(find.textContaining('外部文件'), findsNothing);
    expect(find.textContaining('原文件找不到了'), findsNothing);
  });

  testWidgets('外部视频也带提示（视频不在这里真播，只看提示）', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final video = p.join(tmp.path, '片子.mp4');
    File(video).writeAsBytesSync(<int>[0, 0, 0]);
    await tester.pumpWidget(block('![]($video)', tmp.path));
    await tester.pump();

    // 视频卡片自己也会显示文件名/路径，所以这里只要求"有提示"、不去数个数
    expect(find.textContaining('外部文件'), findsWidgets);
    expect(find.textContaining(video), findsWidgets);
  });

  testWidgets('图片下面那行说明会显示出来（alt 就是图注）', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final root = Directory(p.join(tmp.path, 'images'))..createSync();
    File(p.join(root.path, 'a.png')).writeAsBytesSync(kPng);
    await tester.pumpWidget(block('![这是图注](a.png)', root.path));
    await tester.pump();

    expect(find.text('这是图注'), findsOneWidget);
    // 路径本身不该再当成文字画出来（画成图了）
    expect(find.textContaining('a.png'), findsNothing);
  });

  testWidgets('没写图注就不留空行', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final root = Directory(p.join(tmp.path, 'images'))..createSync();
    File(p.join(root.path, 'a.png')).writeAsBytesSync(kPng);
    await tester.pumpWidget(block('![](a.png)', root.path));
    await tester.pump();

    // 唯一的 Text 是空的就说明多渲染了一个空占位
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .where((t) => (t.data ?? '').isEmpty)
        .length;
    expect(texts, 0, reason: '没有图注时不要画一行空文字');
  });
}
