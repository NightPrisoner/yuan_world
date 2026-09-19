/// 笔记的操作菜单。
///
/// 抽成独立模块的原因：同一个菜单要从三个入口调起，
///   - 列表项悬停的 ⋯ 按钮（贴着按钮弹）
///   - 列表项右键（贴着鼠标弹）
///   - 详情页右上角 ⋯
///
/// 桌面端贴着触发处弹出下拉菜单，手机端才从底部升面板——
/// 具体由 [showAppMenu] 按平台决定。
library;

import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../app_state.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_menu.dart';
import '../../../data/exporter/note_exporter.dart';
import '../../../data/models.dart';
import '../../collections/collection_sheets.dart';
import 'cover_picker.dart';

/// 菜单里用户可能触发的动作。
enum NoteAction {
  none,
  pin,
  favorite,
  moveCollection,
  archived,
  hide,
  cover,
  export,
  copyText,
  deleted,
}

/// 算出一篇笔记在文集树里的路径（外层在前）。
///
/// 用来在压缩包里还原目录结构。找不到所属文集就返回空表 = 放包根目录。
/// 加了 `seen` 防环：数据万一有循环父子关系，这里不能死循环。
List<String> collectionPathOf(Note note, List<Collection> all) {
  final byId = <int, Collection>{for (final c in all) c.id: c};
  final out = <String>[];
  final seen = <int>{};
  var cur = note.collectionId;
  while (cur != null && seen.add(cur)) {
    final c = byId[cur];
    if (c == null) break;
    out.insert(0, c.name);
    cur = c.parentId;
  }
  return out;
}

/// 多篇/整个文集导出：打成**一个压缩包**。
///
/// [items] 的 `path` 是包内目录层级（文集路径），空表示放根目录。
/// 直接调 [NoteExporter.zipBytes]，这个函数只负责"弹保存框 + 报结果"，
/// 和 [exportSingleNote] 保持同一套交互（都用 saveFile 传字节）。
Future<void> exportZip(
  BuildContext context, {
  required List<({List<String> path, Note note})> items,
  required ExportFormat format,
  required String zipName,
}) async {
  if (items.isEmpty || !context.mounted) return;
  final state = context.read<AppState>();

  final bytes = NoteExporter.zipBytes(
    items: items,
    format: format,
    imageRoot: state.db.imageRoot.path,
  );

  Uri? target;
  try {
    target = await FilePicker.saveFile(
      dialogTitle: '导出压缩包到',
      fileName: zipName,
      bytes: bytes,
      type: FileType.custom,
      allowedExtensions: <String>['zip'],
    );
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导出失败：$e')));
    return;
  }
  if (target == null || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('已导出 ${items.length} 篇：${target.toFilePath()}'),
      duration: const Duration(seconds: 4),
    ),
  );
}

/// 弹一个格式选择菜单。单篇和批量共用，免得两处选项对不上。
Future<ExportFormat?> pickExportFormat(
  BuildContext context, {
  String header = '导出为',
}) => showAppMenu<ExportFormat>(
  context,
  header: header,
  items: <AppMenuItem<ExportFormat>>[
    for (final f in ExportFormat.values)
      AppMenuItem(
        value: f,
        label: '${f.label}（.${f.ext}）',
        icon: Icons.description_outlined,
      ),
  ],
);

/// 单篇导出：选格式 → 选保存位置 → 写文件。
///
/// 单独做成顶层函数，是为了让**笔记菜单**和别处都能直接调 ——
/// 之前导出只藏在「多选 → 批量操作」里，想导一篇还得先进入多选模式，
/// 等于找不到入口。
Future<void> exportSingleNote(BuildContext context, Note note) async {
  if (!context.mounted) return;
  final state = context.read<AppState>();

  final format = await pickExportFormat(context);
  if (format == null || !context.mounted) return;

  final full = state.repo.getNote(note.id) ?? note;
  final suggested = '${NoteExporter.suggestedName(full)}.${format.ext}';
  final imageRoot = state.db.imageRoot.path;

  // file_picker 12.x 的 saveFile 要**传字节**，由它负责落盘，
  // 所以这里先把内容渲染出来，而不是自己去写路径
  final bytes = format.isBinary
      ? NoteExporter.renderDocxBytes(full, imageRoot: imageRoot)
      : Uint8List.fromList(
          utf8.encode(NoteExporter.render(full, format, imageRoot: imageRoot)),
        );

  Uri? target;
  try {
    target = await FilePicker.saveFile(
      dialogTitle: '导出到',
      fileName: suggested,
      bytes: bytes,
      type: FileType.custom,
      allowedExtensions: <String>[format.ext],
    );
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('导出失败：$e')),
    );
    return;
  }
  if (target == null || !context.mounted) return;

  // docx 里的视频没法嵌进文档，正文只留一行"视频在 XXX.files 文件夹"的说明。
  // 所以导出完要把视频真拷到文档旁边；用户如果改了文件名，正文也要跟着
  // 重写一次，否则那句话指向的是一个不存在的目录。
  if (format == ExportFormat.docx) {
    final savedPath = target.toFilePath();
    if (NoteExporter.videoRelsOf(full).isNotEmpty) {
      final savedBase = savedPath
          .split(RegExp(r'[\\/]'))
          .last
          .replaceAll(RegExp(r'\.[^.]+$'), '');
      if (savedBase != NoteExporter.suggestedName(full)) {
        File(savedPath).writeAsBytesSync(
          NoteExporter.renderDocxBytes(
            full,
            imageRoot: imageRoot,
            videoFolder: '$savedBase.files',
          ),
          flush: true,
        );
      }
      NoteExporter.copyVideosNextTo(savedPath, full, imageRoot: imageRoot);
    }
  }

  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('已导出：${target.toFilePath()}'),
      duration: const Duration(seconds: 4),
    ),
  );
}

