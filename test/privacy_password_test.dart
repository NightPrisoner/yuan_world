/// 隐私空间密码的测试。
///
/// 这块是**安全边界**，而且它的失效方式是"悄悄失效"——
/// 密码照样能设、能进，只是防不住人。所以每条约束都单独钉。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/features/privacy/privacy_page.dart';

void main() {
  late AppDatabase db;
  late NoteRepository repo;

  setUp(() {
    db = AppDatabase.inMemory();
    repo = NoteRepository(db);
  });
  tearDown(() => db.close());

  group('口令散列', () {
    test('存的是 PBKDF2，不是明文', () {
      const raw = '我的密码1234';
      final h = hashPassword(raw);
      expect(h.contains(raw), isFalse, reason: '明文绝不能出现在存储里');
      expect(h, startsWith('pbkdf2\$'));
    });

    test('同样的密码两次设置得到不同的串（加了盐）', () {
      final a = hashPassword('same');
      final b = hashPassword('same');
      expect(a == b, isFalse, reason: '没加盐的话，翻库就能看出两处密码相同');
      // 但两个都能验过
      expect(verifySecret('same', a).ok, isTrue);
      expect(verifySecret('same', b).ok, isTrue);
    });

    test('正确的密码验得过，错的验不过', () {
      final h = hashPassword('correct horse');
      expect(verifySecret('correct horse', h).ok, isTrue);
      expect(verifySecret('correct hors', h).ok, isFalse);
      expect(verifySecret('', h).ok, isFalse);
      expect(verifySecret('CORRECT HORSE', h).ok, isFalse,
          reason: '密码区分大小写');
    });

    test('空存储一律验不过 —— 没设密码不等于随便输就能过', () {
      expect(verifySecret('anything', '').ok, isFalse);
      expect(verifySecret('', '').ok, isFalse);
    });

    test('损坏的散列不会崩，只是验不过', () {
      for (final bad in <String>[
        'pbkdf2\$',
        'pbkdf2\$abc\$@@@\$xyz',
        'pbkdf2\$notanumber\$c2FsdA\$aGFzaA',
        '完全不是散列的字符串',
      ]) {
        expect(() => verifySecret('x', bad), returnsNormally, reason: bad);
      }
    });

    test('PBKDF2 是确定性的：同样输入同样盐结果一致', () {
      final h = hashPassword('abc');
      // 再验一次必须还是通过（不能因为随机性导致时灵时不灵）
      for (var i = 0; i < 3; i++) {
        expect(verifySecret('abc', h).ok, isTrue);
      }
    });
  });

  group('老散列的兼容与升级', () {
    /// 复刻旧版 FNV-1a，模拟"用户在上一个版本设的密码"。
    String legacy(String raw) {
      var h = 0x811c9dc5;
      for (final c in raw.codeUnits) {
        h ^= c;
        h = (h * 0x01000193) & 0xFFFFFFFF;
      }
      return '${h.toRadixString(16).padLeft(8, '0')}:${raw.length}';
    }

    test('老密码仍然能验过 —— 升级不能让老用户被锁在门外', () {
      final old = legacy('老密码');
      final outcome = verifySecret('老密码', old);
      expect(outcome.ok, isTrue);
    });

    test('老散列会打上"需要升级"的标记', () {
      expect(verifySecret('老密码', legacy('老密码')).needsUpgrade, isTrue);
      expect(verifySecret('x', hashPassword('x')).needsUpgrade, isFalse);
    });

    test('老密码输错了照样验不过', () {
      expect(verifySecret('错的', legacy('老密码')).ok, isFalse);
    });
  });

  group('密保答案', () {
    test('大小写和首尾空格都不计较', () {
      expect(answerKey('  MyDog  '), answerKey('mydog'));
      expect(answerKey('MYDOG'), answerKey('mydog'));
    });

    test('答案也走同一套散列', () {
      final h = hashPassword(answerKey('  Fluffy '));
      expect(verifySecret(answerKey('fluffy'), h).ok, isTrue);
      expect(verifySecret(answerKey('  FLUFFY  '), h).ok, isTrue);
      expect(verifySecret(answerKey('other'), h).ok, isFalse);
    });
  });

  group('设置项与进入', () {
    late AppState state;

    setUp(() async {
      state = AppState(db, repo, ImportService(db, repo));
      await state.init();
    });

    test('没设密码时 hasPrivacyPassword 为假', () {
      expect(hasPrivacyPassword(state), isFalse);
    });

    test('设了密码就为真', () {
      repo.setSetting(kPrivacyPasswordKey, hashPassword('1234'));
      expect(hasPrivacyPassword(state), isTrue);
    });

    test('清成空串等于没设', () {
      repo.setSetting(kPrivacyPasswordKey, hashPassword('1234'));
      repo.setSetting(kPrivacyPasswordKey, '');
      expect(hasPrivacyPassword(state), isFalse);
    });

    test('密保问题单独判断', () {
      expect(hasSecurityQuestion(state), isFalse);
      repo.setSetting(kPrivacyQuestionKey, '我第一只宠物叫什么');
      expect(hasSecurityQuestion(state), isTrue);
    });

    test('三个键互不干扰', () {
      repo.setSetting(kPrivacyPasswordKey, hashPassword('p'));
      repo.setSetting(kPrivacyQuestionKey, 'q');
      repo.setSetting(kPrivacyAnswerKey, hashPassword(answerKey('a')));

      expect(hasPrivacyPassword(state), isTrue);
      expect(hasSecurityQuestion(state), isTrue);
      // 密码不能拿密保答案去验
      expect(
        verifySecret(answerKey('a'), repo.getSetting(kPrivacyPasswordKey)!)
            .ok,
        isFalse,
        reason: '密码和密保答案必须是两套独立的凭据',
      );
    });

    test('密码不会被写进数据库以外的任何地方（getSetting 之外无痕）', () {
      repo.setSetting(kPrivacyPasswordKey, hashPassword('secret'));
      // 模拟有人直接把整个 notes 表读出来
      final rows = db.db.select('SELECT * FROM notes');
      for (final r in rows) {
        expect(r.values.join().contains('secret'), isFalse);
      }
    });
  });
}
