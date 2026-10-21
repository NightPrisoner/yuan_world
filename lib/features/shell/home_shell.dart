/// 应用主壳层（响应式入口）。
///
/// 两种形态：
///   - **宽屏（≥1000px，Windows 与平板）**：交给 [DesktopWorkspace]，
///     呈现「分类导航 | 笔记列表 | 阅读/编辑」三栏布局，
///     布局参考小米笔记网页端和 macOS 版 Apple Notes。
///   - **窄屏（安卓手机）**：底部标签栏 + 各页面独立成页。
///
/// 之所以把阈值定在 1000 而不是 900：三栏需要
/// 236(导航) + 316(列表) + 400(阅读) 才不至于挤成一团。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../../core/motion/app_motion.dart';
import '../../core/motion/apple_page_route.dart';
import '../../core/shortcuts/app_shortcuts.dart';
import '../../core/theme/app_theme.dart';
import '../notes/notes_page.dart';
import '../search/search_page.dart';
import '../settings/settings_page.dart';
import '../stats/stats_page.dart';
import '../todos/todos_page.dart';
import 'desktop_workspace.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = _initialTab();

  /// 窄屏快捷键层的焦点节点（宽屏那套在 DesktopWorkspace 里）。
  final FocusNode _shellFocus = FocusNode(debugLabel: 'mobile-shell');

  @override
  void dispose() {
    _shellFocus.dispose();
    super.dispose();
  }

  /// 调试用：设置环境变量 `YW_TAB=1` 可直接启动到指定标签页，
  /// 免去每次手动点击（截图验证、演示时很方便）。仅 debug 构建生效。
  static int _initialTab() {
    if (!kDebugMode) return 0;
    final raw = Platform.environment['YW_TAB'];
    final v = int.tryParse(raw ?? '') ?? 0;
    return v.clamp(0, 3);
  }

  static const _tabs = <_TabSpec>[
    _TabSpec('笔记', Icons.article_outlined, Icons.article),
    _TabSpec(
      '待办',
      Icons.check_circle_outline_rounded,
      Icons.check_circle_rounded,
    ),
    _TabSpec('统计', Icons.insights_outlined, Icons.insights),
    _TabSpec('设置', Icons.tune_outlined, Icons.tune),
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final wide = MediaQuery.sizeOf(context).width >= 1000;

    // 宽屏：三栏工作区（自带 Scaffold）
    if (wide) return const DesktopWorkspace();

    // 窄屏：底部标签栏
    final body = _MobileTabSwitcher(
      index: _index,
      children: const [NotesPage(), TodosPage(), StatsPage(), SettingsPage()],
    );

    // **窄屏也要能按快捷键。**
    //
    // 设置页里那行「快捷键」是两端口径的，而快捷键层原本只在三栏工作区
    // （宽屏）里 —— 手机上外接键盘按 Ctrl+N 毫无反应，那行说明就是骗人的。
    // 手机能做的动作比桌面少，所以只绑真正存在的那几个：新建、搜索、切标签。
    //
    // 结构照抄工作区那条踩过的坑：**快捷键层在外、焦点节点在内**
    // （按键从当前焦点往上冒泡，反过来的话永远收不到）。
    return CallbackShortcuts(
      bindings: bindShortcuts(<String, VoidCallback>{
        AppShortcutIds.newNote: () => createAndOpenNote(context),
        AppShortcutIds.search: () => Navigator.of(context)
            .push(ApplePageRoute<void>(pageBuilder: (_) => const SearchPage())),
        AppShortcutIds.allNotes: () => setState(() => _index = 0),
        AppShortcutIds.todos: () => setState(() => _index = 1),
        AppShortcutIds.stats: () => setState(() => _index = 2),
        AppShortcutIds.settings: () => setState(() => _index = 3),
      }),
      child: Focus(
        focusNode: _shellFocus,
        autofocus: true,
        child: Scaffold(
          backgroundColor: c.groupedBackground,
          body: body,
          bottomNavigationBar: _MobileTabBar(
            index: _index,
            tabs: _tabs,
            onSelect: (i) => setState(() => _index = i),
          ),
        ),
      ),
    );
  }
}

/// 移动端主标签页切换。
///
/// `IndexedStack` 会瞬间把当前页换掉，内容高度变化较大时尤其像闪烁。
/// 每次只让「上一页 → 当前页」做一次短距离过渡；从第一项直接点第四项
/// 不会把中间两个页面扫过去，同时保留四个页面的状态。
class _MobileTabSwitcher extends StatefulWidget {
  const _MobileTabSwitcher({required this.index, required this.children});

  final int index;
  final List<Widget> children;

  @override
  State<_MobileTabSwitcher> createState() => _MobileTabSwitcherState();
}

