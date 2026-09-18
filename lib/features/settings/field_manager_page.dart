/// 参数管理：头参数 / 尾参数的增删改与排序。
///
/// 这是「参数个数和种类由用户自定义」的落点：
///   - 改名字、改单位、改类型（文本/数字/时间/选项）
///   - 改归属（头 ↔ 尾）
///   - 改默认来源（手动 / 创建时间 / 最后编辑时间）
///   - 拖拽调顺序、删除、恢复出厂
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../core/motion/app_motion.dart';
import '../../core/theme/app_theme.dart';
import '../../data/db/schema.dart';
import '../../data/models.dart';

class FieldManagerPage extends StatefulWidget {
  const FieldManagerPage({super.key});

  @override
  State<FieldManagerPage> createState() => _FieldManagerPageState();
}

class _FieldManagerPageState extends State<FieldManagerPage> {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final state = context.watch<AppState>();
    final head = state.fields.headFields();
    final tail = state.fields.tailFields();

    return Scaffold(
      backgroundColor: c.groupedBackground,
      appBar: AppBar(
        backgroundColor: c.groupedBackground,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 19),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text('文章参数', style: AppText.headline.copyWith(color: c.label)),
        actions: [
          TextButton(
            onPressed: () => _confirmReset(context, state),
            child: Text(
              '恢复默认',
              style: AppText.footnote.copyWith(color: c.tertiaryLabel),
            ),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 60),
        physics: const BouncingScrollPhysics(),
        children: [
          Text(
            '头参数显示在标题和正文之间，尾参数显示在文章末尾。\n'
            '自动来源只是**默认值**：填过就按你写的来，随时能改回自动。',
            style: AppText.caption1.copyWith(color: c.tertiaryLabel, height: 1.7),
          ),
          const SizedBox(height: 16),
          _section(context, state, '头参数', 'head', head),
          const SizedBox(height: 18),
          _section(context, state, '尾参数', 'tail', tail),
        ],
      ),
    );
  }

  Widget _section(
    BuildContext context,
    AppState state,
    String title,
    String slot,
    List<FieldDef> defs,
  ) {
    final c = context.colors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: AppText.footnote.copyWith(
                color: c.secondaryLabel,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${defs.length} 个',
              style: AppText.caption1.copyWith(color: c.quaternaryLabel),
            ),
            const Spacer(),
            Pressable(
              onTap: () => _editField(context, state, slot: slot),
              scale: 0.9,
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(Icons.add_rounded, size: 18, color: c.tint),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (defs.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Text(
              '还没有参数，点右上角 + 加一个',
              style: AppText.caption1.copyWith(color: c.quaternaryLabel),
            ),
          )
        else
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: defs.length,
            onReorderItem: (oldIndex, newIndex) {
              final list = List<FieldDef>.from(defs);
              final item = list.removeAt(oldIndex);
              list.insert(newIndex.clamp(0, list.length), item);
              state.fields.reorderFields(list.map((f) => f.id).toList());
              state.notifyDataChanged();
            },
            itemBuilder: (context, i) => _FieldRow(
              key: ValueKey<int>(defs[i].id),
              def: defs[i],
              index: i,
              onEdit: () => _editField(context, state, existing: defs[i]),
              onDelete: () => _deleteField(context, state, defs[i]),
            ),
          ),
      ],
    );
  }

  Future<void> _deleteField(
    BuildContext context,
    AppState state,
    FieldDef def,
  ) async {
    final c = context.colors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除「${def.name}」？'),
        content: Text(
          '所有笔记上这个参数的内容会一起删掉，无法恢复。',
          style: AppText.callout.copyWith(color: c.secondaryLabel, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: c.destructive),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    state.fields.deleteField(def.id);
    state.notifyDataChanged();
  }

  Future<void> _confirmReset(BuildContext context, AppState state) async {
    final c = context.colors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复默认参数？'),
        content: Text(
          '现在的参数定义会被清空，换成出厂那套（年/月/日/时间 + 自动时间）。\n'
          '笔记里已经填过的内容会一起丢失。',
          style: AppText.callout.copyWith(color: c.secondaryLabel, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: c.destructive),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    state.fields.resetToDefaults(kDefaultFields);
    state.notifyDataChanged();
  }

  Future<void> _editField(
    BuildContext context,
    AppState state, {
    FieldDef? existing,
    String slot = 'head',
  }) async {
    final result = await showDialog<FieldDef>(
      context: context,
      builder: (ctx) => _FieldDialog(existing: existing, slot: slot),
    );
    if (result == null) return;

    if (existing == null) {
      final id = state.fields.createField(
        name: result.name,
        slot: result.slot,
        kind: result.kind,
        unit: result.unit,
        autoSource: result.autoSource,
        options: result.options,
        tailStyle: result.tailStyle,
      );
      if (id == null && context.mounted) {
        _toast(context, '已有同名参数');
        return;
      }
      if (context.mounted) _toast(context, '已添加「${result.name}」');
    } else {
      if (!state.fields.updateField(result)) {
        if (context.mounted) _toast(context, '已有同名参数');
        return;
      }
      if (context.mounted) _toast(context, '已更新「${result.name}」');
    }
    state.notifyDataChanged();
  }

  void _toast(BuildContext context, String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
}

// ── 参数行 ────────────────────────────────────────────────────────────────

class _FieldRow extends StatelessWidget {
  const _FieldRow({
    super.key,
    required this.def,
    required this.index,
    required this.onEdit,
    required this.onDelete,
  });

  final FieldDef def;
  final int index;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  String get _kindLabel => switch (def.kind) {
    'number' => '数字',
    'time' => '时间',
    'select' => '选项',
    _ => '文本',
  };

  String get _autoLabel => switch (def.autoSource) {
    'created' => '创建时间',
    'updated' => '最后编辑',
    _ => '',
  };

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        decoration: BoxDecoration(
          color: c.secondaryBackground,
          borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
          border: Border.all(
            color: c.isDark
                ? c.separator.withValues(alpha: 0.4)
                : const Color(0x0D000000),
            width: 0.5,
          ),
        ),
        child: Row(
          children: [
            ReorderableDragStartListener(
              index: index,
              child: MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 14, 4, 14),
                  child: Icon(Icons.drag_indicator_rounded,
                      size: 17, color: c.quaternaryLabel),
                ),
              ),
            ),
            Expanded(
              child: Pressable(
                onTap: onEdit,
                scale: 0.99,
                haptic: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Text(
                                  def.name,
                                  style:
                                      AppText.callout.copyWith(color: c.label),
                                ),
                                if (def.unit.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  Text(
                                    '后缀「${def.unit}」',
                                    style: AppText.caption2
                                        .copyWith(color: c.quaternaryLabel),
                                  ),
                                ],
                              ],
                            ),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                Text(
                                  _kindLabel,
                                  style: AppText.caption1
                                      .copyWith(color: c.tertiaryLabel),
                                ),
                                if (_autoLabel.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: c.tint.withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      '默认 $_autoLabel',
                                      style: AppText.caption2
                                          .copyWith(color: c.tint),
                                    ),
                                  ),
                                ],
                                if (def.isDash) ...[
                                  const SizedBox(width: 6),
                                  Text(
                                    '合成一行',
                                    style: AppText.caption2
                                        .copyWith(color: c.quaternaryLabel),
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      ),
                      Pressable(
                        onTap: onDelete,
                        scale: 0.88,
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(Icons.delete_outline_rounded,
                              size: 16, color: c.tertiaryLabel),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 编辑对话框 ────────────────────────────────────────────────────────────

class _FieldDialog extends StatefulWidget {
  const _FieldDialog({this.existing, required this.slot});

  final FieldDef? existing;
  final String slot;

  @override
  State<_FieldDialog> createState() => _FieldDialogState();
}

class _FieldDialogState extends State<_FieldDialog> {
  late final TextEditingController _name;
  late final TextEditingController _unit;
  late final TextEditingController _options;
  late String _slot;
  late String _kind;
  late String _auto;
  late String _tailStyle;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _unit = TextEditingController(text: e?.unit ?? '');
    _options = TextEditingController(text: e?.options ?? '');
    _slot = e?.slot ?? widget.slot;
    _kind = e?.kind ?? 'text';
    _auto = e?.autoSource ?? '';
    _tailStyle = e?.tailStyle ?? (_slot == 'tail' ? 'dash' : 'plain');
  }

  @override
  void dispose() {
    _name.dispose();
    _unit.dispose();
    _options.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isNew = widget.existing == null;

    return AlertDialog(
      title: Text(isNew ? '添加参数' : '编辑参数'),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(labelText: '参数名'),
              ),
              const SizedBox(height: 12),
              _choice<String>(
                label: '位置',
                value: _slot,
                options: const <String, String>{'head': '头参数', 'tail': '尾参数'},
                onChanged: (v) => setState(() => _slot = v),
              ),
              const SizedBox(height: 10),
              _choice<String>(
                label: '类型',
                value: _kind,
                options: const <String, String>{
                  'text': '文本',
                  'number': '数字',
                  'time': '时间',
                  'select': '选项',
                },
                onChanged: (v) => setState(() => _kind = v),
              ),
              const SizedBox(height: 10),
              _choice<String>(
                label: '默认来源',
                value: _auto,
                options: const <String, String>{
                  '': '手动填写',
                  'created': '创建时间',
                  'updated': '最后编辑时间',
                },
                onChanged: (v) => setState(() => _auto = v),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _unit,
                decoration: const InputDecoration(
                  labelText: '后缀',
                  hintText: '如「年」「月」，可留空',
                ),
              ),
              if (_kind == 'select') ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _options,
                  decoration: const InputDecoration(
                    labelText: '候选项',
                    hintText: '用逗号分隔，如：好,一般,差',
                  ),
                ),
              ],
              if (_slot == 'tail') ...[
                const SizedBox(height: 10),
                _choice<String>(
                  label: '尾行样式',
                  value: _tailStyle,
                  options: const <String, String>{
                    'dash': '合成一行（——2026年9月14日18:43）',
                    'plain': '单独显示',
                  },
                  onChanged: (v) => setState(() => _tailStyle = v),
                ),
              ],
              if (_auto.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  '选「创建时间」或「最后编辑时间」只是给一个**默认值**，'
                  '笔记里随时可以改成别的内容。',
                  style: AppText.caption1.copyWith(
                    color: c.tertiaryLabel,
                    height: 1.6,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) return;
            final base = widget.existing;
            final def = FieldDef(
              id: base?.id ?? 0,
              name: name,
              slot: _slot,
              kind: _kind,
              unit: _unit.text.trim(),
              autoSource: _auto,
              options: _options.text.trim(),
              tailStyle: _slot == 'tail' ? _tailStyle : 'plain',
              sortOrder: base?.sortOrder ?? 0,
            );
            Navigator.pop(context, def);
          },
          child: const Text('确定'),
        ),
      ],
    );
  }

  Widget _choice<T>({
    required String label,
    required T value,
    required Map<T, String> options,
    required ValueChanged<T> onChanged,
  }) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 66,
          child: Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              label,
              style: AppText.caption1.copyWith(color: c.secondaryLabel),
            ),
          ),
        ),
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final entry in options.entries)
                Pressable(
                  onTap: () => onChanged(entry.key),
                  scale: 0.96,
                  haptic: false,
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: value == entry.key ? c.tint : c.fill,
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      entry.value,
                      style: AppText.caption1.copyWith(
                        color: value == entry.key ? Colors.white : c.label,
                        fontWeight: value == entry.key
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
