/// 版本号彩蛋。
///
/// 盯三件事：点几下才出现、出现了能不能用、能不能出得来。
/// 彩蛋最容易出的问题是"进去了出不来"——那比没有彩蛋糟得多。
library;

import 'package:flutter/material.dart';
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
  group('从标题里挑字', () {
    test('只留汉字、去重、保持顺序', () {
      final out = harvestCharacters(<String>['深夜写作 v2', '写作记录', 'abc']);
      expect(out, <String>['深', '夜', '写', '作', '记', '录']);
    });

    test('标点、数字、字母都不留', () {
      final out = harvestCharacters(<String>['a1b2，。！《》 汉字']);
      expect(out, <String>['汉', '字']);
    });

    test('有上限，超了不会无限攒', () {
      // 得用**互不相同**的字，否则去重之后只剩一个，测不到上限
      final many = <String>[
        for (var i = 0; i < 500; i++) String.fromCharCode(0x4E00 + i),
      ];
      expect(harvestCharacters(many, limit: 10).length, 10);
    });

    test('空输入给空表，不抛', () {
      expect(harvestCharacters(const <String>[]), isEmpty);
      expect(harvestCharacters(<String>['', '   ']), isEmpty);
    });
  });

  late AppDatabase db;
  late AppState state;

  setUp(() async {
    db = AppDatabase.inMemory();
    final repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
    repo.insertNote(
      title: '深夜写作记录',
      content: 'x' * 100,
      excerpt: 'x',
      publishedAt: DateTime.now(),
      charCount: 100,
      wordCount: 50,
    );
  });

  tearDown(() => db.close());

  Future<void> pumpSettings(WidgetTester tester) async {
    // 视口给高一点，让「关于」那一组（版本号在最底下）一次性渲染出来，
    // 省得每个用例都要先滚一下
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
  ///
  /// **全程用 pump(duration)，不用 pumpAndSettle** —— 彩蛋里有会一直转的
  /// 星海和放射光，settle 永远等不到头，会直接超时。这个坑值得写下来：
  /// 凡是打开彩蛋之后的步骤都得按时长推进。
  Future<void> tapVersion(WidgetTester tester) async {
    await tester.ensureVisible(find.text('1.0.0'));
    await tester.pump();
    await tester.tap(find.text('1.0.0'), warnIfMissed: true);
    // 行本身有个 90ms 的按压缩回动画，让它跑完再点下一次
    await tester.pump(const Duration(milliseconds: 150));
  }

  /// 连点到彩蛋打开，并等进场过渡走完。
  Future<void> openEgg(WidgetTester tester) async {
    for (var i = 0; i < kEggTapCount; i++) {
      await tapVersion(tester);
    }
    await tester.pump(const Duration(milliseconds: 800));
  }

  /// 长按大字标进入第二幕。
  Future<void> enterToy(WidgetTester tester) async {
    await tester.longPress(find.text('元世界'));
    await tester.pump(const Duration(milliseconds: 1000));
  }

  testWidgets('点两下什么都不该发生', (tester) async {
    await pumpSettings(tester);

    for (var i = 0; i < kEggTapCount - 1; i++) {
      await tapVersion(tester);
    }
    expect(find.byType(VersionEggPage), findsNothing);
    expect(find.text('长按进入'), findsNothing);
  });

  testWidgets('点够次数出大字标，底下写着版本号', (tester) async {
    await pumpSettings(tester);

    await openEgg(tester);

    expect(find.byType(VersionEggPage), findsOneWidget);
    expect(find.text('元世界'), findsOneWidget);
    expect(find.text('版本 1.0.0'), findsOneWidget);
    expect(find.text('长按进入'), findsOneWidget);
  });

  testWidgets('长按进入第二幕，能捡到字', (tester) async {
    await pumpSettings(tester);

    await openEgg(tester);

    await enterToy(tester);

    // 进入之后提示语换成玩法说明，大字标退场
    expect(find.text('拖动飞船，去捡你自己写过的字'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 把飞船拖到字上：多拖几个位置，总能撞上
    final size = tester.view.physicalSize / tester.view.devicePixelRatio;
    for (final p in <Offset>[
      Offset(size.width * 0.3, size.height * 0.3),
      Offset(size.width * 0.7, size.height * 0.4),
      Offset(size.width * 0.5, size.height * 0.25),
      Offset(size.width * 0.2, size.height * 0.5),
      Offset(size.width * 0.8, size.height * 0.6),
    ]) {
      await tester.dragFrom(
        Offset(size.width / 2, size.height * 0.62),
        p - Offset(size.width / 2, size.height * 0.62),
      );
      await tester.pump(const Duration(milliseconds: 200));
    }
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    // 捡到之后文案会变
    expect(find.text('你捡到了'), findsOneWidget);
  });

  testWidgets('随时能退出来（关闭按钮第一幕第二幕都在）', (tester) async {
    await pumpSettings(tester);

    await openEgg(tester);
    expect(find.byType(VersionEggPage), findsOneWidget);

    // 第一幕：关掉
    await tester.tap(find.byTooltip('离开'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byType(VersionEggPage), findsNothing);
    expect(find.text('版本'), findsOneWidget, reason: '回到设置页');

    // 再进一次，第二幕里也能关掉
    await openEgg(tester);
    await enterToy(tester);
    expect(find.text('拖动飞船，去捡你自己写过的字'), findsOneWidget);

    await tester.tap(find.byTooltip('离开'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.byType(VersionEggPage), findsNothing);
  });

  testWidgets('退出之后再点，计数是重新开始的（不会一下就弹）', (tester) async {
    await pumpSettings(tester);

    // 先进去再出来
    await openEgg(tester);
    await tester.tap(find.byTooltip('离开'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    // 只点一下：不该又弹出来
    await tapVersion(tester);
    expect(find.byType(VersionEggPage), findsNothing);
  });

  testWidgets('没有笔记时用兜底的字，不空场也不崩', (tester) async {
    // 清空笔记（先扔进回收站，再彻底清掉）
    for (final n in state.repo.listNotes(const NoteFilter())) {
      state.repo.deleteNote(n.id);
    }
    state.repo.purgeNotes(
      state.repo.listTrashedNotes().map((n) => n.id).toList(),
    );
    expect(state.repo.listNotes(const NoteFilter()), isEmpty);
    await pumpSettings(tester);

    await openEgg(tester);
    await enterToy(tester);

    expect(tester.takeException(), isNull);
    expect(find.text('拖动飞船，去捡你自己写过的字'), findsOneWidget);
  });
}
