/// 概览卡片的「显示哪些数据」。
///
/// 用户提的两件事：
/// 1. 「词数」去掉 —— 中文按空格切词，数出来的东西不是用户以为的字数；
/// 2. 右上角给个入口，想看的项自己挑。
///
/// 这里钉住四件事：默认全显示、关掉就真没了、设置记得住、全关掉时不留白板。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/stats/stats_page.dart';

/// 概览里能挑的 8 项，和 `_kOverviewStats` 的 id 一一对应。
const List<String> kOverviewIds = <String>[
  'notes',
  'chars',
  'images',
  'videos',
  'collections',
  'tags',
  'favorites',
  'activeDays',
];

/// 每个 id 对应的 key（挂在 `_Stat` 上）。
Key statKeyOf(String id) => switch (id) {
  'notes' => const Key('ov-notes'),
  'chars' => const Key('ov-chars'),
  'images' => const Key('ov-images'),
  'videos' => const Key('ov-videos'),
  'collections' => const Key('ov-collections'),
  'tags' => const Key('ov-tags'),
  'favorites' => const Key('ov-favorites'),
  'activeDays' => const Key('ov-active-days'),
  _ => throw ArgumentError(id),
};

void main() {
  late AppDatabase db;
  late AppState state;

  setUp(() async {
    db = AppDatabase.inMemory();
    final repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
    for (var i = 0; i < 3; i++) {
      state.repo.insertNote(
        title: '第 $i 篇',
        content: 'x' * 120,
        excerpt: '正文',
        publishedAt: DateTime.now(),
        charCount: 120,
      );
    }
    await state.refresh();
  });

  tearDown(() => db.close());

  Future<void> pumpStats(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1300, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(theme: AppTheme.light(), home: const StatsPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 打开概览右上角的选项面板。
  Future<void> openSheet(WidgetTester tester) async {
    await tester.tap(find.byTooltip('概览里显示哪些数据'));
    await tester.pumpAndSettle();
    expect(find.text('概览里显示哪些数据'), findsOneWidget);
  }

  /// 点面板里某一项右边那个开关。
  Future<void> toggleInSheet(WidgetTester tester, String title) async {
    final dialog = find.byType(Dialog);
    final row = find
        .ancestor(
          of: find.descendant(of: dialog, matching: find.text(title)),
          matching: find.byType(Row),
        )
        .first;
    await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
  }

  testWidgets('概览默认把这些项全显示出来，但不再有词数', (tester) async {
    await pumpStats(tester);

    for (final id in kOverviewIds) {
      expect(find.byKey(statKeyOf(id)), findsOneWidget, reason: '少了 $id');
    }
    // 删掉的指标不能再冒出来
    expect(find.text('词数'), findsNothing);
  });

  testWidgets('关掉一项，概览里立刻看不到它，并且写进了设置', (tester) async {
    await pumpStats(tester);
    expect(find.byKey(const Key('ov-images')), findsOneWidget);

    await openSheet(tester);
    await toggleInSheet(tester, '图片');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ov-images')), findsNothing);
    expect(find.byKey(const Key('ov-notes')), findsOneWidget, reason: '别的项不该被连带');
    expect(state.repo.getSetting('stats.overviewHidden'), contains('images'));
  });

  testWidgets('重开页面还是照着上次的选择来', (tester) async {
    state.repo.setSetting('stats.overviewHidden', '["images","videos"]');
    await pumpStats(tester);

    expect(find.byKey(const Key('ov-images')), findsNothing);
    expect(find.byKey(const Key('ov-videos')), findsNothing);
    expect(find.byKey(const Key('ov-notes')), findsOneWidget);
  });

  testWidgets('全部关掉时给一句话，不是一张白卡', (tester) async {
    state.repo.setSetting('stats.overviewHidden', '["${kOverviewIds.join('","')}"]');
    await pumpStats(tester);

    for (final id in kOverviewIds) {
      expect(find.byKey(statKeyOf(id)), findsNothing);
    }
    expect(find.textContaining('概览的数据项都被关掉了'), findsOneWidget);
  });

  testWidgets('选项面板里八项都在，全部显示能把关掉的一次恢复', (tester) async {
    state.repo.setSetting('stats.overviewHidden', '["images","tags"]');
    await pumpStats(tester);

    await openSheet(tester);
    for (final id in kOverviewIds) {
      expect(
        find.byKey(ValueKey<String>('ov-toggle-$id')),
        findsOneWidget,
        reason: '面板里少了 $id',
      );
    }

    await tester.tap(find.text('全部显示'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('ov-images')), findsOneWidget);
    expect(find.byKey(const Key('ov-tags')), findsOneWidget);
  });

  testWidgets('关掉一项不会让同一行的另一项变形', (tester) async {
    await pumpStats(tester);
    final before = tester.getSize(find.byKey(const Key('ov-notes')));

    await openSheet(tester);
    await toggleInSheet(tester, '总字数');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    // 两列布局：笔记仍然占半行，不会被拉成整行宽
    expect(tester.getSize(find.byKey(const Key('ov-notes'))).width,
        closeTo(before.width, 0.5));
  });
}
