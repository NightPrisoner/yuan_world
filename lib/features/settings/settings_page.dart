/// 设置页。iOS 分组列表风格。
library;

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app_state.dart';
import '../../core/app_info.dart';
import '../../core/app_paths.dart';
import '../../core/motion/app_motion.dart';
import '../../core/motion/apple_page_route.dart';
import '../../core/platform/window_mode.dart';
import '../../core/shortcuts/app_shortcuts.dart';
import '../../core/theme/app_theme.dart';
import '../collections/manage_collections_page.dart';
import '../easter_egg/version_egg.dart';
import '../importer/import_page.dart';
import '../privacy/privacy_page.dart';
import '../tags/manage_tags_page.dart';
import '../trash/trash_page.dart';
import 'diagnostics_sheet.dart';
import 'field_manager_page.dart';

/// 快照目录（还没建就建出来，用户点"打开"时才不会是空路径）。
Directory _snapshotDir(AppState state) {
  final d = Directory(
    '${state.db.rootDir.path}${Platform.pathSeparator}snapshots',
  );
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

/// 自动完整备份目录（同上）。
Directory _fullBackupDir(AppState state) => state.backup.fullBackupDir;

String _two(int v) => v.toString().padLeft(2, '0');

String _stamp(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';

/// 自动快照的实情：成了几次、上次什么时候、上次为什么没成。
///
/// 光有一个开关是不够的 —— 开关只代表"想备份"，用户真正要确认的是
/// "上一次到底备成了没有"。
String _snapshotHint(AppState state) {
  final shots = state.backup.snapshots();
  final err = state.lastSnapshotError;
  if (err != null && err.isNotEmpty) {
    final at = state.lastSnapshotErrorAt;
    final when = at == null ? '' : '（${_stamp(at)}）';
    return '上次自动快照没成功$when：$err';
  }
  if (shots.isEmpty) return '还没有快照，明天关掉再开就有第一份了。';
  final last = state.lastSnapshotAt ?? shots.first.statSync().modified;
  return '最近一次自动快照：${_stamp(last)}，共 ${shots.length} 份。';
}

/// 自动完整备份的实情。比快照更要紧 —— 这是唯一带图片视频的备份。
String _fullBackupHint(AppState state) {
  final files = state.backup.fullBackups();
  final err = state.lastFullBackupError;
  if (err != null && err.isNotEmpty) {
    final at = state.lastFullBackupErrorAt;
    final when = at == null ? '' : '（${_stamp(at)}）';
    return '上次自动完整备份没成功$when：$err';
  }
  if (files.isEmpty) return '还没有自动完整备份，本周内会做第一份。';
  final last = state.lastFullBackupAt ?? files.first.statSync().modified;
  final mb = files.fold<int>(0, (s, f) => s + f.lengthSync()) / 1024 / 1024;
  return '最近一次自动完整备份：${_stamp(last)}，共 ${files.length} 份，'
      '占 ${mb.toStringAsFixed(0)} MB。';
}

/// 异地备份的实情：复制到哪儿了、上次成没成。
String _mirrorHint(AppState state) {
  final dir = state.backupMirrorDir.trim();
  if (dir.isEmpty) return '';
  final err = state.lastMirrorError;
  if (err != null && err.isNotEmpty) {
    final at = state.lastMirrorErrorAt;
    final when = at == null ? '' : '（${_stamp(at)}）';
    return '\n上次复制到别的地方没成功$when：$err';
  }
  final last = state.lastMirrorAt;
  if (last == null) return '\n还没有往「$dir」复制过，下次完整备份时会一起放一份。';
  return '\n最近一次复制到「$dir」：${_stamp(last)}。';
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

/// 让用户挑一个"备份也要放一份"的目录。
///
/// 不用 `saveFile`（那是存单个文件），这里要的是目录 —— 很多人会直接选
/// 网盘的同步目录，之后每次完整备份都会自动复制一份进去。
Future<void> _pickMirrorDir(BuildContext context, AppState state) async {
  final messenger = ScaffoldMessenger.of(context);
  final picked = await FilePicker.getDirectoryPath(
    dialogTitle: '选择另外存一份备份的目录',
  );
  if (picked == null || picked.trim().isEmpty) return;
  final dir = Directory(picked);
  try {
    if (!dir.existsSync()) dir.createSync(recursive: true);
    // 先探一下能不能写。选到只读的盘或没权限的目录时，让用户当场知道，
    // 而不是等一周后看到一句"上次备份没成功"。
    final probe = File('${dir.path}${Platform.pathSeparator}.yw-write-test');
    probe.writeAsStringSync('ok');
    probe.deleteSync();
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(
        content: Text('这个目录写不进去：$e'),
        duration: const Duration(seconds: 4),
      ),
    );
    return;
  }
  state.setBackupMirrorDir(dir.path);
  messenger.showSnackBar(
    SnackBar(
      content: Text('以后每次完整备份都会再放一份到 ${dir.path}'),
      duration: const Duration(seconds: 4),
    ),
  );
}

/// 立刻做一次完整备份：打包到本机 backups 目录，配了异地目录就顺手复制一份。
///
/// 以前这里和"另外存一份到别的地方"是两条路：一条弹保存框让你挑一个 zip 放哪，
/// 一条每周自动往镜像目录丢一份 —— 用户看着就是"两个功能重了"，而且手动那条
/// 走的是内存里拼整包的老路，几百兆会卡住界面、也没有任何进度。
/// 现在统一成一条：走流式的 `createFullBackupNow`，中途弹进度，结尾说清楚
/// 存到了哪、有没有复制到异地。
Future<void> _backupNow(BuildContext context, AppState state) async {
  final messenger = ScaffoldMessenger.of(context);
  final progress = ValueNotifier<double>(0);
  var dialogClosed = false;

  void closeDialog() {
    if (dialogClosed) return;
    dialogClosed = true;
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }

  // 打包在后台跑，先把进度框挂上去
  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('正在备份'),
      content: ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (_, value, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('数据库 + 全部图片视频打包中… ${(value * 100).round()}%'),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: value == 0 ? null : value),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: closeDialog,
          child: const Text('后台继续'),
        ),
      ],
    ),
  ));

  try {
    final file = await state.createFullBackupNow(
      onProgress: (v) => progress.value = v,
    );
    progress.value = 1;
    closeDialog();
    final mirrored = state.backupMirrorEnabled && state.lastMirrorError == null;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '已备份到 ${file.path}（${_mb(file.lengthSync())}）'
          '${mirrored ? '\n另存了一份到 ${state.backupMirrorDir}' : ''}',
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  } catch (e) {
    closeDialog();
    messenger.showSnackBar(
      SnackBar(
        content: Text('备份失败：$e'),
        duration: const Duration(seconds: 5),
      ),
    );
  } finally {
    progress.dispose();
  }
}

