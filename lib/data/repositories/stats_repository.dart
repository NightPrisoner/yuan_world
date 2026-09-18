/// 统计与可视化专用的查询层。
///
/// 三条贯穿始终的规则：
///   1. **隐私空间与普通空间数据隔离**：普通统计带 `is_hidden = 0`，
///      进了隐私空间则换成 `is_hidden = 1`（由 [StatsQuery.hiddenOnly] 控制）。
///      藏起来就是不想看到痕迹，包括数字。
///   2. 活跃度类统计基于**笔记发布时间**而不是打开事件 ——
///      导入的历史文章没有打开记录，用事件统计会得到一片空白。
///   3. 所有查询接受一个 [StatsQuery]，统一承载时间范围与文件夹筛选，
///      免得每个方法都摊开一堆参数。
library;

import 'package:sqlite3/sqlite3.dart';

import '../db/app_database.dart';
import 'note_repository.dart' show Overview;

/// 聚合粒度。
enum StatsGranularity {
  day('按天', '%Y-%m-%d'),
  week('按周', '%Y-W%W'),
  month('按月', '%Y-%m'),
  year('按年', '%Y');

  const StatsGranularity(this.label, this.sqlFormat);
  final String label;
  final String sqlFormat;
}

/// 时间范围预设。`custom` 表示用用户手选的起止日期。
enum StatsRange {
  m3('近 3 个月', 3),
  m6('近 6 个月', 6),
  y1('近一年', 12),
  y3('近三年', 36),
  all('全部', 0),
  custom('自定义', -1);

  const StatsRange(this.label, this.months);
  final String label;

  /// > 0：往前推的月数；0：不限；-1：自定义
  final int months;

  DateTime? since(DateTime now) {
    if (months <= 0) return null;
    return DateTime(now.year, now.month - months + 1, 1);
  }
}

/// 一次统计查询的筛选条件。
class StatsQuery {
  const StatsQuery({
    this.from,
    this.to,
    this.collectionId,
    this.collectionIds = const <int>[],
    this.includeDescendants = true,
    this.hiddenOnly = false,
  });

  /// 起始（含）。null = 不限。
  final DateTime? from;

  /// 结束（含）。null = 不限。
  final DateTime? to;

  /// 只看某个文件夹；null = 全部。
  final int? collectionId;

  /// 只看**这几个**文件夹。非空时优先于 [collectionId]。
  ///
  /// 多选是为了让"文件夹之间比较"这件事成立 —— 选了三个文件夹，
  /// 趋势图就该画出三条线，而不是把它们并成一条。
  final List<int> collectionIds;

  /// 是否连同子文件夹一起统计。默认带上，
  /// 因为"这个分类下的数据"通常包含它的子分类。
  final bool includeDescendants;

  /// 是否只统计隐私空间里的内容。
  ///
  /// 普通空间排除隐藏项；进了隐私空间必须反过来 ——
  /// 否则统计会因为"排除隐藏"而变成一片空白。
  final bool hiddenOnly;

  bool get hasRange => from != null || to != null;

  StatsQuery copyWith({
    DateTime? from,
    DateTime? to,
    bool clearFrom = false,
    bool clearTo = false,
    int? collectionId,
    List<int>? collectionIds,
    bool clearCollection = false,
    bool? includeDescendants,
    bool? hiddenOnly,
  }) => StatsQuery(
    from: clearFrom ? null : (from ?? this.from),
    to: clearTo ? null : (to ?? this.to),
    collectionId: clearCollection ? null : (collectionId ?? this.collectionId),
    collectionIds: collectionIds ?? this.collectionIds,
    includeDescendants: includeDescendants ?? this.includeDescendants,
    hiddenOnly: hiddenOnly ?? this.hiddenOnly,
  );

  static const StatsQuery empty = StatsQuery();
}

class TrendPoint {
  const TrendPoint({
    required this.bucket,
    required this.label,
    required this.notes,
    required this.chars,
    required this.words,
    required this.images,
  });

  final String bucket;
  final String label;
  final int notes;
  final int chars;
  final int words;
  final int images;

