/// 文件夹树展开/收起时的"一个一个来"。
///
/// 用户的原话：
///   「文件夹下拉出现子文件夹可以有个一个一个子文件夹展开的动画，收起同理」
///
/// 这里钉三件事（都是"观感"层面、位置对不对看不出来的）：
///   · 展开的第一帧子项**已经在树里**（是滑出来，不是播完才插进来）
///   · 序号靠前的先到位 —— 这就是"一个一个"
///   · 收起时子树还留着滑出去，播完才真的折叠；小三角当场翻过来
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
import 'package:yuan_world/features/shell/home_shell.dart';

void main() {
  late AppDatabase db;
  late AppState state;

  setUp(() async {
    db = AppDatabase.inMemory();
    final repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
  });

  tearDown(() => db.close());

  /// 左栏某个文件夹行前面的收起/展开小三角。
  Finder chevronOf(String name) => find.descendant(
    of: find.ancestor(of: find.text(name), matching: find.byType(Row)).first,
    matching: find.byIcon(Icons.chevron_right_rounded),
  );

  /// 小三角当前旋转角（弧度）：展开态 ≈ 1.57（转了 90°），收起态 ≈ 0。
  double chevronAngle(WidgetTester tester, String name) {
    final t = tester.widget<Transform>(
      find
          .ancestor(of: chevronOf(name), matching: find.byType(Transform))
          .first,
    );
    final m = t.transform;
    return math.atan2(m.storage[1], m.storage[0]).abs();
  }

  /// 父文件夹 → 子一 / 子二，子一底下还有孙一。
  void seedTree() {
    final parent = state.repo.createCollection('父文件夹')!;
    final child = state.repo.createCollection('子一', parentId: parent)!;
    state.repo.createCollection('子二', parentId: parent);
    state.repo.createCollection('孙一', parentId: child);
  }

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

  testWidgets('展开的第一帧子项就在树里（是滑出来，不是播完才出现）', (tester) async {
    seedTree();
    await state.refresh();
    await pumpWide(tester);

    // 默认是**展开**的（子文件夹本来就看得见），先把它收起来
    expect(find.text('子一'), findsOneWidget);
    await tester.tap(chevronOf('父文件夹'));
    await tester.pumpAndSettle();
    expect(find.text('子一'), findsNothing, reason: '收起来后子树要离场');

    await tester.tap(chevronOf('父文件夹'));
    await tester.pump();

    expect(find.text('子一'), findsOneWidget, reason: '这一帧就该在树里滑出来了');
    expect(find.text('孙一'), findsOneWidget);
    final start = tester.getTopLeft(find.text('子一')).dx;

    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('子一')).dx,
      greaterThan(start),
      reason: '子项应该是从左边滑进来的',
    );
  });

  testWidgets('展开是一行一行来的：先出场的先到位', (tester) async {
    seedTree();
    await state.refresh();
    await pumpWide(tester);

    // 默认展开：先量出"完全到位"时的位置
    await tester.pumpAndSettle();
    final kidSettled = tester.getTopLeft(find.text('子一')).dx;
    final grandSettled = tester.getTopLeft(find.text('孙一')).dx;

    // 收起来再来一次，这次抓中途
    await tester.tap(chevronOf('父文件夹'));
    await tester.pumpAndSettle();
    expect(find.text('子一'), findsNothing);

    await tester.tap(chevronOf('父文件夹'));
    await tester.pump();

    // 连采样一段时间：不假定"第几帧刚好到哪"（延迟是计时器排的，
    // 具体落帧跟测试的推进节奏有关），只要在过程中能看到"先出场的先到位"
    // 就够了。这一段的位移是 -10 → 0 的滑入，位移越小越接近到位。
    var sawSlide = false;
    var sawStagger = false;
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      final kid = tester.getTopLeft(find.text('子一')).dx - kidSettled;
      final grand = tester.getTopLeft(find.text('孙一')).dx - grandSettled;
      if (kid < -0.5) sawSlide = true;
      if (kid > grand + 0.5) sawStagger = true;
    }

    expect(sawSlide, isTrue, reason: '子项要从左边滑进来');
    expect(sawStagger, isTrue, reason: '子一排在孙一前面，应该更早出来 —— 这就是"一个一个来"');

    await tester.pumpAndSettle();
  });

  testWidgets('收起：子树滑出去，播完才真的折叠；小三角当场翻过来', (tester) async {
    seedTree();
    await state.refresh();
    await pumpWide(tester);

    // 默认展开，小三角是"转开"的样子
    final expandedAngle = chevronAngle(tester, '父文件夹');

    await tester.tap(chevronOf('父文件夹'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));

    expect(find.text('子一'), findsOneWidget, reason: '正在缩回去，不能瞬间消失');
    expect(find.text('孙一'), findsOneWidget);
    expect(
      chevronAngle(tester, '父文件夹'),
      isNot(closeTo(expandedAngle, 0.2)),
      reason: '小三角要立刻翻，别等动画播完 —— 否则点下去像没反应',
    );

    await tester.pumpAndSettle();
    expect(find.text('子一'), findsNothing);
    expect(find.text('孙一'), findsNothing);
  });

  testWidgets('收起之后父文件夹自己必须留在原位、完全不透明', (tester) async {
    // 回归：曾经把"父文件夹自己"也当成要离场的行，于是收起一次之后
    // 文件夹整个看不见了（行还在、只是被淡成了 0）。
    seedTree();
    await state.refresh();
    await pumpWide(tester);

    List<Opacity> rowOpacities() => tester
        .widgetList<Opacity>(
          find.ancestor(of: find.text('父文件夹'), matching: find.byType(Opacity)),
        )
        .toList();

    final before = tester.getTopLeft(find.text('父文件夹'));
    expect(rowOpacities().every((o) => o.opacity == 1.0), isTrue);

    await tester.tap(chevronOf('父文件夹'));
    for (final ms in [16, 100, 300]) {
      await tester.pump(Duration(milliseconds: ms));
      expect(find.text('父文件夹'), findsOneWidget, reason: '收起的是子树，父行必须留在树里');
      expect(
        rowOpacities().every((o) => o.opacity == 1.0),
        isTrue,
        reason: '父行不能跟着子树一起淡掉（+${ms}ms）',
      );
      expect(
        tester.getTopLeft(find.text('父文件夹')).dx,
        closeTo(before.dx, 0.01),
        reason: '父行不能跟着子树一起滑走（+${ms}ms）',
      );
    }

    await tester.pumpAndSettle();
    expect(find.text('父文件夹'), findsOneWidget);
    expect(rowOpacities().every((o) => o.opacity == 1.0), isTrue);
  });

  testWidgets('收起是展开的倒放：沿原路往左滑出去，不是原地淡出', (tester) async {
    // 用户原话：「怎么展开就怎么收起」。展开是 -10 → 0 的滑入，
    // 收起就该是 0 → -10 的滑出，而且用同一条曲线（时间反演）。
    seedTree();
    await state.refresh();
    await pumpWide(tester);

    // 先来一次完整的收起 → 展开，拿到"完全到位"的位置
    await tester.tap(chevronOf('父文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(chevronOf('父文件夹'));
    await tester.pumpAndSettle();
    final settled = tester.getTopLeft(find.text('子一')).dx;

    await tester.tap(chevronOf('父文件夹'));
    final dxs = <double>[];
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (find.text('子一').evaluate().isEmpty) break;
      dxs.add(tester.getTopLeft(find.text('子一')).dx);
    }

    expect(dxs, isNotEmpty, reason: '收起过程里子项要在树里待一会儿，不能瞬间消失');
    expect(
      dxs.any((d) => d < settled - 0.5),
      isTrue,
      reason: '收起要沿展开那条位移原路滑回去（往左），不能只在原地淡出',
    );
    for (var i = 1; i < dxs.length; i++) {
      expect(
        dxs[i],
        lessThanOrEqualTo(dxs[i - 1] + 0.01),
        reason: '收起的位移要一路往左，不该中途往右弹回去',
      );
    }
    await tester.pumpAndSettle();
  });

  testWidgets('收起侧栏再展开：文件夹行不该把入场动画再演一遍', (tester) async {
    // 回归：展开过文件夹之后 _revealOrder 一直留着序号，侧栏收起时整棵
    // 导航会被拆掉、展开时重建 —— 新建出来的 _TreeReveal 又会从 0 播一遍，
    // 用户看到的就是"收起/展开侧栏时文件夹抽搐"。
    seedTree();
    await state.refresh();
    await pumpWide(tester);

    await tester.tap(chevronOf('父文件夹'));
    await tester.pumpAndSettle();
    await tester.tap(chevronOf('父文件夹'));
    await tester.pumpAndSettle();
    final settledDx = tester.getTopLeft(find.text('子一')).dx;

    await tester.tap(find.text('收起侧栏'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('展开侧栏'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));

    // 量**位置**而不是透明度：侧栏展开时那一栏自己也在交叉淡入，
    // 找 Opacity 会连"整栏的淡入"一起量进去，不是我们要钉的东西。
    // 重演入场动画的行会从左边 -10 的位置开始滑，位置对不上。
    expect(find.text('子一'), findsOneWidget, reason: '侧栏展开后子文件夹应该就在树里');
    expect(
      tester.getTopLeft(find.text('子一')).dx,
      closeTo(settledDx, 0.5),
      reason: '侧栏重建不该让子文件夹把入场动画再演一遍（用户说的"抽搐"）',
    );
    await tester.pumpAndSettle();
  });
}
