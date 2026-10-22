/// 动效与排版的验收测试：把这一轮排查到的问题钉死。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/motion/app_motion.dart';
import 'package:yuan_world/core/platform/window_mode.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/core/widgets/app_menu.dart' show isDesktopPlatform;
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/importer/import_page.dart';
import 'package:yuan_world/features/notes/editor/note_editor_page.dart';

/// 找出子树里所有指定类型的动画组件，返回它们的 duration。
List<Duration> _durationsOf<T extends Widget>(WidgetTester tester) => tester
    .widgetList<T>(find.byType(T))
    .map((w) {
      if (w is AnimatedContainer) return w.duration;
      if (w is AnimatedOpacity) return w.duration;
      if (w is AnimatedScale) return w.duration;
      if (w is AnimatedSwitcher) return w.duration;
      if (w is AnimatedAlign) return w.duration;
      if (w is AnimatedPadding) return w.duration;
      if (w is TweenAnimationBuilder) return w.duration;
      return Duration.zero;
    })
    .toList();

void main() {
  group('减弱动态效果', () {
    // 用一个合成的小页面来验契约：里面三类隐式动画的时长都从
    // AppMotion.respecting 取，这样「开/关减少动效」的差别才看得见。
    Widget probe() => Builder(
      builder: (context) => Scaffold(
        body: Column(
          children: [
            AnimatedContainer(
              duration: AppMotion.respecting(context, AppMotion.fast),
              width: 40,
              height: 40,
            ),
            AnimatedScale(
              scale: 1.2,
              duration: AppMotion.respecting(context, AppMotion.normal),
              child: const SizedBox(width: 10, height: 10),
            ),
            TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: AppMotion.respecting(context, AppMotion.fast),
              builder: (context, v, _) => SizedBox(height: v * 10),
            ),
            AnimatedSwitcher(
              duration: AppMotion.respecting(context, AppMotion.normal),
              child: const Text('x', key: ValueKey<String>('x')),
            ),
          ],
        ),
      ),
    );

    List<Duration> allDurations(WidgetTester tester) => [
      ..._durationsOf<AnimatedContainer>(tester),
      ..._durationsOf<AnimatedScale>(tester),
      ..._durationsOf<AnimatedSwitcher>(tester),
      ..._durationsOf<TweenAnimationBuilder<double>>(tester),
    ];

    testWidgets('开了「减弱动态效果」之后，隐式动画全部退化为零时长', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: child!,
          ),
          home: probe(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      final durations = allDurations(tester);
      expect(durations, isNotEmpty, reason: '探针页面里应该有几处隐式动画');
      expect(
        durations.every((d) => d == Duration.zero),
        isTrue,
        reason: '开了减弱动效后不该还有非零时长的隐式动画：$durations',
      );
    });

    testWidgets('没开的时候时长正常（不是被一刀切成 0）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.light(), home: probe()),
      );
      await tester.pump(const Duration(milliseconds: 300));

      final durations = allDurations(tester);
      expect(durations, isNotEmpty);
      expect(
        durations.every((d) => d > Duration.zero),
        isTrue,
        reason: '正常模式下时长应保持原值：$durations',
      );
    });
  });

  group('排版', () {
    testWidgets('导入页在 320 逻辑像素宽下不溢出（含桌面拖拽提示）', (tester) async {
      final db = AppDatabase.inMemory();
      final repo = NoteRepository(db);
      final state = AppState(db, repo, ImportService(db, repo));
      await state.init();
      addTearDown(() {
        state.dispose();
        db.close();
      });

      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(theme: AppTheme.light(), home: const ImportPage()),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(
        tester.takeException(),
        isNull,
        reason: '320 宽下导入页不该有 RenderFlex 溢出',
      );
      db.close();
    });
  });

  group('平台判定', () {
    test('桌面判定只有一份实现', () {
      // 这个测试只是把"两处别各写一遍"钉在可见处：改平台列表只改一处。
      expect(isDesktopPlatform(), isDesktopWindow);
    });
  });

  group('大字号下的排版', () {
    // 字号放大到 1.3 倍时，参数行（头参数那一串「年/月/日」）曾经把
    // Row 撑出屏幕 —— 用户能自己把字号调到这一档，所以必须不溢出。
    testWidgets('320 宽 + 1.3 倍字号：编辑器不溢出', (tester) async {
      final db = AppDatabase.inMemory();
      final repo = NoteRepository(db);
      final state = AppState(db, repo, ImportService(db, repo));
      await state.init();
      final id = repo.insertNote(
        title: '标题',
        content: '# 标题\n\n正文若干，用来量行高与折行。\n\n- 列表一\n\n> 引用',
        excerpt: '正文',
        publishedAt: DateTime(2025, 1, 2),
        charCount: 120,
        wordCount: 60,
      );
      await state.refresh();
      addTearDown(() {
        state.dispose();
        db.close();
      });

      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.light(),
            builder: (context, child) => MediaQuery.withClampedTextScaling(
              minScaleFactor: 1.3,
              maxScaleFactor: 1.3,
              child: child ?? const SizedBox.shrink(),
            ),
            home: NoteEditorPage(noteId: id),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));

      expect(
        tester.takeException(),
        isNull,
        reason: '320 宽 + 1.3 倍字号下编辑器不该有 RenderFlex 溢出',
      );
    });
  });

  group('滚动定位动画', () {
    testWidgets('点目录跳转的滚动跟着减弱动效一起退化', (tester) async {
      // 只验证契约：AppMotion.respecting 在开了减少动效时返回零时长。
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(disableAnimations: true),
            child: Builder(
              builder: (inner) {
                ctx = inner;
                return const SizedBox();
              },
            ),
          ),
          home: const SizedBox(),
        ),
      );
      expect(AppMotion.respecting(ctx, AppMotion.normal), Duration.zero);
    });
  });
}
