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

part 'stats_cards.dart';
part 'stats_controls.dart';
part 'stats_widgets.dart';

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
  _ModuleSpec('trend', '发布趋势', '按发布日期统计笔记当前内容', Icons.bar_chart_rounded),
  _ModuleSpec('cumulative', '累计增长', '所选区间内的累计量', Icons.show_chart_rounded),
  _ModuleSpec('share', '文集分布', '各文集占比与字数', Icons.donut_large_rounded),
  _ModuleSpec('compare', '文件夹对比', '横向比较各文件夹的产出', Icons.compare_arrows_rounded),
  _ModuleSpec('heatmap', '发布热力图', '近一年每天的发布密度', Icons.calendar_month_rounded),
  _ModuleSpec('hourly', '发布时段', '一天里的发布时段分布', Icons.schedule_rounded),
  _ModuleSpec('length', '篇幅分布', '笔记长度落在哪些区间', Icons.straighten_rounded),
  _ModuleSpec(
    'streak',
    '连续发布',
    '发布天数与活跃密度',
    Icons.local_fire_department_rounded,
  ),
  _ModuleSpec('top', '长文排行', '字数最多的笔记', Icons.format_list_numbered_rounded),
  _ModuleSpec('tags', '标签分布', '标签使用频次', Icons.sell_rounded),
  _ModuleSpec('keywords', '高频词', '内容里反复出现的词', Icons.tag_rounded),
  _ModuleSpec('fields', '参数统计', '头参数 / 尾参数的取值分布', Icons.playlist_add_rounded),
  _ModuleSpec('storage', '存储与数据', '笔记、字数、图片视频与磁盘占用', Icons.storage_rounded),
];

