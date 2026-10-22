/// 文集的编辑与选择面板。
///
/// 两个面板：
///   - [showCollectionEditor]：新建 / 重命名文集，带颜色选择
///   - [showCollectionPicker]：把笔记移动到某个文集
///
/// 之所以做成面板而不是整页：文集操作都是"改一个字段"级别的轻量动作，
/// 弹整页会把用户从当前上下文里拽走。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../core/motion/app_motion.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_menu.dart';
import '../../data/models.dart';
// 仓库的一些方法（`setCollectionParent` / `descendantCollectionIds`）在
// **扩展**里，扩展必须在本 library 可见才能调 —— 所以这里要 import 仓库。
import '../../data/repositories/note_repository.dart';

/// 可选的主题色。取自系统的多彩配色，保证互相之间可区分。
const List<int> kCollectionColors = <int>[
  0xFF007AFF, // 蓝
  0xFF34C759, // 绿
  0xFFFF9500, // 橙
  0xFFFF2D55, // 洋红
  0xFFAF52DE, // 紫
  0xFF5856D6, // 靛
  0xFF00C7BE, // 青
  0xFFFFCC00, // 黄
  0xFFFF6482, // 粉
  0xFF8E8E93, // 灰
];

/// 新建或重命名文集。返回 true 表示有改动。
///
/// [parentId] 非空表示在某个文件夹下**新建子文件夹**（嵌套）。
/// 新建 / 重命名文集。返回**文集 id**，取消或失败返回 null。
///
/// 以前返回的是 bool，调用方只能靠"刚建的那个应该排在最后"去猜 ——
/// 可 `createCollection` 写的是 `MIN(sort_order) - 1`，新文集排**最前**，
/// 于是"新建文集并移入"会把笔记塞进一个完全无关的文件夹。
/// 返回真实 id 之后就不用猜了。
Future<int?> showCollectionEditor(
  BuildContext context, {
  Collection? existing,
  int? parentId,
}) async {
  final state = context.read<AppState>();
  final c = context.colors;

  // 表单类弹窗在桌面端用居中对话框；底部面板是手机的交互。
  final useDialog = prefersAnchoredMenu(context);

  final result = useDialog
      ? await showDialog<_CollectionDraft>(
          context: context,
          builder: (ctx) => Dialog(
            backgroundColor: c.secondaryBackground,
            surfaceTintColor: Colors.transparent,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 400),
              child: _CollectionEditor(initial: existing),
            ),
          ),
        )
      : await showModalBottomSheet<_CollectionDraft>(
          context: context,
          isScrollControlled: true,
          backgroundColor: c.secondaryBackground,
          showDragHandle: true,
          builder: (ctx) => Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
            child: _CollectionEditor(initial: existing),
          ),
        );

  if (result == null) return null;

  if (existing == null) {
    final id = await state.createCollection(
      result.name,
      color: result.color,
      parentId: result.parentChanged ? result.parentId : parentId,
    );
    if (id == null && context.mounted) {
      _toast(context, '已有同名文集');
      return null;
    }
    if (context.mounted) _toast(context, '已创建「${result.name}」');
    return id;
  }

  final renamed = await state.renameCollection(existing.id, result.name);
  if (!renamed && context.mounted) {
    _toast(context, '已有同名文集');
    return null;
  }
  await state.setCollectionColor(existing.id, result.color);
  // 上级动过才写：没动过就别碰父子关系（拖动排序、置顶那些都靠它）
  if (result.parentChanged && result.parentId != existing.parentId) {
    state.repo.setCollectionParent(existing.id, result.parentId);
    await state.refresh();
  }
  if (context.mounted) _toast(context, '已更新「${result.name}」');
  return existing.id;
}

/// 选择要把笔记移到哪个文集。
Future<void> showCollectionPicker(BuildContext context, Note note) async {
  final state = context.read<AppState>();

  // 用一个特殊值表示「新建」，避免和 null（未分类）混淆
  const createMarker = -1;

  final picked = await showAppMenu<int>(
    context,
    header: '移动到文集',
    items: <AppMenuItem<int>>[
      AppMenuItem(
        value: createMarker,
        label: '未分类',
        icon: Icons.inbox_rounded,
        color: context.colors.palette[2],
      ),
      for (final col in state.collections)
        AppMenuItem(
          value: col.id,
          label: col.name,
          icon: note.collectionId == col.id
              ? Icons.check_circle_rounded
              : Icons.folder_rounded,
          color: Color(col.color),
        ),
    ],
    footerValue: -2,
    footerLabel: '新建文集…',
    footerIcon: Icons.add_rounded,
  );

  if (picked == null || !context.mounted) return;

  if (picked == -2) {
    // 拿真实的 id，不要假设"刚建的那个排在最后" —— 它排在最前
    final createdId = await showCollectionEditor(context);
    if (createdId == null || !context.mounted) return;
    await state.moveNoteToCollection(note.id, createdId);
    if (!context.mounted) return;
    final name = state.collections
            .where((x) => x.id == createdId)
            .map((x) => x.name)
            .firstOrNull ??
        '文集';
    _toast(context, '已移动到「$name」');
    return;
  }

  final target = picked == createMarker ? null : picked;
  await state.moveNoteToCollection(note.id, target);
  if (!context.mounted) return;
  final name = target == null
      ? '未分类'
      : state.collections
              .where((x) => x.id == target)
              .map((x) => x.name)
              .firstOrNull ??
          '文集';
  _toast(context, '已移动到「$name」');
}

void _toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
  );
}

class _CollectionDraft {
  const _CollectionDraft(
    this.name,
    this.color, {
    this.parentId,
    this.parentChanged = false,
  });
  final String name;
  final int color;

