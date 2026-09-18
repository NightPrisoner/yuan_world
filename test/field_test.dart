/// 文章自定义参数（头参数 / 尾参数）的测试。
///
/// 重点测三件事：
///   1. 自动参数的**默认**取值正确（年/月/日/时间各自取对粒度）
///   2. 用户手写后**以用户为准**，且能改回自动
///   3. 尾行能拼成 `——2026年9月14日18:43` 这种形态
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/db/schema.dart';
import 'package:yuan_world/data/repositories/field_repository.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';

void main() {
  late AppDatabase db;
  late NoteRepository notes;
  late FieldRepository fields;

  setUp(() {
    db = AppDatabase.inMemory();
    notes = NoteRepository(db);
    fields = FieldRepository(db);
  });

  tearDown(() => db.close());

  /// 建一篇笔记。
  ///
  /// `updated_at` 由 insertNote 写成「现在」，所以要测「最后编辑时间」
  /// 必须建完再用 SQL 改掉 —— 这里替调用方做掉。
  int addNote({DateTime? createdAt, DateTime? updatedAt}) {
    final id = notes.insertNote(
      title: '测试',
      content: 'x',
      excerpt: 'x',
      createdAt: createdAt,
    );
    if (updatedAt != null) {
      db.db.execute(
        'UPDATE notes SET updated_at = ? WHERE id = ?',
        <Object?>[updatedAt.millisecondsSinceEpoch, id],
      );
    }
    return id;
  }

  group('预置参数', () {
    test('开箱就有头参数「年 月 日 时间」', () {
      final head = fields.headFields().map((f) => f.name).toList();
      expect(head, <String>['年', '月', '日', '时间']);
    });

    test('开箱的尾参数是带破折号的一行', () {
      final tail = fields.tailFields();
      expect(tail, isNotEmpty);
      expect(tail.every((f) => f.isDash), isTrue);
      expect(tail.every((f) => f.isAuto), isTrue, reason: '默认跟最后编辑时间走');
    });

    test('头参数默认按创建时间自动填', () {
      final noteId = addNote(createdAt: DateTime(2026, 9, 14, 18, 43));
      final note = notes.getNote(noteId)!;
      final head = fields.entriesFor(note, slot: 'head');

      expect(head.length, 4);
      expect(head.map((e) => e.value).toList(),
          <String>['2026', '9', '14', '18:43']);
      expect(head.every((e) => e.isAuto), isTrue);
      expect(head.every((e) => !e.isOverridden), isTrue);
    });

    test('头尾分别跟创建时间和最后编辑时间走', () {
      final noteId = addNote(
        createdAt: DateTime(2020, 1, 2, 3, 4),
        updatedAt: DateTime(2026, 9, 14, 18, 43),
      );
      final note = notes.getNote(noteId)!;

      expect(
        fields.entriesFor(note, slot: 'head').map((e) => e.value).toList(),
        <String>['2020', '1', '2', '03:04'],
      );
      expect(
        FieldRepository.composeDashedTail(
          fields.entriesFor(note, slot: 'tail'),
        ),
        '——2026年9月14日18:43',
      );
    });
  });

  group('自动取值', () {
    test('年 / 月 / 日 / 时间各取对的粒度', () {
      final t = DateTime(2026, 9, 14, 18, 43, 30);
      String v(String name) =>
          FieldRepository.autoValue(
            fields.all().firstWhere((f) => f.name == name),
            t,
          );

      expect(v('尾年'), '2026');
      expect(v('尾月'), '9');
      expect(v('尾日'), '14');
      expect(v('尾时间'), '18:43', reason: '24 小时制，补零到 HH:mm');
    });

    test('个位数的小时和分钟会补零', () {
      final t = DateTime(2026, 1, 5, 9, 7);
      final time = fields.all().firstWhere((f) => f.name == '尾时间');
      expect(FieldRepository.autoValue(time, t), '09:07');
    });

    test('单位没写明时给出完整的日期时间', () {
      final id = fields.createField(name: '完整时间', autoSource: 'updated')!;
      final def = fields.all().firstWhere((f) => f.id == id);
      expect(
        FieldRepository.autoValue(def, DateTime(2026, 9, 14, 18, 43)),
        '2026-09-14 18:43',
      );
    });
  });

  group('尾行拼接', () {
    test('拼成 ——2026年9月14日18:43', () {
      final noteId = addNote(
        createdAt: DateTime(2020, 1, 1),
        updatedAt: DateTime(2026, 9, 14, 18, 43),
      );
      final note = notes.getNote(noteId)!;
      final tail = fields.entriesFor(note, slot: 'tail');

      expect(
        FieldRepository.composeDashedTail(tail),
        '——2026年9月14日18:43',
      );
    });

    test('一个值都没有时不显示破折号', () {
      final id = fields.createField(
        name: '空的尾参数',
        slot: 'tail',
        tailStyle: 'dash',
      )!;
      // 把预置的尾参数删掉，只留这个空的
      for (final f in fields.tailFields()) {
        if (f.id != id) fields.deleteField(f.id);
      }
      final noteId = addNote();
      final note = notes.getNote(noteId)!;

      expect(
        FieldRepository.composeDashedTail(fields.entriesFor(note, slot: 'tail')),
        '',
        reason: '一个字都没有就不该出现孤零零的破折号',
      );
    });

    test('只有 dash 的参与拼接', () {
      fields.createField(name: '普通尾参数', slot: 'tail', tailStyle: 'plain');
      final noteId = addNote(updatedAt: DateTime(2026, 9, 14, 18, 43));
      final note = notes.getNote(noteId)!;
      final joined =
          FieldRepository.composeDashedTail(fields.entriesFor(note, slot: 'tail'));

      expect(joined, '——2026年9月14日18:43');
      expect(joined.contains('普通尾参数'), isFalse);
    });
  });

  group('用户改写', () {
    test('手写后以用户为准，不再跟自动更新走', () {
      final noteId = addNote(updatedAt: DateTime(2026, 9, 14, 18, 43));
      final yearDef = fields.tailFields().firstWhere((f) => f.name == '尾年');

      fields.setValue(noteId, yearDef.id, '1999');
      final note = notes.getNote(noteId)!;
      final tail = fields.entriesFor(note, slot: 'tail');
      final year = tail.firstWhere((e) => e.def.id == yearDef.id);

      expect(year.value, '1999');
      expect(year.isOverridden, isTrue);
      expect(year.isAuto, isFalse);
      expect(
        FieldRepository.composeDashedTail(tail),
        '——1999年9月14日18:43',
      );
    });

    test('清除手写值后回到自动', () {
      final noteId = addNote(updatedAt: DateTime(2026, 9, 14, 18, 43));
      final yearDef = fields.tailFields().firstWhere((f) => f.name == '尾年');

      fields.setValue(noteId, yearDef.id, '1999');
      fields.clearValue(noteId, yearDef.id);

      final note = notes.getNote(noteId)!;
      final year = fields
          .entriesFor(note, slot: 'tail')
          .firstWhere((e) => e.def.id == yearDef.id);
      expect(year.value, '2026');
      expect(year.isOverridden, isFalse);
    });

    test('头参数改写后不再跟创建时间走', () {
      final noteId = addNote(createdAt: DateTime(2026, 9, 14, 18, 43));
      final head = fields.headFields();
      fields.setValue(noteId, head[0].id, '2020');

      final note = notes.getNote(noteId)!;
      final entries = fields.entriesFor(note, slot: 'head');
      expect(entries[0].value, '2020');
      expect(entries[0].isOverridden, isTrue);
      expect(entries[1].value, '9', reason: '没改的还是自动的');
      expect(entries[1].isAuto, isTrue);
    });

    test('改一篇文章的值不会影响另一篇', () {
      final a = addNote(createdAt: DateTime(2026, 9, 14));
      final b = addNote(createdAt: DateTime(2026, 9, 14));
      final head = fields.headFields().first;
      fields.setValue(a, head.id, '1999');

      final entry =
          fields.entriesFor(notes.getNote(b)!, slot: 'head').first;
      expect(entry.value, '2026', reason: '另一篇还是自动值');
      expect(entry.isOverridden, isFalse);
    });
  });

  group('参数管理', () {
    test('新建参数，重名会被拒', () {
      expect(fields.createField(name: '心情', kind: 'select', options: '好,一般,差'), isNotNull);
      expect(fields.createField(name: '心情'), isNull);
      expect(fields.createField(name: '  '), isNull);
    });

    test('新建的参数默认排在所在那一侧的最后', () {
      final id = fields.createField(name: '天气')!;
      final head = fields.headFields();
      expect(head.last.id, id);
    });

    test('改名撞车返回 false', () {
      final id = fields.createField(name: '甲')!;
      expect(fields.updateField(fields.all().firstWhere((f) => f.id == id).copyWith(name: '年')), isFalse);
    });

    test('改归属能从尾挪到头', () {
      final def = fields.tailFields().first;
      expect(fields.updateField(def.copyWith(slot: 'head')), isTrue);
      expect(fields.headFields().map((f) => f.id), contains(def.id));
    });

    test('删除参数会连带删掉所有笔记上的值', () {
      final noteId = addNote();
      final def = fields.headFields().first;
      fields.setValue(noteId, def.id, '2026');

      fields.deleteField(def.id);

      expect(fields.headFields().map((f) => f.id), isNot(contains(def.id)));
      expect(fields.overridesFor(noteId).containsKey(def.id), isFalse);
    });

    test('可以恢复成出厂参数', () {
      fields.createField(name: '临时参数');
      expect(fields.all().length, greaterThan(8));

      fields.resetToDefaults(kDefaultFields);

      expect(fields.headFields().map((f) => f.name).toList(),
          <String>['年', '月', '日', '时间']);
      expect(fields.all().length, 8);
    });
  });

  group('统计', () {
    test('文本型参数能统计取值分布', () {
      final id = fields.createField(name: '心情')!;
      final a = addNote();
      final b = addNote();
      final c = addNote();
      fields.setValue(a, id, '好');
      fields.setValue(b, id, '好');
      fields.setValue(c, id, '一般');

      final dist = fields.valueDistribution(id);
      expect(dist.first.value, '好');
      expect(dist.first.count, 2);
      expect(dist.last.value, '一般');
    });

    test('自动参数按算出来的值统计（每年写了多少篇）', () {
      final yearDef = fields.tailFields().firstWhere((f) => f.name == '尾年');
      addNote(updatedAt: DateTime(2025, 3, 1));
      addNote(updatedAt: DateTime(2025, 8, 1));
      addNote(updatedAt: DateTime(2026, 1, 1));

      final dist = fields.valueDistribution(yearDef.id);
      expect(dist.firstWhere((d) => d.value == '2025').count, 2);
      expect(dist.firstWhere((d) => d.value == '2026').count, 1);
    });

    test('手写过的那篇按用户的值统计，不会被自动值重复计一次', () {
      final yearDef = fields.tailFields().firstWhere((f) => f.name == '尾年');
      final a = addNote(updatedAt: DateTime(2026, 1, 1));
      addNote(updatedAt: DateTime(2026, 1, 1));
      fields.setValue(a, yearDef.id, '1999');

      final dist = fields.valueDistribution(yearDef.id);
      final total = dist.fold<int>(0, (s, d) => s + d.count);
      expect(total, 2, reason: '两篇笔记只算两次');
      expect(dist.firstWhere((d) => d.value == '1999').count, 1);
      expect(dist.firstWhere((d) => d.value == '2026').count, 1);
    });

    test('数值型参数给出总和与均值', () {
      final head = fields.headFields();
      final yearId = head.firstWhere((f) => f.name == '年').id;
      final a = addNote();
      final b = addNote();
      fields.setValue(a, yearId, '2020');
      fields.setValue(b, yearId, '2026');

      final summary = fields.numericSummary();
      final year = summary.firstWhere((s) => s.def.id == yearId);
      expect(year.sum, 4046);
      expect(year.avg, 2023);
      expect(year.count, 2);
    });

    test('隐私空间的笔记不进入参数统计', () {
      final id = fields.createField(name: '心情')!;
      final a = addNote();
      final secret = addNote();
      fields.setValue(a, id, '好');
      fields.setValue(secret, id, '好');
      notes.setNoteHidden(secret, true);

      final dist = fields.valueDistribution(id);
      expect(dist.first.count, 1, reason: '藏起来那篇不能算进去');
    });
  });
}