/// 把整个数据目录搬到用户挑的位置。
///
/// 会先关掉数据库连接再搬运，中途崩了指针文件已经写好了，下次启动照样
/// 能找到新位置。搬运期间弹一个进度框，几百兆也不至于看起来像死机。
///
/// **是"搬"不是"复制"**：搬到新位置后原位置的那几项会被删掉，数据只留
/// 一份。两份并存过一次，结果用户自己也分不清哪个是正在用的。
Future<void> _moveDataLocation(BuildContext context, AppState state) async {
  final messenger = ScaffoldMessenger.of(context);
  final picked = await FilePicker.getDirectoryPath(
    dialogTitle: '选择数据存放位置',
  );
  if (picked == null || picked.trim().isEmpty) return;
  if (!context.mounted) return;
  final target = dataDirIn(picked.trim());

  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('把数据搬到这里？'),
      content: Text(
        '数据库、图片、视频、快照和备份都会搬到：\n$target\n\n'
        '搬到新位置后，原位置的那份会被删掉 —— 数据只留一份。\n'
        '新位置里已有的同名数据会被这里的数据替换。',
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('搬过去')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;

  await _runDataMove(context, state, picked, messenger, '数据已搬到');
}

/// 回到默认位置（软件目录旁边的 data/）。
Future<void> _resetDataLocation(BuildContext context, AppState state) async {
  final messenger = ScaffoldMessenger.of(context);
  final defaultRoot = await defaultAppRoot();
  if (!context.mounted) return;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('回到默认位置？'),
      content: Text(
        '数据会搬回：\n$defaultRoot\n\n'
        '搬回去之后，当前自定义位置的那份会被删掉 —— 数据只留一份。',
      ),
      actions: <Widget>[
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('搬回去')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;

  await _runDataMove(context, state, null, messenger, '已回到默认位置');
}

/// 真正干活的：进度框 + 调 AppState + 结果提示。
Future<void> _runDataMove(
  BuildContext context,
  AppState state,
  String? target,
  ScaffoldMessengerState messenger,
  String doneLabel,
) async {
  final progress = ValueNotifier<double>(0);
  var dialogClosed = false;
  void closeDialog() {
    if (dialogClosed) return;
    dialogClosed = true;
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }

  unawaited(showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('正在搬数据'),
      content: ValueListenableBuilder<double>(
        valueListenable: progress,
        builder: (_, value, _) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('搬运中… ${(value * 100).round()}%'),
            const SizedBox(height: 12),
            LinearProgressIndicator(value: value == 0 ? null : value),
          ],
        ),
      ),
    ),
  ));

  try {
    final result = await state.moveDataLocation(
      target,
      onProgress: (v) => progress.value = v,
    );
    progress.value = 1;
    closeDialog();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '$doneLabel ${result.target}'
          '${result.files > 0 ? '（${result.files} 个文件，${_mb(result.bytes)}）' : ''}',
        ),
        duration: const Duration(seconds: 6),
      ),
    );
  } catch (e) {
    closeDialog();
    messenger.showSnackBar(
      SnackBar(content: Text('搬移失败：$e'), duration: const Duration(seconds: 6)),
    );
  } finally {
    progress.dispose();
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
                  duration: AppMotion.respecting(context, AppMotion.fast),
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
/// 一个"填数字的间隔"行：标签 + 副标题 + 输入框 + 单位。
///
/// 复用于快照间隔（小时）和完整备份间隔（天）—— 两处长得一模一样，
/// 只是单位和取值范围不同。
class _IntervalRow extends StatefulWidget {
  const _IntervalRow({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.unit,
    required this.zeroHint,
    required this.onChanged,
  });

  final IconData icon;
  final Color iconColor;
  final String label;
  final String subtitle;
  final int value;
  final String unit;

  /// 填 0 时副标题换成这句（快照的"关闭"语义需要说清楚）
  final String zeroHint;
  final ValueChanged<int> onChanged;

  @override
  State<_IntervalRow> createState() => _IntervalRowState();
}

class _IntervalRowState extends State<_IntervalRow> {
  late final TextEditingController _input =
      TextEditingController(text: '${widget.value}');

  @override
  void didUpdateWidget(_IntervalRow old) {
    super.didUpdateWidget(old);
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
                Text(widget.label, style: AppText.callout.copyWith(color: c.label)),
                const SizedBox(height: 1),
                Text(
                  widget.value <= 0 ? widget.zeroHint : widget.subtitle,
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
                suffixText: widget.unit,
                suffixStyle: AppText.caption1.copyWith(color: c.tertiaryLabel),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 瀑布流列数：**直接填数字，没有上限**。
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
                // 手机上数据必须待在应用私有目录里，系统才不清理，
                // 所以只在桌面端给这两个入口。
                if (isDesktopWindow) ...[
                  _RowDivider(),
                  _ActionRow(
                    icon: Icons.drive_file_move_rounded,
                    iconColor: c.palette[4],
                    label: state.dataLocationIsCustom
                        ? '换一个位置…'
                        : '更改数据位置…',
                    subtitle: state.dataLocationIsCustom
                        ? '当前用的是自定义位置，可以再换到别的盘'
                        : '搬到其它盘或网盘目录，原来的那份会随搬移删掉',
                    onTap: () => _moveDataLocation(context, state),
                  ),
                  if (state.dataLocationIsCustom) ...[
                    _RowDivider(),
                    _ActionRow(
                      icon: Icons.restart_alt_rounded,
                      iconColor: c.palette[0],
                      label: '回到默认位置',
                      subtitle: '搬回软件目录下的 data/，原来的那份会随搬移删掉',
                      onTap: () => _resetDataLocation(context, state),
                    ),
                  ],
                ],
              ],
            ),

            // ── 备份与恢复 ─────────────────────────────────────────────
            _SectionHeader('备份与恢复'),
            _Group(
              children: [
                _SwitchRow(
                  icon: Icons.history_rounded,
                  iconColor: c.palette[5],
                  label: '自动快照',
                  subtitle: '只含数据库（几兆），图片视频不重复备份；保留最近 7 份',
                  value: state.backupAutoSnapshot,
                  onChanged: (v) => state.setBackupAutoSnapshot(v),
                ),
                if (state.backupAutoSnapshot) ...[
                  _RowDivider(),
                  _IntervalRow(
                    icon: Icons.schedule_rounded,
                    iconColor: c.palette[5],
                    label: '多久拍一次',
                    subtitle: '按小时算，默认 24 小时',
                    value: state.snapshotEveryHours,
                    unit: '小时',
                    zeroHint: '现在是 0：不再自动拍，只能手动',
                    onChanged: (v) => state.setSnapshotEveryHours(v),
                  ),
                ],
                _RowDivider(),
                _SwitchRow(
                  icon: Icons.inventory_2_rounded,
                  iconColor: c.palette[1],
                  label: '自动完整备份',
                  subtitle: '数据库 + 全部图片视频，存在本机 backups 目录；保留最近 2 份',
                  value: state.backupAutoFull,
                  onChanged: (v) => state.setBackupAutoFull(v),
                ),
                if (state.backupAutoFull) ...[
                  _RowDivider(),
                  _IntervalRow(
                    icon: Icons.schedule_rounded,
                    iconColor: c.palette[1],
                    label: '多久备份一次',
                    subtitle: '按天算，默认 7 天',
                    value: state.fullBackupEveryDays,
                    unit: '天',
                    zeroHint: '至少 1 天',
                    onChanged: (v) => state.setFullBackupEveryDays(v),
                  ),
                ],
                _RowDivider(),
                _ActionRow(
                  icon: Icons.archive_rounded,
                  iconColor: c.palette[2],
                  label: '立即完整备份一次',
                  subtitle: state.backupMirrorEnabled
                      ? '打包存在本机 backups 目录，并复制一份到异地目录'
                      : '打包存在本机 backups 目录；想多一层保障可以再配个异地目录',
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
                _ActionRow(
                  icon: Icons.cloud_upload_rounded,
                  iconColor: c.palette[4],
                  label: state.backupMirrorEnabled
                      ? '异地目录：${state.backupMirrorDir}'
                      : '配一个异地目录…',
                  subtitle: state.backupMirrorEnabled
                      ? '每次完整备份都会再复制一份到这里（外接盘、网盘同步目录）'
                      : '本机的备份和数据库在同一块盘上，换个盘或网盘目录更稳妥',
                  onTap: () => _pickMirrorDir(context, state),
                ),
                if (state.backupMirrorEnabled) ...[
                  _RowDivider(),
                  _ActionRow(
                    icon: Icons.close_rounded,
                    iconColor: c.tertiaryLabel,
                    label: '不再另存到别的地方',
                    subtitle: '已经复制过去的文件不会被删掉',
                    onTap: () => state.setBackupMirrorDir(''),
                  ),
                ],
                _RowDivider(),
                _PathRow(
                  icon: Icons.folder_special_rounded,
                  iconColor: c.palette[3],
                  label: '快照目录',
                  path: _snapshotDir(state).path,
                ),
                _RowDivider(),
                _PathRow(
                  icon: Icons.inventory_2_outlined,
                  iconColor: c.palette[1],
                  label: '完整备份目录',
                  path: _fullBackupDir(state).path,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: Text(
                '${_snapshotHint(state)}\n'
                '${_fullBackupHint(state)}'
                '${_mirrorHint(state)}',
                style: AppText.caption1.copyWith(
                  color: c.tertiaryLabel,
                  height: 1.6,
                ),
              ),
            ),

            // ── 帮助与诊断 ─────────────────────────────────────────────
            // 开源出去的软件，用户反馈"崩了/怪怪的"时，光有一句描述没法查。
            // 这里让用户一键复制一段能直接贴进 issue 的诊断信息。
            _SectionHeader('帮助与诊断'),
            _Group(
              children: [
                _ActionRow(
                  icon: Icons.bug_report_rounded,
                  iconColor: c.palette[3],
                  label: '导出诊断信息…',
                  subtitle: '版本、系统、库大小和最近的错误记录，复制后贴到反馈里',
                  onTap: () => showDiagnosticsSheet(context),
                ),
              ],
            ),

            // ── 关于 ───────────────────────────────────────────────────
            _SectionHeader('关于'),
            _Group(
              children: [
                const _VersionRow(),
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
                _RowDivider(),
                const _InfoRow(
                  label: '制作',
                  value: 'deepseek-v4.1-flash&梦之夜囚',
                ),
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
  const _VersionRow();

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
        duration: AppMotion.respecting(context, AppMotion.instant),
        child: Row(
          children: [
            Text('版本', style: AppText.body.copyWith(color: c.label)),
            const Spacer(),
            Text(
              // 不手写：版本号只在 pubspec 的 version: 里定义一份，
              // 运行时由 AppInfo 从平台包里读出来。
              AppInfo.version,
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
          const SizedBox(width: 16),
          // 值一律贴右。用 Expanded 而不是 Spacer + Flexible：
          // Spacer 和 Flexible 都是 flex 1，会平分剩余空间，
          // 值就被推到中间去了（上一版就是这么错的）。
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: AppText.body.copyWith(color: c.secondaryLabel),
            ),
          ),
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
                      duration: AppMotion.respecting(context, AppMotion.fast),
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
          const SizedBox(height: 12),
          _ThemeSeedPicker(state: state),
          const SizedBox(height: 14),
          ThemeBackgroundPicker(state: state),
          if (state.themeSeed != null ||
              state.themeBackgroundPath != null) ...[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Pressable(
                scale: 0.94,
                onTap: () {
                  state.resetTheme();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('已回到默认主题')),
                  );
                },
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                  decoration: BoxDecoration(
                    color: c.fill,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Icon(Icons.restart_alt_rounded,
                          size: 14, color: c.secondaryLabel),
                      const SizedBox(width: 5),
                      Text(
                        '恢复默认主题',
                        style: AppText.caption1.copyWith(color: c.secondaryLabel),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 强调色选择：一排色块 + 一个"自定义"入口。
///
/// 只改强调色，不动背景/文字 —— 换个颜色就够了，让用户自由改背景
/// 很容易调出一片看不清字的效果。
///
/// 想大改视觉的走下面 [ThemeBackgroundPicker]：那条路由用户自己显式
/// 选图和调浓度，出事也是他自己调出来的。
class _ThemeSeedPicker extends StatelessWidget {
  const _ThemeSeedPicker({required this.state});
  final AppState state;

  /// 预设的一组种子色。和 AppColors 自带那套 palette 同源，
  /// 保证挑出来的颜色在深色底上也够亮。
  static const List<Color> presets = <Color>[
    Color(0xFF007AFF), // 系统蓝
    Color(0xFF34C759), // 绿
    Color(0xFFFF9500), // 橙
    Color(0xFFFF2D55), // 玫红
    Color(0xFFAF52DE), // 紫
    Color(0xFF5856D6), // 靛蓝
    Color(0xFF00C7BE), // 青
    Color(0xFFFF6482), // 粉
  ];

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final current = state.themeSeed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '强调色',
          style: AppText.caption1.copyWith(color: c.secondaryLabel),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 9,
          runSpacing: 9,
          children: [
            for (final color in presets)
              _SeedDot(
                color: color,
                selected: current?.toARGB32() == color.toARGB32(),
                onTap: () => state.setThemeSeed(color),
              ),
            _CustomSeedDot(
              selected: current != null &&
                  !presets.any((p) => p.toARGB32() == current.toARGB32()),
              current: current,
              onTap: () => _pickCustomSeed(context, state),
            ),
          ],
        ),
      ],
    );
  }
}

/// 界面背景图：选一张本地图片铺在最底层，浓度和模糊都能调。
///
/// 做成一整块而不是几个行，是因为这三样（图、浓度、模糊）互相关联 ——
/// 换了图基本都要顺手重调浓度，拆开摆到设置页各处会很难用。
///
/// **不提供"内置图片"**：内置图会让安装包变大，而且用户多半想用自己的
/// 照片。代价是手机上得走文件选择器，桌面端就是普通打开文件对话框。
class ThemeBackgroundPicker extends StatelessWidget {
  const ThemeBackgroundPicker({super.key, required this.state});
  final AppState state;

  Future<void> _pick(BuildContext context) async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: '选一张图当界面背景',
      type: FileType.custom,
      allowedExtensions: <String>['jpg', 'jpeg', 'png', 'webp', 'gif', 'bmp'],
    );
    if (picked.isEmpty) return;
    final path = picked.first.path;
    if (path == null || path.trim().isEmpty) return;
    state.setThemeBackgroundPath(path);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final path = state.themeBackgroundPath;
    final has = path != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                '界面背景图',
                style: AppText.caption1.copyWith(color: c.secondaryLabel),
              ),
            ),
            if (has)
              Pressable(
                scale: 0.94,
                onTap: () => state.setThemeBackgroundPath(null),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(
                    '去掉',
                    style: AppText.caption1.copyWith(color: c.destructive),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Pressable(
          scale: 0.985,
          onTap: () => _pick(context),
          child: Container(
            height: 64,
            decoration: BoxDecoration(
              color: c.fill,
              borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
              image: has
                  ? DecorationImage(
                      image: ResizeImage(FileImage(File(path)),
                          width: 480, policy: ResizeImagePolicy.fit),
                      fit: BoxFit.cover,
                      // 缩略图压暗一点，好让中间那行字看得清
                      colorFilter: const ColorFilter.mode(
                        Color(0x66000000),
                        BlendMode.darken,
                      ),
                    )
                  : null,
            ),
            alignment: Alignment.center,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  has ? Icons.image_rounded : Icons.add_photo_alternate_rounded,
                  size: 16,
                  color: has ? Colors.white : c.secondaryLabel,
                ),
                const SizedBox(width: 6),
                Text(
                  has ? '换一张图' : '选一张图',
                  style: AppText.footnote.copyWith(
                    color: has ? Colors.white : c.secondaryLabel,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (has) ...[
          const SizedBox(height: 12),
          _SliderRow(
            label: '浓度',
            value: state.themeBackgroundOpacity,
            display: '${(state.themeBackgroundOpacity * 100).round()}%',
            onChanged: state.setThemeBackgroundOpacity,
          ),
          const SizedBox(height: 6),
          _SliderRow(
            label: '模糊',
            value: state.themeBackgroundBlur / 40,
            display: '${state.themeBackgroundBlur.round()}',
            onChanged: (v) => state.setThemeBackgroundBlur(v * 40),
          ),
          const SizedBox(height: 6),
          Text(
            // 说清楚代价，别让用户以为"背景图不花钱"
            '图片只是铺在下面，笔记内容仍存在数据库里；浓度调高会压住正文，深色主题下建议不用。',
            style: AppText.caption2.copyWith(color: c.tertiaryLabel),
          ),
        ],
      ],
    );
  }
}

/// 一行「标签 + 滑杆 + 数值」。设置页里只有背景图在用，先就地放这儿。
class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 34,
          child: Text(label,
              style: AppText.caption1.copyWith(color: c.secondaryLabel)),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: SliderComponentShape.noOverlay,
            ),
            child: Slider(value: value.clamp(0.0, 1.0), onChanged: onChanged),
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            display,
            textAlign: TextAlign.right,
            style: AppText.caption1.copyWith(color: c.secondaryLabel),
          ),
        ),
      ],
    );
  }
}

