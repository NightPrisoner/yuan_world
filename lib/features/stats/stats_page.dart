/// 数据统计页。
///
/// 设计取向：**模块化 + 可配置**。
///   - 每个模块是一个独立的卡片，可以单独隐藏/恢复
///   - 图表能换画法（柱状/折线/面积、环形/饼图/条形）
///   - 全局时间范围一处改，所有图跟着变
///
/// 用户的偏好写进 settings 表，下次打开还是他自己那套。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../core/motion/app_motion.dart';
import '../../core/motion/apple_page_route.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_menu.dart';
import '../../core/widgets/app_refresh.dart';
import '../../data/db/app_database.dart';
import '../../data/media/media_importer.dart';
import '../../data/models.dart';
import '../../data/repositories/note_repository.dart' hide TrendPoint;
import '../../data/repositories/stats_repository.dart';
import '../notes/note_detail_page.dart';
import 'field_stats_card.dart';
import 'range_picker.dart';
import 'stats_charts.dart';

// ── 模块清单 ──────────────────────────────────────────────────────────────

class _ModuleSpec {
  const _ModuleSpec(this.id, this.title, this.subtitle, this.icon);
  final String id;
  final String title;
  final String subtitle;
  final IconData icon;
}

/// 全部可用模块。顺序即页面顺序。
/// 磁盘上媒体的统计结果。
class MediaStats {
  const MediaStats({
    required this.images,
    required this.videos,
    required this.bytes,
  });
  final int images;
  final int videos;
  final int bytes;
}

const List<_ModuleSpec> _kModules = <_ModuleSpec>[
  _ModuleSpec('overview', '概览', '笔记数、字数、图片等总览', Icons.dashboard_rounded),
  _ModuleSpec('trend', '写作趋势', '按天/周/月看写作量变化', Icons.bar_chart_rounded),
  _ModuleSpec('cumulative', '累计增长', '总量随时间的累积曲线', Icons.show_chart_rounded),
  _ModuleSpec('share', '文集分布', '各文集占比与字数', Icons.donut_large_rounded),
  _ModuleSpec('compare', '文件夹对比', '横向比较各文件夹的产出', Icons.compare_arrows_rounded),
  _ModuleSpec('heatmap', '发布热力图', '近一年每天的发布密度', Icons.calendar_month_rounded),
  _ModuleSpec('hourly', '写作时段', '一天里的发布时段分布', Icons.schedule_rounded),
  _ModuleSpec('length', '篇幅分布', '笔记长度落在哪些区间', Icons.straighten_rounded),
  _ModuleSpec('streak', '连续写作', '坚持天数与活跃密度', Icons.local_fire_department_rounded),
  _ModuleSpec('top', '长文排行', '字数最多的笔记', Icons.format_list_numbered_rounded),
  _ModuleSpec('tags', '标签分布', '标签使用频次', Icons.sell_rounded),
  _ModuleSpec('keywords', '高频词', '内容里反复出现的词', Icons.tag_rounded),
  _ModuleSpec('fields', '参数统计', '头参数 / 尾参数的取值分布', Icons.playlist_add_rounded),
  _ModuleSpec('storage', '存储与数据', '笔记、字数、图片视频与磁盘占用', Icons.storage_rounded),
];

/// 一次拖拽之后，新的完整模块顺序。
///
/// 抽成纯函数是为了能直接测：拖拽手势在 widget test 里很难稳定复现，
/// 但排序逻辑本身必须被钉死。
///
/// 规则：**只重排可见模块**，被隐藏的模块留在原来的槽位上 ——
/// 否则用户拖动几个模块，暗处那些模块的位置也会莫名其妙地变。
List<String> applyModuleReorder({
  required List<String> full,
  required List<String> visible,
  required int oldIndex,
  required int newIndex,
}) {
  if (oldIndex < 0 || oldIndex >= visible.length) return full;
  if (newIndex < 0 || newIndex > visible.length) return full;
  if (newIndex == oldIndex) return full;

  final moved = visible[oldIndex];
  final newVisible = List<String>.from(visible)..removeAt(oldIndex);
  newVisible.insert(newIndex.clamp(0, newVisible.length), moved);

  final slots = <int>[];
  for (var i = 0; i < full.length; i++) {
    if (visible.contains(full[i])) slots.add(i);
  }

  final out = List<String>.from(full);
  for (var i = 0; i < slots.length && i < newVisible.length; i++) {
    out[slots[i]] = newVisible[i];
  }
  return out;
}

