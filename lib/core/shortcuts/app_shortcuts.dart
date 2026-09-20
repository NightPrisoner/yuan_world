/// 全应用快捷键的**唯一定义处**。
///
/// 为什么非要集中定义：快捷键最容易出的错不是"没绑上"，而是
/// **帮助面板里写的和实际绑定的对不上** —— 用户照着按没反应，
/// 只会以为软件坏了。所以这里只放定义（谁、什么键、干什么），
/// 各处按 [AppShortcut.id] 去绑自己能处理的那几个，
/// 帮助面板也读同一份，想不一致都难。
///
/// 绑定方式（见 `desktop_workspace.dart` / `note_editor_page.dart`）：
///
/// ```dart
/// CallbackShortcuts(
///   bindings: bindShortcuts(<String, VoidCallback>{
///     AppShortcutIds.newNote: () => _createNote(state),
///   }),
///   child: ...,
/// )
/// ```
///
/// ## 只挑"非得有"的
///
/// 没有做「命令面板」，也没有给每个按钮配快捷键：记不住的快捷键等于没有，
/// 而占用了 `Ctrl+字母` 反而会把用户习惯的键抢走。这一版只覆盖
/// 日常最常做的几件事（新建 / 搜索 / 编辑 / 保存 / 切分区 / 看帮助）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// 快捷键的 id。绑定和帮助面板都用它对照，别写字符串字面量。
abstract final class AppShortcutIds {
  static const String newNote = 'new-note';
  static const String search = 'search';
  static const String edit = 'edit';
  static const String save = 'save';
  static const String allNotes = 'section-all';
  static const String archived = 'section-archived';
  static const String todos = 'section-todos';
  static const String stats = 'section-stats';
  static const String trash = 'section-trash';
  static const String settings = 'section-settings';
  static const String help = 'help';
  static const String exitFullscreen = 'exit-fullscreen';
}

/// 一条快捷键。
class AppShortcut {
  const AppShortcut({
    required this.id,
    required this.label,
    required this.group,
    required this.activators,
  });

  final String id;

  /// 帮助面板里显示的动作名，例如「新建笔记」。
  final String label;

  /// 帮助面板里的分组，例如「笔记」。
  final String group;

  /// 实际绑定的按键。**第一个是 Windows/Linux 用的**，
  /// 后面可以跟 macOS 的 ⌘ 变体（帮助面板只显示第一个）。
  final List<ShortcutActivator> activators;
}

/// 所有快捷键。**顺序就是帮助面板里的顺序。**
const List<AppShortcut> kAppShortcuts = <AppShortcut>[
  // ── 笔记 ──────────────────────────────────────────────────────────────
  AppShortcut(
    id: AppShortcutIds.newNote,
    label: '新建笔记',
    group: '笔记',
    activators: _kN,
  ),
  AppShortcut(
    id: AppShortcutIds.search,
    label: '搜索笔记',
    group: '笔记',
    activators: _kF,
  ),
  AppShortcut(
    id: AppShortcutIds.edit,
    label: '编辑当前笔记 / 结束编辑',
    group: '笔记',
    activators: _kE,
  ),
  AppShortcut(
    id: AppShortcutIds.save,
    label: '保存（编辑器内）',
    group: '笔记',
    activators: _kS,
  ),

  // ── 切换分区 ──────────────────────────────────────────────────────────
  AppShortcut(
    id: AppShortcutIds.allNotes,
    label: '全部笔记',
    group: '切换分区',
    activators: _k1,
  ),
  AppShortcut(
    id: AppShortcutIds.archived,
    label: '归档',
    group: '切换分区',
    activators: _k2,
  ),
  AppShortcut(
    id: AppShortcutIds.todos,
    label: '待办',
    group: '切换分区',
    activators: _k3,
  ),
  AppShortcut(
    id: AppShortcutIds.stats,
    label: '统计',
    group: '切换分区',
    activators: _k4,
  ),
  AppShortcut(
    id: AppShortcutIds.trash,
    label: '回收站',
    group: '切换分区',
    activators: _k5,
  ),
  AppShortcut(
    id: AppShortcutIds.settings,
    label: '设置',
    group: '切换分区',
    activators: _k6,
  ),

  // ── 视图 ──────────────────────────────────────────────────────────────
  AppShortcut(
    id: AppShortcutIds.help,
    label: '快捷键一览',
    group: '视图',
    activators: _kSlash,
  ),
  AppShortcut(
    id: AppShortcutIds.exitFullscreen,
    label: '退出全屏',
    group: '视图',
    activators: <ShortcutActivator>[
      SingleActivator(LogicalKeyboardKey.escape),
    ],
  ),
];

