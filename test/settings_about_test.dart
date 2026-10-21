/// 「关于」区块的署名行。
///
/// 用户要求最后加一行「制作   deepseek-v4.1-flash&梦之夜囚」，左边是「制作」，
/// 右边是署名。这里钉住三件事：这行确实在最后、左右位置对、窄屏上不溢出。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/settings/settings_page.dart';

const String kMakerLabel = '制作';
const String kMakerValue = 'deepseek-v4.1-flash&梦之夜囚';

void main() {
  late AppDatabase db;
  late AppState state;

  setUp(() async {
    db = AppDatabase.inMemory();
    final repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
  });

  tearDown(() {
    state.dispose();
    db.close();
  });

  Future<void> pumpSettings(WidgetTester tester, {Size size = const Size(900, 6000)}) async {
    tester.view.physicalSize = size;
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

  testWidgets('关于区块最后一行是制作署名，左标签右署名', (tester) async {
    await pumpSettings(tester);

    final label = find.text(kMakerLabel);
    final value = find.text(kMakerValue);
    expect(label, findsOneWidget);
    expect(value, findsOneWidget);

    // 左右关系：署名整个在「制作」右边
    final labelRect = tester.getRect(label);
    final valueRect = tester.getRect(value);
    expect(valueRect.left, greaterThan(labelRect.right));

    // 同一行：纵向有重叠
    expect(valueRect.top, lessThan(labelRect.bottom));
    expect(labelRect.top, lessThan(valueRect.bottom));

    // 它排在「界面框架」之后 —— 也就是关于区块的最后一行
    final framework = tester.getRect(find.text('Flutter 3.47'));
    expect(labelRect.top, greaterThan(framework.top));
  });

  testWidgets('署名的右边缘跟其它几行的值对齐，都贴右', (tester) async {
    // 用户报的正是这个：上一版用了 Spacer + Flexible，两个都是 flex 1，
    // 把剩余宽度平分了，值就停在了中间。这里拿同行里的其它值当标尺。
    await pumpSettings(tester);

    final makerRight = tester.getRect(find.text(kMakerValue)).right;
    for (final other in <String>['SQLite · FTS5', 'Flutter 3.47', '1.0.0']) {
      final right = tester.getRect(find.text(other)).right;
      expect(
        makerRight,
        closeTo(right, 0.5),
        reason: '「$other」的值贴右在 $right，署名却停在 $makerRight',
      );
    }
  });

  testWidgets('窄屏上署名不会把「制作」挤出屏幕', (tester) async {
    await pumpSettings(tester, size: const Size(360, 6000));

    expect(tester.takeException(), isNull);
    final labelRect = tester.getRect(find.text(kMakerLabel));
    final valueRect = tester.getRect(find.text(kMakerValue));
    expect(labelRect.left, greaterThanOrEqualTo(0));
    expect(valueRect.right, lessThanOrEqualTo(360));
    expect(valueRect.left, greaterThan(labelRect.right));
  });
}