class _SeedDot extends StatelessWidget {
  const _SeedDot({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Pressable(
      onTap: onTap,
      scale: 0.9,
      child: Tooltip(
        message: selected ? '当前强调色' : '用这个颜色',
        child: AnimatedContainer(
          duration: AppMotion.respecting(context, AppMotion.fast),
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            // 选中态用一圈描边而不是勾：勾在浅色块上糊成一团
            border: Border.all(
              color: selected ? c.label : Colors.transparent,
              width: 2.5,
            ),
          ),
          child: selected
              ? const Icon(Icons.check_rounded, size: 16, color: Colors.white)
              : null,
        ),
      ),
    );
  }
}

class _CustomSeedDot extends StatelessWidget {
  const _CustomSeedDot({
    required this.selected,
    required this.current,
    required this.onTap,
  });

  final bool selected;
  final Color? current;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Pressable(
      onTap: onTap,
      scale: 0.9,
      child: Tooltip(
        message: '从色板里挑',
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: selected && current != null ? current : c.fill,
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? c.label : Colors.transparent,
              width: 2.5,
            ),
          ),
          child: Icon(
            Icons.colorize_rounded,
            size: 15,
            color: selected && current != null ? Colors.white : c.secondaryLabel,
          ),
        ),
      ),
    );
  }
}