// `const` 列表里不能调用函数，所以这些按键变体写成常量。
// （写一次、三处用：定义、绑定、帮助面板。）
const List<ShortcutActivator> _kN = <ShortcutActivator>[
  SingleActivator(LogicalKeyboardKey.keyN, control: true),
  SingleActivator(LogicalKeyboardKey.keyN, meta: true),
];
const List<ShortcutActivator> _kF = <ShortcutActivator>[
  SingleActivator(LogicalKeyboardKey.keyF, control: true),
  SingleActivator(LogicalKeyboardKey.keyF, meta: true),
];
const List<ShortcutActivator> _kE = <ShortcutActivator>[
  SingleActivator(LogicalKeyboardKey.keyE, control: true),
  SingleActivator(LogicalKeyboardKey.keyE, meta: true),
];
const List<ShortcutActivator> _kS = <ShortcutActivator>[
  SingleActivator(LogicalKeyboardKey.keyS, control: true),
  SingleActivator(LogicalKeyboardKey.keyS, meta: true),
];
const List<ShortcutActivator> _k1 = <ShortcutActivator>[
  SingleActivator(LogicalKeyboardKey.digit1, control: true),
  SingleActivator(LogicalKeyboardKey.digit1, meta: true),
];
const List<ShortcutActivator> _k2 = <ShortcutActivator>[
  SingleActivator(LogicalKeyboardKey.digit2, control: true),
  SingleActivator(LogicalKeyboardKey.digit2, meta: true),
];
const List<ShortcutActivator> _k3 = <ShortcutActivator>[
  SingleActivator(LogicalKeyboardKey.digit3, control: true),
  SingleActivator(LogicalKeyboardKey.digit3, meta: true),
];
const List<ShortcutActivator> _k4 = <ShortcutActivator>[
  SingleActivator(LogicalKeyboardKey.digit4, control: true),
  SingleActivator(LogicalKeyboardKey.digit4, meta: true),
];
const List<ShortcutActivator> _k5 = <ShortcutActivator>[
  SingleActivator(LogicalKeyboardKey.digit5, control: true),
  SingleActivator(LogicalKeyboardKey.digit5, meta: true),
];
const List<ShortcutActivator> _k6 = <ShortcutActivator>[
  SingleActivator(LogicalKeyboardKey.digit6, control: true),
  SingleActivator(LogicalKeyboardKey.digit6, meta: true),
];
const List<ShortcutActivator> _kSlash = <ShortcutActivator>[
  SingleActivator(LogicalKeyboardKey.slash, control: true),
  SingleActivator(LogicalKeyboardKey.slash, meta: true),
];

AppShortcut? shortcutById(String id) {
  for (final s in kAppShortcuts) {
    if (s.id == id) return s;
  }
  return null;
}

/// 按 id 建 [CallbackShortcuts] 要的映射表。
///
/// [handlers] 里只写这个界面**真的支持**的动作，没写的就不绑 ——
/// 不做"绑上了但什么也不干"的空动作，那样按了没反应更让人困惑。
Map<ShortcutActivator, VoidCallback> bindShortcuts(
  Map<String, VoidCallback> handlers,
) {
  final map = <ShortcutActivator, VoidCallback>{};
  for (final entry in handlers.entries) {
    final s = shortcutById(entry.key);
    assert(s != null, '没有这个快捷键 id：${entry.key}');
    for (final a in s?.activators ?? const <ShortcutActivator>[]) {
      map[a] = entry.value;
    }
  }
  return map;
}

/// 把一个按键组合写成给人看的样子：`Ctrl+N` / `Ctrl+Shift+F` / `Esc`。
String describeShortcut(ShortcutActivator activator) {
  if (activator is! SingleActivator) return activator.toString();
  final parts = <String>[];
  if (activator.control) parts.add('Ctrl');
  if (activator.meta) parts.add('⌘');
  if (activator.alt) parts.add('Alt');
  if (activator.shift) parts.add('Shift');
  parts.add(_keyLabel(activator.trigger));
  return parts.join('+');
}

String _keyLabel(LogicalKeyboardKey key) {
  if (key == LogicalKeyboardKey.escape) return 'Esc';
  if (key == LogicalKeyboardKey.slash) return '/';
  if (key == LogicalKeyboardKey.comma) return ',';
  if (key == LogicalKeyboardKey.enter) return 'Enter';
  if (key == LogicalKeyboardKey.space) return 'Space';
  final label = key.keyLabel;
  return label.isEmpty ? key.keyId.toString() : label;
}

/// 弹出「快捷键一览」。
///
/// 所有桌面端快捷键的**唯一入口**：设置页里有一行，`Ctrl+/` 也能直接开。
/// 没做独立的帮助页面 —— 一共十来条，弹窗一眼能看完，不值得一次跳转。
Future<void> showShortcutHelp(BuildContext context) {
  final c = context.colors;
  // 按 group 归拢，保持 kAppShortcuts 里的先后顺序
  final groups = <String, List<AppShortcut>>{};
  for (final s in kAppShortcuts) {
    groups.putIfAbsent(s.group, () => <AppShortcut>[]).add(s);
  }

  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      backgroundColor: c.secondaryBackground,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
      ),
      title: Text('快捷键', style: AppText.headline),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final e in groups.entries) ...<Widget>[
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 6),
                child: Text(
                  e.key,
                  style: AppText.caption1.copyWith(
                    color: c.tertiaryLabel,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              for (final s in e.value)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      _KeyCap(text: describeShortcut(s.activators.first)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          s.label,
                          style: AppText.footnote.copyWith(color: c.label),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            // 非桌面端也要说清楚：安卓手机上没有这些键
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                '快捷键需要实体键盘（外接键盘的平板、Android 平板同样可用）。',
                style: AppText.caption2.copyWith(color: c.tertiaryLabel),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

/// 帮助面板里那种"键帽"。
class _KeyCap extends StatelessWidget {
  const _KeyCap({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      constraints: const BoxConstraints(minWidth: 64),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.fill,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: c.separator, width: 0.5),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: AppText.caption1.copyWith(
          color: c.secondaryLabel,
          fontWeight: FontWeight.w600,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
