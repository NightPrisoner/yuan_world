import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/app_info.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';

/// 主题自定义：强调色、背景图、浓度/模糊、一键回默认。
///
/// 这些都在 `AppState` 里，读的是 settings 表 —— 所以直接建内存库测，
/// 不经过界面。界面那层只关心"能不能点到"，见 settings_new_options_test。
void main() {
  late Directory root;
  late AppDatabase db;
  late NoteRepository repo;
  late AppState state;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('yw_theme_');
    db = AppDatabase.openAt(root.path);
    repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
    AppInfo.setVersionForTesting('1.0.0');
  });

  tearDown(() {
    state.dispose();
    db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('强调色', () {
    test('默认没有自定义色', () {
      expect(state.themeSeed, isNull);
    });

    test('设了之后存得住，重开也还在', () async {
      state.setThemeSeed(const Color(0xFF34C759));
      expect(state.themeSeed?.toARGB32(), 0xFF34C759);

      // 换一套 AppState 模拟重启
      final again = AppState(db, repo, ImportService(db, repo));
      await again.init();
      expect(again.themeSeed?.toARGB32(), 0xFF34C759);
      again.dispose();
    });

    test('设成 null 就是清空，不是存一个 0', () {
      state.setThemeSeed(const Color(0xFF34C759));
      state.setThemeSeed(null);
      expect(state.themeSeed, isNull);
      expect(repo.getSetting('theme.seed'), '');
    });

    test('存了坏值也不崩，当没设过', () {
      repo.setSetting('theme.seed', 'not-a-color');
      expect(state.themeSeed, isNull);
    });
  });

  group('派生出来的颜色真的变了', () {
    test('换强调色时底色也跟着偏，不再只有按钮变', () {
      final plain = AppTheme.light();
      final green = AppTheme.light(seed: const Color(0xFF34C759));
      final a = plain.extension<AppColors>()!;
      final b = green.extension<AppColors>()!;

      // 强调色当然要变
      expect(b.tint.toARGB32(), isNot(a.tint.toARGB32()));
      // 这次的重点：分组底这种大面积的颜色也得跟着偏，
      // 否则用户会觉得"选了颜色但整个应用没变"
      expect(b.groupedBackground.toARGB32(),
          isNot(a.groupedBackground.toARGB32()));
      expect(b.tertiaryBackground.toARGB32(),
          isNot(a.tertiaryBackground.toARGB32()));
      // 但文字色不能动 —— 动了就可能读不清
      expect(b.label.toARGB32(), a.label.toARGB32());
      expect(b.secondaryLabel.toARGB32(), a.secondaryLabel.toARGB32());
    });

    test('深色主题下底色也偏，且幅度比如来小一些以免发白', () {
      final plain = AppTheme.dark().extension<AppColors>()!;
      final blue = AppTheme.dark(seed: const Color(0xFFFF2D55))
          .extension<AppColors>()!;
      expect(blue.groupedBackground.toARGB32(),
          isNot(plain.groupedBackground.toARGB32()));
      expect(blue.label.toARGB32(), plain.label.toARGB32());
    });

    test('不传 seed 就是原样那套，一点都不偏', () {
      final a = AppTheme.light().extension<AppColors>()!;
      expect(a.tint.toARGB32(), AppColors.light.tint.toARGB32());
      expect(a.groupedBackground.toARGB32(),
          AppColors.light.groupedBackground.toARGB32());
    });
  });

  group('界面背景图', () {
    test('默认没有背景图', () {
      expect(state.themeBackgroundPath, isNull);
      expect(state.themeBackgroundOpacity, 0.5);
      expect(state.themeBackgroundBlur, 0);
    });

    test('选了图之后路径存得住', () {
      final img = File(p.join(root.path, 'bg.png'))
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);
      state.setThemeBackgroundPath(img.path);
      expect(state.themeBackgroundPath, img.path);
    });

    test('图被删了就当没设过，别每帧都去开一次失败的文件', () {
      final img = File(p.join(root.path, 'bg.png'))
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);
      state.setThemeBackgroundPath(img.path);
      img.deleteSync();
      expect(state.themeBackgroundPath, isNull);
    });

    test('浓度夹在 0~1，模糊夹在 0~40', () {
      state.setThemeBackgroundOpacity(3.4);
      expect(state.themeBackgroundOpacity, 1.0);
      state.setThemeBackgroundOpacity(-2);
      expect(state.themeBackgroundOpacity, 0.0);

      state.setThemeBackgroundBlur(999);
      expect(state.themeBackgroundBlur, 40.0);
      state.setThemeBackgroundBlur(-1);
      expect(state.themeBackgroundBlur, 0.0);
    });

    test('参数存的是字符串，重开还是那个数', () async {
      state.setThemeBackgroundOpacity(0.35);
      state.setThemeBackgroundBlur(12);
      final again = AppState(db, repo, ImportService(db, repo));
      await again.init();
      expect(again.themeBackgroundOpacity, closeTo(0.35, 0.001));
      expect(again.themeBackgroundBlur, closeTo(12, 0.001));
      again.dispose();
    });

    test('半透明主题把几层底色都放透，卡片留得多一点', () {
      final base = AppTheme.light();
      final faded = AppTheme.translucent(base, keep: 0.5);
      final a = base.extension<AppColors>()!;
      final b = faded.extension<AppColors>()!;

      // 底越"外"越透，卡片（secondaryBackground）比页面底更实，
      // 这样正文不会在照片上晃
      expect(b.background.a, lessThan(a.background.a));
      expect(b.secondaryBackground.a, greaterThan(b.background.a));
      // 文字不变
      expect(b.label.toARGB32(), a.label.toARGB32());
      expect(b.tint.toARGB32(), a.tint.toARGB32());
    });
  });

  group('一键回默认', () {
    test('强调色、背景图、浓度、模糊一起清掉', () {
      final img = File(p.join(root.path, 'bg.png'))
        ..writeAsBytesSync(<int>[1, 2, 3, 4]);
      state.setThemeSeed(const Color(0xFF34C759));
      state.setThemeBackgroundPath(img.path);
      state.setThemeBackgroundOpacity(0.8);
      state.setThemeBackgroundBlur(20);

      state.resetTheme();

      expect(state.themeSeed, isNull);
      expect(state.themeBackgroundPath, isNull);
      expect(state.themeBackgroundOpacity, 0.5);
      expect(state.themeBackgroundBlur, 0);
    });

    test('不碰明暗模式 —— 用户选深色是他要的', () {
      state.setThemeMode(ThemeMode.dark);
      state.setThemeSeed(const Color(0xFF34C759));
      state.resetTheme();
      expect(state.themeMode, ThemeMode.dark);
    });
  });
}