  int valueOf(TrendMetric m) => switch (m) {
    TrendMetric.notes => notes,
    TrendMetric.chars => chars,
    TrendMetric.words => words,
    TrendMetric.images => images,
  };
}

enum TrendMetric {
  chars('字数'),
  notes('篇数'),
  words('词数'),
  images('图片');

  const TrendMetric(this.label);
  final String label;
}

enum TrendStyle {
  bar('柱状图'),
  line('折线图'),
  area('面积图');

  const TrendStyle(this.label);
  final String label;
}

class CumulativePoint {
  const CumulativePoint(this.label, this.notes, this.chars);
  final String label;
  final int notes;
  final int chars;
}

class ShareItem {
  const ShareItem({
    required this.name,
    required this.color,
    required this.value,
    required this.extra,
  });

  final String name;
  final int color;
  final int value;

  /// 附加数值（字数），图例第二列用。
  final int extra;
}

enum ShareStyle {
  donut('环形图'),
  pie('饼图'),
  bar('条形图');

  const ShareStyle(this.label);
  final String label;
}

class LengthBucket {
  const LengthBucket(this.label, this.count, this.min, this.max);
  final String label;
  final int count;
  final int min;
  final int max;
}

/// 篇幅分档的粗细。
///
/// 默认那套分档对"几千字一篇"的语料合适，但对每天几百字的日记来说，
/// 前四档全挤在 0 上、最后一档一根冲天柱 —— 分档得能换。
enum LengthScale {
  coarse('粗', <(String, int, int)>[
    ('< 2000', 0, 2000),
    ('2000–1万', 2000, 10000),
    ('1万–3万', 10000, 30000),
    ('≥ 3万', 30000, 1 << 30),
  ]),
  normal('标准', <(String, int, int)>[
    ('< 500 字', 0, 500),
    ('500–2000', 500, 2000),
    ('2000–5000', 2000, 5000),
    ('5000–1万', 5000, 10000),
    ('1万–2万', 10000, 20000),
    ('≥ 2万', 20000, 1 << 30),
  ]),
  fine('细', <(String, int, int)>[
    ('< 300', 0, 300),
    ('300–800', 300, 800),
    ('800–1500', 800, 1500),
    ('1500–3000', 1500, 3000),
    ('3000–6000', 3000, 6000),
    ('6000–1万', 6000, 10000),
    ('1万–2万', 10000, 20000),
    ('2万–5万', 20000, 50000),
    ('≥ 5万', 50000, 1 << 30),
  ]);

  const LengthScale(this.label, this.bands);
  final String label;

  /// (标签, 下限含, 上限不含)
  final List<(String, int, int)> bands;
}

class StreakInfo {
  const StreakInfo({
    required this.current,
    required this.longest,
    required this.activeDays,
    required this.totalDays,
    required this.lastDate,
  });

  final int current;
  final int longest;
  final int activeDays;
  final int totalDays;
  final DateTime? lastDate;

  double get density => totalDays == 0 ? 0 : activeDays / totalDays;
}

class KeywordStat {
  const KeywordStat(this.word, this.count);
  final String word;
  final int count;
}

/// 文件夹之间的横向对比。
class CollectionComparison {
  const CollectionComparison({
    required this.id,
    required this.name,
    required this.color,
    required this.notes,
    required this.chars,
    required this.images,
    required this.lastAt,
  });

  final int id;
  final String name;
  final int color;
  final int notes;
  final int chars;
  final int images;
  final DateTime? lastAt;

  int get avgChars => notes == 0 ? 0 : chars ~/ notes;
}

class StatsRepository {
  StatsRepository(this.db);

  final AppDatabase db;

  Database get _d => db.db;

  /// 笔记的「活动时间」：优先原文发布时间，否则本地创建时间。
  String _ts(String a) => 'IFNULL($a.published_at, $a.created_at)';

