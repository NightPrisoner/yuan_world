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
import '../../core/theme/app_theme.dart';
import '../notes/notes_page.dart';
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
    _TabSpec('待办', Icons.check_circle_outline_rounded, Icons.check_circle_rounded),
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
    final body = IndexedStack(
      index: _index,
      children: const [
        NotesPage(),
        TodosPage(),
        StatsPage(),
        SettingsPage(),
      ],
    );

    return Scaffold(
      backgroundColor: c.groupedBackground,
      body: body,
      bottomNavigationBar: _MobileTabBar(
        index: _index,
        tabs: _tabs,
        onSelect: (i) => setState(() => _index = i),
      ),
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
                          duration: AppMotion.fast,
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
                            fontWeight:
                                index == i ? FontWeight.w600 : FontWeight.w400,
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
