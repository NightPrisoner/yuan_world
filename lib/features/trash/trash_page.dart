/// 回收站。
///
/// 删除在这里是**可以后悔的**：笔记和文件夹被删后先进这里，
/// 由用户决定是恢复还是彻底清掉，或者等自动清理到期。
///
/// 三件必须做对的事：
///   1. 「彻底删除」要**二次确认**，并说清"不可恢复"
///   2. 恢复笔记时**连同它所属的文件夹一起恢复**（在数据层做），
///      否则文章回来了却挂在回收站里的文件夹上，看起来像"没恢复"
///   3. **文件夹也要单独列出来** —— 只列笔记的话，一个空文件夹
///      被删掉之后就永远捞不回来了
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../core/motion/app_motion.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_menu.dart';
import '../../data/models.dart';
import '../../data/repositories/note_repository.dart';

class TrashPage extends StatefulWidget {
  const TrashPage({super.key, this.embedded = false});

  /// 嵌在桌面三栏的中间栏里时为 true：不套 Scaffold、不显示返回按钮
  /// （外面已经提供了背景和导航）。手机上作为独立路由时是 false。
  final bool embedded;

  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
  bool _busy = false;

  /// 多选模式。回收站里一次要处理好几项是常态（删了一整个文件夹之后）。
  bool _selecting = false;
  final Set<int> _pickedNotes = <int>{};
  final Set<int> _pickedCols = <int>{};

  bool get _anyPicked => _pickedNotes.isNotEmpty || _pickedCols.isNotEmpty;