/// 概览卡片里可以单独开关的数据项。
///
/// 顺序即默认显示顺序，两两一行。id 会写进设置（`stats.overviewHidden`），
/// 所以**不要随便改名**，否则老用户存下的配置会对不上。
const List<_ModuleSpec> _kOverviewStats = <_ModuleSpec>[
  _ModuleSpec('notes', '笔记', '库里的笔记总数', Icons.article_rounded),
  _ModuleSpec('chars', '总字数', '所有笔记的字符总数', Icons.text_fields_rounded),
  _ModuleSpec('images', '图片', '正文与封面引用到的图片', Icons.image_rounded),
  _ModuleSpec('videos', '视频', '正文里插入的视频', Icons.videocam_rounded),
  _ModuleSpec('collections', '文集', '文件夹数量', Icons.folder_rounded),
  _ModuleSpec('tags', '标签', '标签数量', Icons.sell_rounded),
  _ModuleSpec('favorites', '收藏', '收藏的笔记数', Icons.star_rounded),
  _ModuleSpec('activeDays', '活跃天数', '有发布记录的天数', Icons.event_available_rounded),
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

  /// 概览里被关掉的数据项（存 id）。默认全部显示。
  final Set<String> _overviewHidden = <String>{};

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
  int _lastRevision = -1;
  bool _refreshScheduled = false;
  int _mediaGeneration = 0;

  /// 给两个 `part` 文件里的扩展方法用。
  ///
  /// 扩展不是 `State` 的子类，里面直接调 `setState` 会被判成"用了受保护
  /// 成员"（`@protected`，只是警告，但没必要留一堆噪音）。这里开一个
  /// 同库内的转发口，行为完全一样。
  void _setState(VoidCallback fn) => setState(fn);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
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
      _range = byName(
        StatsRange.values,
        repo.getSetting('stats.range'),
        _range,
      );
      _granularity = byName(
        StatsGranularity.values,
        repo.getSetting('stats.granularity'),
        _granularity,
      );
      _metric = byName(
        TrendMetric.values,
        repo.getSetting('stats.metric'),
        _metric,
      );
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
      final overviewRaw = repo.getSetting('stats.overviewHidden');
      if (overviewRaw != null && overviewRaw.isNotEmpty) {
        try {
          _overviewHidden
            ..clear()
            ..addAll(
              (jsonDecode(overviewRaw) as List<dynamic>).map((e) => e.toString()),
            );
        } catch (_) {
          // 同上
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
    repo.setSetting('stats.overviewHidden', jsonEncode(_overviewHidden.toList()));
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
  List<String> get _visibleModules => _orderedIds().where(_show).toList();

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
    _lastRevision = state.dataRevision;
    _lastPrivacy = state.privacyMode;
    final stats = _stats = StatsRepository(state.db);
    final q = _query;

    // 口径变了，缓存必须作废
    _trendSeriesCache = null;
    _cumulativeSeriesCache = null;
    _moduleCache.clear();

    setState(() {
      // 概览也走 _query：勾了文件夹就只算这几个
      _overview = stats.overview(query: q);
      // 磁盘扫描比较慢（要遍历整个图片目录），只在加载时做一次
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
    _refreshMedia();
  }

  /// 热力图在"全部"时要靠数据的实际跨度才知道画到哪儿。
  void _refreshDensitySpan(StatsRepository stats, StatsQuery q) {
    // 范围里没写死起止时，才需要问数据本身的首尾
    if (q.from != null && q.to != null) {
      _densityFrom = null;
      _densityTo = null;
      return;
    }
    final span = stats.dataSpan(query: q);
    _densityFrom = q.from ?? span.first;
    _densityTo = q.to ?? span.last ?? (q.from != null ? DateTime.now() : null);
  }

  /// 换筛选条件只需要重算与筛选相关的部分，
  /// 词频这种重活跟着重算一次也就几毫秒，索性一起刷新，保证图之间自洽。
  void _reload() {
    final stats = _stats;
    if (stats == null) return;
    // 这一轮算完就代表"已是最新"，账本得一起更新。
    // 不更新的话：换筛选 → _reload 重算 → build 里拿 state.dataRevision
    // 跟过期的 _lastRevision 比 → 判定"数据变了" → 下一帧又整页 _load 一遍。
    // 白算一整轮，参数卡片还会跟着再重查一次。
    final state = context.read<AppState>();
    _lastRevision = state.dataRevision;
    _lastPrivacy = state.privacyMode;
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
    from: _range == StatsRange.custom ? _from : _range.since(DateTime.now()),
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

  List<TrendSeries> get _trendSeries => _trendSeriesCache ??= _seriesFor(
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
                words: p.words,
                images: p.images,
                videos: p.videos,
              ),
          ],
        );

    if (_collectionIds.isEmpty) {
      return <TrendSeries>[wrap('全部', context.colors.tint, _cumulative)];
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
    0xFF3B82F6,
    0xFFEF4444,
    0xFF10B981,
    0xFFF59E0B,
    0xFF8B5CF6,
    0xFFEC4899,
    0xFF06B6D4,
    0xFF84CC16,
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

  /// 概览里的某个数据项是否显示。只有明确关过才隐藏。
  bool _showOverviewStat(String id) => !_overviewHidden.contains(id);

  // ── 构建 ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // 数据可能在其他页面被改动，每次切回来都刷新
    final state = context.watch<AppState>();

    // 进出隐私空间等于换了数据源，必须重算一遍 ——
    // 只靠 watch 触发重建的话，界面会拿着旧数字给人看
    if (!_loading &&
        !_refreshScheduled &&
        (state.privacyMode != _lastPrivacy ||
            state.dataRevision != _lastRevision)) {
      _refreshScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _refreshScheduled = false;
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
          sliver: SliverToBoxAdapter(child: centered(_allHiddenCard(c))),
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
              _DragHandleScope(index: i, child: _moduleWidget(visible[i], c)),
            ),
          ),
        ),
      ),
    ];
  }

  /// 按 id 造出单个模块卡片。
  Widget _moduleWidget(String id, AppColors c) => switch (id) {
    // 概览的缓存键要带上"显示了哪些项"，否则开关切完拿回来的还是旧卡片
    'overview' => _cached('overview', (
      c,
      _overview,
      (_overviewHidden.toList()..sort()).join(','),
    ), () => _overviewCard(c)),
    'trend' => _cached('trend', (
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
    ), () => _trendCard(c)),
    'cumulative' => _cached('cumulative', (
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
    ), () => _cumulativeCard(c)),
    'share' => _cached('share', (c, _share, _shareStyle), () => _shareCard(c)),
    'compare' => _cached('compare', (c, _comparisons), () => _compareCard(c)),
    'heatmap' => _cached('heatmap', (
      c,
      _density,
      _range,
      _from,
      _to,
    ), () => _heatmapCard(c)),
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
    'fields' => _cached('fields', (
      c,
      _range,
      _from,
      _to,
      _collectionIds,
      _lastPrivacy,
      _lastRevision,
    ), () => _fieldsCard(c)),
    'storage' => _cached('storage', (
      c,
      _mediaStats,
      _dbBytes,
    ), () => _storageCard(c)),
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

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(2)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  /// 数一遍图片目录：图片、视频各多少，一共占多少字节。
  Future<void> _refreshMedia() async {
    final generation = ++_mediaGeneration;
    final root = context.read<AppState>().db.imageRoot;
    final media = await _scanMedia(root);
    if (!mounted || generation != _mediaGeneration) return;
    setState(() => _mediaStats = media);
  }

  Future<MediaStats> _scanMedia(Directory root) async {
    var images = 0;
    var videos = 0;
    var bytes = 0;
    try {
      if (!await root.exists()) {
        return const MediaStats(images: 0, videos: 0, bytes: 0);
      }
      await for (final e in root.list(recursive: true, followLinks: false)) {
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
          bytes += await e.length();
        } catch (_) {
          // 单个文件读不到长度就跳过，不能让整个统计挂掉
        }
      }
    } catch (_) {
      // 目录被挪走/权限不足时给 0，而不是抛异常
    }
    return MediaStats(images: images, videos: videos, bytes: bytes);
  }

  // ── 顶部栏 ──────────────────────────────────────────────────────────────

  /// 时间范围按钮上的文字。
  String get _rangeLabel {
    if (_range != StatsRange.custom) return _range.label;
    if (_from == null || _to == null) return '自定义';
    return '${_fmtDay(_from)} – ${_fmtDay(_to)}';
  }

  /// 筛选按钮上的文字。
  ///
  /// 多选时不能再写"全部文件夹" —— 用户明明勾了两个，
  /// 按钮却说全部，这个谎话比不显示还糟。
  String get _folderLabel {
    if (_collectionIds.isEmpty) return '全部文件夹';
    if (_collectionIds.length == 1) {
      return _collectionName(_collectionIds.first);
    }
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

  // ── 文件夹对比 ──────────────────────────────────────────────────────────

  // ── 模块配置面板 ────────────────────────────────────────────────────────

  // ── 各模块 ──────────────────────────────────────────────────────────────

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

  /// 读回上次的缩放倍率。存坏了、或者不在档位里（比如档位改过），
  /// 就老实退回 1× —— 别让一个设置项把图表卡在一个奇怪的倍率上。
  static double _storedZoom(NoteRepository repo, String key) {
    final v = double.tryParse(repo.getSetting(key) ?? '');
    return (v != null && _zoomLevels.contains(v)) ? v : 1;
  }

  /// 把一条轴和它的序列**一起**裁到可视窗口。
  ///
  /// 两个都得裁：只裁轴的话序列还是全长，多线模式下 `spots` 的下标 0
  /// 就成了全量的开头，画出来是窗口外的数据。
  /// 裁完交给 TrendChart，Y 轴范围自然跟着窗口重算 ——
  /// 放大到某几个月时，那几个月之间的高低差才撑得开。
  ({List<TrendPoint> axis, List<TrendSeries> series}) _windowTrend(
    List<TrendPoint> axisAll,
    List<TrendSeries> seriesAll, {
    bool cumulative = false,
  }) {
    final w = trendWindow(axisAll.length, _zoom, _viewStart);
    final axis = sliceRange(axisAll, w.start, w.end);
    final groupSize = math.max(1, (axis.length / 600).ceil());
    return (
      axis: compactTrendPoints(axis, groupSize, cumulative: cumulative),
      series: <TrendSeries>[
        for (final s in seriesAll)
          TrendSeries(
            label: s.label,
            color: s.color,
            points: compactTrendPoints(
              sliceRange(s.points, w.start, w.end),
              groupSize,
              cumulative: cumulative,
            ),
          ),
      ],
    );
  }
}

// ── 通用小部件 ────────────────────────────────────────────────────────────

/// 把「当前模块的可拖拽下标」传给卡片内部的拖拽把手。
///
/// 用 InheritedWidget 是为了不必给 11 个 `_xxxCard` 方法都加一个 dragIndex 参数
/// —— 那会把每个方法的签名都污染一遍。
