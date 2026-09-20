/// 文章自定义参数（头参数 / 尾参数）的呈现。
///
/// 头和尾**共用同一套交互**，这是刻意的：
///   1. 阅读态、编辑态平时都只是**一行普通文字**，不抢眼
///   2. 进了编辑态，行尾多一个**小编辑图标**
///   3. 点图标才展开成一排可编辑的块，带「回到自动 / 完成」
///
/// 之前头和尾各写了一套，结果头参数一进编辑态就把框全铺开，
/// 和尾参数的交互对不上。合并成一个 [FieldLine] 之后这类偏差不可能再出现。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../app_state.dart';
import '../../../core/motion/app_motion.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models.dart';
import '../../../data/repositories/field_repository.dart';
import '../../../data/repositories/note_repository.dart';

/// 一行参数。[slot] 为 `head` 时左对齐，`tail` 时右对齐并带 `——` 前缀。
class FieldLine extends StatefulWidget {
  const FieldLine({
    super.key,
    required this.noteId,
    required this.slot,
    this.editable = true,
    this.onChanged,
  });

  final int noteId;

  /// `head` | `tail`
  final String slot;

  /// 阅读态传 false：只有普通文字，没有编辑图标。
  final bool editable;

  final VoidCallback? onChanged;

  @override
  State<FieldLine> createState() => _FieldLineState();
}

class _FieldLineState extends State<FieldLine> {
  List<FieldEntry> _entries = const <FieldEntry>[];
  bool _editing = false;

  // 控制器必须挂在 State 上。在 build 里 new 一个的话，
  // 每次重建都会换新实例，焦点和光标位置全丢，根本没法输入。
  final Map<int, TextEditingController> _controllers = {};

  bool get _isTail => widget.slot == 'tail';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(FieldLine old) {
    super.didUpdateWidget(old);
    if (old.noteId != widget.noteId || old.slot != widget.slot) _load();
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _load() {
    if (!mounted) return;
    final state = context.read<AppState>();
    final note = state.repo.getNote(widget.noteId);
    if (note == null) return;

    final entries = state.fields.entriesFor(note, slot: widget.slot);
    for (final c in _controllers.values) {
      c.dispose();
    }
    _controllers.clear();
    for (final e in entries) {
      _controllers[e.def.id] = TextEditingController(text: e.value);
    }

    setState(() {
      _entries = entries;
      _editing = false;
    });
  }

  /// 平时显示的那一行文字。
  ///
  /// 尾参数拼上 `——` 前缀；头参数就是各段顺次排开。
  /// 空值不参与，免得留下多余空格。
  ///
  /// **间隔和尾参数保持一致（直接连排，不加空格）**。
  /// 之前头参数用两个空格连接，和尾参数那种紧排放在一起看就是"忽宽忽窄"；
  /// 而且 年/月/日/时间 这些单位本身就起了分隔作用，再加空格是多余的。
  String get _display {
    if (_isTail) return FieldRepository.composeDashedTail(_entries);
    return _entries
        .where((e) => !e.isEmpty)
        .map((e) => '${e.value}${e.def.unit}')
        .join();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (_entries.isEmpty) return const SizedBox.shrink();

    final line = _display;
    if (line.isEmpty && !_editing) return const SizedBox.shrink();

    final align =
        _isTail ? Alignment.centerRight : Alignment.centerLeft;

    return Align(
      alignment: align,
      child: Padding(
        padding: EdgeInsets.only(top: _isTail ? 22 : 0, bottom: 4),
        child: _editing
            ? _editor(c)
            : Pressable(
                // 只有编辑态才给点：阅读态它就该是死的文字
                onTap: widget.editable
                    ? () => setState(() => _editing = true)
                    : null,
                scale: 0.99,
                haptic: false,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      line,
                      style: AppText.footnote.copyWith(
                        color: c.secondaryLabel,
                        height: 1.6,
                      ),
                    ),
                    if (widget.editable) ...[
                      const SizedBox(width: 8),
                      Icon(Icons.edit_rounded,
                          size: 12, color: c.quaternaryLabel),
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  /// 展开成一排可编辑的块。
  Widget _editor(AppColors c) {
    return Column(
      crossAxisAlignment:
          _isTail ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final e in _entries) _editBlock(c, e),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Pressable(
              onTap: () {
                // 清掉全部手动值 → 整行回到自动
                for (final e in _entries) {
                  if (e.def.isAuto) {
                    context
                        .read<AppState>()
                        .fields
                        .clearValue(widget.noteId, e.def.id);
                  }
                }
                _load();
                widget.onChanged?.call();
              },
              scale: 0.95,
              child: Text(
                '回到自动',
                style: AppText.caption1.copyWith(color: c.tertiaryLabel),
              ),
            ),
            const SizedBox(width: 14),
            Pressable(
              onTap: () {
                _load();
                widget.onChanged?.call();
              },
              scale: 0.95,
              child: Text(
                '完成',
                style: AppText.caption1.copyWith(
                  color: c.tint,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _editBlock(AppColors c, FieldEntry e) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: c.secondaryBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: e.isOverridden
              ? c.tint.withValues(alpha: 0.55)
              : c.tint.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IntrinsicWidth(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: e.def.isTime ? 40 : 22,
                maxWidth: 110,
              ),
              child: TextField(
                controller: _controllers[e.def.id],
                textAlign: TextAlign.center,
                style: AppText.caption1.copyWith(
                  color: c.label,
                  fontWeight:
                      e.isOverridden ? FontWeight.w600 : FontWeight.w400,
                ),
                keyboardType: e.def.isNumber
                    ? TextInputType.number
                    : TextInputType.text,
                onChanged: (v) {
                  final fields = context.read<AppState>().fields;
                  if (v.trim().isEmpty) {
                    fields.clearValue(widget.noteId, e.def.id);
                  } else {
                    fields.setValue(widget.noteId, e.def.id, v.trim());
                  }
                },
                decoration: InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  hintText: e.def.isTime ? '__:__' : '　',
                  hintStyle:
                      AppText.caption1.copyWith(color: c.quaternaryLabel),
                ),
              ),
            ),
          ),
          if (e.def.unit.isNotEmpty) ...[
            const SizedBox(width: 2),
            Text(
              e.def.unit,
              style: AppText.caption1.copyWith(color: c.secondaryLabel),
            ),
          ],
        ],
      ),
    );
  }
}

// ── 两个语义化的别名，调用处读起来更清楚 ──────────────────────────────────

/// 头参数：标题与正文之间。
class HeadFieldsBlock extends StatelessWidget {
  const HeadFieldsBlock({
    super.key,
    required this.noteId,
    this.editable = true,
    this.onChanged,
  });

  final int noteId;
  final bool editable;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) => FieldLine(
    noteId: noteId,
    slot: 'head',
    editable: editable,
    onChanged: onChanged,
  );
}

/// 尾参数：文章末尾，右对齐一行 `——2026年9月14日18:43`。
class TailFieldsLine extends StatelessWidget {
  const TailFieldsLine({
    super.key,
    required this.noteId,
    this.editable = true,
    this.onChanged,
  });

  final int noteId;
  final bool editable;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) => FieldLine(
    noteId: noteId,
    slot: 'tail',
    editable: editable,
    onChanged: onChanged,
  );
}
