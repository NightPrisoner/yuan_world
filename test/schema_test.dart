/// schema 迁移的完整性测试。
///
/// 这个文件的存在是因为一个真实事故：`kSchemaVersion` 升到 7，
/// 但 `kMigrations` 里漏了第 7 项。迁移循环跑到 v7 找不到配置，
/// **什么都没做却把版本号写成了 7** —— 库被标成"已升级"而列根本不存在，
/// 之后永远不会再迁移，用户一启动就是白屏。
///
/// 这类错误不会在编译期报，也不会被普通业务测试覆盖，只能专门钉。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/db/schema.dart';

void main() {
  group('迁移表完整性', () {
    test('每个版本号都有对应的迁移步骤', () {
      for (var v = 2; v <= kSchemaVersion; v++) {
        expect(
          kMigrations.containsKey(v),
          isTrue,
          reason: 'kSchemaVersion 是 $kSchemaVersion，但 kMigrations 里没有 $v。'
              '这会让迁移静默跳过、版本号却照样前进。',
        );
        expect(
          kMigrations[v],
          isNotEmpty,
          reason: 'v$v 的迁移步骤是空的，等于没迁移',
        );
      }
    });

    test('迁移表里没有超出当前版本的项', () {
      for (final v in kMigrations.keys) {
        expect(
          v,
          lessThanOrEqualTo(kSchemaVersion),
          reason: 'v$v 比当前版本 $kSchemaVersion 还新，说明改完忘了升版本号',
        );
      }
    });
  });

  group('全新安装', () {
    test('建库后就带 deleted_at 列，无需迁移', () {
      final db = AppDatabase.inMemory();
      final cols = db.db
          .select('PRAGMA table_info(notes)')
          .map((r) => r['name'])
          .toSet();

      expect(cols, contains('deleted_at'));
      expect(
        db.db
            .select('PRAGMA table_info(collections)')
            .map((r) => r['name'])
            .toSet(),
        contains('deleted_at'),
      );
      db.close();
    });

    test('user_version 等于 kSchemaVersion', () {
      final db = AppDatabase.inMemory();
      final v = db.db.select('PRAGMA user_version').first.columnAt(0) as int;
      expect(v, kSchemaVersion);
      db.close();
    });
  });

  group('自愈', () {
    test('版本号到位但缺列时，重开数据库会自动补上', () {
      // 用**文件库**才能测"关掉再打开" —— 内存库一关就没了
      final dir = Directory.systemTemp.createTempSync('yw_schema_');
      final path = '${dir.path}/yuanworld.db';

      // 1) 先正常建一个库
      final first = AppDatabase.openAt(dir.path);
      // SQLite 不允许删掉「被索引引用」的列，所以索引要先删
      first.db.execute('DROP INDEX IF EXISTS idx_notes_deleted');
      first.db.execute('DROP INDEX IF EXISTS idx_collections_deleted');
      first.db.execute('ALTER TABLE notes DROP COLUMN deleted_at');
      first.db.execute('ALTER TABLE collections DROP COLUMN deleted_at');
      // 版本号保持 v7 —— 这正是事故现场：版本说升过了，列却不在
      final broken = first.db
          .select('PRAGMA table_info(notes)')
          .map((r) => r['name'])
          .toSet();
      expect(broken.contains('deleted_at'), isFalse, reason: '先确认真删掉了');
      first.close();

      // 2) 重新打开 —— 自愈逻辑应该把列补回来，而不是继续白屏
      final second = AppDatabase.openAt(dir.path);
      final healed = second.db
          .select('PRAGMA table_info(notes)')
          .map((r) => r['name'])
          .toSet();
      expect(healed, contains('deleted_at'), reason: '自愈没生效，用户还是会白屏');
      expect(
        second.db
            .select('PRAGMA table_info(collections)')
            .map((r) => r['name'])
            .toSet(),
        contains('deleted_at'),
      );

      // 3) 补好之后原来的查询能跑通
      expect(
        () => second.db.execute(
          'SELECT COUNT(*) FROM notes WHERE deleted_at IS NOT NULL',
        ),
        returnsNormally,
      );
      second.close();
      expect(File(path).existsSync(), isTrue);
      dir.deleteSync(recursive: true);
    });

    test('列本来就在时不会重复加（幂等）', () {
      final dir = Directory.systemTemp.createTempSync('yw_schema2_');
      AppDatabase.openAt(dir.path).close();
      // 再开两次，每次都会跑一遍自愈检查
      AppDatabase.openAt(dir.path).close();
      final db = AppDatabase.openAt(dir.path);

      final names = db.db
          .select('PRAGMA table_info(notes)')
          .map((r) => r['name'] as String)
          .toList();
      // 只有一列 deleted_at，不能出现重复列
      expect(names.where((n) => n == 'deleted_at').length, 1);
      db.close();
      dir.deleteSync(recursive: true);
    });

    test('关键列被查询时不会报 no such column', () {
      // 白屏的直接原因就是这句查询抛异常
      final db = AppDatabase.inMemory();
      expect(
        () => db.db.execute(
          'SELECT COUNT(*) FROM notes WHERE deleted_at IS NOT NULL',
        ),
        returnsNormally,
      );
      expect(
        () => db.db.execute(
          'SELECT COUNT(*) FROM collections WHERE deleted_at IS NOT NULL',
        ),
        returnsNormally,
      );
      db.close();
    });
  });
}