  /// 拼出统一的 WHERE 子句。
  String _where(StatsQuery q, {String alias = 'notes'}) {
    final parts = <String>[
      '$alias.is_archived = 0',
      // 回收站里的内容不参与统计 —— 它已经被"删掉"了
      '$alias.deleted_at IS NULL',
      // 普通空间排除隐藏项；隐私空间里反过来只看隐藏项
      q.hiddenOnly ? '$alias.is_hidden = 1' : '$alias.is_hidden = 0',
    ];

    // 多选优先：选了三个文件夹，聚合统计的口径就是这三个（含各自子文件夹）
    if (q.collectionIds.isNotEmpty) {
      final all = <int>{};
      for (final id in q.collectionIds) {
        all.add(id);
        if (q.includeDescendants) all.addAll(_descendants(id));
      }
      parts.add('$alias.collection_id IN (${all.join(',')})');
    } else if (q.collectionId != null) {
      final ids = q.includeDescendants
          ? <int>[q.collectionId!, ..._descendants(q.collectionId!)]
          : <int>[q.collectionId!];
      parts.add('$alias.collection_id IN (${ids.join(',')})');
    }

    if (q.from != null) {
      parts.add('${_ts(alias)} >= ${q.from!.millisecondsSinceEpoch}');
    }
    if (q.to != null) {
      // 结束日期按"当天结束"算：用户选 3 月 10 日，期望包含 3 月 10 日全天
      final end = DateTime(q.to!.year, q.to!.month, q.to!.day + 1);
      parts.add('${_ts(alias)} < ${end.millisecondsSinceEpoch}');
    }

    return parts.join(' AND ');
  }

  List<int> _descendants(int id) {
    final rows = _d.select('SELECT id, parent_id FROM collections');
    final byParent = <int, List<int>>{};
    for (final r in rows) {
      final p = r['parent_id'] as int?;
      if (p != null) (byParent[p] ??= <int>[]).add(r['id'] as int);
    }
    final out = <int>[];
    void walk(int pid) {
      for (final child in byParent[pid] ?? const <int>[]) {
        if (out.contains(child)) continue;
        out.add(child);
        walk(child);
      }
    }

    walk(id);
    return out;
  }

  // ── 趋势 ────────────────────────────────────────────────────────────────

  List<TrendPoint> trend({
    StatsQuery query = StatsQuery.empty,
    StatsGranularity granularity = StatsGranularity.month,
  }) {
    final rows = _d.select('''
      SELECT strftime('${granularity.sqlFormat}', ${_ts('n')} / 1000,
                      'unixepoch', 'localtime') AS bucket,
             COUNT(*) AS cnt,
             IFNULL(SUM(n.char_count), 0) AS chars,
             IFNULL(SUM(n.word_count), 0) AS words,
             IFNULL(SUM(n.image_count), 0) AS images
      FROM notes n
      WHERE ${_where(query, alias: 'n')}
      GROUP BY bucket
      ORDER BY bucket ASC
    ''');

    final raw = <String, TrendPoint>{};
    for (final r in rows) {
      final b = r['bucket'] as String?;
      if (b == null) continue;
      raw[b] = TrendPoint(
        bucket: b,
        label: _labelFor(b, granularity),
        notes: r['cnt'] as int,
        chars: r['chars'] as int,
        words: r['words'] as int,
        images: r['images'] as int,
      );
    }

    return _padBuckets(raw, granularity, query.from, query.to);
  }

  List<TrendPoint> _padBuckets(
    Map<String, TrendPoint> raw,
    StatsGranularity granularity,
    DateTime? since,
    DateTime? until,
  ) {
    // **范围内一条数据都没有时也要补齐**。
    //
    // 之前这里直接 return 空列表，后果是：某个文集在选定区间里没有笔记
    // （比如 2025 年之后就停更了），它那条线**整个消失**，
    // 而不是显示成一条贴着 0 的直线 —— 用户会以为这个文集被漏掉了。
    //
    // 只有当既没数据、又不知道区间起点时才真的没什么可画。
    if (raw.isEmpty && since == null) return const <TrendPoint>[];

    final keys = _bucketKeysBetween(
      since ?? _parseBucketKey(raw.keys.first, granularity),
      // 终点跟着**数据**走，而不是 DateTime.now()。
      // 一律补到今天的话，2014 年就停更的文集会拖出十几年空线。
      until ?? _parseBucketKey(raw.keys.last, granularity),
      granularity,
    );

    return <TrendPoint>[
      for (final k in keys)
        raw[k] ??
            TrendPoint(
              bucket: k,
              label: _labelFor(k, granularity),
              notes: 0,
              chars: 0,
              words: 0,
              images: 0,
            ),
    ];
  }