class _MobileTabSwitcherState extends State<_MobileTabSwitcher>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.normal,
    value: 1,
  );
  late int _activeIndex = widget.index;
  late final Set<int> _visibleIndices = {_activeIndex};
  late List<double> _fromOpacity = [
    for (var i = 0; i < widget.children.length; i++) i == _activeIndex ? 1 : 0,
  ];
  late List<double> _fromOffset = List.filled(widget.children.length, 0);
  late List<double> _toOffset = List.filled(widget.children.length, 0);

  double get _progress => AppMotion.enter.transform(_controller.value);

  double _opacity(int i) =>
      _fromOpacity[i] +
      ((i == _activeIndex ? 1 : 0) - _fromOpacity[i]) * _progress;

  double _offset(int i) =>
      _fromOffset[i] + (_toOffset[i] - _fromOffset[i]) * _progress;

  void _finish(AnimationStatus status) {
    if (status != AnimationStatus.completed || !mounted) return;
    if (_visibleIndices.length == 1) return;
    setState(() {
      _visibleIndices
        ..clear()
        ..add(_activeIndex);
    });
  }

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener(_finish);
  }

  @override
  void didUpdateWidget(covariant _MobileTabSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.index == _activeIndex) return;
    final direction = widget.index > _activeIndex ? 1 : -1;
    // Snapshot all currently painted pages before changing targets. Quick taps
    // must not turn a half-visible page opaque or reset its position.
    final opacity = [
      for (var i = 0; i < widget.children.length; i++) _opacity(i),
    ];
    final offset = [
      for (var i = 0; i < widget.children.length; i++) _offset(i),
    ];
    _visibleIndices.removeWhere((i) => opacity[i] < 0.001);
    if (!_visibleIndices.contains(widget.index)) {
      offset[widget.index] = direction * 0.035;
    }
    _visibleIndices.add(widget.index);
    _fromOpacity = opacity;
    _fromOffset = offset;
    _activeIndex = widget.index;
    _toOffset = [
      for (var i = 0; i < widget.children.length; i++)
        i == _activeIndex ? 0 : -direction * 0.035,
    ];
    if (AppMotion.reduceMotion(context)) {
      _controller.value = 1;
      _visibleIndices
        ..clear()
        ..add(_activeIndex);
    } else {
      _controller.forward(from: 0);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduceMotion(context)) {
      _controller.value = 1;
      _visibleIndices
        ..clear()
        ..add(_activeIndex);
    }
  }

  @override
  void dispose() {
    _controller.removeStatusListener(_finish);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Stack(
          fit: StackFit.expand,
          children: [
            for (var i = 0; i < widget.children.length; i++)
              // Keep every page at a stable keyed position. Moving it between
              // Offstage and the animated branch recreates its State.
              Offstage(
                key: ValueKey<int>(i),
                offstage: !_visibleIndices.contains(i),
                child: TickerMode(
                  enabled: _visibleIndices.contains(i),
                  child: ExcludeFocus(
                    excluding: i != _activeIndex,
                    child: ExcludeSemantics(
                      excluding: i != _activeIndex,
                      child: IgnorePointer(
                        ignoring: i != _activeIndex,
                        child: AnimatedBuilder(
                          animation: _controller,
                          child: widget.children[i],
                          builder: (context, child) {
                            return Opacity(
                              opacity: _opacity(i).clamp(0.0, 1.0),
                              child: Transform.translate(
                                offset: Offset(width * _offset(i), 0),
                                child: child,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _TabSpec {
  const _TabSpec(this.label, this.icon, this.activeIcon);
  final String label;
  final IconData icon;
  final IconData activeIcon;
}

/// 移动端底部标签栏。选中态带缩放与色变，接近 iOS 观感。
class _MobileTabBar extends StatelessWidget {
  const _MobileTabBar({
    required this.index,
    required this.tabs,
    required this.onSelect,
  });

  final int index;
  final List<_TabSpec> tabs;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      decoration: BoxDecoration(
        color: c.isDark
            ? const Color(0xFF1C1C1E).withValues(alpha: 0.92)
            : Colors.white.withValues(alpha: 0.92),
        border: Border(top: BorderSide(color: c.separator, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 54,
          child: Row(
            children: [
              for (var i = 0; i < tabs.length; i++)
                Expanded(
                  child: Pressable(
                    onTap: () => onSelect(i),
                    scale: 0.92,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        AnimatedScale(
                          scale: index == i ? 1.0 : 0.94,
                          duration: AppMotion.respecting(
                            context,
                            AppMotion.fast,
                          ),
                          curve: AppMotion.enter,
                          child: Icon(
                            index == i ? tabs[i].activeIcon : tabs[i].icon,
                            size: 22,
                            color: index == i ? c.tint : c.tertiaryLabel,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          tabs[i].label,
                          style: AppText.caption2.copyWith(
                            color: index == i ? c.tint : c.tertiaryLabel,
                            fontWeight: index == i
                                ? FontWeight.w600
                                : FontWeight.w400,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
