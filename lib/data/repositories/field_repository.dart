/// 文章自定义参数（头参数 / 尾参数）的读写与统计。
///
/// 单独一个仓储，不塞进已经八百多行的 NoteRepository 里。
///
/// 核心规则：
///   - [FieldDef.autoSource] 只决定**默认值从哪来**，不锁定。
///     用户手动改过就存进 `note_fields`，从此以用户写的为准 ——
///     始终保留改写的权力。
///   - 没有手动值时，自动参数**现算**，不落库。
library;

import 'package:sqlite3/sqlite3.dart';

import '../db/app_database.dart';
import '../models.dart';

class FieldRepository {
  FieldRepository(this.db);

  final AppDatabase db;

  Database get _d => db.db;

  static String _two(int v) => v.toString().padLeft(2, '0');

  // ── 定义 ────────────────────────────────────────────────────────────────

  List<FieldDef> all() => _d
      .select('SELECT * FROM field_defs ORDER BY slot ASC, sort_order ASC, id ASC')
      .map(FieldDef.fromRow)
      .toList();

  List<FieldDef> headFields() =>
      all().where((f) => f.isHead).toList();

  List<FieldDef> tailFields() =>
      all().where((f) => f.isTail).toList();

  /// 新建参数。名字重复返回 null。
  int? createField({
    required String name,
    String slot = 'head',
    String kind = 'text',
    String unit = '',
    String autoSource = '',
    String options = '',
    String tailStyle = 'plain',
  }) {
    final n = name.trim();
    if (n.isEmpty) return null;
    final clash = _d.select('SELECT 1 FROM field_defs WHERE name = ?', <Object?>[n]);
    if (clash.isNotEmpty) return null;

    final next = (_d
                .select('SELECT IFNULL(MAX(sort_order), -1) AS m FROM field_defs '
                    'WHERE slot = ?', <Object?>[slot])
                .first['m'] as int) +
        1;

    _d.execute(
      'INSERT INTO field_defs '
      '(name, slot, kind, unit, auto_source, options, tail_style, sort_order, created_at) '
      'VALUES (?,?,?,?,?,?,?,?,?)',
      <Object?>[
        n,
        slot,
        kind,
        unit,
        autoSource,
        options,
        tailStyle,
        next,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    return _d.lastInsertRowId;
  }

  /// 更新参数。改名撞车返回 false。
  bool updateField(FieldDef def) {
    final n = def.name.trim();
    if (n.isEmpty) return false;
    final clash = _d.select(
      'SELECT 1 FROM field_defs WHERE name = ? AND id <> ?',
      <Object?>[n, def.id],
    );
    if (clash.isNotEmpty) return false;

    _d.execute(
      'UPDATE field_defs SET name = ?, slot = ?, kind = ?, unit = ?, '
      'auto_source = ?, options = ?, tail_style = ?, sort_order = ? WHERE id = ?',
      <Object?>[
        n,
        def.slot,
        def.kind,
        def.unit,
        def.autoSource,
        def.options,
        def.tailStyle,
        def.sortOrder,
        def.id,
      ],
    );
    return true;
  }

  /// 删除参数定义，连带删掉所有笔记上这个参数的值。
  void deleteField(int id) =>
      _d.execute('DELETE FROM field_defs WHERE id = ?', <Object?>[id]);

  /// 按传入顺序重排**同一侧**的参数。
  void reorderFields(List<int> orderedIds) {
    if (orderedIds.isEmpty) return;
    _d.execute('BEGIN');
    try {
      final stmt = _d.prepare('UPDATE field_defs SET sort_order = ? WHERE id = ?');
      for (var i = 0; i < orderedIds.length; i++) {
        stmt.execute(<Object?>[i, orderedIds[i]]);
      }
      stmt.close();
      _d.execute('COMMIT');
    } catch (_) {
      _d.execute('ROLLBACK');
      rethrow;
    }
  }

  /// 恢复成出厂那套参数（先清空再重建）。
  void resetToDefaults(List<String> defaultInserts) {
    _d.execute('DELETE FROM field_defs');
    for (final sql in defaultInserts) {
      _d.execute(sql);
    }
  }

  // ── 取值 ────────────────────────────────────────────────────────────────

  /// 自动参数在某个时刻的默认值。
  ///
  /// 按单位/类型挑粒度：单位是「年」就给年份，是时间类型就给 `18:43`，
  /// 什么都没写就给完整的 `2026-09-14 18:43`。
  static String autoValue(FieldDef def, DateTime t) {
    switch (def.unit) {
      case '年':
        return '${t.year}';
      case '月':
        return '${t.month}';
      case '日':
        return '${t.day}';
    }
    if (def.isTime) return '${_two(t.hour)}:${_two(t.minute)}';
    return '${t.year}-${_two(t.month)}-${_two(t.day)} '
        '${_two(t.hour)}:${_two(t.minute)}';
  }

  /// 用户手写过、覆盖掉自动值的那些参数。
  Map<int, String> overridesFor(int noteId) {
    final rows = _d.select(
      'SELECT field_id, value FROM note_fields WHERE note_id = ?',
      <Object?>[noteId],
    );
    return <int, String>{
      for (final r in rows) r['field_id'] as int: (r['value'] as String?) ?? '',
    };
  }

  /// 算出某篇笔记在某一侧（头/尾）的完整参数列表，已含最终值。
  List<FieldEntry> entriesFor(Note note, {required String slot}) {
    final defs = all().where((f) => f.slot == slot).toList();
    if (defs.isEmpty) return const <FieldEntry>[];

    final overrides = overridesFor(note.id);

    return <FieldEntry>[
      for (final def in defs)
        () {
          final manual = overrides[def.id];
          final isOverridden = manual != null;
          // 按参数**自己**的自动来源取时间，而不是按它属于头还是尾 ——
          // 用户可以把任意参数放到任意一侧，还允许指定它跟创建还是跟编辑。
          final t = def.autoSource == 'created' ? note.createdAt : note.updatedAt;
          final value = isOverridden
              ? manual
              : (def.isAuto ? autoValue(def, t) : '');
          return FieldEntry(
            def: def,
            value: value,
            isAuto: def.isAuto && !isOverridden,
            isOverridden: isOverridden,
          );
        }(),
    ];
  }

  void setValue(int noteId, int fieldId, String value) {
    _d.execute(
      'INSERT INTO note_fields (note_id, field_id, value) VALUES (?,?,?) '
      'ON CONFLICT(note_id, field_id) DO UPDATE SET value = excluded.value',
      <Object?>[noteId, fieldId, value],
    );
  }

  /// 清除手动值，让它退回自动计算。
  void clearValue(int noteId, int fieldId) => _d.execute(
    'DELETE FROM note_fields WHERE note_id = ? AND field_id = ?',
    <Object?>[noteId, fieldId],
  );

  /// 把尾参数拼成一行，如 `——2026年9月14日18:43`。
  ///
  /// 只有 [FieldDef.isDash] 的参与拼接；其余尾参数各自成块。
  /// 前缀破折号是尾行的固定样式，不占用参数本身。
  static String composeDashedTail(List<FieldEntry> tail) {
    final dashes = tail.where((e) => e.def.isDash).toList();
    if (dashes.isEmpty) return '';
    final body = dashes
        .map((e) => e.isEmpty ? '' : '${e.value}${e.def.unit}')
        .join();
    if (body.isEmpty) return '';
    return '——$body';
  }

  // ── 统计 ────────────────────────────────────────────────────────────────

  /// 某个参数在各篇笔记上的取值分布（文本型用）。
  ///
  /// 自动参数算出来的值也计入 —— 所以「年」这种参数能直接统计出
  /// 每年写了多少篇。
  List<({String value, int count})> valueDistribution(
    int fieldId, {
    bool hiddenOnly = false,
  }) {
    final def = all().where((f) => f.id == fieldId).firstOrNull;
    if (def == null) return const <({String value, int count})>[];

    final counts = <String, int>{};
    final hideFlag = hiddenOnly ? 1 : 0;

    // 手动值
    final rows = _d.select(
      'SELECT nf.value, COUNT(*) AS cnt FROM note_fields nf '
      'JOIN notes n ON n.id = nf.note_id AND n.is_hidden = $hideFlag '
      'WHERE nf.field_id = ? GROUP BY nf.value',
      <Object?>[fieldId],
    );
    for (final r in rows) {
      final v = (r['value'] as String?) ?? '';
      if (v.trim().isEmpty) continue;
      counts[v] = (counts[v] ?? 0) + (r['cnt'] as int);
    }

    // 自动值：对没手写过的笔记现算
    if (def.isAuto) {
      final notes = _d.select(
        'SELECT id, created_at, updated_at FROM notes '
        'WHERE is_hidden = $hideFlag AND is_archived = 0 '
        'AND id NOT IN (SELECT note_id FROM note_fields WHERE field_id = ?)',
        <Object?>[fieldId],
      );
      for (final r in notes) {
        final t = DateTime.fromMillisecondsSinceEpoch(
          (def.autoSource == 'created' ? r['created_at'] : r['updated_at']) as int,
        );
        final v = autoValue(def, t);
        counts[v] = (counts[v] ?? 0) + 1;
      }
    }

    final list = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return list.map((e) => (value: e.key, count: e.value)).toList();
  }

  /// 数值型参数的总和 / 均值，用于「所有参数都可以被统计计算」。
  List<({FieldDef def, double sum, double avg, int count})> numericSummary({
    bool hiddenOnly = false,
  }) {
    final out = <({FieldDef def, double sum, double avg, int count})>[];

    for (final def in all().where((f) => f.isNumber)) {
      var sum = 0.0;
      var count = 0;

      for (final row in valueDistribution(def.id, hiddenOnly: hiddenOnly)) {
        final v = double.tryParse(row.value);
        if (v == null) continue;
        sum += v * row.count;
        count += row.count;
      }
      if (count == 0) continue;
      out.add((def: def, sum: sum, avg: sum / count, count: count));
    }
    return out;
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