  List<String> _bucketKeysBetween(DateTime from, DateTime to, StatsGranularity g) {
    final maxPoints = switch (g) {
      StatsGranularity.day => 400,
      StatsGranularity.week => 260,
      _ => 400,
    };

    final out = <String>[];
    var cursor = _truncate(from, g);
    final end = _truncate(to, g);

    while (!cursor.isAfter(end) && out.length < maxPoints) {
      out.add(_keyOf(cursor, g));
      cursor = switch (g) {
        StatsGranularity.day => cursor.add(const Duration(days: 1)),
        StatsGranularity.week => cursor.add(const Duration(days: 7)),
        StatsGranularity.month => DateTime(cursor.year, cursor.month + 1, 1),
        StatsGranularity.year => DateTime(cursor.year + 1, 1, 1),
      };
    }
    return out;
  }

  DateTime _truncate(DateTime d, StatsGranularity g) => switch (g) {
    StatsGranularity.day => DateTime(d.year, d.month, d.day),
    StatsGranularity.week =>
      DateTime(d.year, d.month, d.day).subtract(Duration(days: d.weekday - 1)),
    StatsGranularity.month => DateTime(d.year, d.month, 1),
    StatsGranularity.year => DateTime(d.year, 1, 1),
  };

  String _keyOf(DateTime d, StatsGranularity g) {
    String two(int v) => v.toString().padLeft(2, '0');
    return switch (g) {
      StatsGranularity.day => '${d.year}-${two(d.month)}-${two(d.day)}',
      StatsGranularity.week => '${d.year}-W${two(_isoWeek(d))}',
      StatsGranularity.month => '${d.year}-${two(d.month)}',
      StatsGranularity.year => '${d.year}',
    };
  }

  DateTime _parseBucketKey(String key, StatsGranularity g) {
    try {
      switch (g) {
        case StatsGranularity.day:
          final p = key.split('-');
          return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
        case StatsGranularity.month:
          final p = key.split('-');
          return DateTime(int.parse(p[0]), int.parse(p[1]), 1);
        case StatsGranularity.year:
          return DateTime(int.parse(key), 1, 1);
        case StatsGranularity.week:
          final p = key.split('-W');
          return DateTime(int.parse(p[0]), 1, 1);
      }
    } catch (_) {
      return DateTime.now();
    }
  }

  static int _isoWeek(DateTime d) {
    final dayOfYear = d.difference(DateTime(d.year, 1, 1)).inDays + 1;
    return ((dayOfYear - d.weekday + 10) / 7).floor();
  }

  String _labelFor(String bucket, StatsGranularity g) {
    switch (g) {
      case StatsGranularity.month:
        final p = bucket.split('-');
        if (p.length < 2) return bucket;
        final now = DateTime.now();
        final y = int.tryParse(p[0]) ?? now.year;
        final m = int.tryParse(p[1]) ?? 1;
        return y == now.year ? '$m月' : '${y % 100}年$m月';
      case StatsGranularity.day:
        final p = bucket.split('-');
        return p.length >= 3 ? '${int.parse(p[1])}/${int.parse(p[2])}' : bucket;
      case StatsGranularity.week:
        final p = bucket.split('-W');
        return p.length >= 2 ? '${int.parse(p[1])}周' : bucket;
      case StatsGranularity.year:
        return '$bucket年';
    }
  }

  List<CumulativePoint> cumulative({
    StatsQuery query = StatsQuery.empty,
    StatsGranularity granularity = StatsGranularity.month,
  }) {
    final points = trend(query: query, granularity: granularity);
    var notes = 0;
    var chars = 0;
    final out = <CumulativePoint>[];
    for (final p in points) {
      notes += p.notes;
      chars += p.chars;
      out.add(CumulativePoint(p.label, notes, chars));
    }
    return out;
  }