  @override
  void initState() {
    super.initState();
    // 页面自己拉一次，避免用户直接切过来时看到的是旧列表
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<AppState>().refreshTrash();
    });
  }

  void _exitSelection() => setState(() {
    _selecting = false;
    _pickedNotes.clear();
    _pickedCols.clear();
  });

  // ── 操作 ────────────────────────────────────────────────────────────────

  /// 这四个操作都用 `_busy` 做重入保护。
  ///
  /// **`_busy` 必须在 finally 里复位。** 以前是"await 成功之后才置回 false"，
  /// 中间任何一次异常（数据库报错、刷新失败）都会把它**永久留在 true** ——
  /// 于是这一页所有按钮的 onTap 都变成 null，整页点不动，
  /// 只能退出去再进来。这类"点不动"最难查，因为界面看起来完全正常。
  Future<void> _runOnce(Future<void> Function() work, String done) async {
    if (_busy) return;
    setState(() => _busy = true);
    Object? failure;
    try {
      await work();
    } catch (e) {
      // **不能咽下去**：删/恢复出错必须留下痕迹。
      // 但也不能 rethrow —— 批量操作里一步失败不该把后面的步骤全掐断。
      failure = e;
      debugPrint('回收站操作失败: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    _toast(failure == null ? done : '有内容没能完成：$failure');
  }

  Future<void> _restoreNotes(List<int> ids) async {
    if (ids.isEmpty) return;
    await _runOnce(
      () => context.read<AppState>().restoreFromTrash(ids),
      '已恢复 ${ids.length} 篇（连同所属文件夹）',
    );
  }

  Future<void> _restoreCols(List<int> ids) async {
    if (ids.isEmpty) return;
    await _runOnce(
      () => context.read<AppState>().restoreCollections(ids),
      '已恢复 ${ids.length} 个文件夹',
    );
  }

  Future<void> _purgeNotes(List<int> ids) async {
    if (ids.isEmpty) return;
    final ok = await _confirm(
      '彻底删除这 ${ids.length} 篇？',
      '删除后无法恢复，图片也会一并清掉。',
    );
    if (ok != true || !mounted) return;
    await _runOnce(
      () => context.read<AppState>().purgeFromTrash(ids),
      '已彻底删除 ${ids.length} 篇',
    );
  }

  Future<void> _purgeCols(List<int> ids) async {
    if (ids.isEmpty) return;
    final ok = await _confirm(
      '彻底删除这 ${ids.length} 个文件夹？',
      '文件夹和里面的笔记都会被永久删除，无法恢复。',
    );
    if (ok != true || !mounted) return;
    await _runOnce(
      () => context.read<AppState>().purgeCollections(ids),
      '已彻底删除 ${ids.length} 个文件夹',
    );
  }

  Future<void> _emptyAll() async {
    final state = context.read<AppState>();
    final n = state.trashedNotes.length + state.trashedCollections.length;
    if (n == 0) return;

    final ok = await _confirm('清空回收站？', '里面的 $n 项将无法恢复。');
    if (ok != true || !mounted) return;

    await _runOnce(() async {
      // 文件夹先删：它的笔记会跟着一起走
      await state.purgeCollections(
        state.trashedCollections.map((c) => c.id).toList(),
      );
      await state.emptyTrash();
    }, '已清空回收站');
    if (mounted) _exitSelection();
  }

  Future<bool?> _confirm(String title, String body) => showDialog<bool>(
    context: context,
    builder: (ctx) {
      final c = ctx.colors;
      return AlertDialog(
        title: Text(title),
        content: Text(
          body,
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
      );
    },
  );

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  // ── 界面 ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final state = context.watch<AppState>();
    final cols = state.trashedCollections;
    final notes = state.trashedNotes;
    final empty = cols.isEmpty && notes.isEmpty;

    // 外面这层原来是"直接返回 Column"—— 那是给桌面中间栏用的（父级已经
    // 提供了背景和 Material）。手机上这一页是**独立路由**，没有 Scaffold
    // 就没有 Material 表面和底色，于是整页渲染成黑底 + 淡黄色的文字
    // （用户的原话："回收站画面很怪"）。
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(c, state, cols.length + notes.length),
        if (_selecting && !empty) _selectionBar(c, cols, notes),
        Divider(height: 1, color: c.separator),
        Expanded(
          child: empty
              ? _emptyState(c)
              : ListView(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  children: [
                    if (cols.isNotEmpty) ...[
                      _sectionLabel(c, '文件夹', cols.length),
                      for (final col in cols) _collectionRow(c, col),
                      const SizedBox(height: 8),
                    ],
                    if (notes.isNotEmpty) ...[
                      _sectionLabel(c, '笔记', notes.length),
                      for (final n in notes) _noteRow(c, n),
                    ],
                  ],
                ),
        ),
      ],
    );

    if (widget.embedded) return body;

    return Scaffold(
      backgroundColor: c.groupedBackground,
      appBar: AppBar(
        backgroundColor: c.groupedBackground,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 19),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text('回收站', style: AppText.headline.copyWith(color: c.label)),
      ),
      body: SafeArea(top: false, child: body),
    );
  }

  Widget _header(AppColors c, AppState state, int total) {
    final days = state.trashRetentionDays;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 16, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('回收站', style: AppText.title2.copyWith(color: c.label)),
                const SizedBox(height: 3),
                GestureDetector(
                  // 天数写在这一行里，点它就能改 —— 单独放一个"设置"入口
                  // 反而让人找不到。0 天 = 永不自动清理。
                  onTap: () => _pickRetentionDays(context, state),
                  child: Text(
                    total == 0
                        ? '空'
                        : '$total 项 · ${days > 0 ? '超过 $days 天自动清理' : '不自动清理'}',
                    style: AppText.caption1.copyWith(
                      color: c.tertiaryLabel,
                      decoration: TextDecoration.underline,
                      decorationColor: c.quaternaryLabel,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (total > 0) ...[
            // 多选：回收站里一次处理好几项是常态
            _pill(
              c,
              _selecting ? '完成' : '多选',
              _selecting ? c.tint : c.secondaryLabel,
              () => _selecting ? _exitSelection() : setState(() => _selecting = true),
            ),
            const SizedBox(width: 8),
            _pill(c, '清空回收站', c.destructive, _emptyAll),
          ],
        ],
      ),
    );
  }

  /// 选自动清理天数。0 = 永不清理。
  Future<void> _pickRetentionDays(BuildContext context, AppState state) async {
    const options = <int>[0, 7, 14, 30, 60, 90, 180];
    final current = state.trashRetentionDays;
    final picked = await showAppMenu<int>(
      context,
      header: '回收站保留多久',
      anchor: AppMenuAnchor(context: context),
      items: <AppMenuItem<int>>[
        for (final d in options)
          AppMenuItem(
            value: d,
            label: d == 0 ? '一直不删，手动清理' : '$d 天',
            icon: d == current
                ? Icons.check_circle_rounded
                : Icons.circle_outlined,
            color: d == current ? context.colors.tint : null,
          ),
      ],
    );
    if (picked == null || !mounted) return;
    state.setTrashRetentionDays(picked);
    // 改成更短的保留期，当场就把超期的清掉 —— 否则用户以为立刻生效，
    // 结果要等下次启动才清。改为 0（永不清理）时什么也不做。
    if (picked > 0) {
      state.repo.purgeTrashOlderThan(picked);
      state.refreshTrash();
    }
  }

  Widget _pill(AppColors c, String label, Color color, VoidCallback onTap) =>
      Pressable(
        onTap: onTap,
        scale: 0.96,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Text(
            label,
            style: AppText.footnote.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );

  /// 多选模式下的一条操作栏。
  Widget _selectionBar(AppColors c, List<Collection> cols, List<Note> notes) {
    final colIds = cols.map((x) => x.id).toSet();
    final noteIds = notes.map((x) => x.id).toSet();

    Widget btn(String label, Color color, VoidCallback? onTap) => Pressable(
      onTap: onTap,
      scale: 0.95,
      haptic: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Text(
          label,
          style: AppText.caption1.copyWith(
            color: onTap == null ? c.quaternaryLabel : color,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );

    // **先 await 上一个，并且先把选中的 id 抄下来。**
    //
    // 两个坑叠在一起：
    //   1. 这两个方法都以 `if (_busy) return;` 开头，而 `_busy = true` 是在
    //      第一个 await 之前同步执行的 —— 不等就调第二个，它会在门口被挡掉；
    //   2. 第一个操作跑完会刷新列表，`_load` 里会把选中集合清空 ——
    //      所以第二个操作**不能再去读 _pickedNotes**，那时它已经是空的了。
    // 表现都是：文件夹和笔记一起选，点"恢复"只回来文件夹，
    // 笔记还躺在回收站里，下一次"清空回收站"就真没了。
    Future<void> restoreAll() async {
      final cols = _pickedCols.toList();
      final notes = _pickedNotes.toList();
      // 先快照再动手：第一步跑完会刷新列表，选中集合可能已经被清掉
      if (cols.isNotEmpty) await _restoreCols(cols);
      if (notes.isNotEmpty) await _restoreNotes(notes);
    }

    Future<void> purgeAll() async {
      final cols = _pickedCols.toList();
      final notes = _pickedNotes.toList();
      if (cols.isNotEmpty) await _purgeCols(cols);
      if (notes.isNotEmpty) await _purgeNotes(notes);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 12, 8),
      child: Row(
        children: [
          Text(
            '已选 ${_pickedCols.length + _pickedNotes.length} 项',
            style: AppText.caption1.copyWith(
              color: _anyPicked ? c.tint : c.tertiaryLabel,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          btn('全选', c.tint, () {
            setState(() {
              _pickedCols
                ..clear()
                ..addAll(colIds);
              _pickedNotes
                ..clear()
                ..addAll(noteIds);
            });
          }),
          btn('反选', c.tint, () {
            setState(() {
              final nextCols = colIds.difference(_pickedCols);
              final nextNotes = noteIds.difference(_pickedNotes);
              _pickedCols
                ..clear()
                ..addAll(nextCols);
              _pickedNotes
                ..clear()
                ..addAll(nextNotes);
            });
          }),
          btn('恢复', c.tint, _anyPicked && !_busy ? restoreAll : null),
          btn('彻底删除', c.destructive, _anyPicked && !_busy ? purgeAll : null),
        ],
      ),
    );
  }

  Widget _sectionLabel(AppColors c, String text, int count) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 10, 24, 6),
    child: Row(
      children: [
        Text(
          text,
          style: AppText.caption1.copyWith(
            color: c.tertiaryLabel,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          '$count',
          style: AppText.caption2.copyWith(color: c.quaternaryLabel),
        ),
      ],
    ),
  );

  /// 一条可勾选的行。多选模式才显示勾选框。
  Widget _tile(
    AppColors c, {
    required IconData icon,
    required Color accent,
    required String title,
    required String subtitle,
    required bool picked,
    required VoidCallback onTap,
    required VoidCallback onRestore,
    required VoidCallback onPurge,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 3),
      child: Pressable(
        onTap: onTap,
        scale: 0.995,
        haptic: false,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: picked ? c.tint.withValues(alpha: 0.12) : null,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            children: [
              if (_selecting) ...[
                Icon(
                  picked
                      ? Icons.check_circle_rounded
                      : Icons.circle_outlined,
                  size: 17,
                  color: picked ? c.tint : c.quaternaryLabel,
                ),
                const SizedBox(width: 10),
              ],
              Icon(icon, size: 17, color: accent),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.callout.copyWith(color: c.label),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption2.copyWith(color: c.tertiaryLabel),
                    ),
                  ],
                ),
              ),
              // 多选模式下不给单行按钮 —— 免得和批量操作打架
              if (!_selecting) ...[
                const SizedBox(width: 8),
                _rowAction(c, '恢复', c.tint, onRestore),
                _rowAction(c, '彻底删除', c.destructive, onPurge),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _rowAction(AppColors c, String label, Color color, VoidCallback onTap) =>
      Pressable(
        onTap: onTap,
        scale: 0.94,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          child: Text(
            label,
            style: AppText.footnote.copyWith(
              color: color,
              fontWeight: label == '恢复' ? FontWeight.w600 : null,
            ),
          ),
        ),
      );

  Widget _collectionRow(AppColors c, Collection col) => _tile(
    c,
    icon: Icons.folder_rounded,
    accent: Color(col.color),
    title: col.name,
    subtitle: <String>[
      if (col.deletedAt != null) '${_ago(col.deletedAt!)}删除',
      '文件夹',
    ].join(' · '),
    picked: _pickedCols.contains(col.id),
    onTap: () {
      if (!_selecting) return;
      setState(() {
        if (!_pickedCols.remove(col.id)) _pickedCols.add(col.id);
      });
    },
    onRestore: () => _restoreCols(<int>[col.id]),
    onPurge: () => _purgeCols(<int>[col.id]),
  );

  Widget _noteRow(AppColors c, Note note) => _tile(
    c,
    icon: Icons.article_rounded,
    accent: c.secondaryLabel,
    title: note.title.trim().isEmpty ? '无标题笔记' : note.title.trim(),
    subtitle: <String>[
      if (note.deletedAt != null) '${_ago(note.deletedAt!)}删除',
      // 显示归属，用户才知道"恢复之后它会回到哪个文件夹"
      if ((note.collectionName ?? '').isNotEmpty) note.collectionName!,
      '${note.charCount} 字',
    ].join(' · '),
    picked: _pickedNotes.contains(note.id),
    onTap: () {
      if (!_selecting) return;
      setState(() {
        if (!_pickedNotes.remove(note.id)) _pickedNotes.add(note.id);
      });
    },
    onRestore: () => _restoreNotes(<int>[note.id]),
    onPurge: () => _purgeNotes(<int>[note.id]),
  );

  Widget _emptyState(AppColors c) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.delete_outline_rounded, size: 44, color: c.quaternaryLabel),
        const SizedBox(height: 12),
        Text(
          '回收站是空的',
          style: AppText.callout.copyWith(color: c.tertiaryLabel),
        ),
        const SizedBox(height: 5),
        Text(
          '删除的笔记和文件夹会先到这里',
          style: AppText.caption1.copyWith(color: c.quaternaryLabel),
        ),
      ],
    ),
  );

  static String _ago(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    if (d.inDays < 30) return '${d.inDays} 天前';
    return '${t.year}年${t.month}月${t.day}日';
  }
}
