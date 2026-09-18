/// 统计时间范围的选取器。
///
/// 两种方式并排给：
///   - **选择**：月历网格，`《 年 》` 切年、`< 月 >` 切月，点两下选出起止
///   - **输入**：直接敲日期，适合"就要 2023-06-01 到 2023-08-31"这种精确区间
///
/// 为什么不用 Material 的 `showDateRangePicker`：它在窄屏上是**全屏页**，
/// 在小屏上直接盖掉整个统计页；而且年份要点头部才能切，没有 `《》`。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/motion/app_motion.dart';
import '../../core/theme/app_theme.dart';

/// 弹出范围选择器。取消返回 null。
Future<DateTimeRange?> showRangePicker(
  BuildContext context, {
  DateTimeRange? initial,
  DateTime? earliest,
  DateTime? latest,
}) {
  return showDialog<DateTimeRange>(
    context: context,
    builder: (ctx) => _RangePickerDialog(
      initial: initial,
      earliest: earliest,
      latest: latest,
    ),
  );
}

class _RangePickerDialog extends StatefulWidget {
  const _RangePickerDialog({this.initial, this.earliest, this.latest});

  final DateTimeRange? initial;
  final DateTime? earliest;
  final DateTime? latest;

  @override
  State<_RangePickerDialog> createState() => _RangePickerDialogState();
}

class _RangePickerDialogState extends State<_RangePickerDialog> {
  /// 0 = 选择（月历），1 = 输入（手打）
  int _mode = 0;

  late DateTime _month;
  DateTime? _start;
  DateTime? _end;

  final _fromInput = TextEditingController();
  final _toInput = TextEditingController();
  String? _inputError;

  @override
  void initState() {
    super.initState();
    final s = widget.initial?.start;
    final e = widget.initial?.end;
    _start = s;
    _end = e;
    _month = DateTime((s ?? DateTime.now()).year, (s ?? DateTime.now()).month);
    if (s != null) _fromInput.text = _fmt(s);
    if (e != null) _toInput.text = _fmt(e);
  }

  @override
  void dispose() {
    _fromInput.dispose();
    _toInput.dispose();
    super.dispose();
  }