  // ── 分布类 ──────────────────────────────────────────────────────────────

  List<ShareItem> collectionShare({StatsQuery query = StatsQuery.empty}) {
    final rows = _d.select('''
      SELECT IFNULL(c.name, '未分类') AS name,
             IFNULL(c.color, 0xFF94A3B8) AS color,
             COUNT(n.id) AS cnt,
             IFNULL(SUM(n.char_count), 0) AS chars
      FROM notes n LEFT JOIN collections c ON c.id = n.collection_id
      WHERE ${_where(query, alias: 'n')}
      GROUP BY c.id
      ORDER BY cnt DESC
    ''');
    return rows
        .map((r) => ShareItem(
              name: r['name'] as String,
              color: r['color'] as int,
              value: r['cnt'] as int,
              extra: r['chars'] as int,
            ))
        .toList();
  }

  List<LengthBucket> lengthDistribution({
    StatsQuery query = StatsQuery.empty,
    LengthScale scale = LengthScale.normal,
  }) {
    final rows = _d
        .select('SELECT n.char_count FROM notes n WHERE ${_where(query, alias: 'n')}')
        .map((r) => (r['char_count'] as int?) ?? 0)
        .toList();

    return <LengthBucket>[
      for (final (label, min, max) in scale.bands)
        LengthBucket(
          label,
          rows.where((c) => c >= min && c < max).length,
          min,
          max,
        ),
    ];
  }

  List<int> hourlyDistribution({StatsQuery query = StatsQuery.empty}) {
    final out = List<int>.filled(24, 0);
    final rows = _d.select('''
      SELECT CAST(strftime('%H', ${_ts('n')} / 1000, 'unixepoch', 'localtime') AS INTEGER) AS h,
             COUNT(*) AS cnt
      FROM notes n WHERE ${_where(query, alias: 'n')}
      GROUP BY h
    ''');
    for (final r in rows) {
      final h = r['h'] as int?;
      if (h != null && h >= 0 && h < 24) out[h] = r['cnt'] as int;
    }
    return out;
  }

  List<int> weekdayDistribution({StatsQuery query = StatsQuery.empty}) {
    final out = List<int>.filled(7, 0);
    final rows = _d.select('''
      SELECT CAST(strftime('%w', ${_ts('n')} / 1000, 'unixepoch', 'localtime') AS INTEGER) AS w,
             COUNT(*) AS cnt
      FROM notes n WHERE ${_where(query, alias: 'n')}
      GROUP BY w
    ''');
    for (final r in rows) {
      final w = r['w'] as int?; // 0=周日
      if (w == null) continue;
      out[(w + 6) % 7] = r['cnt'] as int;
    }
    return out;
  }

  Map<String, int> dailyDensity({StatsQuery query = StatsQuery.empty}) {
    final rows = _d.select('''
      SELECT strftime('%Y-%m-%d', ${_ts('n')} / 1000, 'unixepoch', 'localtime') AS day,
             COUNT(*) AS cnt
      FROM notes n WHERE ${_where(query, alias: 'n')}
      GROUP BY day
    ''');
    return <String, int>{
      for (final r in rows)
        if (r['day'] != null) r['day'] as String: r['cnt'] as int,
    };
  }

