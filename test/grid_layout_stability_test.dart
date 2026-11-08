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

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/notes/widgets/note_card.dart';
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

  /// 用户报的原话：
  ///   「就是笔记编辑完返回去瀑布流会有大片空缺没有补上来」
  ///   「移动端的问题」
  ///
  /// 根因不在刷新，在瀑布流库：`SliverMasonryGrid` 把每一格落在哪一列
  /// 记在 parentData 里，而 sliver 的子节点是**按下标**复用的。编辑完
  /// 一篇，它因为 `updated_at` 变了跳到最前面，后面每个下标都换成了
  /// 另一篇笔记，但"第 i 个孩子在第几列、上次多高"还是旧的 —— 库不会
  /// 因为顺序变了就从头重排，于是左列越堆越高、右列顶上留一大片空。
  ///
  /// 判据：**每一列的第一张卡都要从顶上开始**。出 bug 时右列的第一张
  /// 会掉到半屏以下（探针实测：左列 162，右列 480）。
  testWidgets('手机两列：编辑一篇变长并跳到最前，两列都得从顶上开始', (tester) async {
    // 手机宽度，2 列 —— 用户报的就是这个场景。
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    state.setGridColumns(2);
    await state.refresh();
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(theme: AppTheme.light(), home: const HomeShell()),
      ),
    );
    await tester.pumpAndSettle();

    final before = _columnTops(tester);
    expect(before.length, 2, reason: '两列都该有卡片（$before）');
    final topLine = before.values.reduce(math.min);
    for (final entry in before.entries) {
      expect(
        entry.value,
        closeTo(topLine, 1.0),
        reason: '一开始两列就该齐平（$before）',
      );
    }

    // 真点开一篇、改长、返回 —— 和用户的操作顺序一致。
    await tester.tap(find.text('笔记 4').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('编辑').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField).first,
      List<String>.generate(40, (i) => '很长很长的一段正文内容 $i').join('\n\n'),
    );
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pumpAndSettle();
    for (var i = 0; i < 2; i++) {
      final back = find.byTooltip('返回');
      if (back.evaluate().isNotEmpty) {
        await tester.tap(back.first);
      } else {
        tester.state<NavigatorState>(find.byType(Navigator)).pop();
      }
      await tester.pumpAndSettle();
    }

    final after = _columnTops(tester);
    expect(after.length, 2, reason: '编辑之后两列都还该有卡片（$after）');
    final newTop = after.values.reduce(math.min);
    for (final entry in after.entries) {
      expect(
        entry.value - newTop,
        lessThan(80),
        reason: '列 ${entry.key} 顶上留了一大片空（$after）—— 瀑布流没有重新按高度分配',
      );
    }
  });
}

/// 每一列第一张卡片的 y。
///
/// 直接量 `NoteCard` 的外框（手机宽度走的就是它；桌面三栏用的是私有的
/// `_NoteGridCard`，那个拿不到类型）。按左边缘 x 分组，同一列的 x 完全
/// 相同；每组取最小的 y 就是这一列的顶部。
///
/// 不能用标题自己的 y —— 有头图的卡片，标题天然就低一截。
Map<double, double> _columnTops(WidgetTester tester) {
  final out = <double, double>{};
  for (final element in find.byType(NoteCard).evaluate()) {
    final box = element.renderObject;
    if (box is! RenderBox || !box.hasSize) continue;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    final key = (rect.left * 2).roundToDouble() / 2;
    final old = out[key];
    if (old == null || rect.top < old) out[key] = rect.top;
  }
  return out;
}

