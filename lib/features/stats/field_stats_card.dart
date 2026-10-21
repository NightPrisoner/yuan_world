/// 统计页的「参数统计」模块。
///
/// 自己加载数据，外部只要把它作为一个卡片塞进统计页就行 ——
/// 免得为了一个模块把 stats_page 的参数和状态再摊开一层。
///
/// 用的是 [FieldRepository.valueDistribution]，所以：
///   - 手写过的按用户的值算
///   - 没写过的按自动值算（「年」这种就能统计出每年写了多少篇）
///   - 时间、文件夹、隐私空间与页面其他统计采用同一范围
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../core/motion/app_motion.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models.dart';
import '../../data/repositories/stats_repository.dart'
    show ShareItem, ShareStyle, StatsQuery;
import 'stats_charts.dart';

class FieldStatsCard extends StatefulWidget {
  const FieldStatsCard({
    super.key,
    this.query = StatsQuery.empty,
    this.revision = 0,
  });
  final StatsQuery query;
  final int revision;

  @override
  State<FieldStatsCard> createState() => _FieldStatsCardState();
}

class _FieldStatsCardState extends State<FieldStatsCard> {
  List<FieldDef> _defs = const <FieldDef>[];
  int? _selectedId;
  List<({String value, int count})> _dist = const [];
  List<({FieldDef def, double sum, double avg, int count})> _numeric = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(covariant FieldStatsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query ||
        oldWidget.revision != widget.revision) {
      _load();
    }
  }

  void _load() {
    if (!mounted) return;
    final state = context.read<AppState>();
    final fields = state.fields;
    final defs = fields.all();

    // 默认选一个"有东西可看"的：优先数值型（能算总和均值），否则第一个
    final first = defs.isEmpty
        ? null
        : (defs.firstWhere((f) => f.isNumber, orElse: () => defs.first));

    setState(() {
      _defs = defs;
      if (!defs.any((f) => f.id == _selectedId)) _selectedId = first?.id;
      _numeric = fields.numericSummary(query: widget.query);
      _dist = _selectedId == null
          ? const []
          : fields.valueDistribution(_selectedId!, query: widget.query);
      _loading = false;
    });
  }

  void _select(int id) {
    setState(() {
      _selectedId = id;
      _dist = context.read<AppState>().fields.valueDistribution(
        id,
        query: widget.query,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    if (_defs.isEmpty) {
      return Text(
        '还没有参数。去「设置 → 文章参数」加几个，这里就能统计了。',
        style: AppText.footnote.copyWith(color: c.tertiaryLabel, height: 1.6),
      );
    }

    final selected = _defs.where((f) => f.id == _selectedId).firstOrNull;
    final total = _dist.fold<int>(0, (s, d) => s + d.count);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 选一个参数来统计
        SizedBox(
          height: 30,
          child: ListView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            children: [
              for (final def in _defs)
                Pressable(
                  onTap: () => _select(def.id),
                  scale: 0.95,
                  child: AnimatedContainer(
                    duration: AppMotion.fast,
                    curve: AppMotion.enter,
                    margin: const EdgeInsets.only(right: 7),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 11,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: _selectedId == def.id ? c.tint : c.fill,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      def.name,
                      style: AppText.caption1.copyWith(
                        color: _selectedId == def.id
                            ? Colors.white
                            : c.secondaryLabel,
                        fontWeight: _selectedId == def.id
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),

        if (selected != null) _summary(c, selected),

        if (_dist.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Text(
              '这个参数还没有任何取值',
              style: AppText.footnote.copyWith(color: c.tertiaryLabel),
            ),
          )
        else ...[
          if (selected != null)
            Text(
              '取值分布 · 共 $total 篇',
              style: AppText.caption1.copyWith(color: c.tertiaryLabel),
            ),
          const SizedBox(height: 8),
          ShareChart(
            style: ShareStyle.bar,
            items: <ShareItem>[
              for (var i = 0; i < _dist.length && i < 12; i++)
                ShareItem(
                  name: _dist[i].value,
                  // 用调色板循环上色，同一个参数的不同取值一眼能分开
                  color: c.palette[i % c.palette.length].toARGB32(),
                  value: _dist[i].count,
                  extra: 0,
                ),
            ],
          ),
          if (_dist.length > 12)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '只显示前 12 项，共 ${_dist.length} 种取值',
                style: AppText.caption2.copyWith(color: c.quaternaryLabel),
              ),
            ),
        ],
      ],
    );
  }

  /// 数值型参数给一行总和 / 均值。
  Widget _summary(AppColors c, FieldDef selected) {
    final entry = _numeric.where((n) => n.def.id == selected.id).firstOrNull;
    if (entry == null) return const SizedBox.shrink();

    String fmt(double v) =>
        v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(1);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Wrap(
        spacing: 18,
        runSpacing: 6,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '总和',
                style: AppText.caption1.copyWith(color: c.tertiaryLabel),
              ),
              const SizedBox(width: 5),
              Text(
                fmt(entry.sum),
                style: AppText.footnote.copyWith(
                  color: c.label,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '平均',
                style: AppText.caption1.copyWith(color: c.tertiaryLabel),
              ),
              const SizedBox(width: 5),
              Text(
                fmt(entry.avg),
                style: AppText.footnote.copyWith(
                  color: c.label,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '有值',
                style: AppText.caption1.copyWith(color: c.tertiaryLabel),
              ),
              const SizedBox(width: 5),
              Text(
                '${entry.count} 篇',
                style: AppText.footnote.copyWith(
                  color: c.label,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
