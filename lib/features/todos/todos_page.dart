/// 待办清单页。对标小米笔记的「待办」。
///
/// 交互设计：
///   - 顶部常驻输入框，输入后回车或点 + 直接添加（不用先弹窗，减少一次跳转）
///   - 点圆圈勾选：圆形填充 + 勾号"写"出来 + 文字划删除线，全部走弹簧动画
///   - 长按拖动排序：用 ReorderableDelayedDragStartListener，
///     这样点击（勾选）和长按（拖拽）互不冲突
///   - 左滑删除
///   - 已完成区默认折叠，展开后可一键清空
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../core/motion/app_motion.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_menu.dart';
import '../../core/widgets/app_refresh.dart';
import '../../core/widgets/todo_check.dart';
import '../../data/models.dart';

class TodosPage extends StatefulWidget {
  const TodosPage({super.key});

  @override
  State<TodosPage> createState() => _TodosPageState();
}

class _TodosPageState extends State<TodosPage> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _scroll = ScrollController();
  final ValueNotifier<double> _collapse = ValueNotifier<double>(0);

  bool _showDone = _initialShowDone();
  bool _canSubmit = false;

  /// 调试用：`YW_TODO_DONE=1` 启动时就展开「已完成」区，方便截图与演示。
  /// 仅 debug 构建生效。
  static bool _initialShowDone() {
    if (!kDebugMode) return false;
    return Platform.environment['YW_TODO_DONE'] == '1';
  }

  static const double _expandedHeight = 112;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _input.addListener(() {
      final can = _input.text.trim().isNotEmpty;
      if (can != _canSubmit) setState(() => _canSubmit = can);
    });
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final max = _expandedHeight - kToolbarHeight;
    final t = (_scroll.offset / max).clamp(0.0, 1.0);
    if ((t - _collapse.value).abs() > 0.004) _collapse.value = t;
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _collapse.dispose();
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    context.read<AppState>().addTodo(text);
    _input.clear();
    // 连续录入时不失焦，方便一口气列清单
    _inputFocus.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final c = context.colors;

    final all = state.todoList;
    final open = all.where((t) => !t.isDone).toList();
    final done = all.where((t) => t.isDone).toList();

    return Scaffold(
      backgroundColor: c.groupedBackground,
      body: CustomScrollView(
        controller: _scroll,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        slivers: <Widget>[
          AppRefresh.sliver(onRefresh: () async => state.refreshTodos()),
          _header(c, state, open.length, done.length),
          SliverToBoxAdapter(child: _inputBar(c)),
          if (all.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: EmptyHint(
                icon: Icons.checklist_rounded,
                title: '还没有待办',
                subtitle: '在上方输入框写下第一件事，\n回车即可添加',
              ),
            )
          else ...[
            if (open.isNotEmpty)
              _reorderableOpen(context, state, open)
            else
              SliverToBoxAdapter(child: _allDoneHint(c)),
            if (done.isNotEmpty) ...[
              SliverToBoxAdapter(child: _doneHeader(c, state, done.length)),
              if (_showDone) _doneList(state, done),
            ],
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 110)),
        ],
      ),
    );
  }

  // ── 标题栏 ──────────────────────────────────────────────────────────────

  Widget _header(AppColors c, AppState state, int open, int done) {
    final parts = <String>['未完成 $open'];
    if (done > 0) parts.add('已完成 $done');
    if (state.overdueTodoCount > 0) parts.add('逾期 ${state.overdueTodoCount}');
    final subtitle = parts.join(' · ');

    return SliverAppBar(
      pinned: true,
      expandedHeight: _expandedHeight,
      backgroundColor: c.groupedBackground,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      automaticallyImplyLeading: false,
      titleSpacing: 0,
      title: ValueListenableBuilder<double>(
        valueListenable: _collapse,
        builder: (context, t, _) => Opacity(
          opacity: ((t - 0.55) / 0.45).clamp(0.0, 1.0),
          child: Text('待办', style: AppText.headline.copyWith(color: c.label)),
        ),
      ),
      actions: [
        if (state.overdueTodoCount > 0)
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: c.destructive.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '逾期 ${state.overdueTodoCount}',
                  style: AppText.caption1.copyWith(
                    color: c.destructive,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
      ],
      flexibleSpace: ValueListenableBuilder<double>(
        valueListenable: _collapse,
        builder: (context, t, _) => FlexibleSpaceBar(
          titlePadding: const EdgeInsetsDirectional.only(start: 20, bottom: 12),
          title: Opacity(
            opacity: (1 - t * 1.6).clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, -t * 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '待办',
                    style: AppText.largeTitle.copyWith(color: c.label),
                  ),
                  Text(
                    subtitle,
                    style: AppText.footnote.copyWith(color: c.tertiaryLabel),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── 输入栏 ──────────────────────────────────────────────────────────────

  Widget _inputBar(AppColors c) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Container(
        decoration: BoxDecoration(
          color: c.secondaryBackground,
          borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
          border: Border.all(
            color: c.isDark
                ? c.separator.withValues(alpha: 0.5)
                : const Color(0x14000000),
            width: 0.5,
          ),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        child: Row(
          children: [
            Icon(Icons.add_rounded, size: 19, color: c.tertiaryLabel),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _input,
                focusNode: _inputFocus,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                style: AppText.callout.copyWith(color: c.label),
                decoration: InputDecoration(
                  isDense: true,
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                  hintText: '添加待办…',
                  hintStyle: AppText.callout.copyWith(color: c.tertiaryLabel),
                ),
              ),
            ),
            // 有内容时才出现，且用弹簧缩放，避免一直占着一个死按钮
            SpringAnimatedValue(
              value: _canSubmit ? 1 : 0,
              builder: (context, v) => Transform.scale(
                scale: v,
                child: Opacity(
                  opacity: v.clamp(0.0, 1.0),
                  child: GlassIconButton(
                    icon: Icons.arrow_upward_rounded,
                    size: 28,
                    iconSize: 15,
                    onTap: _canSubmit ? _submit : null,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── 未完成（可拖拽排序） ────────────────────────────────────────────────

  Widget _reorderableOpen(
    BuildContext context,
    AppState state,
    List<Todo> open,
  ) {
    final c = context.colors;
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverReorderableList(
        itemCount: open.length,
        // onReorderItem 给的 newIndex 已经处理过"移除后下标偏移"，
        // 不需要像旧的 onReorder 那样手动 newIndex -= 1
        onReorderItem: (oldIndex, newIndex) {
          final list = List<Todo>.from(open);
          final item = list.removeAt(oldIndex);
          list.insert(newIndex, item);
          state.reorderTodos(list);
        },
        itemBuilder: (context, index) {
          final t = open[index];
          return Dismissible(
            key: ValueKey<int>(t.id),
            direction: DismissDirection.endToStart,
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 20),
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: c.destructive,
                borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
              ),
              child: const Icon(
                Icons.delete_outline_rounded,
                color: Colors.white,
                size: 20,
              ),
            ),
            onDismissed: (_) => state.deleteTodo(t.id),
            child: ReorderableDelayedDragStartListener(
              index: index,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _TodoTile(
                  todo: t,
                  onToggle: () => state.toggleTodo(t),
                  onEdit: () => _editDialog(state, t),
                  onDue: (a) => _dueSheet(state, t, a),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _allDoneHint(AppColors c) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 22),
        decoration: BoxDecoration(
          color: c.secondaryBackground,
          borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
        ),
        child: Column(
          children: [
            Icon(Icons.check_circle_rounded, size: 26, color: c.palette[1]),
            const SizedBox(height: 8),
            Text('全部完成了', style: AppText.callout.copyWith(color: c.label)),
          ],
        ),
      ),
    );
  }

  // ── 已完成 ──────────────────────────────────────────────────────────────

  Widget _doneHeader(AppColors c, AppState state, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 6),
      child: Row(
        children: [
          Pressable(
            onTap: () => setState(() => _showDone = !_showDone),
            scale: 0.97,
            child: Row(
              children: [
                AnimatedRotation(
                  turns: _showDone ? 0.25 : 0,
                  duration: AppMotion.respecting(context, AppMotion.fast),
                  curve: AppMotion.enter,
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: c.tertiaryLabel,
                  ),
                ),
                const SizedBox(width: 2),
                Text(
                  '已完成 $count',
                  style: AppText.footnote.copyWith(
                    color: c.secondaryLabel,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          TextButton(
            onPressed: () => _confirmClear(state, count),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              '清空',
              style: AppText.footnote.copyWith(color: c.destructive),
            ),
          ),
        ],
      ),
    );
  }

  Widget _doneList(AppState state, List<Todo> done) {
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      sliver: SliverList.builder(
        itemCount: done.length,
        itemBuilder: (context, i) {
          final t = done[i];
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _TodoTile(
              todo: t,
              onToggle: () => state.toggleTodo(t),
              onEdit: () => _editDialog(state, t),
              onDue: (a) => _dueSheet(state, t, a),
            ),
          );
        },
      ),
    );
  }

  // ── 弹层 ────────────────────────────────────────────────────────────────

  Future<void> _editDialog(AppState state, Todo t) async {
    final controller = TextEditingController(text: t.content);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('编辑待办'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: null,
          decoration: const InputDecoration(hintText: '内容'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result != null && result.trim().isNotEmpty) {
      state.updateTodoContent(t.id, result);
    }
    controller.dispose();
  }

  Future<void> _dueSheet(
    AppState state,
    Todo t, [
    AppMenuAnchor? anchor,
  ]) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final options = <(String, DateTime?)>[
      ('今天', today),
      ('明天', today.add(const Duration(days: 1))),
      ('三天后', today.add(const Duration(days: 3))),
      ('下周一', today.add(Duration(days: 7 - now.weekday + 1))),
      ('清除截止时间', null),
    ];

    final picked = await showAppMenu<int>(
      context,
      anchor: anchor,
      header: '截止时间',
      items: <AppMenuItem<int>>[
        for (var i = 0; i < options.length; i++)
          AppMenuItem(
            value: i,
            label: options[i].$1,
            icon: options[i].$2 == null
                ? Icons.event_busy_rounded
                : (t.dueAt != null && _sameDay(t.dueAt!, options[i].$2!)
                      ? Icons.check_circle_rounded
                      : Icons.event_rounded),
            color: options[i].$2 == null ? context.colors.destructive : null,
          ),
      ],
    );

    if (picked == null) return;
    state.setTodoDue(t.id, options[picked].$2);
  }

  Future<void> _confirmClear(AppState state, int count) async {
    final c = context.colors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空已完成？'),
        content: Text(
          '将删除 $count 条已完成的待办，此操作不可撤销。',
          style: AppText.callout.copyWith(color: c.secondaryLabel),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: c.destructive),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (ok == true) state.clearCompletedTodos();
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

// ── 单条待办 ──────────────────────────────────────────────────────────────

class _TodoTile extends StatelessWidget {
  const _TodoTile({
    required this.todo,
    required this.onToggle,
    required this.onEdit,
    required this.onDue,
  });

  final Todo todo;
  final VoidCallback onToggle;
  final VoidCallback onEdit;
  final void Function(AppMenuAnchor anchor) onDue;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final done = todo.isDone;

    return AnimatedContainer(
      duration: AppMotion.respecting(context, AppMotion.fast),
      curve: AppMotion.enter,
      decoration: BoxDecoration(
        color: c.secondaryBackground,
        borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
        border: Border.all(
          color: c.isDark
              ? c.separator.withValues(alpha: 0.4)
              : const Color(0x0F000000),
          width: 0.5,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(6, 6, 10, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          TodoCheck(checked: done, onChanged: (_) => onToggle()),
          Expanded(
            child: GestureDetector(
              onTap: onEdit,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedStrikethrough(
                      done: done,
                      child: AnimatedDefaultTextStyle(
                        duration: AppMotion.respecting(context, AppMotion.fast),
                        curve: AppMotion.enter,
                        style: AppText.callout.copyWith(
                          color: done ? c.tertiaryLabel : c.label,
                          height: 1.4,
                        ),
                        child: Text(todo.content),
                      ),
                    ),
                    if (todo.dueAt != null || todo.priority > 0) ...[
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          if (todo.priority > 0) ...[
                            _priorityChip(c),
                            const SizedBox(width: 6),
                          ],
                          if (todo.dueAt != null) _dueChip(c),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (!done)
            Builder(
              builder: (btnCtx) => Pressable(
                onTap: () => onDue(AppMenuAnchor(context: btnCtx)),
                scale: 0.9,
                child: Padding(
                  padding: const EdgeInsets.all(6),
                  child: Icon(
                    todo.dueAt == null
                        ? Icons.event_outlined
                        : Icons.event_rounded,
                    size: 17,
                    color: todo.isOverdue ? c.destructive : c.tertiaryLabel,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _priorityChip(AppColors c) {
    final (label, color) = switch (todo.priority) {
      3 => ('高', c.palette[3]),
      2 => ('中', c.palette[2]),
      _ => ('低', c.palette[0]),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: AppText.caption2.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _dueChip(AppColors c) {
    final overdue = todo.isOverdue;
    final color = overdue ? c.destructive : c.tertiaryLabel;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.schedule_rounded, size: 11, color: color),
        const SizedBox(width: 3),
        Text(
          todo.dueLabel,
          style: AppText.caption2.copyWith(
            color: color,
            fontWeight: overdue ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ],
    );
  }
}