  StreakInfo streak({StatsQuery query = StatsQuery.empty}) {
    final rows = _d.select('''
      SELECT DISTINCT strftime('%Y-%m-%d', ${_ts('n')} / 1000, 'unixepoch', 'localtime') AS day
      FROM notes n WHERE ${_where(query, alias: 'n')}
      ORDER BY day ASC
    ''');

    final days = <DateTime>[];
    for (final r in rows) {
      final s = r['day'] as String?;
      if (s == null) continue;
      final p = s.split('-');
      if (p.length < 3) continue;
      days.add(DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2])));
    }
    if (days.isEmpty) {
      return const StreakInfo(
        current: 0,
        longest: 0,
        activeDays: 0,
        totalDays: 0,
        lastDate: null,
      );
    }

    var longest = 1;
    var run = 1;
    for (var i = 1; i < days.length; i++) {
      run = days[i].difference(days[i - 1]).inDays == 1 ? run + 1 : 1;
      if (run > longest) longest = run;
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final last = days.last;
    var current = 0;
    if (today.difference(last).inDays <= 1) {
      current = 1;
      for (var i = days.length - 1; i > 0; i--) {
        if (days[i].difference(days[i - 1]).inDays == 1) {
          current++;
        } else {
          break;
        }
      }
    }

    final span = last.difference(days.first).inDays + 1;
    return StreakInfo(
      current: current,
      longest: longest,
      activeDays: days.length,
      totalDays: span,
      lastDate: last,
    );
  }

  // ── 排行 / 对比 / 词频 ──────────────────────────────────────────────────

  List<({int id, String title, int chars, int? color})> topByLength({
    StatsQuery query = StatsQuery.empty,
    int limit = 10,
  }) {
    final rows = _d.select('''
      SELECT n.id, n.title, n.char_count, c.color AS color
      FROM notes n LEFT JOIN collections c ON c.id = n.collection_id
      WHERE ${_where(query, alias: 'n')}
      ORDER BY n.char_count DESC
      LIMIT ?
    ''', <Object?>[limit]);
    return rows
        .map((r) => (
              id: r['id'] as int,
              title: (r['title'] as String?) ?? '',
              chars: (r['char_count'] as int?) ?? 0,
              color: r['color'] as int?,
            ))
        .toList();
  }

  /// 文件夹之间的横向对比。
  ///
  /// 只比较**顶层**文件夹，并把子文件夹的数据累加进去 ——
  /// 否则一个用来分组的父文件夹永远是 0，对比毫无意义。
  /// 概览。**跟着筛选走** ——
  ///
  /// 以前这里读的是全库总数：勾了两个文件夹、时间范围换成"近一年"，
  /// 概览还写着 76 篇 / 全部字数，和下面每一张卡片都对不上。
  /// 一个页面里两套口径，用户只会得出"筛选坏了"这一个结论。
  ///
  /// 文集数和标签数也按同一口径收窄：选了文件夹就数选中的那几个（含子文件夹），
  /// 标签只数这些笔记真正用到的。
  Overview overview({StatsQuery query = StatsQuery.empty}) {
    final r = _d.select('''
      SELECT COUNT(*) AS note_count,
             IFNULL(SUM(n.char_count), 0) AS total_chars,
             IFNULL(SUM(n.word_count), 0) AS total_words,
             IFNULL(SUM(n.image_count), 0) AS image_count,
             IFNULL(SUM(CASE WHEN n.is_favorite = 1 THEN 1 ELSE 0 END), 0) AS favorite_count,
             MIN(${_ts('n')}) AS first_at,
             MAX(${_ts('n')}) AS last_at
      FROM notes n WHERE ${_where(query, alias: 'n')}
    ''').first;

    final hideFlag = query.hiddenOnly ? 1 : 0;

    // 文集数：选了文件夹就数这几个（含后代），否则数库里所有可见文集
    var collectionCount = 0;
    if (query.collectionIds.isNotEmpty) {
      final all = <int>{};
      for (final id in query.collectionIds) {
        all.add(id);
        if (query.includeDescendants) all.addAll(_descendants(id));
      }
      collectionCount =
          _d.select(
                'SELECT COUNT(*) AS c FROM collections '
                'WHERE id IN (${all.join(',')}) AND is_hidden = $hideFlag '
                'AND deleted_at IS NULL',
              ).first['c']
              as int;
    } else {
      collectionCount =
          _d.select(
                'SELECT COUNT(*) AS c FROM collections '
                'WHERE is_hidden = $hideFlag AND deleted_at IS NULL',
              ).first['c']
              as int;
    }

    final tagCount =
        _d.select('''
          SELECT COUNT(DISTINCT nt.tag_id) AS c
          FROM note_tags nt JOIN notes n ON n.id = nt.note_id
          WHERE ${_where(query, alias: 'n')}
        ''').first['c']
            as int;

    DateTime? dt(Object? v) =>
        v == null ? null : DateTime.fromMillisecondsSinceEpoch(v as int);

    return Overview(
      noteCount: r['note_count'] as int,
      totalChars: r['total_chars'] as int,
      totalWords: r['total_words'] as int,
      imageCount: r['image_count'] as int,
      collectionCount: collectionCount,
      tagCount: tagCount,
      favoriteCount: r['favorite_count'] as int,
      firstAt: dt(r['first_at']),
      lastAt: dt(r['last_at']),
    );
  }

  List<CollectionComparison> compareCollections({StatsQuery query = StatsQuery.empty}) {
    final hideFlag = query.hiddenOnly ? 1 : 0;

    // **时间范围也得跟着走**。以前这块只认隐私空间，旁边所有卡片都变成
    // "近一年"了，它还照算全部 —— 数字对不上，看着就是坏的。
    final range = <String>[];
    if (query.from != null) {
      range.add('${_ts('n')} >= ${query.from!.millisecondsSinceEpoch}');
    }
    if (query.to != null) {
      final end = DateTime(query.to!.year, query.to!.month, query.to!.day + 1);
      range.add('${_ts('n')} < ${end.millisecondsSinceEpoch}');
    }
    final rangeSql = range.isEmpty ? '' : ' AND ${range.join(' AND ')}';

    // 比谁：选了文件夹就逐个比这几个，没选才比全部顶级文件夹。
    // 不这么切的话，用户在别处筛选了半天，只有这块还在列全库，
    // 一眼看上去就是"筛选没生效"。
    final targets = <({int id, String name, int color})>[];
    if (query.collectionIds.isNotEmpty) {
      for (final id in query.collectionIds) {
        final r = _d.select(
          'SELECT id, name, color FROM collections '
          'WHERE id = ? AND is_hidden = $hideFlag AND deleted_at IS NULL',
          <Object?>[id],
        );
        if (r.isEmpty) continue;
        targets.add((
          id: id,
          name: r.first['name'] as String,
          color: r.first['color'] as int,
        ));
      }
    } else {
      final tops = _d.select(
        'SELECT id, name, color FROM collections '
        'WHERE is_hidden = $hideFlag AND deleted_at IS NULL AND parent_id IS NULL '
        'ORDER BY sort_order ASC, name ASC',
      );
      for (final t in tops) {
        targets.add((
          id: t['id'] as int,
          name: t['name'] as String,
          color: t['color'] as int,
        ));
      }
    }

    final out = <CollectionComparison>[];
    for (final t in targets) {
      final ids = <int>[t.id, ..._descendants(t.id)];
      final r = _d.select('''
        SELECT COUNT(*) AS cnt,
               IFNULL(SUM(n.char_count), 0) AS chars,
               IFNULL(SUM(n.image_count), 0) AS images,
               MAX(${_ts('n')}) AS last_at
        FROM notes n
        WHERE n.is_archived = 0 AND n.deleted_at IS NULL AND n.is_hidden = $hideFlag
          AND n.collection_id IN (${ids.join(',')})$rangeSql
      ''').first;

      out.add(CollectionComparison(
        id: t.id,
        name: t.name,
        color: t.color,
        notes: r['cnt'] as int,
        chars: r['chars'] as int,
        images: r['images'] as int,
        lastAt: r['last_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(r['last_at'] as int),
      ));
    }

    // 未分类也算一个可比对象，否则总数对不上会让人困惑。
    // 但用户明确勾了文件夹时就不掺进来了 —— 那不在他要看的范围里。
    if (query.collectionIds.isEmpty) {
      final orphan = _d.select('''
        SELECT COUNT(*) AS cnt,
               IFNULL(SUM(char_count), 0) AS chars,
               IFNULL(SUM(image_count), 0) AS images,
               MAX(${_ts('n')}) AS last_at
        FROM notes n
        WHERE n.is_archived = 0 AND n.deleted_at IS NULL AND n.is_hidden = $hideFlag
          AND n.collection_id IS NULL$rangeSql
      ''').first;
      if ((orphan['cnt'] as int) > 0) {
        out.add(CollectionComparison(
          id: -1,
          name: '未分类',
          color: 0xFF94A3B8,
          notes: orphan['cnt'] as int,
          chars: orphan['chars'] as int,
          images: orphan['images'] as int,
          lastAt: orphan['last_at'] == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(orphan['last_at'] as int),
        ));
      }
    }

    out.sort((a, b) => b.notes.compareTo(a.notes));
    return out;
  }

  List<({String name, int count, int color})> tagFrequency({
    StatsQuery query = StatsQuery.empty,
    int limit = 40,
  }) {
    final rows = _d.select('''
      SELECT t.name, t.color, COUNT(nt.note_id) AS cnt
      FROM tags t
      JOIN note_tags nt ON nt.tag_id = t.id
      JOIN notes n ON n.id = nt.note_id
      WHERE ${_where(query, alias: 'n')}
      GROUP BY t.id HAVING cnt > 0
      ORDER BY cnt DESC, t.name ASC
      LIMIT ?
    ''', <Object?>[limit]);
    return rows
        .map((r) => (
              name: r['name'] as String,
              count: r['cnt'] as int,
              color: r['color'] as int,
            ))
        .toList();
  }

  List<KeywordStat> keywords({
    StatsQuery query = StatsQuery.empty,
    int limit = 24,
    int minCount = 3,
  }) {
    final rows = _d.select(
      'SELECT n.title, n.excerpt FROM notes n WHERE ${_where(query, alias: 'n')}',
    );

    final counts = <String, int>{};
    final cjkRun = RegExp(r'[\u4e00-\u9fff]{2,}');

    for (final r in rows) {
      final text = '${r['title'] ?? ''} ${r['excerpt'] ?? ''}';
      for (final m in cjkRun.allMatches(text)) {
        final s = m.group(0)!;
        for (var i = 0; i + 2 <= s.length; i++) {
          final g = s.substring(i, i + 2);
          if (_stopwords.contains(g)) continue;
          counts[g] = (counts[g] ?? 0) + 1;
        }
      }
    }

    final list = counts.entries.where((e) => e.value >= minCount).toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return list.take(limit).map((e) => KeywordStat(e.key, e.value)).toList();
  }

  /// 哪些年份/月份有数据，用于自定义日期选择器给出可点的范围。
  ///
  /// 传 [query] 就只看那部分笔记 —— 图表的**默认时间范围**要跟着
  /// 所选内容走：一个只有 2014 年笔记的文件夹，时间线就该是 2014 那一段，
  /// 而不是一路延伸到今天、拖出一条什么都没有的长尾巴。
  ({DateTime? first, DateTime? last}) dataSpan({StatsQuery? query}) {
    final r = _d.select('''
      SELECT MIN(${_ts('n')}) AS a, MAX(${_ts('n')}) AS b
      FROM notes n WHERE ${_where(query ?? StatsQuery.empty, alias: 'n')}
    ''').first;
    DateTime? dt(Object? v) =>
        v == null ? null : DateTime.fromMillisecondsSinceEpoch(v as int);
    return (first: dt(r['a']), last: dt(r['b']));
  }

  static const Set<String> _stopwords = <String>{
    '的时', '时候', '一个', '什么', '这个', '那个', '可以', '就是', '没有',
    '自己', '因为', '所以', '但是', '如果', '还是', '这样', '那样', '已经',
    '他们', '我们', '你们', '这些', '那些', '不是', '只是', '而且', '然后',
    '一次', '一样', '一直', '真的', '可能', '应该', '觉得', '知道', '看到',
    '起来', '出来', '过来', '下来', '一些', '有点', '很多', '非常', '比较',
    '以及', '或者', '虽然', '不过', '于是', '其实', '感觉', '东西', '事情',
    '问题', '方式', '方面', '情况', '之后', '之前', '当时', '现在', '以后',
    '一种', '这里', '那里', '为了', '对于', '关于', '通过', '进行', '成为',
    '一定', '不断', '越来越', '在于', '让我', '我的', '你的', '他的', '她的',
  };
}
