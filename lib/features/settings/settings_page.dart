/// 设置页。iOS 分组列表风格。
library;

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_state.dart';
import '../../core/motion/app_motion.dart';
import '../../core/motion/apple_page_route.dart';
import '../../core/shortcuts/app_shortcuts.dart';
import '../../core/theme/app_theme.dart';
import '../collections/manage_collections_page.dart';
import '../easter_egg/version_egg.dart';
import '../importer/import_page.dart';
import '../privacy/privacy_page.dart';
import '../tags/manage_tags_page.dart';
import '../trash/trash_page.dart';
import 'field_manager_page.dart';

/// 快照目录（还没建就建出来，用户点"打开"时才不会是空路径）。
Directory _snapshotDir(AppState state) {
  final d = Directory(
    '${state.db.rootDir.path}${Platform.pathSeparator}snapshots',
  );
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

/// 底部那句小字：告诉用户上一次快照是什么时候、有几份。
String _lastSnapshotHint(AppState state) {
  final shots = state.backup.snapshots();
  if (shots.isEmpty) return '还没有快照，明天关掉再开就有第一份了。';
  final last = shots.first.statSync().modified;
  String two(int v) => v.toString().padLeft(2, '0');
  return '最近一次快照：${last.year}-${two(last.month)}-${two(last.day)} '
      '${two(last.hour)}:${two(last.minute)}，共 ${shots.length} 份。';
}

/// 点一下就有动作的设置行（备份、恢复这类）。
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _RowShell(
      icon: icon,
      iconColor: iconColor,
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: AppText.body.copyWith(color: c.label)),
          const SizedBox(height: 2),
          Text(
            subtitle,
            style: AppText.caption1.copyWith(color: c.tertiaryLabel),
          ),
        ],
      ),
    );
  }
}

/// 立刻导出一份全量备份到用户选的位置。
Future<void> _backupNow(BuildContext context, AppState state) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final bytes = state.backup.exportAll();
    final stamp = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final name = '元世界备份-${stamp.year}${two(stamp.month)}${two(stamp.day)}'
        '-${two(stamp.hour)}${two(stamp.minute)}.zip';
    final target = await FilePicker.saveFile(
      dialogTitle: '保存备份',
      fileName: name,
      bytes: bytes,
      type: FileType.custom,
      allowedExtensions: <String>['zip'],
    );
    if (target == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text('已备份到 ${target.toFilePath()}（${_mb(bytes.length)}）'),
        duration: const Duration(seconds: 5),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('备份失败：$e')));
  }
}

/// 从备份恢复。**先确认，再动手** —— 这会覆盖现有数据。
Future<void> _restoreFromBackup(BuildContext context, AppState state) async {
  final messenger = ScaffoldMessenger.of(context);

  PlatformFile? picked;
  try {
    picked = await FilePicker.pickFile(
      dialogTitle: '选择备份文件',
      type: FileType.custom,
      allowedExtensions: <String>['zip', 'db'],
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('选择文件失败：$e')));
    return;
  }
  final path = picked?.path;
  if (path == null || !context.mounted) return;

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('用这份备份覆盖当前数据？'),
      content: Text(
        '当前数据会被替换成备份里的内容。\n\n'
        '恢复前会自动把现在的数据库存一份到快照目录，万一恢复错了还能找回来。\n\n'
        '$path',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('覆盖恢复'),
        ),
      ],
    ),
  );
  if (ok != true) return;

  try {
    final r = state.backup.restore(File(path));
    // 恢复进来的可能是个旧库、也可能带着另一套设置 —— 重新读一遍
    await state.init();
    messenger.showSnackBar(
      SnackBar(
        content: Text('${r.summary}。建议重启一下应用。'),
        duration: const Duration(seconds: 6),
      ),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('恢复失败：$e')));
  }
}

