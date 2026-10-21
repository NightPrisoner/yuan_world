/// 中栏瀑布流的"点来点去"稳定性。
///
/// 用户报的原话：
///   「中间那一栏是怎么排序的，为什么上面点到不同的文章，
///     下面的文章布局会变，这样点来点去文章布局一闪一闪的总是变化」
///
/// 瀑布流是按"当前最短的那一列"来放下一张卡的（不是按行），
/// 所以只要**任何一张卡的高度变了 2px**，"哪一列最短"就可能换人，
/// 后面一串卡会集体换列 —— 看起来就是整面墙在跳。
///
/// 当时选中的描边是画在 decoration 上的：未选中 0.5px、选中 1.5px，
/// 边框占布局 ⇒ 选中一篇，那张卡高度 +2px，整墙重排。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/shell/home_shell.dart';

void main() {
  late AppDatabase db;
  late AppState state;

  setUp(() async {
    db = AppDatabase.inMemory();
    final repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
    state.setGridMode(true);
    state.setGridColumns(3);
    for (var i = 0; i < 9; i++) {
      repo.insertNote(
        title: '笔记 $i',
        content: '正文 $i',
        excerpt: '正文',
        publishedAt: DateTime.now().subtract(Duration(days: i)),
      );
    }
  });

  tearDown(() => db.close());

  Future<void> pumpWide(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(theme: AppTheme.light(), home: const HomeShell()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 卡片本身的位置和尺寸（卡片是标题文字最近的 AnimatedContainer 祖先）。
  Rect cardRect(WidgetTester tester, String title) {
    final finder = find
        .ancestor(
          of: find.text(title).first,
          matching: find.byType(AnimatedContainer),
        )
        .first;
    return tester.getRect(finder);
  }

  testWidgets('换一篇笔记时，别的卡片一张都不许挪', (tester) async {
    await state.refresh();
    await pumpWide(tester);

    final titles = <String>[for (var i = 0; i < 9; i++) '笔记 $i'];

    // 先点开一篇：这时列表栏会变窄，位置变化是应该的，作为基准。
    await tester.tap(find.text('笔记 4').first);
    await tester.pumpAndSettle();
    final before = <String, Rect>{
      for (final t in titles) t: cardRect(tester, t),
    };

    // 再换一篇。列表栏宽度没变，唯一的差别是选中态换了个人 ——
    // 除了这两张卡自己的描边，谁都不该动。
    await tester.tap(find.text('笔记 8').first);
    await tester.pumpAndSettle();

    for (final t in titles) {
      if (t == '笔记 4' || t == '笔记 8') continue;
      expect(
        cardRect(tester, t),
        before[t],
        reason: '$t 不该因为"选了另一篇"而换位置或变尺寸',
      );
    }
  });

  testWidgets('选中与未选中的卡片尺寸完全一致', (tester) async {
    await state.refresh();
    await pumpWide(tester);

    // 「笔记 0」在左列第一张，不点它，先把尺寸记下来。
    final idle = cardRect(tester, '笔记 0');

    // 点开别的一篇，让正文栏出现、列表栏变窄，等它稳定。
    await tester.tap(find.text('笔记 4').first);
    await tester.pumpAndSettle();

    // 选中态的那张卡（笔记 4）与被选中的外框有关，
    // 这里验的是：描边厚度变化不参与布局。
    final selected = cardRect(tester, '笔记 4');
    expect(
      selected.height,
      closeTo(
        cardRect(tester, '笔记 0').height,
        0.001,
      ),
      reason: '两张卡内容行数相同，高度应该一样；描边不能撑高',
    );
    expect(idle.height, greaterThan(0));
  });
}
