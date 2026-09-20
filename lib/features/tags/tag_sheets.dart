/// 给一篇笔记加/删标签。
///
/// 标签功能在数据层和统计里一直有，但**界面上从来没有入口** ——
/// 于是它等于不存在。这个弹窗就是那个入口：读笔记时点一下标题栏的
/// 标签按钮，或者编辑器里点一下。
///
/// 交互上刻意做得"轻"：点一下就加/去掉，不像文件夹那样要"移动"确认 ——
/// 标签本来就是多对多的、随手贴的东西，误点了再点一下就去掉了。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../core/motion/app_motion.dart';
import '../../core/theme/app_theme.dart';

/// 打开某篇笔记的标签编辑弹窗。返回是否改过（调用方据此决定要不要重读）。
Future<bool> showNoteTagEditor(BuildContext context, int noteId) async {
  final changed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _NoteTagSheet(noteId: noteId),
  );
  return changed ?? false;
}

class _NoteTagSheet extends StatefulWidget {
  const _NoteTagSheet({required this.noteId});

  final int noteId;

  @override
  State<_NoteTagSheet> createState() => _NoteTagSheetState();
}

class _NoteTagSheetState extends State<_NoteTagSheet> {
  final TextEditingController _input = TextEditingController();
  late List<String> _tags;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _tags = List<String>.from(
      context.read<AppState>().repo.getNote(widget.noteId)?.tags ??
          const <String>[],
    );
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _persist() {
    context.read<AppState>().setNoteTags(widget.noteId, _tags);
    _changed = true;
  }

  void _add(String raw) {
    final name = raw.trim();
    if (name.isEmpty) return;
    if (_tags.contains(name)) {
      _input.clear();
      return;
    }
    setState(() {
      _tags.add(name);
      _input.clear();
    });
    _persist();
  }

  void _remove(String name) {
    setState(() => _tags.remove(name));
    _persist();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final state = context.watch<AppState>();

    // 候选：库里已经有、但这篇还没有的标签（点一下即添加，不用打字）
    final suggestions = state.tags
        .map((t) => t.name)
        .where((n) => !_tags.contains(n))
        .take(12)
        .toList();

    return Padding(
      // 键盘弹起来时把内容顶上去
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: c.secondaryBackground,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppMetrics.radiusLg),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('标签', style: AppText.headline.copyWith(color: c.label)),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(_changed),
                  child: const Text('完成'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if (_tags.isEmpty)
              Text(
                '还没有标签。输入一个回车就能加上。',
                style: AppText.footnote.copyWith(color: c.tertiaryLabel),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final t in _tags)
                    _TagChip(
                      name: t,
                      onDelete: () => _remove(t),
                    ),
                ],
              ),
            const SizedBox(height: 14),
            Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: c.fill,
                borderRadius: BorderRadius.circular(AppMetrics.radiusSm),
              ),
              child: Row(
                children: [
                  Icon(Icons.label_outline_rounded,
                      size: 16, color: c.tertiaryLabel),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      autofocus: false,
                      textInputAction: TextInputAction.done,
                      onSubmitted: _add,
                      style: AppText.footnote.copyWith(color: c.label),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: '新标签，回车添加',
                        hintStyle:
                            AppText.footnote.copyWith(color: c.tertiaryLabel),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                  Pressable(
                    onTap: () => _add(_input.text),
                    scale: 0.9,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(Icons.add_rounded, size: 18, color: c.tint),
                    ),
                  ),
                ],
              ),
            ),
            if (suggestions.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                '已有标签',
                style: AppText.caption1.copyWith(color: c.tertiaryLabel),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in suggestions)
                    Pressable(
                      onTap: () => _add(s),
                      scale: 0.94,
                      child: _TagChip(name: s, plain: true),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 标签小胶囊。[onDelete] 非空时右边带一个 ×。
class _TagChip extends StatelessWidget {
  const _TagChip({required this.name, this.onDelete, this.plain = false});

  final String name;
  final VoidCallback? onDelete;
  final bool plain;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      padding: EdgeInsets.fromLTRB(10, 5, onDelete == null ? 10 : 4, 5),
      decoration: BoxDecoration(
        color: plain ? c.fill : c.tint.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            name,
            style: AppText.caption1.copyWith(
              color: plain ? c.secondaryLabel : c.tint,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (onDelete != null)
            Pressable(
              onTap: onDelete!,
              scale: 0.85,
              child: Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Icon(Icons.close_rounded, size: 13, color: c.tint),
              ),
            ),
        ],
      ),
    );
  }
}

/// 只读的标签胶囊，阅读页在标题下面用。
class TagPill extends StatelessWidget {
  const TagPill({super.key, required this.name, this.onTap});

  final String name;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: c.fill,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        name,
        style: AppText.caption2.copyWith(color: c.secondaryLabel),
      ),
    );
    if (onTap == null) return pill;
    return Pressable(onTap: onTap!, scale: 0.94, child: pill);
  }
}