String _mb(int bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

/// 多选一的设置行。用它而不是开关，是因为「大小」有中间档。
class _ChoiceRow<T> extends StatelessWidget {
  const _ChoiceRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.options,
    required this.labelOf,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final List<T> options;
  final String Function(T) labelOf;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _RowShell(
      icon: icon,
      iconColor: iconColor,
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: AppText.callout.copyWith(color: c.label)),
          ),
          for (final o in options)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Pressable(
                onTap: () => onChanged(o),
                scale: 0.94,
                haptic: false,
                child: AnimatedContainer(
                  duration: AppMotion.fast,
                  curve: AppMotion.enter,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                  decoration: BoxDecoration(
                    color: value == o ? c.tint : c.fill,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    labelOf(o),
                    style: AppText.caption1.copyWith(
                      color: value == o ? Colors.white : c.secondaryLabel,
                      fontWeight:
                          value == o ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 瀑布流列数：**直接填数字，没有上限**。
///
/// 之前用步进器加 2–10 的夹取，用户想铺 12 列都没门。
/// 既然是他自己的屏幕、自己的眼睛，就把决定权整个交出去。
class _ColumnCountRow extends StatefulWidget {
  const _ColumnCountRow({
    required this.icon,
    required this.iconColor,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final Color iconColor;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  State<_ColumnCountRow> createState() => _ColumnCountRowState();
}

class _ColumnCountRowState extends State<_ColumnCountRow> {
  late final TextEditingController _input =
      TextEditingController(text: '${widget.value}');

  @override
  void didUpdateWidget(_ColumnCountRow old) {
    super.didUpdateWidget(old);
    // 外部改了值（比如其它入口），同步到输入框；正在输入时不动它
    if (widget.value != old.value && _input.text != '${widget.value}') {
      _input.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _commit(String raw) {
    final v = int.tryParse(raw.trim());
    if (v == null) {
      // 填了不是数字的东西就退回原值，不要把它当成 0
      _input.text = '${widget.value}';
      return;
    }
    widget.onChanged(v);
    _input.text = '${widget.value}';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _RowShell(
      icon: widget.icon,
      iconColor: widget.iconColor,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '瀑布流每行几列',
                  style: AppText.callout.copyWith(color: c.label),
                ),
                const SizedBox(height: 1),
                Text(
                  '想几列就几列，最多按一列 60 像素算',
                  style: AppText.caption1.copyWith(color: c.tertiaryLabel),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 62,
            child: TextField(
              controller: _input,
              textAlign: TextAlign.center,
              keyboardType: TextInputType.number,
              onSubmitted: _commit,
              onTapOutside: (_) => _commit(_input.text),
              style: AppText.callout.copyWith(
                color: c.label,
                fontWeight: FontWeight.w600,
              ),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: c.fill,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide.none,
                ),
                suffixText: '列',
                suffixStyle:
                    AppText.caption1.copyWith(color: c.tertiaryLabel),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  /// 隐私空间那一行右侧的说明。
  ///
  /// **刻意不显示"几个文件夹几篇笔记"** —— 那等于把藏了多少东西
  /// 直接写在设置页上，谁路过都能看见。
  ///
  /// 但**必须说清它不是加密**：数据库仍旧是明文文件，绕开应用直接看
  /// 文件就能读到。用户以为"进了隐私空间就安全了"，才是真的危险。
  static String _privacySubtitle(BuildContext context) =>
      '密码保护 + 从列表与搜索里隐藏（数据库本身未加密）';

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final state = context.watch<AppState>();

    return Scaffold(
      backgroundColor: c.groupedBackground,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(0, 20, 0, 110),
          physics: const BouncingScrollPhysics(),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
              child: Text('设置', style: AppText.largeTitle.copyWith(color: c.label)),
            ),

            // ── 外观 ───────────────────────────────────────────────────
            _SectionHeader('外观'),
            _Group(
              children: [
                _ThemeRow(state: state),
                _RowDivider(),
                _SwitchRow(
                  icon: Icons.grid_view_rounded,
                  iconColor: c.palette[4],
                  label: '瀑布流视图',
                  subtitle: '首页默认使用卡片布局',
                  value: state.gridMode,
                  onChanged: state.setGridMode,
                ),
                // 每行几列**只在开了瀑布流之后才出现** ——
                // 列表视图下它没有任何作用，摆在那里只会让人困惑
                // "我设了怎么没反应"。
                if (state.gridMode) ...[
                  _RowDivider(),
                  _ColumnCountRow(
                    icon: Icons.view_column_rounded,
                    iconColor: c.palette[4],
                    value: state.gridColumns,
                    onChanged: state.setGridColumns,
                  ),
                ],
              ],
            ),

            // ── 数据 ───────────────────────────────────────────────────
            _SectionHeader('数据'),
            _Group(
              children: [
                // 回收站：**手机端唯一的入口**。
                //
                // 桌面左栏有「回收站」，而手机是底部四个标签 + 这个设置页，
                // 之前 TrashPage 只被 desktop_workspace 引用 —— 也就是说
                // 在手机上删掉的笔记**永远找不回来**（也没有地方彻底清空）。
                // 入口放这儿是因为它属于"系统级的地方"，不是一种筛选视图。
                _NavRow(
                  icon: Icons.delete_outline_rounded,
                  iconColor: c.palette[3],
                  label: '回收站',
                  subtitle: state.trashedNotes.isEmpty
                      ? '空的'
                      : '${state.trashedNotes.length} 篇，可恢复或彻底删除',
                  onTap: () => Navigator.of(context).push(
                    ApplePageRoute<void>(pageBuilder: (_) => const TrashPage()),
                  ),
                ),
                _RowDivider(),
                _NavRow(
                  icon: Icons.playlist_add_rounded,
                  iconColor: c.palette[4],
                  label: '文章参数',
                  subtitle: '头参数 / 尾参数的个数与种类',
                  onTap: () => Navigator.of(context).push(
                    ApplePageRoute<void>(
                      pageBuilder: (_) => const FieldManagerPage(),
                    ),
                  ),
                ),
                _RowDivider(),
                _SwitchRow(
                  icon: Icons.vertical_align_top_rounded,
                  iconColor: c.palette[4],
                  label: '显示头参数',
                  subtitle: '标题与正文之间',
                  value: state.headFieldsEnabled,
                  onChanged: state.setHeadFieldsEnabled,
                ),
                _RowDivider(),
                _SwitchRow(
                  icon: Icons.vertical_align_bottom_rounded,
                  iconColor: c.palette[4],
                  label: '显示尾参数',
                  subtitle: '文章末尾右对齐一行',
                  value: state.tailFieldsEnabled,
                  onChanged: state.setTailFieldsEnabled,
                ),
                _RowDivider(),
                _ChoiceRow(
                  icon: Icons.format_size_rounded,
                  iconColor: c.palette[3],
                  label: '文字大小',
                  options: AppState.textScaleOptions,
                  labelOf: (v) => switch (v) {
                    0.9 => '小',
                    1.15 => '大',
                    1.3 => '特大',
                    _ => '标准',
                  },
                  value: state.textScale,
                  onChanged: state.setTextScale,
                ),
                _RowDivider(),
                _SwitchRow(
                  icon: Icons.toc_rounded,
                  iconColor: c.palette[4],
                  label: '显示文章目录',
                  subtitle: '正文有标题时，右上角出现目录入口',
                  value: state.tocEnabled,
                  onChanged: state.setTocEnabled,
                ),
                _RowDivider(),
                _NavRow(
                  icon: Icons.folder_rounded,
                  iconColor: c.palette[2],
                  label: '文件夹管理',
                  subtitle: '新建 / 重命名 / 排序 / 删除',
                  onTap: () => Navigator.of(context).push(
                    ApplePageRoute<void>(
                      pageBuilder: (_) => const ManageCollectionsPage(),
                    ),
                  ),
                ),
                _RowDivider(),
                _NavRow(
                  icon: Icons.label_rounded,
                  iconColor: c.palette[5],
                  label: '标签管理',
                  subtitle: '重命名 / 合并 / 换色 / 删除',
                  onTap: () => Navigator.of(context).push(
                    ApplePageRoute<void>(
                      pageBuilder: (_) => const ManageTagsPage(),
                    ),
                  ),
                ),
                _RowDivider(),
                // 进了隐私空间以后，这一行**变成出口**。
                //
                // 桌面上有左栏那个锁形提示可以退出；手机端原本只有
                // 「进入」这一个入口、**没有任何出口** —— 用户进了隐私空间
                // 之后只会看到一片（或少量）隐藏内容，既不知道自己在哪儿，
                // 也退不出去（不持久化，重启才行）。这是实打实的能力缺口。
                _NavRow(
                  icon: state.privacyMode
                      ? Icons.lock_open_rounded
                      : Icons.lock_rounded,
                  iconColor: c.palette[6],
                  label: state.privacyMode ? '退出隐私空间' : '进入隐私空间',
                  subtitle: state.privacyMode
                      ? '当前只看隐私内容，退出后回到全部笔记'
                      : _privacySubtitle(context),
                  onTap: () async {
                    if (state.privacyMode) {
                      state.exitPrivacyMode();
                      return;
                    }
                    // 没密码直接进，有密码验一下就进 —— 不再有中间页
                    final ok = await enterPrivacySpace(context);
                    if (!ok || !context.mounted) return;
                    Navigator.of(context).popUntil((r) => r.isFirst);
                  },
                ),
                _RowDivider(),
                _NavRow(
                  icon: Icons.password_rounded,
                  iconColor: c.palette[6],
                  label: '隐私空间密码',
                  subtitle: hasPrivacyPassword(state) ? '已设置，点击修改' : '未设置，点击添加',
                  onTap: () => showPasswordSetup(context),
                ),
                _RowDivider(),
                _NavRow(
                  icon: Icons.help_outline_rounded,
                  iconColor: c.palette[6],
                  label: '密保问题',
                  subtitle: hasSecurityQuestion(state) ? '已设置，点击修改' : '未设置，忘记密码时无法找回',
                  onTap: () => showSecurityQuestionSetup(context),
                ),
                _RowDivider(),
                _NavRow(
                  icon: Icons.download_rounded,
                  iconColor: c.palette[0],
                  label: '导入 .docx 文集',
                  subtitle: '支持整个文件夹批量导入',
                  onTap: () => Navigator.of(context).push(
                    ApplePageRoute<void>(
                      pageBuilder: (_) => const ImportPage(),
                      fullscreenDialog: true,
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: Text(
                '隐私空间做的是两件事：进门要密码、内容不再出现在列表与搜索里。'
                '它不做加密 —— 数据仍是本机的明文文件，绕开应用直接看文件就能读到。'
                '要防"电脑/硬盘被别人拿到"，请配合系统级加密'
                '（Windows 的 BitLocker、手机的锁屏加密）。',
                style: AppText.caption1.copyWith(
                  color: c.tertiaryLabel,
                  height: 1.6,
                ),
              ),
            ),

            // ── 存储位置 ───────────────────────────────────────────────
            _SectionHeader('存储位置'),
            _Group(
              children: [
                _PathRow(
                  icon: Icons.storage_rounded,
                  iconColor: c.palette[2],
                  label: '数据库',
                  path:
                      '${state.db.rootDir.path}${Platform.pathSeparator}yuanworld.db',
                  // 是文件不是目录：打开它**所在的目录**才有意义
                  isDirectory: false,
                ),
                _RowDivider(),
                _PathRow(
                  icon: Icons.photo_library_rounded,
                  iconColor: c.palette[6],
                  label: '图片与视频',
                  path: state.db.imageRoot.path,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: Text(
                '全部数据都在本机，不上传任何服务器。备份时直接复制上面两个目录即可。',
                style: AppText.caption1.copyWith(
                  color: c.tertiaryLabel,
                  height: 1.6,
                ),
              ),
            ),

            // ── 备份与恢复 ─────────────────────────────────────────────
            _SectionHeader('备份与恢复'),
            _Group(
              children: [
                _SwitchRow(
                  icon: Icons.history_rounded,
                  iconColor: c.palette[5],
                  label: '每天自动快照',
                  subtitle: '只含数据库（几兆），图片视频不重复备份；保留最近 7 份',
                  value: state.backupAutoSnapshot,
                  onChanged: (v) => state.setBackupAutoSnapshot(v),
                ),
                _RowDivider(),
                _ActionRow(
                  icon: Icons.archive_rounded,
                  iconColor: c.palette[2],
                  label: '立即完整备份…',
                  subtitle: '数据库 + 全部图片视频，打成一个压缩包给你保存',
                  onTap: () => _backupNow(context, state),
                ),
                _RowDivider(),
                _ActionRow(
                  icon: Icons.settings_backup_restore_rounded,
                  iconColor: c.palette[0],
                  label: '从备份恢复…',
                  subtitle: '会覆盖当前数据（恢复前会自动存一份安全副本）',
                  onTap: () => _restoreFromBackup(context, state),
                ),
                _RowDivider(),
                _PathRow(
                  icon: Icons.folder_special_rounded,
                  iconColor: c.palette[3],
                  label: '快照目录',
                  path: _snapshotDir(state).path,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: Text(
                '全部数据都在本机，不上传任何服务器。'
                '${_lastSnapshotHint(state)}',
                style: AppText.caption1.copyWith(
                  color: c.tertiaryLabel,
                  height: 1.6,
                ),
              ),
            ),

            // ── 关于 ───────────────────────────────────────────────────
            _SectionHeader('关于'),
            _Group(
              children: [
                _VersionRow(version: '1.0.0'),
                _RowDivider(),
                // 快捷键一览：桌面端有一堆 Ctrl+ 组合，不写出来没人猜得到。
                // 内容直接读 core/shortcuts 的定义，不在这里手抄一份。
                _ActionRow(
                  icon: Icons.keyboard_rounded,
                  iconColor: c.palette[5],
                  label: '快捷键',
                  subtitle: 'Ctrl+N 新建 · Ctrl+F 搜索 · Ctrl+/ 看全部',
                  onTap: () => showShortcutHelp(context),
                ),
                _RowDivider(),
                const _InfoRow(label: '本地数据库', value: 'SQLite · FTS5'),
                _RowDivider(),
                const _InfoRow(label: '界面框架', value: 'Flutter 3.47'),
              ],
            ),
            const SizedBox(height: 24),
            Center(
              child: Column(
                children: [
                  // 应用图标：设置页最下面这块"关于"的地方，光有名字太素，
                  // 加个图标一眼就认出来这是什么应用（两端共用这一页）。
                  ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Image.asset(
                      'assets/branding/logo.png',
                      width: 58,
                      height: 58,
                      fit: BoxFit.cover,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '元世界',
                    style: AppText.footnote.copyWith(
                      color: c.tertiaryLabel,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    '本地优先的笔记与知识可视化',
                    style: AppText.caption2.copyWith(color: c.quaternaryLabel),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 通用行组件 ────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Text(
        text,
        style: AppText.caption1.copyWith(
          color: c.tertiaryLabel,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _Group extends StatelessWidget {
  const _Group({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: c.secondaryBackground,
        borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
        border: Border.all(
          color: c.isDark ? c.separator.withValues(alpha: 0.4) : const Color(0x0F000000),
          width: 0.5,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(children: children),
    );
  }
}

class _RowDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(left: 52),
      child: Container(height: 0.5, color: c.separator),
    );
  }
}

class _RowShell extends StatelessWidget {
  const _RowShell({
    required this.child,
    this.onTap,
    this.icon,
    this.iconColor,
  });

  final Widget child;
  final VoidCallback? onTap;
  final IconData? icon;
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          if (icon != null) ...[
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                color: (iconColor ?? c.tint).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(7),
              ),
              child: Icon(icon, size: 15, color: iconColor ?? c.tint),
            ),
            const SizedBox(width: 12),
          ],
          Expanded(child: child),
        ],
      ),
    );
    if (onTap == null) return content;
    return InkWell(onTap: onTap, child: content);
  }
}

/// 「版本」这一行 —— 连点几下会出彩蛋。
///
/// 照安卓那套：点的时候**有反馈但不告诉你还差几次**（安卓是点版本号，
/// 点够了弹出大字标）。这里每点一下让整行轻轻缩一下、再来一次轻触感，
/// 点满 [kEggTapCount] 下就打开彩蛋。
///
/// 计数不落盘：换一次页面就重新数。彩蛋不该被"上次点了两下"提前触发。
class _VersionRow extends StatefulWidget {
  const _VersionRow({required this.version});
  final String version;

  @override
  State<_VersionRow> createState() => _VersionRowState();
}

class _VersionRowState extends State<_VersionRow> {
  int _taps = 0;
  double _scale = 1;

  Future<void> _tap() async {
    _taps++;
    HapticFeedback.selectionClick();
    // 每一下都缩一下 —— 点的人能感觉到"点到了"，但看不出进度
    setState(() => _scale = 0.97);
    await Future<void>.delayed(const Duration(milliseconds: 90));
    if (mounted) setState(() => _scale = 1);
    if (_taps < kEggTapCount || !mounted) return;
    _taps = 0;
    HapticFeedback.mediumImpact();
    await showVersionEgg(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _RowShell(
      onTap: _tap,
      child: AnimatedScale(
        scale: _scale,
        duration: AppMotion.instant,
        child: Row(
          children: [
            Text('版本', style: AppText.body.copyWith(color: c.label)),
            const Spacer(),
            Text(
              widget.version,
              style: AppText.body.copyWith(color: c.secondaryLabel),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _RowShell(
      child: Row(
        children: [
          Text(label, style: AppText.body.copyWith(color: c.label)),
          const Spacer(),
          Text(value, style: AppText.body.copyWith(color: c.secondaryLabel)),
        ],
      ),
    );
  }
}

class _NavRow extends StatelessWidget {
  const _NavRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.onTap,
    this.subtitle,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _RowShell(
      icon: icon,
      iconColor: iconColor,
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppText.body.copyWith(color: c.label)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: AppText.caption1.copyWith(color: c.tertiaryLabel),
                  ),
                ],
              ],
            ),
          ),
          Icon(Icons.chevron_right_rounded, size: 19, color: c.tertiaryLabel),
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _RowShell(
      icon: icon,
      iconColor: iconColor,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppText.body.copyWith(color: c.label)),
                if (subtitle != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle!,
                    style: AppText.caption1.copyWith(color: c.tertiaryLabel),
                  ),
                ],
              ],
            ),
          ),
          Switch.adaptive(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _PathRow extends StatelessWidget {
  const _PathRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.path,
    this.isDirectory = true,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final String path;

  /// 是目录就打开它，是文件就打开所在目录 ——
  /// 双击一个 .db 文件只会让系统问"用什么打开"，那不是用户想要的。
  final bool isDirectory;

  Future<void> _open(BuildContext context) async {
    final target = isDirectory ? path : File(path).parent.path;
    final dir = Directory(target);
    if (!dir.existsSync()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('目录还不存在')),
      );
      return;
    }
    try {
      await launchUrl(Uri.file(target), mode: LaunchMode.externalApplication);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('打不开：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return _RowShell(
      icon: icon,
      iconColor: iconColor,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppText.body.copyWith(color: c.label)),
                const SizedBox(height: 3),
                SelectableText(
                  path,
                  maxLines: 2,
                  style: AppText.caption2.copyWith(
                    color: c.tertiaryLabel,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // 点一下直接在文件管理器里打开 —— 路径本身没法点，
          // 用户要复制出去再粘贴到资源管理器，太绕了
          Pressable(
            onTap: () => _open(context),
            scale: 0.94,
            child: Tooltip(
              message: '在文件管理器中打开',
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
                decoration: BoxDecoration(
                  color: c.fill,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.folder_open_rounded, size: 14, color: c.tint),
                    const SizedBox(width: 5),
                    Text(
                      '打开',
                      style: AppText.caption1.copyWith(
                        color: c.tint,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ThemeRow extends StatelessWidget {
  const _ThemeRow({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final modes = <(ThemeMode, String, IconData)>[
      (ThemeMode.system, '跟随系统', Icons.brightness_auto_rounded),
      (ThemeMode.light, '浅色', Icons.light_mode_rounded),
      (ThemeMode.dark, '深色', Icons.dark_mode_rounded),
    ];

    return _RowShell(
      icon: Icons.palette_rounded,
      iconColor: c.palette[3],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('主题', style: AppText.body.copyWith(color: c.label)),
          const SizedBox(height: 10),
          Row(
            children: [
              for (final (mode, label, icon) in modes) ...[
                Expanded(
                  child: GestureDetector(
                    onTap: () => state.setThemeMode(mode),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      decoration: BoxDecoration(
                        color: state.themeMode == mode ? c.tint : c.fill,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Column(
                        children: [
                          Icon(
                            icon,
                            size: 15,
                            color: state.themeMode == mode
                                ? Colors.white
                                : c.secondaryLabel,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            label,
                            style: AppText.caption2.copyWith(
                              color: state.themeMode == mode
                                  ? Colors.white
                                  : c.secondaryLabel,
                              fontWeight: state.themeMode == mode
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (mode != ThemeMode.dark) const SizedBox(width: 8),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