  /// 目标上级文集（null = 顶层）。
  final int? parentId;

  /// 用户**动过**上级没有。
  ///
  /// 必须和"值等于 null"分开：null 是合法目标（移到顶层），
  /// 只看值的话分不清"没改"和"要挪到顶层"。
  final bool parentChanged;
}

class _CollectionEditor extends StatefulWidget {
  const _CollectionEditor({this.initial});
  final Collection? initial;

  @override
  State<_CollectionEditor> createState() => _CollectionEditorState();
}

class _CollectionEditorState extends State<_CollectionEditor> {
  late final TextEditingController _name =
      TextEditingController(text: widget.initial?.name ?? '');
  late int _color = widget.initial?.color ?? kCollectionColors.first;
  late int? _parentId = widget.initial?.parentId;
  bool _parentChanged = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// 「上级文集」那一行：显示当前选择，点一下换。
  Widget _parentPicker(AppColors c) {
    final state = context.read<AppState>();
    final name = _parentId == null
        ? '顶层'
        : state.collections
                .where((x) => x.id == _parentId)
                .map((x) => x.name)
                .firstOrNull ??
            '顶层';

    return Pressable(
      onTap: _pickParent,
      child: Container(
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: c.fill,
          borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
        ),
        child: Row(
          children: [
            Icon(
              _parentId == null ? Icons.layers_outlined : Icons.folder_rounded,
              size: 18,
              color: c.secondaryLabel,
            ),
            const SizedBox(width: 10),
            Text(
              '上级文集',
              style: AppText.footnote.copyWith(color: c.secondaryLabel),
            ),
            const Spacer(),
            Text(name, style: AppText.callout.copyWith(color: c.label)),
            const SizedBox(width: 4),
            Icon(Icons.expand_more_rounded, size: 18, color: c.tertiaryLabel),
          ],
        ),
      ),
    );
  }

  /// 选上级。**排除自己和自己的子孙**：不然能把一个文件夹塞进它自己的
  /// 子树里，树就成了环，之后所有遍历（面包屑、展开、统计）都会卡死。
  Future<void> _pickParent() async {
    final state = context.read<AppState>();
    final self = widget.initial?.id;
    final blocked = <int>{};
    if (self != null) {
      blocked
        ..add(self)
        ..addAll(state.repo.descendantCollectionIds(self));
    }
    // -1 = 顶层（null 会和"取消"撞在一起）
    final picked = await showAppMenu<int>(
      context,
      header: '上级文集',
      items: <AppMenuItem<int>>[
        const AppMenuItem(
          value: -1,
          label: '顶层（不在任何文集里）',
          icon: Icons.layers_outlined,
        ),
        for (final col in state.collections)
          if (!blocked.contains(col.id))
            AppMenuItem(
              value: col.id,
              label: col.name,
              icon: Icons.folder_rounded,
              color: Color(col.color),
            ),
      ],
    );
    if (picked == null || !mounted) return;
    setState(() {
      _parentId = picked == -1 ? null : picked;
      _parentChanged = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isNew = widget.initial == null;
    final canSave = _name.text.trim().isNotEmpty;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isNew ? '新建文集' : '编辑文集',
              style: AppText.headline.copyWith(color: c.label),
            ),
            const SizedBox(height: 16),

            // 名称
            TextField(
              controller: _name,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) {
                if (canSave) {
                  Navigator.pop(
                    context,
                    _CollectionDraft(
                    _name.text.trim(),
                    _color,
                    parentId: _parentId,
                    parentChanged: _parentChanged,
                  ),
                  );
                }
              },
              style: AppText.body.copyWith(color: c.label),
              decoration: InputDecoration(
                hintText: '文集名称',
                prefixIcon: Icon(Icons.folder_rounded, size: 18, color: Color(_color)),
              ),
            ),
            const SizedBox(height: 14),

            // 上级文集：桌面靠"把文件夹拖到另一个上面"来嵌套，
            // **手机上拖不了**，所以这里给一个显式的选择项 ——
            // 没有它，安卓用户永远建不出子文件夹。
            _parentPicker(c),
            const SizedBox(height: 18),

            Text(
              '颜色',
              style: AppText.footnote.copyWith(
                color: c.secondaryLabel,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final color in kCollectionColors)
                  _ColorDot(
                    color: Color(color),
                    selected: _color == color,
                    onTap: () => setState(() => _color = color),
                  ),
              ],
            ),
            const SizedBox(height: 22),

            Row(
              children: [
                Expanded(
                  child: Pressable(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      height: 44,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: c.fill,
                        borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
                      ),
                      child: Text(
                        '取消',
                        style: AppText.callout.copyWith(color: c.label),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Pressable(
                    onTap: canSave
                        ? () => Navigator.pop(
                              context,
                              _CollectionDraft(
                    _name.text.trim(),
                    _color,
                    parentId: _parentId,
                    parentChanged: _parentChanged,
                  ),
                            )
                        : null,
                    child: AnimatedOpacity(
                      duration: AppMotion.respecting(context, AppMotion.fast),
                      opacity: canSave ? 1 : 0.4,
                      child: Container(
                        height: 44,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: c.tint,
                          borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
                        ),
                        child: Text(
                          isNew ? '创建' : '保存',
                          style: AppText.callout.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Pressable(
      onTap: onTap,
      scale: 0.88,
      child: AnimatedContainer(
        duration: AppMotion.respecting(context, AppMotion.fast),
        curve: AppMotion.enter,
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: selected
              ? Border.all(color: color.withValues(alpha: 0.35), width: 3)
              : null,
        ),
        child: selected
            ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
            : null,
      ),
    );
  }
}