/// 弹出笔记操作菜单并执行选中的动作。
///
/// [anchor] 决定桌面端菜单贴着哪里弹：按钮触发传按钮的 context，
/// 右键触发传指针坐标。
Future<NoteAction> showNoteActions(
  BuildContext context,
  Note note, {
  bool popOnDelete = false,
  AppMenuAnchor? anchor,
}) async {
  final state = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);

  final action = await showAppMenu<NoteAction>(
    context,
    anchor: anchor,
    header: note.title.isEmpty ? '无标题笔记' : note.title,
    items: <AppMenuItem<NoteAction>>[
      AppMenuItem(
        value: NoteAction.pin,
        label: note.isPinned ? '取消置顶' : '置顶',
        icon: note.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
      ),
      AppMenuItem(
        value: NoteAction.favorite,
        label: note.isFavorite ? '取消收藏' : '收藏',
        icon: note.isFavorite ? Icons.star_rounded : Icons.star_outline_rounded,
        color: context.colors.palette[7],
      ),
      const AppMenuItem(
        value: NoteAction.moveCollection,
        label: '移动到文集',
        icon: Icons.drive_file_move_outline,
      ),
      AppMenuItem(
        value: NoteAction.archived,
        label: note.isArchived ? '取消归档' : '归档',
        icon: note.isArchived ? Icons.unarchive_outlined : Icons.archive_outlined,
      ),
      // 在隐私空间里就反过来给「移出」—— 否则内容进去就再也出不来了
      AppMenuItem(
        value: NoteAction.hide,
        label: state.privacyMode ? '移出隐私空间' : '移入隐私空间',
        icon: state.privacyMode
            ? Icons.visibility_outlined
            : Icons.visibility_off_outlined,
      ),
      const AppMenuItem(
        value: NoteAction.cover,
        label: '设置头图',
        icon: Icons.wallpaper_rounded,
      ),
      const AppMenuItem(
        value: NoteAction.export,
        label: '导出为文件',
        icon: Icons.file_download_outlined,
      ),
      const AppMenuItem(
        value: NoteAction.copyText,
        label: '复制全文',
        icon: Icons.copy_rounded,
      ),
      AppMenuItem(
        value: NoteAction.deleted,
        label: '删除',
        icon: Icons.delete_outline_rounded,
        destructive: true,
      ),
    ],
  );

  if (action == null) return NoteAction.none;

  switch (action) {
    case NoteAction.pin:
      await state.togglePin(note);
    case NoteAction.favorite:
      await state.toggleFavorite(note);
    case NoteAction.moveCollection:
      if (context.mounted) await showCollectionPicker(context, note);
    case NoteAction.archived:
      await state.toggleArchive(note);
    case NoteAction.hide:
      // 隐藏后它会从当前列表里立刻消失，所以顺带退出详情页。
      // 在隐私空间里则相反：移出之后它同样会从当前列表消失。
      final movingOut = state.privacyMode;
      state.repo.setNoteHidden(note.id, movingOut ? false : true);
      await state.refresh();
      if (popOnDelete && context.mounted) Navigator.of(context).maybePop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            movingOut ? '已移出隐私空间，回到普通笔记里了' : '已移入隐私空间',
          ),
        ),
      );
    case NoteAction.cover:
      if (context.mounted) {
        final full = state.repo.getNote(note.id);
        if (full != null) await showCoverPicker(context, full);
      }
    case NoteAction.export:
      if (context.mounted) await exportSingleNote(context, note);
    case NoteAction.copyText:
      final full = state.repo.getNote(note.id);
      await Clipboard.setData(ClipboardData(text: full?.content ?? ''));
      messenger.showSnackBar(const SnackBar(content: Text('全文已复制到剪贴板')));
    case NoteAction.deleted:
      if (!context.mounted) return NoteAction.none;
      final ok = await _confirmDelete(context, note);
      if (ok != true) return NoteAction.none;
      await state.deleteNote(note.id);
      if (popOnDelete && context.mounted) Navigator.of(context).maybePop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '已删除「${note.title.isEmpty ? '无标题笔记' : note.title}」',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    case NoteAction.none:
      break;
  }
  return action;
}

Future<bool?> _confirmDelete(BuildContext context, Note note) {
  final c = context.colors;
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('删除这篇笔记？'),
      content: Text(
        note.title.isEmpty ? '无标题笔记' : note.title,
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
          child: const Text('删除'),
        ),
      ],
    ),
  );
}
