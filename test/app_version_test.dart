/// 版本号的唯一来源。
///
/// 这条测试盯的是「界面显示的版本必须是包里那个」，而不是某个写死的字面量：
///   · 代码里不许再出现 `'1.0.0'` 这种版本字面量（改了 pubspec 必然漏改）；
///   · 设置页「关于」里显示的就是 `AppInfo.version`；
///   · `AppInfo` 读不到平台包时回落成破折号，而不是瞎猜一个版本。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/app_info.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/settings/settings_page.dart';

void main() {
  Future<void> pumpSettings(WidgetTester tester, AppState state) async {
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

  tearDown(AppInfo.resetForTesting);

  group('AppInfo', () {
    test('没读到平台包时回落成破折号，不会瞎报一个版本', () {
      AppInfo.resetForTesting();
      expect(AppInfo.loaded, isFalse);
      expect(AppInfo.version, AppInfo.unknownVersion);
    });

    test('注入什么就显示什么', () {
      AppInfo.setVersionForTesting('2.3.4+56');
      expect(AppInfo.loaded, isTrue);
      expect(AppInfo.version, '2.3.4+56');
    });
  });

  group('版本号单一来源', () {
    test('lib/ 里不许再出现版本号字面量', () {
      // 允许出现的地方：本文件、AppInfo 自己（注释里提到 1.0.0 是历史说明）。
      // 其余任何 dart 源码里冒出一串 `x.y.z` 又像版本号的，都说明有人又开始
      // 手写第二份版本号了。
      final versionLiteral = RegExp(r'''['"]\d+\.\d+\.\d+(?:\+\d+)?['"]''');
      final offenders = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final lines = entity.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.trimLeft().startsWith('//')) continue;
          final hit = versionLiteral.firstMatch(line);
          if (hit != null) {
            offenders.add('${entity.path}:${i + 1}  ${hit.group(0)}');
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            '版本号只该在 pubspec.yaml 的 version: 里写一份，'
            '界面读 AppInfo.version。这些地方又写死了：\n${offenders.join('\n')}',
      );
      // 顺带确认：那条正则真的能抓到东西（否则这条测试是假绿）
      expect(versionLiteral.hasMatch("const v = '1.0.0';"), isTrue);
    });

    testWidgets('设置页「关于」显示的是 AppInfo 里的版本，不是写死的', (tester) async {
      AppInfo.setVersionForTesting('7.7.7+77');
      final db = AppDatabase.inMemory();
      addTearDown(db.close);
      final repo = NoteRepository(db);
      final state = AppState(db, repo, ImportService(db, repo));
      await state.init();

      await pumpSettings(tester, state);

      expect(find.text('7.7.7+77'), findsOneWidget);
      expect(find.text('版本'), findsOneWidget);
      // 老字面量必须已经不在了
      expect(find.text('1.0.0'), findsNothing);
    });
  });
}
