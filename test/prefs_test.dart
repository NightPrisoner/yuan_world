/// 界面偏好设置的测试。
///
/// 这几项都是「改了就应该记住」的开关。它们逻辑很薄，但薄不等于不用测 ——
/// 之前几次翻车都是从"改动太小不用测"开始的。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';

void main() {
  late AppDatabase db;

  setUp(() => db = AppDatabase.inMemory());
  tearDown(() => db.close());

  /// 新建一个 AppState（模拟"重启应用"），确保测的是真的落库而不是内存状态。
  Future<AppState> boot() async {
    final repo = NoteRepository(db);
    final state = AppState(db, repo, ImportService(db, repo));
    await state.init();
    return state;
  }

  group('文字大小', () {
    test('默认是标准档', () async {
      final state = await boot();
      expect(state.textScale, 1.0);
    });

    test('换档位会落库', () async {
      final state = await boot();
      state.setTextScale(1.3);

      expect(state.textScale, 1.3);
      expect(state.repo.getSetting('textScale'), '1.3');
    });

    test('重启后仍然是上次选的档位', () async {
      final first = await boot();
      first.setTextScale(1.15);

      // 同一份数据库，新建一个 AppState —— 相当于重启应用
      final second = await boot();
      expect(second.textScale, 1.15);
    });

    test('不在档位表里的值会被忽略', () async {
      final state = await boot();
      state.setTextScale(1.3);

      state.setTextScale(2.5);
      expect(state.textScale, 1.3, reason: '2.5 不是合法档位，应该原样保留');
      expect(state.repo.getSetting('textScale'), isNot('2.5'));
    });

    test('档位表是递增的，且包含默认值 1.0', () async {
      expect(AppState.textScaleOptions, contains(1.0));
      final sorted = List<double>.from(AppState.textScaleOptions)..sort();
      expect(AppState.textScaleOptions, sorted);
    });

    test('库里存了非法值时回落到默认，不会崩', () async {
      final repo = NoteRepository(db);
      repo.setSetting('textScale', '不是数字');

      final state = await boot();
      expect(state.textScale, 1.0);
    });
  });

  group('瀑布流列数', () {
    test('默认两列', () async {
      final state = await boot();
      expect(state.gridColumns, 2);
    });

    test('换列数会落库并能在重启后恢复', () async {
      final first = await boot();
      first.setGridColumns(4);

      expect(first.repo.getSetting('gridColumns'), '4');
      final second = await boot();
      expect(second.gridColumns, 4);
    });

    test('列数可以随便填，只挡手滑的极端值', () async {
      final state = await boot();

      // 想要多少要多少 —— 之前的 2–5 / 2–10 都是产品意义上的限制
      state.setGridColumns(7);
      expect(state.gridColumns, 7);
      state.setGridColumns(12);
      expect(state.gridColumns, 12);

      state.setGridColumns(99999);
      // 没有产品上限，只有一个防手滑的兜底
      //（输入框里打进去 99999 会让布局当场炸掉）
      expect(state.gridColumns, AppState.sanityMaxGridColumns);

      state.setGridColumns(0);
      expect(state.gridColumns, AppState.minGridColumns);
    });
  });

  group('目录与参数开关', () {
    test('目录默认开，关掉后重启仍然是关的', () async {
      final first = await boot();
      expect(first.tocEnabled, isTrue);

      first.setTocEnabled(false);
      final second = await boot();
      expect(second.tocEnabled, isFalse);
    });

    test('头参尾参默认都开', () async {
      final state = await boot();
      expect(state.headFieldsEnabled, isTrue);
      expect(state.tailFieldsEnabled, isTrue);
    });

    test('可以分别关掉头参和尾参，互不影响', () async {
      final first = await boot();
      first.setHeadFieldsEnabled(false);

      final second = await boot();
      expect(second.headFieldsEnabled, isFalse);
      expect(second.tailFieldsEnabled, isTrue, reason: '关头参不该连带关掉尾参');
    });
  });

  group('隐私空间', () {
    test('进入后会过滤隐藏内容', () async {
      final state = await boot();
      final id = state.repo.insertNote(title: '秘密', content: 'x', excerpt: 'x');
      state.repo.setNoteHidden(id, true);
      state.repo.insertNote(title: '公开', content: 'x', excerpt: 'x');
      await state.refresh();

      expect(state.notes.length, 1);
      expect(state.notes.first.title, '公开');

      state.enterPrivacyMode();
      expect(state.privacyMode, isTrue);
      expect(state.notes.length, 1);
      expect(state.notes.first.title, '秘密', reason: '隐私空间里只该看到藏起来那篇');
    });

    test('退出后回到普通内容', () async {
      final state = await boot();
      final id = state.repo.insertNote(title: '秘密', content: 'x', excerpt: 'x');
      state.repo.setNoteHidden(id, true);
      state.repo.insertNote(title: '公开', content: 'x', excerpt: 'x');
      await state.refresh();

      state.enterPrivacyMode();
      state.exitPrivacyMode();

      expect(state.privacyMode, isFalse);
      expect(state.notes.first.title, '公开');
    });

    test('隐私模式不持久化 —— 重启回到普通空间', () async {
      final first = await boot();
      first.enterPrivacyMode();
      expect(first.privacyMode, isTrue);

      // 重启
      final second = await boot();
      expect(second.privacyMode, isFalse,
          reason: '别人打开应用不该直接落在隐私内容上');
    });

    test('左栏只列隐私空间里的文件夹', () async {
      final state = await boot();
      final visible = state.repo.createCollection('公开集')!;
      final hidden = state.repo.createCollection('私密集')!;
      state.repo.setCollectionHidden(hidden, true);
      await state.refresh();

      expect(state.collections.map((c) => c.name), contains('公开集'));
      expect(state.collections.map((c) => c.name), isNot(contains('私密集')));

      state.enterPrivacyMode();
      expect(state.collections.map((c) => c.name), contains('私密集'));
      expect(state.collections.map((c) => c.name), isNot(contains('公开集')));
      expect(visible, isNotNull);
    });
  });

  group('主题', () {
    test('主题模式会落库并恢复', () async {
      final first = await boot();
      first.setThemeMode(ThemeMode.dark);

      final second = await boot();
      expect(second.themeMode, ThemeMode.dark);
    });
  });
}