  static String _fmt(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  void _shiftMonth(int delta) => setState(
    () => _month = DateTime(_month.year, _month.month + delta),
  );

  void _shiftYear(int delta) => setState(
    () => _month = DateTime(_month.year + delta, _month.month),
  );

  /// 点日期：第一次定起点，第二次定终点；再点则重新开始。
  void _tapDay(DateTime d) {
    setState(() {
      if (_start == null || _end != null) {
        _start = d;
        _end = null;
      } else if (d.isBefore(_start!)) {
        // 第二次点的比起点还早 → 把它当新起点，原来的起点当终点。
        // 直接忽略的话用户会觉得"点了没反应"。
        _end = _start;
        _start = d;
      } else {
        _end = d;
      }
      _fromInput.text = _start == null ? '' : _fmt(_start!);
      _toInput.text = _end == null ? '' : _fmt(_end!);
    });
  }

  /// 手打模式：解析两个输入框。
  void _submitInput() {
    final a = _parse(_fromInput.text);
    final b = _parse(_toInput.text);
    if (a == null || b == null) {
      setState(() => _inputError = '格式要像 2023-06-01');
      return;
    }
    final range = a.isAfter(b)
        ? DateTimeRange(start: b, end: a)
        : DateTimeRange(start: a, end: b);
    Navigator.pop(context, range);
  }

  /// 宽松解析：`2023-6-1`、`2023/6/1`、`20230601` 都认。
  static DateTime? _parse(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;

    final m = RegExp(r'^(\d{4})\D+(\d{1,2})\D+(\d{1,2})$').firstMatch(s);
    if (m != null) {
      return _safe(int.parse(m.group(1)!), int.parse(m.group(2)!),
          int.parse(m.group(3)!));
    }
    final compact = RegExp(r'^(\d{4})(\d{2})(\d{2})$').firstMatch(s);
    if (compact != null) {
      return _safe(int.parse(compact.group(1)!), int.parse(compact.group(2)!),
          int.parse(compact.group(3)!));
    }
    return null;
  }

  /// 校验真实存在的日期 —— `2023-02-30` 要挡住，不能悄悄变成 3 月 2 日。
  static DateTime? _safe(int y, int m, int d) {
    if (m < 1 || m > 12 || d < 1 || d > 31) return null;
    final dt = DateTime(y, m, d);
    if (dt.year != y || dt.month != m || dt.day != d) return null;
    return dt;
  }

  void _confirm() {
    if (_start == null) return;
    Navigator.pop(
      context,
      DateTimeRange(start: _start!, end: _end ?? _start!),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Dialog(
      backgroundColor: c.secondaryBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '统计时间范围',
                style: AppText.headline.copyWith(color: c.label),
              ),
              const SizedBox(height: 10),
              _modeTabs(c),
              const SizedBox(height: 12),
              if (_mode == 0) _calendar(c) else _manual(c),
              const SizedBox(height: 12),
              _footer(c),
            ],
          ),
        ),
      ),
    );
  }

  Widget _modeTabs(AppColors c) {
    Widget tab(int i, String label, IconData icon) {
      final on = _mode == i;
      return Expanded(
        child: Pressable(
          onTap: () => setState(() {
            _mode = i;
            _inputError = null;
          }),
          scale: 0.98,
          child: AnimatedContainer(
            duration: AppMotion.fast,
            padding: const EdgeInsets.symmetric(vertical: 7),
            decoration: BoxDecoration(
              color: on ? c.tint.withValues(alpha: 0.14) : null,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 15, color: on ? c.tint : c.secondaryLabel),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: AppText.footnote.copyWith(
                    color: on ? c.tint : c.secondaryLabel,
                    fontWeight: on ? FontWeight.w600 : null,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: c.fill,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          tab(0, '选择', Icons.calendar_month_rounded),
          tab(1, '输入', Icons.keyboard_rounded),
        ],
      ),
    );
  }

  // ── 月历 ────────────────────────────────────────────────────────────────

  Widget _calendar(AppColors c) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            _navBtn(c, Icons.keyboard_double_arrow_left_rounded, '上一年',
                () => _shiftYear(-1)),
            _navBtn(c, Icons.chevron_left_rounded, '上一月',
                () => _shiftMonth(-1)),
            Expanded(
              child: Center(
                child: Text(
                  '${_month.year} 年 ${_month.month} 月',
                  style: AppText.callout.copyWith(
                    color: c.label,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            _navBtn(c, Icons.chevron_right_rounded, '下一月',
                () => _shiftMonth(1)),
            _navBtn(c, Icons.keyboard_double_arrow_right_rounded, '下一年',
                () => _shiftYear(1)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final w in const <String>['一', '二', '三', '四', '五', '六', '日'])
              Expanded(
                child: Center(
                  child: Text(
                    w,
                    style: AppText.caption2.copyWith(color: c.tertiaryLabel),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        _grid(c),
      ],
    );
  }

  Widget _navBtn(AppColors c, IconData icon, String tip, VoidCallback onTap) =>
      Tooltip(
        message: tip,
        child: Pressable(
          onTap: onTap,
          scale: 0.9,
          child: SizedBox(
            width: 34,
            height: 30,
            child: Icon(icon, size: 18, color: c.secondaryLabel),
          ),
        ),
      );

  /// 6 行 × 7 列。**行数固定为 6**，否则切月份时表格高度会跳。
  Widget _grid(AppColors c) {
    final first = DateTime(_month.year, _month.month, 1);
    // weekday：周一 = 1 … 周日 = 7，所以周一的偏移是 0
    final lead = first.weekday - 1;
    final daysInMonth = DateTime(_month.year, _month.month + 1, 0).day;
    final today = _day(DateTime.now());

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var row = 0; row < 6; row++)
          Row(
            children: [
              for (var col = 0; col < 7; col++)
                Expanded(
                  child: _dayCell(
                    c,
                    row * 7 + col - lead + 1,
                    daysInMonth,
                    today,
                  ),
                ),
            ],
          ),
      ],
    );
  }

  Widget _dayCell(AppColors c, int day, int daysInMonth, DateTime today) {
    if (day < 1 || day > daysInMonth) {
      return const SizedBox(height: 32);
    }
    final d = DateTime(_month.year, _month.month, day);
    final isStart = _start != null && _day(_start!) == d;
    final isEnd = _end != null && _day(_end!) == d;
    final inRange = _start != null &&
        _end != null &&
        d.isAfter(_day(_start!)) &&
        d.isBefore(_day(_end!));
    final edge = isStart || isEnd;

    return Pressable(
      onTap: () => _tapDay(d),
      scale: 0.9,
      haptic: false,
      child: Container(
        height: 32,
        margin: const EdgeInsets.all(1),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: edge
              ? c.tint
              : (inRange ? c.tint.withValues(alpha: 0.14) : null),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Text(
          '$day',
          style: AppText.footnote.copyWith(
            color: edge
                ? Colors.white
                : (d == today ? c.tint : c.label),
            fontWeight: edge || d == today ? FontWeight.w700 : null,
          ),
        ),
      ),
    );
  }

  // ── 手打 ────────────────────────────────────────────────────────────────

  Widget _manual(AppColors c) {
    Widget field(TextEditingController ctl, String label) => TextField(
      controller: ctl,
      keyboardType: TextInputType.datetime,
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.allow(RegExp(r'[0-9\-/.]')),
        LengthLimitingTextInputFormatter(10),
      ],
      decoration: InputDecoration(
        labelText: label,
        hintText: '2023-06-01',
        isDense: true,
      ),
      style: AppText.callout.copyWith(color: c.label),
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: field(_fromInput, '开始')),
            const SizedBox(width: 10),
            Expanded(child: field(_toInput, '结束')),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          _inputError ?? '支持 2023-06-01 / 2023/6/1 / 20230601',
          style: AppText.caption1.copyWith(
            color: _inputError == null ? c.tertiaryLabel : c.destructive,
          ),
        ),
      ],
    );
  }

  // ── 底部 ────────────────────────────────────────────────────────────────

  Widget _footer(AppColors c) {
    final start = _start;
    final end = _end;
    final label = start == null
        ? '还没选日期'
        : '${_fmt(start)}  至  ${_fmt(end ?? start)}';

    return Row(
      children: [
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption1.copyWith(
              color: start == null ? c.tertiaryLabel : c.label,
              fontWeight: start == null ? null : FontWeight.w600,
            ),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          // 手打模式走另一条提交路径
          onPressed: _mode == 0 ? (_start == null ? null : _confirm) : _submitInput,
          child: const Text('确定'),
        ),
      ],
    );
  }
}