class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  // ── 用户可调的配置 ──
  StatsRange _range = StatsRange.all;
  StatsGranularity _granularity = StatsGranularity.month;
  TrendMetric _metric = TrendMetric.chars;
  TrendStyle _trendStyle = TrendStyle.bar;
  ShareStyle _shareStyle = ShareStyle.donut;
  final Set<String> _hidden = <String>{};

  /// 自定义范围（仅当 [_range] == custom 时生效）。
  DateTime? _from;
  DateTime? _to;

  /// 只统计某个文件夹；null = 全部。
  // 字段已换成 _collectionIds，见下方 getter

  /// 自定义的模块顺序（存的是 id）。为空表示用默认顺序。
  List<String> _order = <String>[];

  // 数据
  StatsRepository? _stats;
  Overview? _overview;
  List<TrendPoint> _trend = const <TrendPoint>[];
  List<CumulativePoint> _cumulative = const <CumulativePoint>[];
  List<ShareItem> _share = const <ShareItem>[];
  Map<String, int> _density = const <String, int>{};
  List<int> _hourly = const <int>[];
  List<int> _weekday = const <int>[];
  List<LengthBucket> _lengths = const <LengthBucket>[];
  List<({int id, String title, int chars, int? color})> _top = const [];
  List<({String name, int count, int color})> _tags = const [];
  List<KeywordStat> _keywords = const <KeywordStat>[];
  List<CollectionComparison> _comparisons = const <CollectionComparison>[];
  StreakInfo? _streak;
  bool _loading = true;

  int _dbBytes = 0;
  MediaStats _mediaStats = const MediaStats(images: 0, videos: 0, bytes: 0);

  /// 热力图靠这两个兜底：时间范围选"全部"时没有起止，
  /// 得拿数据本身的首尾才知道格子从哪天排到哪天。
  DateTime? _densityFrom;
  DateTime? _densityTo;

  /// 上一次见到的隐私空间状态，用于判断要不要重算。
  bool _lastPrivacy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreConfig();
      _load();
    });
  }

  // ── 配置持久化 ──────────────────────────────────────────────────────────

  void _restoreConfig() {
    final repo = context.read<AppState>().repo;
    T byName<T extends Enum>(List<T> values, String? name, T fallback) =>
        values.firstWhere((v) => v.name == name, orElse: () => fallback);

    setState(() {
      _range = byName(StatsRange.values, repo.getSetting('stats.range'), _range);
      _granularity = byName(
        StatsGranularity.values,
        repo.getSetting('stats.granularity'),
        _granularity,
      );
      _metric =
          byName(TrendMetric.values, repo.getSetting('stats.metric'), _metric);
      _trendStyle = byName(
        TrendStyle.values,
        repo.getSetting('stats.trendStyle'),
        _trendStyle,
      );
      _shareStyle = byName(
        ShareStyle.values,
        repo.getSetting('stats.shareStyle'),
        _shareStyle,
      );
      _cumMetric = byName(
        TrendMetric.values,
        repo.getSetting('stats.cumMetric'),
        _cumMetric,
      );
      _cumStyle = byName(
        TrendStyle.values,
        repo.getSetting('stats.cumStyle'),
        _cumStyle,
      );
      // 显示选项：只有明确存过 '0' 才算关，其它情况保持默认开
      bool flag(String key) => repo.getSetting(key) != '0';
      _showDots = flag('stats.showDots');
      _smooth = flag('stats.smooth');
      _showGrid = flag('stats.showGrid');
      // 倍率记着，平移位置不记（下次打开回到开头更符合预期）
      _zoom = _storedZoom(repo, 'stats.zoom');
      _lenScale = byName(
        LengthScale.values,
        repo.getSetting('stats.lenScale'),
        _lenScale,
      );
      final raw = repo.getSetting('stats.hidden');
      if (raw != null && raw.isNotEmpty) {
        try {
          _hidden
            ..clear()
            ..addAll(
              (jsonDecode(raw) as List<dynamic>).map((e) => e.toString()),
            );
        } catch (_) {
          // 存坏了就当没配置过，不要因为一个设置项打不开页面
        }
      }

      _collectionIds = (repo.getSetting('stats.collectionIds') ?? '')
        .split(',')
        .map(int.tryParse)
        .whereType<int>()
        .toList();
    if (_collectionIds.isEmpty) {
      final one = int.tryParse(repo.getSetting('stats.collectionId') ?? '');
      if (one != null) _collectionIds = <int>[one];
    }
      _from = DateTime.tryParse(repo.getSetting('stats.from') ?? '');
      _to = DateTime.tryParse(repo.getSetting('stats.to') ?? '');

      final orderRaw = repo.getSetting('stats.order');
      if (orderRaw != null && orderRaw.isNotEmpty) {
        try {
          _order = (jsonDecode(orderRaw) as List<dynamic>)
              .map((e) => e.toString())
              .toList();
        } catch (_) {
          _order = <String>[];
        }
      }
    });
  }

  void _persist() {
    final repo = context.read<AppState>().repo;
    repo.setSetting('stats.range', _range.name);
    repo.setSetting('stats.granularity', _granularity.name);
    repo.setSetting('stats.metric', _metric.name);
    repo.setSetting('stats.trendStyle', _trendStyle.name);
    repo.setSetting('stats.shareStyle', _shareStyle.name);
    repo.setSetting('stats.hidden', jsonEncode(_hidden.toList()));
    repo.setSetting('stats.collectionIds', _collectionIds.join(','));
    repo.setSetting('stats.collectionId', _collectionId?.toString() ?? '');
    repo.setSetting('stats.from', _from?.toIso8601String() ?? '');
    repo.setSetting('stats.to', _to?.toIso8601String() ?? '');
    repo.setSetting('stats.order', jsonEncode(_orderedIds()));
    repo.setSetting('stats.zoom', '$_zoom');
    repo.setSetting('stats.lenScale', _lenScale.name);
    repo.setSetting('stats.cumMetric', _cumMetric.name);
    repo.setSetting('stats.cumStyle', _cumStyle.name);
    repo.setSetting('stats.showDots', _showDots ? '1' : '0');
    repo.setSetting('stats.smooth', _smooth ? '1' : '0');
    repo.setSetting('stats.showGrid', _showGrid ? '1' : '0');
  }

  // ── 模块顺序 ────────────────────────────────────────────────────────────

  /// 把用户存的顺序与现有模块对齐。
  ///
  /// 用户存的是 id 列表，但模块会随版本增删：新模块补到末尾，
  /// 已经不存在的 id 直接丢掉。这样升级后顺序不会乱、也不会丢模块。
  List<String> _orderedIds() {
    final known = _kModules.map((m) => m.id).toSet();
    final out = <String>[];
    for (final id in _order) {
      if (known.contains(id) && !out.contains(id)) out.add(id);
    }
    for (final m in _kModules) {
      if (!out.contains(m.id)) out.add(m.id);
    }
    return out;
  }

  /// 当前实际显示的模块 id，按用户顺序。
  List<String> get _visibleModules =>
      _orderedIds().where(_show).toList();

  /// 拖拽排序。真正的排序逻辑在 [applyModuleReorder] 里，这里只负责落地。
  ///
  /// 用的是 `onReorderItem`：它给的 newIndex 已经处理过"移除后下标前移"，
  /// 不用再自己 `if (newIndex > oldIndex) newIndex -= 1`。
  void _onReorder(int oldIndex, int newIndex) {
    final next = applyModuleReorder(
      full: _orderedIds(),
      visible: _visibleModules,
      oldIndex: oldIndex,
      newIndex: newIndex,
    );
    setState(() => _order = next);
    _persist();
  }

  // ── 加载 ────────────────────────────────────────────────────────────────

  void _load() {
    final state = context.read<AppState>();
    final stats = _stats ??= StatsRepository(state.db);
    final q = _query;

    // 口径变了，缓存必须作废
    _trendSeriesCache = null;
    _cumulativeSeriesCache = null;
    _moduleCache.clear();

    setState(() {
      // 概览也走 _query：勾了文件夹就只算这几个
      _overview = stats.overview(query: q);
      // 磁盘扫描比较慢（要遍历整个图片目录），只在加载时做一次
      _mediaStats = _scanMedia();
      _dbBytes = _dbBytesOf(state.db);
      _trend = stats.trend(query: q, granularity: _granularity);
      _cumulative = stats.cumulative(query: q, granularity: _granularity);
      _share = stats.collectionShare(query: q);
      // 热力图跟着页面时间范围走，取数也就跟着走
      _density = stats.dailyDensity(query: q);
      _refreshDensitySpan(stats, q);
      _hourly = stats.hourlyDistribution(query: q);
      _weekday = stats.weekdayDistribution(query: q);
      _lengths = stats.lengthDistribution(query: q, scale: _lenScale);
      _top = stats.topByLength(query: q, limit: 10);
      _tags = stats.tagFrequency(query: q);
      _keywords = stats.keywords(query: q, limit: 26);
      _streak = stats.streak(query: q);
      _comparisons = stats.compareCollections(query: q);
      _loading = false;
    });
  }

  /// 热力图在"全部"时要靠数据的实际跨度才知道画到哪儿。
  void _refreshDensitySpan(StatsRepository stats, StatsQuery q) {
    // 范围里没写死起止时，才需要问数据本身的首尾
    if (q.from != null && q.to != null) {
      _densityFrom = null;
      _densityTo = null;
      return;
    }
    final span = stats.dataSpan(
      query: q.copyWith(clearFrom: true, clearTo: true),
    );
    _densityFrom = q.from ?? span.first;
    _densityTo = q.to ?? span.last;
  }

  /// 换筛选条件只需要重算与筛选相关的部分，
  /// 词频这种重活跟着重算一次也就几毫秒，索性一起刷新，保证图之间自洽。
  void _reload() {
    final stats = _stats;
    if (stats == null) return;
    final q = _query;
    _trendSeriesCache = null;
    _cumulativeSeriesCache = null;
    // 数据整体重算，模块缓存全作废（不清也不会错，键里都有数据实例，
    // 但清掉更省内存也更不容易想歪）
    _moduleCache.clear();
    setState(() {
      // **概览也得重算**。以前漏了这一行：图表全跟着筛选变了，
      // 只有概览还挂着上一次的数字，看着就是"筛选没生效"。
      _overview = stats.overview(query: q);
      _trend = stats.trend(query: q, granularity: _granularity);
      _cumulative = stats.cumulative(query: q, granularity: _granularity);
      _share = stats.collectionShare(query: q);
      _density = stats.dailyDensity(query: q);
      _refreshDensitySpan(stats, q);
      _hourly = stats.hourlyDistribution(query: q);
      _weekday = stats.weekdayDistribution(query: q);
      _lengths = stats.lengthDistribution(query: q, scale: _lenScale);
      _top = stats.topByLength(query: q, limit: 10);
      _tags = stats.tagFrequency(query: q);
      _keywords = stats.keywords(query: q, limit: 26);
      _streak = stats.streak(query: q);
      _comparisons = stats.compareCollections(query: q);
    });
  }

  /// 只重算篇幅分布。
  ///
  /// 换分档只影响这一个直方图，没必要把整页十来个聚合全跑一遍 ——
  /// 那是几十到几百毫秒的同步阻塞，用户看到的就是"点完卡住不动"。
  void _reloadLengths() {
    final stats = _stats;
    if (stats == null) return;
    setState(() {
      _lengths = stats.lengthDistribution(query: _query, scale: _lenScale);
    });
  }

  /// 当前生效的筛选条件。
  ///
  /// `hiddenOnly` 跟着隐私空间走：**统计也要数据隔离**，
  /// 否则进了隐私空间看到的还是外面的数字。
  StatsQuery get _query => StatsQuery(
    from: _range == StatsRange.custom
        ? _from
        : _range.since(DateTime.now()),
    to: _range == StatsRange.custom ? _to : null,
    collectionIds: _collectionIds,
    collectionId: _collectionId,
    hiddenOnly: context.read<AppState>().privacyMode,
  );

  void _setRange(StatsRange r) {
    setState(() => _range = r);
    _persist();
    _reload();
  }

  void _setGranularity(StatsGranularity g) {
    setState(() => _granularity = g);
    _persist();
    _reload();
  }

  /// 多选文件夹。空 = 全部。
  ///
  /// 选 1 个时就是原来那个单选筛选；选 2 个以上时，
  /// 趋势和累计会**一个文件夹画一条线**，用来横向比较。
  List<int> _collectionIds = <int>[];

  /// 单选的口径，给那些还不支持多序列的模块用（它们的合集就是这些文件夹）。
  int? get _collectionId =>
      _collectionIds.length == 1 ? _collectionIds.first : null;

  void _setCollection(int? id) =>
      _setCollections(id == null ? <int>[] : <int>[id]);

  void _setCollections(List<int> ids) {
    setState(() => _collectionIds = List<int>.from(ids));
    _persist();
    _reload();
  }

  /// 趋势的多序列。**带缓存** ——
  ///
  /// 这两个 getter 每次都会查库。缩放条一拖就是每帧一次重建，
  /// 不缓存的话拖一下要打好几十轮 SQL，文件夹一多直接卡住。
  /// 只在 `_load` / `_reload` 里清掉，那才是口径真的变了的时候。
  List<TrendSeries>? _trendSeriesCache;
  List<TrendSeries>? _cumulativeSeriesCache;

  List<TrendSeries> get _trendSeries =>
      _trendSeriesCache ??= _seriesFor(
        (q) => _stats!.trend(query: q, granularity: _granularity),
        (p) => p.notes,
      );

  /// 每个选区一条序列。选了 N 个文件夹就返回 N 条。
  ///
  /// 单选/不选时只有一条 —— 走的还是原来的路径，不影响原来那些图。
  /// 按当前选中的文件夹逐条取数。
  ///
  /// 抽成泛型是因为趋势和累计的取数函数签名一样、
  /// 只是返回的点类型不同 —— 写两遍容易改一处漏一处。
  List<TrendSeries> _seriesFor<T>(
    List<T> Function(StatsQuery q) fetch,
    int Function(T point) countOf,
  ) {
    final stats = _stats;
    if (stats == null) return const <TrendSeries>[];

    if (_collectionIds.isEmpty) {
      final pts = fetch(_query);
      return <TrendSeries>[
        TrendSeries(
          label: '全部',
          color: context.colors.tint,
          points: pts.map(_trendPointOf).toList(),
        ),
      ];
    }

    final all = context.read<AppState>().collections;
    // **所有序列共用同一条 X 轴**。
    //
    // 不指定起点的话，每个文件夹会各自从"自己第一条笔记"开始补零，
    // 于是各条线的横轴刻度对不上 —— 叠在一起看就是错位的、
    // 像断掉一样。统一用一个起点（用户选的区间，或全库最早的日期）。
    // **默认区间跟着所选内容走**：一个只有 2014 年笔记的文件夹，
    // 时间线就该是 2014 那一段；一律补到今天的话会拖出一条空长尾。
    // dataSpan 传 _query（已带 collectionIds），拿到的是这些文件夹的并集跨度。
    final span = stats.dataSpan(query: _query);
    final commonFrom = _query.from ?? span.first;
    final commonTo = _query.to ?? span.last;

    final out = <TrendSeries>[];
    for (var i = 0; i < _collectionIds.length; i++) {
      final id = _collectionIds[i];
      final col = all.where((x) => x.id == id).firstOrNull;
      final pts = fetch(
        _query.copyWith(
          collectionIds: <int>[id],
          clearCollection: true,
          from: commonFrom,
          clearFrom: commonFrom == null,
          to: commonTo,
          clearTo: commonTo == null,
        ),
      );
      out.add(
        TrendSeries(
          label: col?.name ?? '文件夹 $id',
          color: Color(col?.color ?? _seriesPalette[i % _seriesPalette.length]),
          points: pts.map(_trendPointOf).toList(),
        ),
      );
    }
    return out;
  }

  TrendPoint _trendPointOf(dynamic p) => p is TrendPoint
      ? p
      : TrendPoint(
          bucket: p.bucket as String,
          label: p.label as String,
          notes: p.notes as int,
          chars: p.chars as int,
          words: p.words as int,
          images: p.images as int,
        );

  /// 累计增长的多序列版本（**带缓存**，原因同 [_trendSeries]）。
  List<TrendSeries> get _cumulativeSeries =>
      _cumulativeSeriesCache ??= _computeCumulativeSeries();

  /// 和趋势一样按文件夹逐条取 —— 累计点是另一种类型，得转一下。
  List<TrendSeries> _computeCumulativeSeries() {
    final stats = _stats;
    if (stats == null) return const <TrendSeries>[];

    TrendSeries wrap(String label, Color color, List<CumulativePoint> pts) =>
        TrendSeries(
          label: label,
          color: color,
          points: <TrendPoint>[
            for (final p in pts)
              TrendPoint(
                bucket: p.label,
                label: p.label,
                notes: p.notes,
                chars: p.chars,
                words: 0,
                images: 0,
              ),
          ],
        );

    if (_collectionIds.isEmpty) {
      return <TrendSeries>[
        wrap('全部', context.colors.tint, _cumulative),
      ];
    }

    final all = context.read<AppState>().collections;
    // **和趋势一样：所有序列共用同一条 X 轴。**
    //
    // fl_chart 是按**下标**画点的 —— 各条线桶数不同、起点不同时，
    // 同一个下标对应的是不同月份，整条线会水平错位，
    // 叠在一起就是"对不上"。tooltip 也只列出下标上有点的那些序列。
    // **默认区间跟着所选内容走**：一个只有 2014 年笔记的文件夹，
    // 时间线就该是 2014 那一段；一律补到今天的话会拖出一条空长尾。
    // dataSpan 传 _query（已带 collectionIds），拿到的是这些文件夹的并集跨度。
    final span = stats.dataSpan(query: _query);
    final commonFrom = _query.from ?? span.first;
    final commonTo = _query.to ?? span.last;
    final out = <TrendSeries>[];
    for (var i = 0; i < _collectionIds.length; i++) {
      final id = _collectionIds[i];
      final col = all.where((x) => x.id == id).firstOrNull;
      out.add(
        wrap(
          col?.name ?? '文件夹 $id',
          Color(col?.color ?? _seriesPalette[i % _seriesPalette.length]),
          stats.cumulative(
            query: _query.copyWith(
              collectionIds: <int>[id],
              clearCollection: true,
              from: commonFrom,
              clearFrom: commonFrom == null,
              to: commonTo,
              clearTo: commonTo == null,
            ),
            granularity: _granularity,
          ),
        ),
      );
    }
    return out;
  }

  /// 文件夹没设颜色时的兜底配色。
  static const List<int> _seriesPalette = <int>[
    0xFF3B82F6, 0xFFEF4444, 0xFF10B981, 0xFFF59E0B,
    0xFF8B5CF6, 0xFFEC4899, 0xFF06B6D4, 0xFF84CC16,
  ];

  Future<void> _pickCustomRange() async {
    final span = _stats?.dataSpan();
    final first = span?.first ?? DateTime(DateTime.now().year - 3, 1, 1);
    final last = span?.last ?? DateTime.now();

    final picked = await showRangePicker(
      context,
      initial: (_from != null && _to != null)
          ? DateTimeRange(start: _from!, end: _to!)
          : null,
      earliest: DateTime(first.year - 3, 1, 1),
      latest: DateTime(last.year + 1, 12, 31),
    );

    if (picked == null) return;
    setState(() {
      _range = StatsRange.custom;
      _from = picked.start;
      _to = picked.end;
    });
    _persist();
    _reload();
  }

  bool _show(String id) => !_hidden.contains(id);

  // ── 构建 ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // 数据可能在其他页面被改动，每次切回来都刷新
    final state = context.watch<AppState>();

    // 进出隐私空间等于换了数据源，必须重算一遍 ——
    // 只靠 watch 触发重建的话，界面会拿着旧数字给人看
    if (state.privacyMode != _lastPrivacy) {
      _lastPrivacy = state.privacyMode;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    }

    return Scaffold(
      backgroundColor: c.groupedBackground,
      body: SafeArea(
        bottom: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
            : CustomScrollView(
                physics: const AlwaysScrollableScrollPhysics(
                  parent: BouncingScrollPhysics(),
                ),
                slivers: <Widget>[
                  AppRefresh.sliver(onRefresh: () async => _load()),
                  SliverToBoxAdapter(child: _header(c)),
                  ..._moduleSlivers(context, c),
                ],
              ),
      ),
    );
  }

  List<Widget> _moduleSlivers(BuildContext context, AppColors c) {
    final visible = _visibleModules;

    Widget centered(Widget child) => Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1120),
        // **每张卡片独立成层**。
        //
        // 图表（尤其 fl_chart 那种几十条路径的）一帧重画一次不便宜，
        // 而这个列表是懒加载的：滑动时新卡片进场、旧卡片离场，
        // 没有边界的话整个视口每帧都在重画。加一层之后没变的卡片
        // 直接复用已有的图层。
        child: RepaintBoundary(child: child),
      ),
    );

    if (visible.isEmpty) {
      return <Widget>[
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 110),
          sliver: SliverToBoxAdapter(
            child: centered(_allHiddenCard(c)),
          ),
        ),
      ];
    }

    return <Widget>[
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 110),
        sliver: SliverReorderableList(
          itemCount: visible.length,
          onReorderItem: _onReorder,
          itemBuilder: (context, i) => KeyedSubtree(
            key: ValueKey<String>(visible[i]),
            child: centered(
              _DragHandleScope(
                index: i,
                child: _moduleWidget(visible[i], c),
              ),
            ),
          ),
        ),
      ),
    ];
  }

  /// 按 id 造出单个模块卡片。
  Widget _moduleWidget(String id, AppColors c) => switch (id) {
    'overview' => _cached('overview', (c, _overview), () => _overviewCard(c)),
    'trend' => _cached(
      'trend',
      (
        c,
        _trend,
        _metric,
        _trendStyle,
        _showDots,
        _smooth,
        _showGrid,
        _zoom,
        _viewStart,
        _granularity,
      ),
      () => _trendCard(c),
    ),
    'cumulative' => _cached(
      'cumulative',
      (
        c,
        _cumulative,
        _cumMetric,
        _cumStyle,
        _showDots,
        _smooth,
        _showGrid,
        _zoom,
        _viewStart,
        _granularity,
      ),
      () => _cumulativeCard(c),
    ),
    'share' => _cached('share', (c, _share, _shareStyle), () => _shareCard(c)),
    'compare' => _cached('compare', (c, _comparisons), () => _compareCard(c)),
    'heatmap' => _cached(
      'heatmap',
      (c, _density, _range, _from, _to),
      () => _heatmapCard(c),
    ),
    'hourly' => _cached('hourly', (c, _hourly, _weekday), () => _hourlyCard(c)),
    'length' => _cached(
      'length',
      // 换分档只让这一个 key 变 —— 其余模块的实例原样还回去，
      // Flutter 直接跳过它们的 build
      (c, _lengths, _lenScale),
      () => _lengthCard(c),
    ),
    'streak' => _cached('streak', (c, _streak), () => _streakCard(c)),
    'top' => _cached('top', (c, _top), () => _topCard(c)),
    'tags' => _cached('tags', (c, _tags), () => _tagsCard(c)),
    'keywords' => _cached('keywords', (c, _keywords), () => _keywordsCard(c)),
    // 参数统计自己会去查库，隐私空间一换必须重来
    'fields' => _cached(
      'fields',
      (c, context.read<AppState>().privacyMode),
      () => _fieldsCard(c),
    ),
    'storage' => _cached(
      'storage',
      (c, _mediaStats, _dbBytes),
      () => _storageCard(c),
    ),
    _ => const SizedBox.shrink(),
  };

  /// 模块卡片的实例缓存。
  ///
  /// 每次 `setState` 都会把所有可见模块重造一遍 —— 整页三千来个 widget，
  /// 其中三张 fl_chart 是大头（实测换一次篇幅分档要 300ms 左右，
  /// 而那次改动只影响一个直方图）。其余模块其实一个字都没变。
  ///
  /// 这里按**模块自己的输入**缓存 widget 实例：输入没变就把同一个对象还回去。
  /// Flutter 的 `Element.updateChild` 发现新旧 widget 是同一个对象时，
  /// 会直接跳过整棵子树的 build —— 比任何"局部刷新"的写法都省。
  ///
  /// 缓存键里放的是数据对象**本身**（同一份数据就是同一个实例）。
  /// 所以"漏了某个输入"最坏也只是某次样式没刷新，不会露陈旧数据：
  /// 数据一变实例就变，实例一变必然重建。数据整体重算时
  /// （[_load] / [_reload]）还会把整张表清掉，双保险。
  final Map<String, ({Object key, Widget widget})> _moduleCache =
      <String, ({Object key, Widget widget})>{};

  Widget _cached(String id, Object key, Widget Function() build) {
    final hit = _moduleCache[id];
    if (hit != null && hit.key == key) return hit.widget;
    final w = build();
    _moduleCache[id] = (key: key, widget: w);
    return w;
  }

  /// 存储与数据：笔记数、总字数、图片、视频、磁盘占用。
  ///
  /// 这些原来挤在设置页里，和"主题""字号"那些**偏好设置**混在一起；
  /// 它们其实是**数据**，放在统计页才顺。
  ///
  /// 图片和视频的**个数**直接数磁盘上的文件，而不是读 note.image_count：
  /// 那个字段是笔记侧的冗余统计，导入之外还可能包含已删笔记的图；
  /// 这里要给的是"存储里到底有多少东西"，以磁盘为准最实在。
  Widget _storageCard(AppColors c) {
    final media = _mediaStats;

    Widget row(String label, String value, {Color? accent}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: AppText.callout.copyWith(color: c.secondaryLabel),
            ),
          ),
          Text(
            value,
            style: AppText.callout.copyWith(
              color: accent ?? c.label,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );

    return _Card(
      title: '存储与数据',
      child: Column(
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                // 磁盘上的东西没法按文件夹切分，所以这一张**永远是整库口径**。
                // 以前这里也列"笔记/总字数"，那两行会跟着筛选变，
                // 和下面的磁盘数字不是一回事 —— 索性去掉，概览里已经有了。
                '全部存在本机，不上传任何服务器 · 以下为整库占用',
                style: AppText.caption1.copyWith(color: c.tertiaryLabel),
              ),
            ),
          ),
          row('图片', '${media.images} 张'),
          row('视频', '${media.videos} 个'),
          row('媒体占用', _fmtBytes(media.bytes)),
          Divider(height: 1, color: c.separator),
          row('数据库大小', _fmtBytes(_dbBytes), accent: c.tint),
        ],
      ),
    );
  }

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  /// 数一遍图片目录：图片、视频各多少，一共占多少字节。
  MediaStats _scanMedia() {
    var images = 0;
    var videos = 0;
    var bytes = 0;
    try {
      final root = context.read<AppState>().db.imageRoot;
      if (!root.existsSync()) {
        return const MediaStats(images: 0, videos: 0, bytes: 0);
      }
      for (final e in root.listSync(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        final ext = e.path.split('.').last.toLowerCase();
        if (MediaImporter.videoExts.contains(ext)) {
          videos++;
        } else if (MediaImporter.imageExts.contains(ext)) {
          images++;
        } else {
          continue;
        }
        try {
          bytes += e.lengthSync().round();
        } catch (_) {
          // 单个文件读不到长度就跳过，不能让整个统计挂掉
        }
      }
    } catch (_) {
      // 目录被挪走/权限不足时给 0，而不是抛异常
    }
    return MediaStats(images: images, videos: videos, bytes: bytes);
  }

  int _dbBytesOf(AppDatabase db) {
    try {
      var total = 0;
      // WAL 模式的库有三个文件：.db / -wal / -shm，加起来才是真实占用
      for (final suffix in <String>['', '-wal', '-shm']) {
        final f = File('${db.rootDir.path}${Platform.pathSeparator}'
            'yuanworld.db$suffix');
        if (f.existsSync()) total += f.lengthSync().round();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  Widget _allHiddenCard(AppColors c) => _Card(
    title: '全部模块都被隐藏了',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '统计模块可以随时开关、还能拖动排序，把你关心的留下来。',
          style: AppText.footnote.copyWith(color: c.secondaryLabel),
        ),
        const SizedBox(height: 12),
        _GhostButton(
          label: '恢复全部模块',
          icon: Icons.restart_alt_rounded,
          onTap: () {
            setState(() => _hidden.clear());
            _persist();
          },
        ),
      ],
    ),
  );

  // ── 顶部栏 ──────────────────────────────────────────────────────────────

  Widget _header(AppColors c) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1120),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '统计',
                          style: AppText.largeTitle.copyWith(color: c.label),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _rangeSubtitle(),
                          style: AppText.footnote.copyWith(color: c.tertiaryLabel),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  GlassIconButton(
                    icon: Icons.tune_rounded,
                    size: 32,
                    iconSize: 17,
                    tooltip: '选择要显示的模块',
                    onTap: () => _showModuleSheet(c),
                  ),
                ],
              ),
              const SizedBox(height: 14),

              // 时间范围 + 文件夹：**都收成下拉，摆在同一行**。
              //
              // 六个 chip 铺一行既占地方，又和下面的文件夹下拉风格不一致，
              // 而真正常用的就那一两个。两个下拉一行放得下，
              // 窄屏自动折到两行。
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  Builder(
                    builder: (btnCtx) => _FilterButton(
                      icon: Icons.schedule_rounded,
                      label: _rangeLabel,
                      accent: _range == StatsRange.all
                          ? c.tint
                          : c.palette[4],
                      onTap: () => _pickRangeMenu(btnCtx),
                    ),
                  ),
                  Builder(
                    builder: (btnCtx) => _FilterButton(
                      icon: Icons.folder_rounded,
                      label: _folderLabel,
                      accent: _folderAccent(c),
                      onTap: () => _pickCollectionMenu(btnCtx),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 时间范围按钮上的文字。
  String get _rangeLabel {
    if (_range != StatsRange.custom) return _range.label;
    if (_from == null || _to == null) return '自定义';
    return '${_fmtDay(_from)} – ${_fmtDay(_to)}';
  }

  /// 时间范围下拉。选「自定义」再弹日历。
  Future<void> _pickRangeMenu(BuildContext btnCtx) async {
    final picked = await showAppMenu<StatsRange>(
      btnCtx,
      anchor: AppMenuAnchor(context: btnCtx),
      header: '时间范围',
      items: <AppMenuItem<StatsRange>>[
        for (final r in StatsRange.values)
          AppMenuItem(
            value: r,
            label: r == StatsRange.custom && _range == r
                ? _rangeLabel
                : r.label,
            icon: _range == r
                ? Icons.check_circle_rounded
                : (r == StatsRange.custom
                      ? Icons.calendar_month_rounded
                      : Icons.circle_outlined),
            color: _range == r ? context.colors.tint : null,
          ),
      ],
    );
    if (picked == null || !mounted) return;
    if (picked == StatsRange.custom) {
      await _pickCustomRange();
    } else {
      _setRange(picked);
    }
  }

  /// 文件夹多选。
  ///
  /// 用带勾选的对话框而不是下拉菜单：菜单点一下就关，多选要反复点开，
  /// 那个来回太烦。对话框里能一次勾完再确定。
  Future<void> _pickCollectionMenu(BuildContext btnCtx) async {
    final collections = context.read<AppState>().collections;
    final picked = await showDialog<List<int>>(
      context: context,
      builder: (ctx) => _CollectionPicker(
        collections: collections,
        selected: _collectionIds,
      ),
    );
    if (picked == null || !mounted) return;
    _setCollections(picked);
  }

  String _fmtDay(DateTime? d) =>
      d == null ? '自定义' : '${d.year}.${d.month}.${d.day}';

  /// 筛选按钮上的文字。
  ///
  /// 多选时不能再写"全部文件夹" —— 用户明明勾了两个，
  /// 按钮却说全部，这个谎话比不显示还糟。
  String get _folderLabel {
    if (_collectionIds.isEmpty) return '全部文件夹';
    if (_collectionIds.length == 1) return _collectionName(_collectionIds.first);
    return '已选 ${_collectionIds.length} 个文件夹';
  }

  /// 筛选按钮的点色：单选跟文件夹自己的颜色，多选/全选统一用主色。
  Color _folderAccent(AppColors c) {
    if (_collectionIds.length != 1) return c.tint;
    final all = context.read<AppState>().collections;
    for (final x in all) {
      if (x.id == _collectionIds.first) return Color(x.color);
    }
    // 文件夹被删了但设置里还留着 id —— 兜底成主色，不要抛
    return c.tint;
  }

  String _rangeSubtitle() {
    final stats = _stats;
    final o = _overview;
    if (stats == null || o == null) return '还没有数据';

    // **篇数必须是筛选后的**。以前这里永远显示全库总数 ——
    // 勾了 3 个文件夹之后摘要还写着"共 76 篇"，而下面的图只有 12 篇，
    // 用户会以为筛选坏了。趋势点的合计恰好就是范围内的篇数。
    final scoped = _trend.fold<int>(0, (s, p) => s + p.notes);
    if (scoped == 0) return '还没有数据';

    final scope = switch (_collectionIds.length) {
      0 => '',
      1 => ' · 只看「${_collectionName(_collectionIds.first)}」',
      final n => ' · 对比 $n 个文件夹',
    };
    if (_range == StatsRange.custom) {
      return '${_fmtDay(_from)} – ${_fmtDay(_to)} · 共 $scoped 篇$scope';
    }
    // 起止也跟着范围走：选了"近一年"，头一行就不该从 2014 年开始报
    final span = stats.dataSpan(query: _query);
    final first = span.first;
    final last = span.last;
    if (first == null || last == null) return '共 $scoped 篇$scope';
    String d(DateTime t) => '${t.year}.${t.month}';
    return '${d(first)} – ${d(last)} · 共 $scoped 篇$scope';
  }

  String _collectionName(int id) {
    for (final c in context.read<AppState>().collections) {
      if (c.id == id) return c.name;
    }
    return '文件夹';
  }

  // ── 文件夹对比 ──────────────────────────────────────────────────────────

  Widget _compareCard(AppColors c) {
    if (_comparisons.length < 2) {
      // 只勾了一个文件夹时，问题不是"库里没有两个文件夹"，
      // 而是"你还差一个没勾" —— 同一句话会把人指错方向
      final msg = _collectionIds.length == 1
          ? '再选一个文件夹就能对比'
          : '至少要有两个文件夹才能对比';
      return _Card(title: '文件夹对比', child: _empty(c, msg));
    }

    final maxNotes = _comparisons.map((e) => e.notes).reduce(math.max);

    return _Card(
      title: '文件夹对比',
      trailing: Text(
        '共 ${_comparisons.length} 个',
        style: AppText.caption1.copyWith(color: c.tertiaryLabel),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 表头
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                const SizedBox(width: 104),
                Expanded(
                  child: Text('篇数',
                      style: AppText.caption2.copyWith(color: c.quaternaryLabel)),
                ),
                SizedBox(
                  width: 58,
                  child: Text('总字数',
                      textAlign: TextAlign.right,
                      style: AppText.caption2.copyWith(color: c.quaternaryLabel)),
                ),
                SizedBox(
                  width: 62,
                  child: Text('篇均',
                      textAlign: TextAlign.right,
                      style: AppText.caption2.copyWith(color: c.quaternaryLabel)),
                ),
                SizedBox(
                  width: 52,
                  child: Text('最近',
                      textAlign: TextAlign.right,
                      style: AppText.caption2.copyWith(color: c.quaternaryLabel)),
                ),
              ],
            ),
          ),
          for (final it in _comparisons)
            Pressable(
              onTap: () => _setCollection(
                _collectionId == it.id ? null : (it.id < 0 ? null : it.id),
              ),
              scale: 0.99,
              haptic: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    SizedBox(
                      width: 104,
                      child: Row(
                        children: [
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: Color(it.color),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              it.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppText.footnote.copyWith(
                                color: _collectionId == it.id ? c.tint : c.label,
                                fontWeight: _collectionId == it.id
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: TweenAnimationBuilder<double>(
                          tween: Tween<double>(
                            begin: 0,
                            end: maxNotes == 0 ? 0 : it.notes / maxNotes,
                          ),
                          duration: AppMotion.normal,
                          curve: AppMotion.enter,
                          builder: (context, v, _) => LinearProgressIndicator(
                            value: v,
                            minHeight: 7,
                            backgroundColor: c.fill,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(Color(it.color)),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 58,
                      child: Text(
                        '${it.notes}',
                        textAlign: TextAlign.right,
                        style: AppText.caption1.copyWith(
                          color: c.label,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 58,
                      child: Text(
                        fmtNum(it.chars),
                        textAlign: TextAlign.right,
                        style: AppText.caption1.copyWith(color: c.secondaryLabel),
                      ),
                    ),
                    SizedBox(
                      width: 62,
                      child: Text(
                        fmtNum(it.avgChars),
                        textAlign: TextAlign.right,
                        style: AppText.caption1.copyWith(color: c.tertiaryLabel),
                      ),
                    ),
                    SizedBox(
                      width: 52,
                      child: Text(
                        it.lastAt == null ? '—' : _fmtDay(it.lastAt),
                        textAlign: TextAlign.right,
                        style: AppText.caption1.copyWith(color: c.quaternaryLabel),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 6),
          Text(
            '点一行可以只看该文件夹的数据',
            style: AppText.caption2.copyWith(color: c.quaternaryLabel),
          ),
        ],
      ),
    );
  }

  // ── 模块配置面板 ────────────────────────────────────────────────────────

  Future<void> _showModuleSheet(AppColors c) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final inner = ctx.colors;

          // 关键：按**用户自己的顺序**渲染，而不是 _kModules 的固定顺序。
          // 否则在页面上拖完，打开这个面板看到的还是老顺序。
          final ordered = _orderedIds()
              .map((id) => _kModules.firstWhere((m) => m.id == id))
              .toList();

          void sync() {
            setLocal(() {});
            setState(() {});
            _persist();
          }

          void toggle(String id, bool on) {
            if (on) {
              _hidden.remove(id);
            } else {
              _hidden.add(id);
            }
            sync();
          }

          void reorder(int oldIndex, int newIndex) {
            // 面板里 12 个模块全都列出来，所以 visible 就是全部
            final all = _orderedIds();
            _order = applyModuleReorder(
              full: all,
              visible: all,
              oldIndex: oldIndex,
              newIndex: newIndex,
            );
            sync();
          }

          return Dialog(
            backgroundColor: inner.secondaryBackground,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400, maxHeight: 640),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '显示哪些模块',
                      style: AppText.headline.copyWith(color: inner.label),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '左右拖动 ≡ 可以调顺序，开关控制显示',
                      style: AppText.caption1.copyWith(color: inner.tertiaryLabel),
                    ),
                    const SizedBox(height: 10),
                    Flexible(
                      child: ReorderableListView.builder(
                        shrinkWrap: true,
                        // 自己画把手，不用默认那套
                        buildDefaultDragHandles: false,
                        itemCount: ordered.length,
                        onReorderItem: reorder,
                        itemBuilder: (context, i) => _ModuleToggle(
                          key: ValueKey<String>(ordered[i].id),
                          spec: ordered[i],
                          index: i,
                          on: _show(ordered[i].id),
                          onChanged: (v) => toggle(ordered[i].id, v),
                        ),
                      ),
                    ),
                    const Divider(height: 20),
                    Row(
                      children: [
                        TextButton(
                          onPressed: () {
                            // 「全部显示」只恢复可见性，不动用户排好的顺序
                            _hidden.clear();
                            sync();
                          },
                          child: const Text('全部显示'),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () => Navigator.pop(ctx),
                          child: const Text('完成'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ── 各模块 ──────────────────────────────────────────────────────────────

  Widget _overviewCard(AppColors c) {
    final o = _overview;
    if (o == null) return const SizedBox.shrink();

    final avg = o.noteCount == 0 ? 0 : o.totalChars ~/ o.noteCount;

    return _Card(
      title: '概览',
      trailing: Text(
        '平均每篇 ${fmtNum(avg)} 字',
        style: AppText.caption1.copyWith(color: c.tertiaryLabel),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _Stat(
                // key 是给测试用的：筛选一变，这个数字就得跟着变，
                // 之前漏了 _overview 的重算，它一直挂着旧值
                key: const Key('ov-notes'),
                label: '笔记',
                value: '${o.noteCount}',
                unit: '篇',
                color: c.tint,
                icon: Icons.article_rounded,
              ),
              _Stat(
                key: const Key('ov-chars'),
                label: '总字数',
                value: fmtNum(o.totalChars),
                color: c.palette[4],
                icon: Icons.text_fields_rounded,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _Stat(
                label: '词数',
                value: fmtNum(o.totalWords),
                color: c.palette[2],
                icon: Icons.abc_rounded,
              ),
              _Stat(
                label: '图片',
                value: fmtNum(o.imageCount),
                color: c.palette[5],
                icon: Icons.image_rounded,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _Stat(
                label: '文集',
                value: '${o.collectionCount}',
                unit: '个',
                color: c.palette[0],
                icon: Icons.folder_rounded,
              ),
              _Stat(
                label: '标签',
                value: '${o.tagCount}',
                unit: '个',
                color: c.palette[1],
                icon: Icons.sell_rounded,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _Stat(
                label: '收藏',
                value: '${o.favoriteCount}',
                unit: '篇',
                color: c.palette[7],
                icon: Icons.star_rounded,
              ),
              _Stat(
                label: '活跃天数',
                value: '${_streak?.activeDays ?? 0}',
                unit: '天',
                color: c.palette[3],
                icon: Icons.event_available_rounded,
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 图表显示选项。
  ///
  /// 这几项都是"同一份数据怎么画"的问题，和指标、样式属于一类，
  /// 所以合并成一个下拉，不占地方也不打断视线。
  ///
  /// **Y 轴不在这里**：它现在完全自动（见 trendYRange），
  /// 该从 0 起还是贴着数据画，数据自己说了算。
  bool _showDots = true;
  bool _smooth = true;
  bool _showGrid = true;

  /// 篇幅分布的**X 轴**分档。纵轴不再提供任何调节。
  LengthScale _lenScale = LengthScale.normal;

  /// 累计增长的指标与样式。以前写死成"字数 + 面积"。
  TrendMetric _cumMetric = TrendMetric.chars;
  TrendStyle _cumStyle = TrendStyle.area;

  /// 缩放档位。连续滑块点不准，给整数档。
  static const List<double> _zoomLevels = <double>[1, 2, 3, 5, 8, 12];
  double _zoom = 1;

  /// 可视窗口的起点（0..1）。**不持久化** ——
  /// 平移是个临时动作，下次打开回到开头比停在上次那个位置更符合预期。
  double _viewStart = 0;

  int _stepIn(List<double> levels, double cur, int dir) =>
      (math.max(0, levels.indexOf(cur)) + dir).clamp(0, levels.length - 1);

  /// 读回上次的缩放倍率。存坏了、或者不在档位里（比如档位改过），
  /// 就老实退回 1× —— 别让一个设置项把图表卡在一个奇怪的倍率上。
  static double _storedZoom(NoteRepository repo, String key) {
    final v = double.tryParse(repo.getSetting(key) ?? '');
    return (v != null && _zoomLevels.contains(v)) ? v : 1;
  }

  void _stepZoom(int dir) {
    final next = _stepIn(_zoomLevels, _zoom, dir);
    if (_zoomLevels[next] == _zoom) return;
    setState(() {
      _zoom = _zoomLevels[next];
      // 回到 1× 时窗口本来就是全量，不清掉的话下次放大位置会很怪
      if (_zoom <= 1) _viewStart = 0;
    });
    _persist();
  }

  /// 把一条轴和它的序列**一起**裁到可视窗口。
  ///
  /// 两个都得裁：只裁轴的话序列还是全长，多线模式下 `spots` 的下标 0
  /// 就成了全量的开头，画出来是窗口外的数据。
  /// 裁完交给 TrendChart，Y 轴范围自然跟着窗口重算 ——
  /// 放大到某几个月时，那几个月之间的高低差才撑得开。
  ({List<TrendPoint> axis, List<TrendSeries> series}) _windowTrend(
    List<TrendPoint> axisAll,
    List<TrendSeries> seriesAll,
  ) {
    if (_zoom <= 1) return (axis: axisAll, series: seriesAll);
    final w = trendWindow(axisAll.length, _zoom, _viewStart);
    return (
      axis: sliceRange(axisAll, w.start, w.end),
      series: <TrendSeries>[
        for (final s in seriesAll)
          TrendSeries(
            label: s.label,
            color: s.color,
            points: sliceRange(s.points, w.start, w.end),
          ),
      ],
    );
  }

  /// 图表下方的**横轴**控制条。
  ///
  /// 放在图下面而不是塞进右上角的菜单里 —— 缩放是个要**反复拖**的操作，
  /// 藏进菜单会让它变成没人发现的功能。
  ///
  /// 只有横轴：纵轴现在完全自动，没有可调的东西。
  Widget _zoomBar(AppColors c, List<TrendPoint> axis) {
    final first = axis.isEmpty ? null : axis.first.label;
    final last = axis.isEmpty ? null : axis.last.label;
    final xText = _zoom <= 1
        ? '全部'
        : (first != null && last != null ? '$first – $last' : '—');

    return Padding(
      // 页面上别处也有"全部"字样（范围筛选），测试要能精确定位到这一条
      key: const Key('stats-zoom-bar'),
      padding: const EdgeInsets.only(top: 2),
      child: _zoomRow(
        c,
        '横轴',
        _zoom,
        _viewStart,
        () => _stepZoom(-1),
        () => _stepZoom(1),
        (v) => setState(() => _viewStart = v),
        xText,
        'x',
      ),
    );
  }

  Widget _zoomRow(
    AppColors c,
    String name,
    double zoom,
    double viewStart,
    VoidCallback zoomOut,
    VoidCallback zoomIn,
    ValueChanged<double> onPan,
    String readout,
    String keyName,
  ) {
    final zoomed = zoom > 1;
    return Row(
      // 一行横轴一行纵轴，测试要能分清是哪一行
      key: Key('stats-zoom-$keyName'),
      children: <Widget>[
        SizedBox(
          width: 28,
          child: Text(
            name,
            style: AppText.caption2.copyWith(color: c.quaternaryLabel),
          ),
        ),
        _zoomBtn(c, Icons.remove_rounded, zoomed, zoomOut, '$name缩小'),
        SizedBox(
          width: 34,
          child: Text(
            '${zoom.toInt()}×',
            textAlign: TextAlign.center,
            style: AppText.caption1.copyWith(
              color: zoomed ? c.tint : c.tertiaryLabel,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        _zoomBtn(
          c,
          Icons.add_rounded,
          zoom < _zoomLevels.last,
          zoomIn,
          '$name放大',
        ),
        const SizedBox(width: 6),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 13),
            ),
            child: Slider(
              value: viewStart.clamp(0.0, 1.0),
              // 没放大时整段就是全部，滑它没有意义 —— 置灰而不是隐藏，
              // 免得用户以为"这个图不能滑动"
              onChanged: zoomed ? onPan : null,
            ),
          ),
        ),
        const SizedBox(width: 4),
        // 窄屏上时段文字会很长（"2024年3月 – 2026年1月"），
        // 不夹住的话滑块会被挤成几像素宽，根本拖不动
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 112),
          child: Text(
            readout,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: AppText.caption2.copyWith(color: c.tertiaryLabel),
          ),
        ),
      ],
    );
  }

  Widget _zoomBtn(
    AppColors c,
    IconData icon,
    bool enabled,
    VoidCallback onTap,
    String tip,
  ) => Tooltip(
    message: tip,
    child: InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(7),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Icon(
          icon,
          size: 17,
          color: enabled ? c.secondaryLabel : c.quaternaryLabel,
        ),
      ),
    ),
  );

  Widget _displayOptions(AppColors c) => Builder(
    builder: (btnCtx) => _IconMenuButton(
      icon: Icons.tune_rounded,
      tooltip: '显示选项',
      onTap: () async {
        final picked = await showAppMenu<String>(
          btnCtx,
          anchor: AppMenuAnchor(context: btnCtx),
          header: '显示选项',
          items: <AppMenuItem<String>>[
            AppMenuItem(
              value: 'dots',
              label: '显示数据点',
              icon: _showDots
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              color: _showDots ? c.tint : null,
            ),
            AppMenuItem(
              value: 'smooth',
              label: '平滑曲线',
              icon: _smooth
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              color: _smooth ? c.tint : null,
            ),
            AppMenuItem(
              value: 'grid',
              label: '显示网格线',
              icon: _showGrid
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              color: _showGrid ? c.tint : null,
            ),
          ],
        );
        if (picked == null || !mounted) return;
        setState(() {
          switch (picked) {
            case 'dots':
              _showDots = !_showDots;
            case 'smooth':
              _smooth = !_smooth;
            case 'grid':
              _showGrid = !_showGrid;
          }
        });
        _persist();
      },
    ),
  );

  Widget _trendCard(AppColors c) {
    // 空数据时不要去取序列 —— 那是真查库的
    final ({List<TrendPoint> axis, List<TrendSeries> series}) win =
        _trend.isEmpty
        ? (axis: _trend, series: const <TrendSeries>[])
        : _windowTrend(_trend, _trendSeries);
    return _Card(
      title: '写作趋势',
      controls: <Widget>[
        _MiniSelect<StatsGranularity>(
          value: _granularity,
          options: StatsGranularity.values,
          labelOf: (v) => v.label,
          onChanged: _setGranularity,
        ),
        _MiniSelect<TrendMetric>(
          value: _metric,
          options: TrendMetric.values,
          labelOf: (v) => v.label,
          onChanged: (v) {
            setState(() => _metric = v);
            _persist();
          },
        ),
        _ChartStyleButton<TrendStyle>(
          value: _trendStyle,
          options: TrendStyle.values,
          labelOf: (v) => v.label,
          iconOf: (v) => switch (v) {
            TrendStyle.bar => Icons.bar_chart_rounded,
            TrendStyle.line => Icons.show_chart_rounded,
            TrendStyle.area => Icons.area_chart_rounded,
          },
          onChanged: (v) {
            setState(() => _trendStyle = v);
            _persist();
          },
        ),
        _displayOptions(c),
      ],
      child: _trend.isEmpty
          ? _empty(c, '这个时间范围内还没有数据')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Summary(
                  items: <(String, String)>[
                    ('合计', fmtNum(_trend.fold<int>(0, (s, p) => s + p.notes))),
                    ('字数', fmtNum(_trend.fold<int>(0, (s, p) => s + p.chars))),
                    ('峰值', _peakLabel()),
                  ],
                ),
                const SizedBox(height: 14),
                SizedBox(
                  // 多线对比时图例要占地方，配高一点
                  height: _trendSeries.length > 1 ? 250 : 210,
                  child: TrendChart(
                    points: win.axis,
                    metric: _metric,
                    style: _trendStyle,
                    // 选了多个文件夹时画多条线
                    series: win.series,
                    showDots: _showDots,
                    smooth: _smooth,
                    showGrid: _showGrid,
                  ),
                ),
                _zoomBar(c, win.axis),
              ],
            ),
    );
  }

  String _peakLabel() {
    if (_trend.isEmpty) return '—';
    var best = _trend.first;
    for (final p in _trend) {
      if (p.valueOf(_metric) > best.valueOf(_metric)) best = p;
    }
    return '${best.label} ${fmtNum(best.valueOf(_metric))}';
  }

  Widget _cumulativeCard(AppColors c) {
    if (_cumulative.length < 2) {
      return _Card(
        title: '累计增长',
        child: _empty(c, '数据太少，画不出增长曲线'),
      );
    }
    final last = _cumulative.last;
    // 累计是单调递增的，放大看某一段同样有意义（看那段时间涨了多少）
    final cumPoints = <TrendPoint>[
      for (final p in _cumulative)
        TrendPoint(
          bucket: p.label,
          label: p.label,
          notes: p.notes,
          chars: p.chars,
          words: 0,
          images: 0,
        ),
    ];
    final ({List<TrendPoint> axis, List<TrendSeries> series}) win = _windowTrend(
      cumPoints,
      _cumulativeSeries,
    );
    return _Card(
      title: '累计增长',
      controls: <Widget>[
        // 之前累计只能看字数、只能画面积 —— 和趋势比可调的东西太少
        _MiniSelect<StatsGranularity>(
          value: _granularity,
          options: StatsGranularity.values,
          labelOf: (v) => v.label,
          onChanged: _setGranularity,
        ),
        _MiniSelect<TrendMetric>(
          value: _cumMetric,
          // 累计是单调递增的，词数/图片同样能累积，一并给出来
          options: const <TrendMetric>[
            TrendMetric.chars,
            TrendMetric.notes,
            TrendMetric.words,
            TrendMetric.images,
          ],
          labelOf: (v) => v.label,
          onChanged: (v) {
            setState(() => _cumMetric = v);
            _persist();
          },
        ),
        _ChartStyleButton<TrendStyle>(
          value: _cumStyle,
          options: const <TrendStyle>[TrendStyle.area, TrendStyle.line],
          labelOf: (v) => v.label,
          iconOf: (v) => v == TrendStyle.area
              ? Icons.area_chart_rounded
              : Icons.show_chart_rounded,
          onChanged: (v) {
            setState(() => _cumStyle = v);
            _persist();
          },
        ),
        _displayOptions(c),
      ],
      trailing: Text(
        '截至 ${last.label}',
        style: AppText.caption1.copyWith(color: c.tertiaryLabel),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Summary(
            items: <(String, String)>[
              ('累计篇数', '${last.notes}'),
              ('累计字数', fmtNum(last.chars)),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: _cumulativeSeries.length > 1 ? 250 : 210,
            child: TrendChart(
              points: win.axis,
              metric: _cumMetric,
              style: _cumStyle,
              series: win.series,
              showDots: _showDots,
              smooth: _smooth,
              showGrid: _showGrid,
            ),
          ),
          _zoomBar(c, win.axis),
        ],
      ),
    );
  }

  Widget _shareCard(AppColors c) {
    return _Card(
      title: '文集分布',
      controls: <Widget>[
        _ChartStyleButton<ShareStyle>(
          value: _shareStyle,
          options: ShareStyle.values,
          labelOf: (v) => v.label,
          iconOf: (v) => switch (v) {
            ShareStyle.donut => Icons.donut_large_rounded,
            ShareStyle.pie => Icons.pie_chart_rounded,
            ShareStyle.bar => Icons.bar_chart_rounded,
          },
          onChanged: (v) {
            setState(() => _shareStyle = v);
            _persist();
          },
        ),
      ],
      child: _share.isEmpty
          ? _empty(c, '还没有笔记')
          : ShareChart(items: _share, style: _shareStyle),
    );
  }

  Widget _heatmapCard(AppColors c) {
    // 窗口跟着页面顶部的时间范围走，卡片上只如实报出实际画的是哪一段
    final win = heatWindow(
      rangeFrom: _query.from,
      rangeTo: _query.to,
      dataFrom: _densityFrom,
      dataTo: _densityTo,
      now: DateTime.now(),
    );
    String d(DateTime t) => '${t.year}.${t.month}';
    return _Card(
      title: '发布热力图',
      trailing: Text(
        '${d(win.from)} – ${d(win.to)}',
        style: AppText.caption1.copyWith(color: c.tertiaryLabel),
      ),
      child: DensityHeatmap(data: _density, from: win.from, to: win.to),
    );
  }

  Widget _hourlyCard(AppColors c) {
    final peak = _peakHour();
    return _Card(
      title: '写作时段',
      trailing: Text(
        peak < 0 ? '' : '最常在 $peak 点',
        style: AppText.caption1.copyWith(color: c.tertiaryLabel),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(height: 150, child: HourlyChart(hours: _hourly)),
          const SizedBox(height: 16),
          Text(
            '星期分布',
            style: AppText.footnote.copyWith(
              color: c.secondaryLabel,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          WeekdayChart(days: _weekday),
        ],
      ),
    );
  }

  int _peakHour() {
    if (_hourly.isEmpty) return -1;
    var best = 0;
    for (var i = 1; i < _hourly.length; i++) {
      if (_hourly[i] > _hourly[best]) best = i;
    }
    return _hourly[best] == 0 ? -1 : best;
  }

  Widget _lengthCard(AppColors c) {
    final total = _lengths.fold<int>(0, (s, b) => s + b.count);
    return _Card(
      title: '篇幅分布',
      controls: <Widget>[
        // 只留 X 轴：换分档。日记和长文集共用一套档位，必然有一半是空的。
        // 纵轴不给任何调节 —— 柱状图从 0 起是它唯一的诚实画法。
        _MiniSelect<LengthScale>(
          value: _lenScale,
          options: LengthScale.values,
          labelOf: (v) => '${v.label}分档',
          onChanged: (v) {
            setState(() => _lenScale = v);
            _persist();
            // **只重算这一个直方图**。
            //
            // 以前这里调的是 _reload() —— 换个分档把整页十来个聚合全跑一遍
            // （含全库词频和文件夹逐条取数），在真实库上就是一段明显的
            // 同步卡顿：点完界面不动了，还以为死了。分档只影响这一张图。
            _reloadLengths();
          },
        ),
      ],
      trailing: Text(
        '$total 篇',
        style: AppText.caption1.copyWith(color: c.tertiaryLabel),
      ),
      child: LengthHistogram(buckets: _lengths),
    );
  }

  Widget _streakCard(AppColors c) {
    final s = _streak;
    if (s == null) return const SizedBox.shrink();
    return _Card(
      title: '连续写作',
      child: Column(
        children: [
          Row(
            children: [
              _Stat(
                label: '当前连续',
                value: '${s.current}',
                unit: '天',
                color: c.palette[1],
                icon: Icons.local_fire_department_rounded,
              ),
              _Stat(
                label: '最长连续',
                value: '${s.longest}',
                unit: '天',
                color: c.palette[4],
                icon: Icons.emoji_events_rounded,
              ),
            ],
          ),
          const SizedBox(height: 14),
          // 活跃密度：有发布记录的天数 / 总跨度
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    '活跃密度',
                    style: AppText.footnote.copyWith(color: c.secondaryLabel),
                  ),
                  const Spacer(),
                  Text(
                    '${(s.density * 100).toStringAsFixed(1)}%'
                    '（${s.activeDays}/${s.totalDays} 天）',
                    style: AppText.caption1.copyWith(color: c.tertiaryLabel),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: s.density),
                  duration: AppMotion.sheet,
                  curve: AppMotion.enter,
                  builder: (context, v, _) => LinearProgressIndicator(
                    value: v,
                    minHeight: 9,
                    backgroundColor: c.fill,
                    valueColor: AlwaysStoppedAnimation<Color>(c.palette[1]),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _topCard(AppColors c) {
    if (_top.isEmpty) {
      return _Card(title: '长文排行', child: _empty(c, '还没有笔记'));
    }
    final maxV = _top.first.chars;
    return _Card(
      title: '长文排行',
      trailing: Text(
        'Top ${_top.length}',
        style: AppText.caption1.copyWith(color: c.tertiaryLabel),
      ),
      child: Column(
        children: [
          for (var i = 0; i < _top.length; i++)
            _RankRow(
              index: i,
              title: _top[i].title,
              value: '${fmtNum(_top[i].chars)} 字',
              ratio: maxV == 0 ? 0 : _top[i].chars / maxV,
              color: _top[i].color == null ? c.tint : Color(_top[i].color!),
              onTap: () => _openNote(_top[i].id),
            ),
        ],
      ),
    );
  }

  void _openNote(int id) {
    Navigator.of(context).push(
      ApplePageRoute<void>(pageBuilder: (_) => NoteDetailPage(noteId: id)),
    );
  }

  Widget _tagsCard(AppColors c) {
    if (_tags.isEmpty) {
      return _Card(title: '标签分布', child: _empty(c, '还没有打过标签'));
    }
    final total = _tags.fold<int>(0, (s, t) => s + t.count);
    return _Card(
      title: '标签分布',
      trailing: Text(
        '$total 次使用',
        style: AppText.caption1.copyWith(color: c.tertiaryLabel),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final t in _tags)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
              decoration: BoxDecoration(
                color: Color(t.color).withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '#${t.name}',
                    style: AppText.footnote.copyWith(color: Color(t.color)),
                  ),
                  const SizedBox(width: 5),
                  Text(
                    '${t.count}',
                    style: AppText.caption2.copyWith(color: c.tertiaryLabel),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _keywordsCard(AppColors c) {
    return _Card(
      title: '高频词',
      trailing: Text(
        '来自标题与摘要',
        style: AppText.caption1.copyWith(color: c.tertiaryLabel),
      ),
      child: KeywordBars(keywords: _keywords),
    );
  }

  /// 参数统计。数据由卡片自己加载，这里只负责套上统一的卡片外壳。
  Widget _fieldsCard(AppColors c) => _Card(
    title: '参数统计',
    trailing: Text(
      '数值型可求和求均值',
      style: AppText.caption1.copyWith(color: c.tertiaryLabel),
    ),
    child: const FieldStatsCard(),
  );

  Widget _empty(AppColors c, String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 18),
    child: Text(
      text,
      style: AppText.footnote.copyWith(color: c.tertiaryLabel),
    ),
  );
}

// ── 通用小部件 ────────────────────────────────────────────────────────────

/// 把「当前模块的可拖拽下标」传给卡片内部的拖拽把手。
///
/// 用 InheritedWidget 是为了不必给 11 个 `_xxxCard` 方法都加一个 dragIndex 参数
/// —— 那会把每个方法的签名都污染一遍。
class _DragHandleScope extends InheritedWidget {
  const _DragHandleScope({required this.index, required super.child});

  final int index;

  static int? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_DragHandleScope>()
      ?.index;

  @override
  bool updateShouldNotify(_DragHandleScope oldWidget) =>
      oldWidget.index != index;
}

class _Card extends StatelessWidget {
  const _Card({
    required this.title,
    required this.child,
    this.trailing,
    this.controls,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  /// 标题右侧的一排控制项（下拉、图表类型切换等）
  final List<Widget>? controls;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 15, 16, 16),
        decoration: BoxDecoration(
          color: c.secondaryBackground,
          borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
          border: Border.all(
            color: c.isDark
                ? c.separator.withValues(alpha: 0.4)
                : const Color(0x0D000000),
            width: 0.5,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // 拖拽把手：只有把手能起拖，卡片别处照常可以滚动/点击
                if (_DragHandleScope.maybeOf(context) != null)
                  ReorderableDragStartListener(
                    index: _DragHandleScope.maybeOf(context)!,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.grab,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 7, top: 2, bottom: 2),
                        child: Icon(
                          Icons.drag_indicator_rounded,
                          size: 17,
                          color: c.quaternaryLabel,
                        ),
                      ),
                    ),
                  ),
                Expanded(
                  child: Text(
                    title,
                    style: AppText.headline.copyWith(
                      color: c.label,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
            if (controls != null && controls!.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: controls!),
            ],
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    super.key,
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
    this.unit,
  });

  final String label;
  final String value;
  final String? unit;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Expanded(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.fromLTRB(12, 11, 12, 12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: c.isDark ? 0.16 : 0.09),
          borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 13, color: color),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: AppText.caption1.copyWith(color: c.secondaryLabel),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Flexible(
                  child: Text(
                    value,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.title3.copyWith(color: c.label),
                  ),
                ),
                if (unit != null) ...[
                  const SizedBox(width: 2),
                  Text(
                    unit!,
                    style: AppText.caption1.copyWith(color: c.tertiaryLabel),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.items});
  final List<(String, String)> items;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Wrap(
      spacing: 18,
      runSpacing: 6,
      children: [
        for (final (label, value) in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: AppText.caption1.copyWith(color: c.tertiaryLabel),
              ),
              const SizedBox(width: 5),
              Text(
                value,
                style: AppText.footnote.copyWith(
                  color: c.label,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _RankRow extends StatelessWidget {
  const _RankRow({
    required this.index,
    required this.title,
    required this.value,
    required this.ratio,
    required this.color,
    required this.onTap,
  });

  final int index;
  final String title;
  final String value;
  final double ratio;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Pressable(
      onTap: onTap,
      scale: 0.99,
      opacity: 0.7,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              child: Text(
                '${index + 1}',
                style: AppText.caption1.copyWith(
                  color: index < 3 ? color : c.quaternaryLabel,
                  fontWeight: index < 3 ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title.isEmpty ? '无标题笔记' : title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppText.footnote.copyWith(color: c.label),
                  ),
                  const SizedBox(height: 5),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(begin: 0, end: ratio),
                      duration: AppMotion.normal,
                      curve: AppMotion.enter,
                      builder: (context, v, _) => LinearProgressIndicator(
                        value: v,
                        minHeight: 5,
                        backgroundColor: c.fill,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          color.withValues(alpha: 0.75),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              value,
              style: AppText.caption1.copyWith(color: c.tertiaryLabel),
            ),
          ],
        ),
      ),
    );
  }
}

/// 时间范围 / 文件夹用的小胶囊。
/// 文件夹多选对话框。返回选中的 id 列表（空 = 全部）。
class _CollectionPicker extends StatefulWidget {
  const _CollectionPicker({required this.collections, required this.selected});

  final List<Collection> collections;
  final List<int> selected;

  @override
  State<_CollectionPicker> createState() => _CollectionPickerState();
}

class _CollectionPickerState extends State<_CollectionPicker> {
  late final Set<int> _picked = <int>{...widget.selected};

  /// 收起来的父节点。
  ///
  /// 文集一多（导入一堆文集之后很常见），全摊开会变成一条几十行的长列表，
  /// 想勾的那个要滚半天 —— 和外面左栏一样能收起来才找得到。
  final Set<int> _collapsed = <int>{};

  /// 把扁平列表还原成"深度优先"的顺序，附带层级。
  ///
  /// `allCollections()` 给的是按置顶/序号排的**扁平**列表，
  /// 直接铺出来会和左栏的树对不上 —— 统计里勾选的位置和外面的位置
  /// 不一致，用户要来回找。这里按父子关系重新走一遍。
  ///
  /// 收起来的节点**不往下走**，所以返回的就是当前该显示的那几行。
  List<({Collection col, int depth, bool hasKids, int pickedBelow})>
  get _tree {
    final byParent = <int?, List<Collection>>{};
    for (final c in widget.collections) {
      (byParent[c.parentId] ??= <Collection>[]).add(c);
    }
    final out = <({Collection col, int depth, bool hasKids, int pickedBelow})>[];
    void walk(int? parentId, int depth) {
      // 深度兜底：数据万一成环也不能把列表渲染卡死
      if (depth > 8) return;
      for (final c in byParent[parentId] ?? const <Collection>[]) {
        final kids = byParent[c.id] ?? const <Collection>[];
        out.add((
          col: c,
          depth: depth,
          hasKids: kids.isNotEmpty,
          pickedBelow: _countPickedBelow(c.id, byParent),
        ));
        if (kids.isNotEmpty && !_collapsed.contains(c.id)) walk(c.id, depth + 1);
      }
    }

    walk(null, 0);
    return out;
  }

  /// 这个节点下面（不含自己）勾了几个。
  ///
  /// 收起来之后底下勾着什么是看不见的，不提示的话用户会以为白勾了。
  int _countPickedBelow(int id, Map<int?, List<Collection>> byParent) {
    var n = 0;
    void walk(int pid, int depth) {
      if (depth > 8) return;
      for (final c in byParent[pid] ?? const <Collection>[]) {
        if (_picked.contains(c.id)) n++;
        walk(c.id, depth + 1);
      }
    }

    walk(id, 0);
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final all = widget.collections;
    final tree = _tree;

    return Dialog(
      backgroundColor: c.secondaryBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400, maxHeight: 520),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '选择文件夹',
                style: AppText.headline.copyWith(color: c.label),
              ),
              const SizedBox(height: 3),
              Text(
                '选两个以上就能在趋势、累计里互相对比',
                style: AppText.caption1.copyWith(color: c.tertiaryLabel),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  _mini(c, '全部（不筛选）', () => setState(_picked.clear)),
                  const SizedBox(width: 8),
                  _mini(
                    c,
                    '全选',
                    () => setState(
                      () => _picked
                        ..clear()
                        ..addAll(all.map((x) => x.id)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _mini(
                    c,
                    '反选',
                    () => setState(() {
                      final next =
                          all.map((x) => x.id).toSet().difference(_picked);
                      _picked
                        ..clear()
                        ..addAll(next);
                    }),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Flexible(
                child: all.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(vertical: 20),
                        child: Text(
                          '还没有文件夹',
                          textAlign: TextAlign.center,
                          style:
                              AppText.caption1.copyWith(color: c.tertiaryLabel),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: tree.length,
                        itemBuilder: (context, i) {
                          final node = tree[i];
                          final col = node.col;
                          final collapsed = _collapsed.contains(col.id);
                          final on = _picked.contains(col.id);
                          return Pressable(
                            onTap: () => setState(() {
                              if (!_picked.remove(col.id)) _picked.add(col.id);
                            }),
                            scale: 0.995,
                            haptic: false,
                            child: Padding(
                              // 按层级缩进，嵌套关系和外面一致
                              padding: EdgeInsets.fromLTRB(
                                0,
                                6,
                                0,
                                6,
                              ).add(EdgeInsets.only(left: node.depth * 16)),
                              child: Row(
                                children: [
                                  // 展开/收起的三角。没有子文件夹时留同样的空位，
                                  // 否则同级之间会错开一格
                                  SizedBox(
                                    width: 20,
                                    child: node.hasKids
                                        ? Pressable(
                                            onTap: () => setState(() {
                                              if (!_collapsed.remove(col.id)) {
                                                _collapsed.add(col.id);
                                              }
                                            }),
                                            scale: 0.85,
                                            haptic: false,
                                            child: Icon(
                                              collapsed
                                                  ? Icons
                                                        .chevron_right_rounded
                                                  : Icons.expand_more_rounded,
                                              size: 18,
                                              color: c.tertiaryLabel,
                                            ),
                                          )
                                        : null,
                                  ),
                                  Icon(
                                    on
                                        ? Icons.check_box_rounded
                                        : Icons.check_box_outline_blank_rounded,
                                    size: 18,
                                    color: on ? c.tint : c.quaternaryLabel,
                                  ),
                                  const SizedBox(width: 10),
                                  Icon(
                                    node.depth > 0
                                        ? Icons.subdirectory_arrow_right_rounded
                                        : Icons.folder_rounded,
                                    size: 16,
                                    color: Color(col.color),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      col.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppText.callout
                                          .copyWith(color: c.label),
                                    ),
                                  ),
                                  // 收起来时底下还勾着什么，得说出来
                                  if (collapsed && node.pickedBelow > 0)
                                    Text(
                                      '含 ${node.pickedBelow} 个已选',
                                      style: AppText.caption2.copyWith(
                                        color: c.tint,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _picked.isEmpty ? '当前：全部' : '已选 ${_picked.length} 个',
                      style: AppText.caption1.copyWith(
                        color: _picked.isEmpty ? c.tertiaryLabel : c.tint,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () =>
                        Navigator.pop(context, _picked.toList()),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _mini(AppColors c, String label, VoidCallback onTap) => Pressable(
    onTap: onTap,
    scale: 0.95,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: c.fill,
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        label,
        style: AppText.caption1.copyWith(color: c.secondaryLabel),
      ),
    ),
  );
}

/// 筛选下拉按钮。比一排 chip 省地方，也不会随选项增多而溢出。
class _FilterButton extends StatefulWidget {
  const _FilterButton({
    required this.icon,
    required this.label,
    required this.accent,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color accent;
  final VoidCallback onTap;

  @override
  State<_FilterButton> createState() => _FilterButtonState();
}

class _FilterButtonState extends State<_FilterButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Pressable(
        onTap: widget.onTap,
        scale: 0.97,
        child: AnimatedContainer(
          duration: AppMotion.fast,
          padding: const EdgeInsets.fromLTRB(11, 6, 8, 6),
          decoration: BoxDecoration(
            color: _hover
                ? c.fill
                : widget.accent.withValues(alpha: c.isDark ? 0.20 : 0.11),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 14, color: widget.accent),
              const SizedBox(width: 6),
              ConstrainedBox(
                // 名字太长时截断，别把整行撑破
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.footnote.copyWith(
                    color: widget.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.expand_more_rounded, size: 15, color: widget.accent),
            ],
          ),
        ),
      ),
    );
  }
}


/// 卡片里的小下拉（粒度、指标）。
class _MiniSelect<T> extends StatelessWidget {
  const _MiniSelect({
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onChanged,
  });

  final T value;
  final List<T> options;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Pressable(
      onTap: () async {
        final picked = await showAppMenu<T>(
          context,
          anchor: AppMenuAnchor(context: context),
          items: <AppMenuItem<T>>[
            for (final o in options)
              AppMenuItem(
                value: o,
                label: labelOf(o),
                icon: o == value
                    ? Icons.check_circle_rounded
                    : Icons.circle_outlined,
                color: o == value ? c.tint : null,
              ),
          ],
        );
        // 等菜单关掉的这段时间里，这张卡片可能已经被滚出屏幕
        // （模块列表是懒加载的 sliver），那就别再往下走
        if (picked != null && context.mounted) onChanged(picked);
      },
      scale: 0.96,
      child: Container(
        padding: const EdgeInsets.fromLTRB(11, 6, 8, 6),
        decoration: BoxDecoration(
          color: c.fill,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              labelOf(value),
              style: AppText.caption1.copyWith(
                color: c.label,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 3),
            Icon(Icons.expand_more_rounded, size: 14, color: c.tertiaryLabel),
          ],
        ),
      ),
    );
  }
}

/// 图表画法切换按钮。
/// 卡片标题右侧的纯图标按钮（点了自己开菜单）。
class _IconMenuButton extends StatelessWidget {
  const _IconMenuButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: tooltip,
      child: Pressable(
        onTap: onTap,
        scale: 0.92,
        child: Container(
          width: 26,
          height: 26,
          margin: const EdgeInsets.only(left: 6),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: c.fill,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Icon(icon, size: 14, color: c.secondaryLabel),
        ),
      ),
    );
  }
}

class _ChartStyleButton<T> extends StatelessWidget {
  const _ChartStyleButton({
    required this.value,
    required this.options,
    required this.labelOf,
    required this.iconOf,
    required this.onChanged,
  });

  final T value;
  final List<T> options;
  final String Function(T) labelOf;
  final IconData Function(T) iconOf;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Pressable(
      onTap: () async {
        final picked = await showAppMenu<T>(
          context,
          anchor: AppMenuAnchor(context: context),
          items: <AppMenuItem<T>>[
            for (final o in options)
              AppMenuItem(
                value: o,
                label: labelOf(o),
                icon: o == value ? Icons.check_circle_rounded : iconOf(o),
                color: o == value ? c.tint : null,
              ),
          ],
        );
        // 同 _MiniSelect：卡片可能已经不在树上了
        if (picked != null && context.mounted) onChanged(picked);
      },
      scale: 0.9,
      child: Tooltip(
        message: '切换图表类型（当前：${labelOf(value)}）',
        child: Container(
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: c.fill,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(iconOf(value), size: 15, color: c.secondaryLabel),
        ),
      ),
    );
  }
}

/// 模块开关行。
class _ModuleToggle extends StatelessWidget {
  const _ModuleToggle({
    super.key,
    required this.spec,
    required this.on,
    required this.onChanged,
    this.index,
  });

  final _ModuleSpec spec;
  final bool on;
  final ValueChanged<bool> onChanged;

  /// 在可拖拽列表里的下标。为空则不显示拖拽把手。
  final int? index;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return Row(
      children: [
        // 把手放在 Pressable **外面**：它是纯拖拽用的，
        // 放进可点击区域里会变成"点一下就切换开关"，很烦。
        if (index != null)
          ReorderableDragStartListener(
            index: index!,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Padding(
                padding: const EdgeInsets.only(right: 6, top: 10, bottom: 10),
                child: Icon(
                  Icons.drag_indicator_rounded,
                  size: 18,
                  color: c.quaternaryLabel,
                ),
              ),
            ),
          ),
        Expanded(
          child: Pressable(
            onTap: () => onChanged(!on),
            scale: 0.99,
            haptic: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: [
                  Icon(
                    spec.icon,
                    size: 17,
                    color: on ? c.tint : c.quaternaryLabel,
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          spec.title,
                          style: AppText.footnote.copyWith(
                            color: on ? c.label : c.tertiaryLabel,
                          ),
                        ),
                        Text(
                          spec.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              AppText.caption2.copyWith(color: c.quaternaryLabel),
                        ),
                      ],
                    ),
                  ),
                  Switch.adaptive(
                    value: on,
                    onChanged: onChanged,
                    activeTrackColor: c.tint,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _GhostButton extends StatelessWidget {
  const _GhostButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Pressable(
      onTap: onTap,
      scale: 0.97,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: c.tint.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: c.tint),
            const SizedBox(width: 7),
            Text(
              label,
              style: AppText.footnote.copyWith(
                color: c.tint,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
