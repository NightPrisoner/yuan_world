/// 版本号彩蛋：连点设置里的版本号，随机放一张图。
///
/// 盯三件事：点几下才出现、出现的是不是图库里的图、能不能出得来。
/// 彩蛋最容易出的问题是"进去了出不来"——那比没有彩蛋糟得多。
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/easter_egg/version_egg.dart';
import 'package:yuan_world/features/settings/settings_page.dart';

void main() {
  late AppDatabase db;
  late AppState state;

  setUp(() async {
    db = AppDatabase.inMemory();
    final repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
    repo.insertNote(
      title: '随便一篇',
      content: 'x' * 100,
      excerpt: 'x',
      publishedAt: DateTime.now(),
      charCount: 100,
      wordCount: 50,
    );
  });

  tearDown(() => db.close());

  Future<void> pumpSettings(WidgetTester tester) async {
    // 视口给高一点，「关于」那一组（版本号在最底下）一次性渲染出来
    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(theme: AppTheme.light(), home: const SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 点一下版本号那一行。
  Future<void> tapVersion(WidgetTester tester) async {
    await tester.ensureVisible(find.text('1.0.0'));
    await tester.pump();
    await tester.tap(find.text('1.0.0'), warnIfMissed: true);
    // 行本身有个 90ms 的按压缩回动画，让它跑完再点下一次
    await tester.pump(const Duration(milliseconds: 150));
  }

  Future<void> openEgg(WidgetTester tester) async {
    for (var i = 0; i < kEggTapCount; i++) {
      await tapVersion(tester);
    }
    await tester.pumpAndSettle();
  }

  group('图库清单', () {
    test('真的能从资源清单里列出图库（pubspec 配错了这条会红）', () async {
      final gallery = await loadEggGallery();
      expect(
        gallery,
        isNotEmpty,
        reason: 'assets/egg/ 里没列出任何图 —— pubspec 的 assets 配错了？',
      );
      expect(
        gallery.every((p) => p.startsWith(kEggAssetDir)),
        isTrue,
        reason: '列出来的必须都在图库目录里',
      );
    });

    test('图库里至少有一张能认出来的图片格式', () async {
      final gallery = await loadEggGallery();
      const ok = <String>['.gif', '.jpg', '.jpeg', '.png', '.webp', '.bmp'];
      expect(
        gallery.any((p) => ok.any((e) => p.toLowerCase().endsWith(e))),
        isTrue,
        reason: '图库里没有图片文件：$gallery',
      );
    });

    test('顺序是固定的（便于复现）', () async {
      final a = await loadEggGallery();
      final b = await loadEggGallery();
      expect(a, b);
    });

    test('每张图都能解码，而且 GIF 是多帧的（说明真的会动）', () async {
      final gallery = await loadEggGallery();
      var animated = 0;
      for (final path in gallery) {
        final data = await rootBundle.load(path);
        final codec = await ui.instantiateImageCodec(
          data.buffer.asUint8List(),
        );
        expect(
          codec.frameCount,
          greaterThan(0),
          reason: '$path 解不出帧来',
        );
        if (path.toLowerCase().endsWith('.gif') && codec.frameCount > 1) {
          animated++;
        }
        // 顺手记下尺寸，零尺寸的图等于坏了
        final frame = await codec.getNextFrame();
        expect(frame.image.width, greaterThan(0), reason: '$path 宽度是 0');
        expect(frame.image.height, greaterThan(0), reason: '$path 高度是 0');
        frame.image.dispose();
        codec.dispose();
      }
      // 图库里有 GIF 的话，它们必须是会动的 —— 静态 GIF 当彩蛋没意思
      final gifs = gallery
          .where((p) => p.toLowerCase().endsWith('.gif'))
          .length;
      if (gifs > 0) {
        expect(animated, gifs, reason: '有 GIF 是静态的，不会动');
      }
    });
  });

  group('彩蛋页', () {
    Future<void> pumpEgg(
      WidgetTester tester, {
      required List<String> gallery,
      int seed = 7,
    }) async {
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: VersionEggPage(gallery: gallery, random: math.Random(seed)),
        ),
      );
      await tester.pumpAndSettle();
    }

    /// 当前显示的是哪张图。
    String? shown(WidgetTester tester) {
      final images = find.byType(Image).evaluate();
      if (images.isEmpty) return null;
      final w = images.first.widget as Image;
      return (w.image as AssetImage).assetName;
    }

    testWidgets('抽到的必须是图库里的图', (tester) async {
      final gallery = await loadEggGallery();
      await pumpEgg(tester, gallery: gallery);

      final asset = shown(tester);
      expect(asset, isNotNull, reason: '一张图都没显示出来');
      expect(gallery, contains(asset));
    });

    testWidgets('点一下换一张，而且换的还在图库里', (tester) async {
      final gallery = await loadEggGallery();
      await pumpEgg(tester, gallery: gallery);

      final first = shown(tester);
      if (gallery.length < 2) return; // 只有一张时没有"换一张"这回事

      // 多点几次，总该换到别的
      var changed = false;
      for (var i = 0; i < 8 && !changed; i++) {
        await tester.tap(find.byType(Image).first);
        await tester.pumpAndSettle();
        changed = shown(tester) != first;
      }
      expect(changed, isTrue, reason: '连点 8 次都没换图');
      expect(gallery, contains(shown(tester)));
    });

    testWidgets('随时能退出来', (tester) async {
      await pumpEgg(tester, gallery: await loadEggGallery());
      expect(find.byTooltip('离开'), findsOneWidget);
    });

    testWidgets('图库为空时给出提示，不崩也不空白', (tester) async {
      await pumpEgg(tester, gallery: const <String>[]);
      expect(find.textContaining('图库是空的'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('只有一张图时不显示"点一下换一张"', (tester) async {
      await pumpEgg(tester, gallery: <String>['${kEggAssetDir}091.webp']);
      expect(find.text('点一下换一张'), findsNothing);
    });

    testWidgets('读不出来的图给出错误提示，整页不崩', (tester) async {
      await pumpEgg(tester, gallery: <String>['$kEggAssetDir不存在.png']);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.textContaining('读不出来'), findsOneWidget);
    });
  });

  testWidgets('点两下什么都不该发生', (tester) async {
    await pumpSettings(tester);

    for (var i = 0; i < kEggTapCount - 1; i++) {
      await tapVersion(tester);
    }
    expect(find.byType(VersionEggPage), findsNothing);
  });

  testWidgets('点够次数弹出彩蛋，显示的是一张图', (tester) async {
    await pumpSettings(tester);
    await openEgg(tester);

    expect(find.byType(VersionEggPage), findsOneWidget);
    expect(find.byType(Image), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('从彩蛋退出来，回到设置页', (tester) async {
    await pumpSettings(tester);
    await openEgg(tester);
    expect(find.byType(VersionEggPage), findsOneWidget);

    await tester.tap(find.byTooltip('离开'));
    await tester.pumpAndSettle();
    expect(find.byType(VersionEggPage), findsNothing);
    expect(find.text('版本'), findsOneWidget);
  });

  testWidgets('退出之后再点，计数是重新开始的（不会一下就弹）', (tester) async {
    await pumpSettings(tester);
    await openEgg(tester);
    await tester.tap(find.byTooltip('离开'));
    await tester.pumpAndSettle();

    await tapVersion(tester);
    expect(find.byType(VersionEggPage), findsNothing);
  });
}