/// 从 Material 色板里挑一个种子色。用系统自带的 picker 对话框 ——
/// 自己画 HSV 转盘要写一堆代码，还不一定有它好用。
Future<void> _pickCustomSeed(BuildContext context, AppState state) async {
  var picked = state.themeSeed ?? _ThemeSeedPicker.presets.first;
  final result = await showDialog<Color>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        final c = ctx.colors;
        return AlertDialog(
          title: const Text('挑一个强调色'),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  height: 54,
                  decoration: BoxDecoration(
                    color: picked,
                    borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
                  ),
                  child: const Center(
                    child: Icon(Icons.check_rounded,
                        color: Colors.white, size: 26),
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: [
                    for (final hue in <double>[
                      0, 20, 40, 60, 90, 120, 150, 170, 190, 210, 230, 250,
                      270, 290, 310, 330,
                    ])
                      for (final light in <double>[0.38, 0.5, 0.62])
                        GestureDetector(
                          onTap: () => setLocal(() {
                            picked = HSLColor.fromAHSL(1, hue, 0.72, light)
                                .toColor();
                          }),
                          child: Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              color: HSLColor.fromAHSL(1, hue, 0.72, light)
                                  .toColor(),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: picked.toARGB32() ==
                                        HSLColor.fromAHSL(1, hue, 0.72, light)
                                            .toColor()
                                            .toARGB32()
                                    ? c.label
                                    : Colors.transparent,
                                width: 2,
                              ),
                            ),
                          ),
                        ),
                  ],
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, picked),
              child: const Text('用这个'),
            ),
          ],
        );
      },
    ),
  );
  if (result != null) state.setThemeSeed(result);
}
