/// 诊断信息弹窗：把"我这版本、这系统、这库大小、最近这几条错误"拼成一段
/// 能直接贴进 issue 的文本，并允许一键复制 / 全部清空。
///
/// 为什么不是"上传日志"：本应用的定位就是数据全在本机，不做任何上报。
/// 用户自己看得到、自己决定贴不贴，才是这套定位下正确的做法。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../core/app_info.dart';
import '../../core/diagnostics/crash_log.dart';
import '../../core/theme/app_theme.dart';

/// 拼出诊断文本（纯函数，方便测试）。
///
/// [now] 只在测试里固定时间用。
String buildDiagnosticsText({
  required AppState state,
  required String version,
  String? platformOverride,
  DateTime? now,
  int? logBytesOverride,
  int? crashCount,
}) {
  String two(int v) => v.toString().padLeft(2, '0');
  final t = now ?? DateTime.now();
  final stamp =
      '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';

  final int notes;
  final int collections;
  try {
    notes = state.notes.length;
    collections = state.collections.length;
  } catch (_) {
    // 库还没就绪时不该让诊断本身崩
    return '元世界诊断信息\n生成时间：$stamp\n版本：$version\n'
        '（数据库尚未就绪，读不到统计）\n';
  }

  final buffer = StringBuffer()
    ..writeln('元世界诊断信息')
    ..writeln('生成时间：$stamp')
    ..writeln('版本：$version')
    ..writeln('系统：${platformOverride ?? Platform.operatingSystem}');
  if (platformOverride == null) {
    try {
      buffer.writeln('系统版本：${Platform.operatingSystemVersion}');
    } catch (_) {}
  }
  buffer
    ..writeln('笔记：$notes 篇')
    ..writeln('文集：$collections 个')
    ..writeln('数据目录：${state.db.rootDir.path}');

  final logBytes = logBytesOverride ?? CrashLog.totalBytes();
  final logs = crashCount ?? CrashLog.files().length;
  buffer
    ..writeln('日志：$logs 份，共 ${_kb(logBytes)}')
    ..writeln();

  final recent = CrashLog.recentText(maxChars: 3000);
  if (recent.isEmpty) {
    buffer.writeln('最近的错误：没有记录到错误。');
  } else {
    buffer
      ..writeln('最近的错误（最新的在最后）：')
      ..writeln('────────────────────────')
      ..writeln(recent.trimRight());
  }
  return buffer.toString();
}

String _kb(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}

/// 打开诊断弹窗。
Future<void> showDiagnosticsSheet(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => const _DiagnosticsDialog(),
  );
}

class _DiagnosticsDialog extends StatefulWidget {
  const _DiagnosticsDialog();

  @override
  State<_DiagnosticsDialog> createState() => _DiagnosticsDialogState();
}

class _DiagnosticsDialogState extends State<_DiagnosticsDialog> {
  late String _text;

  @override
  void initState() {
    super.initState();
    _text = buildDiagnosticsText(
      state: context.read<AppState>(),
      version: AppInfo.version,
    );
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('诊断信息已复制，粘贴到反馈里就行'),
        duration: Duration(seconds: 3),
      ),
    );
  }

  void _clear() {
    CrashLog.clear();
    setState(() {
      _text = buildDiagnosticsText(
        state: context.read<AppState>(),
        version: AppInfo.version,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hasError = _text.contains('最近的错误（');
    return Dialog(
      backgroundColor: c.secondaryBackground,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppMetrics.radiusLg),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 620),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '诊断信息',
                    style: AppText.headline.copyWith(color: c.label),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '全部在本机生成，不会自动上传。复制后由你决定贴到哪里。',
                    style: AppText.caption1.copyWith(
                      color: c.tertiaryLabel,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 20),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: c.fill,
                  borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _text,
                    style: AppText.caption2.copyWith(
                      color: c.secondaryLabel,
                      height: 1.55,
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                children: [
                  if (hasError)
                    TextButton(
                      onPressed: _clear,
                      child: Text(
                        '清空日志',
                        style: AppText.callout.copyWith(color: c.destructive),
                      ),
                    ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text(
                      '关闭',
                      style: AppText.callout.copyWith(color: c.secondaryLabel),
                    ),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: _copy,
                    style: FilledButton.styleFrom(
                      backgroundColor: c.tint,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                    child: Text(
                      '复制',
                      style: AppText.callout.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
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
