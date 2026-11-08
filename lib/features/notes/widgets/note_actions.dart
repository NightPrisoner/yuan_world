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

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../../app_state.dart';
import '../../../core/platform/external_open.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/app_menu.dart';
import '../../../data/exporter/note_exporter.dart';
import '../../../data/exporter/note_times.dart';
import '../../../data/exporter/pdf_exporter.dart';
import '../../../data/media/media_importer.dart';
import '../../../data/models.dart';
import '../editor/body_segments.dart';
import '../../collections/collection_sheets.dart';
import '../../importer/directory_picker_page.dart';
import 'cover_picker.dart';
import '../../../data/repositories/note_repository.dart';

/// 保存框返回的 Uri 转成真实文件路径；拿不到就返回 null。
///
/// 桌面（Windows/macOS/Linux）上是 `file://`，转得出来。
/// 手机上是 SAF 的 document id —— `content://com.android...` 或者
/// `/document/msf:1234` 这种 —— `toFilePath()` 会抛
/// `Unsupported operation: Cannot extract a file path from a content URI`。
/// 导出完还要把图片视频拷到文件旁边，那需要真实目录，所以手机上不能走
/// 保存框，得改成"选一个文件夹"自己写盘（见 [_saveToPickedDir]）。
String? realPathOf(Uri target) {
  try {
    final path = target.toFilePath();
    return path.isEmpty ? null : path;
  } catch (_) {
    return null;
  }
}

/// 给用户看的位置说明。真路径拿不到时退回文件名，绝不抛异常 ——
/// 这句话是塞进 SnackBar 的，抛出去就连"已导出"都看不到了。
String describeSavedTarget(Uri target) {
  final path = realPathOf(target);
  if (path != null) return path;
  final parts = target.path.split('/').where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return '你选择的位置';
  final last = parts.last;
  try {
    return Uri.decodeComponent(last);
  } catch (_) {
    return last;
  }
}

/// 导出成功后告诉用户「图片视频去哪了」。
///
/// 用户的原话：「提示解释一下图片视频等文件会如何如何处理，打包在哪里」。
/// 这件事必须说清楚，因为四种格式对媒体的处理**各不相同**：
///   * docx：图片嵌进文档里，视频嵌不进去，只能放在旁边；
///   * pdf：同样只能嵌图片，视频在旁边的文件夹里；
///   * markdown / txt：正文里只有一行路径，图片视频都靠旁边的文件夹，
///     而且**必须整包一起移动**，否则链接全断。
String mediaHintOf(
  ExportFormat format, {
  required String mediaFolder,
  required int images,
  required int videos,
  bool insideZip = false,
}) {
  if (images == 0 && videos == 0) return '';
  final folder = insideZip ? '$mediaFolder/' : '「$mediaFolder」文件夹';
  final where = insideZip ? '包内 $folder 里' : '旁边的$folder里';
  final parts = <String>[];
  switch (format) {
    case ExportFormat.docx:
    case ExportFormat.pdf:
      final kind = format == ExportFormat.docx ? '文档' : 'PDF';
      if (images > 0) parts.add('$images 张图片已嵌进$kind');
      if (videos > 0) parts.add('$videos 个视频放$where');
      break;
    case ExportFormat.markdown:
    case ExportFormat.text:
      if (images > 0) parts.add('$images 张图片');
      if (videos > 0) parts.add('$videos 个视频');
      parts.add('都放$where，整包一起移动才不会断链');
      break;
  }
  return parts.join('；');
}

/// 导出前把"图片视频会怎么处理"讲清楚，用户点「继续」才往下走。
///
/// 为什么放在选格式之后、选位置之前：格式决定媒体的命运（嵌进文档 /
/// 放在旁边文件夹），所以只有拿到格式才说得准；而一旦弹出系统的保存框，
/// 用户注意力就跑到挑文件夹上了，那之后再解释已经晚了。
///
/// 没有媒体时直接放行，不打扰。
Future<bool> confirmExportMedia(
  BuildContext context,
  Note note,
  ExportFormat format,
) async {
  final media = mediaBreakdown(note.content);  if (media.images == 0 && media.videos == 0) return true;
  final folder = NoteExporter.mediaFolderOf(
    NoteExporter.suggestedName(note),
  );
  final lines = <String>[];
  switch (format) {
    case ExportFormat.docx:
      lines.add('图片会嵌进 Word 文档里，跟着文档走。');
      lines.add('视频不能嵌进 Word，会放在文档旁边同名的「$folder」文件夹里。');
      break;
    case ExportFormat.pdf:
      lines.add('图片会嵌进 PDF 里，跟着 PDF 走。');
      lines.add('视频不能嵌进 PDF，同样放在旁边的「$folder」文件夹里。');
      break;
    case ExportFormat.markdown:
      lines.add('正文里保留图片的引用路径（Markdown 原始写法）。');
      lines.add('${media.images} 张图片、${media.videos} 个视频都放在旁边的「$folder」文件夹里。');
      break;
    case ExportFormat.text:
      lines.add('正文里只有一行说明文字，看不到图。');
      lines.add('${media.images} 张图片、${media.videos} 个视频都放在旁边的「$folder」文件夹里。');
      break;
  }
  lines.add('整个文件夹一起移动，链接才不会断。');

  final c = context.colors;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('导出为 ${format.label}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                line,
                style: AppText.callout.copyWith(
                  color: c.secondaryLabel,
                  height: 1.5,
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('继续导出'),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// 批量导出（压缩包）时，媒体在包内的位置。
///
/// 和单篇的 [mediaHintOf] 分开写：单篇说的是"文件旁边有个文件夹"，
/// 批量说的是"压缩包里每篇各有一个文件夹" —— 两种交付形态，用户
/// 拿到手要先知道去哪找，否则解压完只看见一堆文档。
String zipMediaHint(ExportFormat format) => switch (format) {
  ExportFormat.docx ||
  ExportFormat.pdf =>
    '图片已嵌进文档；视频在包内每篇自己的「标题.files」文件夹里',
  ExportFormat.markdown ||
  ExportFormat.text =>
    '图片和视频都在包内每篇自己的「标题.files」文件夹里，'
        '正文里的路径就是它，解压后整包一起移动',
};

/// 手机上导出单篇：让用户选一个文件夹，由我们自己把字节写进去。
///
/// 为什么不复用保存框：`ACTION_CREATE_DOCUMENT` 只给 document id，
/// 拿不到真实路径，图片/视频就没法拷到文件旁边（用户看到的是
/// "导出成功，但图片和视频没跟过来"）。选文件夹 + 直接写盘这条路
/// 备份已经在用了，行为一致。
///
/// 需要「所有文件访问」：没有这个权限，写不进用户挑的公共目录。
Future<String?> _saveToPickedDir(
  BuildContext context, {
  required String fileName,
  required Uint8List bytes,
}) async {
  final messenger = ScaffoldMessenger.of(context);

  if (!await hasAllFilesAccess()) {
    final why = await requestAllFilesAccess();
    if (why != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(why),
          duration: const Duration(seconds: 6),
        ),
      );
    }
    return null;
  }
  if (!context.mounted) return null;

  final dir = await pickDirectoryManually(context, title: '导出到这个文件夹');
  if (dir == null || dir.trim().isEmpty) return null;

  final folder = Directory(dir.trim());
  try {
    if (!folder.existsSync()) folder.createSync(recursive: true);
    var file = File(p.join(folder.path, fileName));
    if (file.existsSync()) {
      // 同名不覆盖：用户可能已经导过一次，第二次不该把第一次的结果顶掉。
      final stem = p.basenameWithoutExtension(fileName);
      final ext = p.extension(fileName);
      for (var i = 2; i < 1000; i++) {
        final candidate = File(p.join(folder.path, '$stem ($i)$ext'));
        if (!candidate.existsSync()) {
          file = candidate;
          break;
        }
      }
    }
    file.writeAsBytesSync(bytes, flush: true);
    return file.path;
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(
        content: Text('导出失败：$e'),
        duration: const Duration(seconds: 6),
      ),
    );
    return null;
  }
}

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

/// 读出 PDF 用的内嵌中文字体（GBK 子集的思源黑体，7.4 MB）。
///
/// 为什么必须内嵌：PDF 阅读器只保证认得 PDF 自带的 14 种西文字体，
/// 中文一律靠系统字体兜底 —— 换个没装中文字体的机器就是满屏方框。
/// 所以导出时把字形跟着文档走。
///
/// 只在真要导 PDF 时才读：这是 7 MB 的资源，导个 txt 也读一遍是浪费。
Future<ByteData> loadPdfFont() async =>
    await rootBundle.load('assets/fonts/NotoSansSC-GBK-Regular.ttf');

/// 把导出时抛的异常翻译成用户看得懂的一句话。
///
/// 直接把 `$e` 塞给用户会出现
/// "PdfException: Widget won't fit into the page as its height ..." 这种
/// 完全不知道该怎么办的东西，所以按消息内容给出人话 + 保留原文。
///
/// 刻意不 `import package:pdf` 来做类型判断：这一层不该为了认一个
/// 异常类型把 PDF 库拉进 UI 依赖里，消息匹配足够稳（那几条都是
/// pdf 包写死的字符串）。
String _describeExportError(Object e) {
  final raw = e.toString();
  if (raw.contains("won't fit into the page")) {
    return '这一篇里有一段内容太高，一页放不下（$raw）';
  }
  if (raw.contains('Missing glyph')) {
    return '内嵌字体缺字：$raw';
  }
  if (raw.contains('more than') && raw.contains('pages')) {
    return '这篇太长，超过单次导出的页数上限（$raw）';
  }
  if (raw.contains('Out of memory') || raw.contains('OutOfMemory')) {
    return '内存不够了，试试先关掉别的程序，或者把这篇拆成两篇再导';
  }
  if (raw.contains('No space left')) {
    return '磁盘空间不足';
  }
  return raw.length > 160 ? '${raw.substring(0, 160)}…' : raw;
}

/// 多篇/整个文集导出：打成**一个压缩包**。
///
/// [items] 的 `path` 是包内目录层级（文集路径），空表示放根目录。
/// 直接调 [NoteExporter.zipBytesProgressive]，这个函数只负责"弹进度 + 弹保存框 + 报结果"。
///
/// **为什么要进度条**：一个几百篇的文集，渲染 + 打包要好几十秒，中间界面
/// 一动不动 —— 用户会以为点空了，然后再点一次。所以打包期间显示一个
/// 不可关闭的进度对话框，带一个取消按钮：打包中途取消就整个丢掉，
/// 不打开保存框、也不留下半截文件。
Future<void> exportZip(
  BuildContext context, {
  required List<({List<String> path, Note note})> items,
  required ExportFormat format,
  required String zipName,
}) async {
  if (items.isEmpty || !context.mounted) return;
  final state = context.read<AppState>();
  final imageRoot = state.db.imageRoot.path;

  final progress = ValueNotifier<double>(0);
  var dialogClosed = false;
  var cancelled = false;

  void closeDialog() {
    if (dialogClosed) return;
    dialogClosed = true;
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
  }

  // PDF 的字体要先读出来（7 MB），放到对话框之后再读，
  // 否则点下导出到进度条出现之间会有一段没有任何反馈的空白。
  unawaited(
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('正在导出'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (_, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                value >= 1
                    ? '正在压缩…'
                    : '${items.length} 篇正在打包… ${(value * 100).round()}%',
              ),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: value == 0 ? null : value),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () {
              cancelled = true;
              closeDialog();
            },
            child: const Text('取消导出'),
          ),
        ],
      ),
    ),
  );

  Uint8List? bytes;
  String? failure;
  try {
    bytes = await NoteExporter.zipBytesProgressive(
      items: items,
      format: format,
      imageRoot: imageRoot,
      // PDF 才用得上；其它格式读它等于白读 7 MB 字体，所以按需加载
      pdfFont: format == ExportFormat.pdf ? await loadPdfFont() : null,
      onProgress: (v) => progress.value = v,
      isCancelled: () => cancelled,
    );
  } on ExportCancelledException {
    // 用户自己取消的，不是错误
  } catch (e) {
    failure = _describeExportError(e);
  } finally {
    closeDialog();
    progress.dispose();
  }

  if (!context.mounted) return;
  if (cancelled) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已取消导出，没有留下文件'),
        duration: Duration(seconds: 3),
      ),
    );
    return;
  }
  if (bytes == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('导出失败：${failure ?? '未知原因'}'),
        duration: const Duration(seconds: 6),
      ),
    );
    return;
  }

  // 手机上不能用保存框：它只给 document id，拿不到真实路径。
  // 压缩包本身不需要往旁边拷东西，所以这条只是为了让"已导出到哪"
  // 这句话能说清楚 —— 保存框在 Android 上连 `toFilePath()` 都会抛。
  if (needsFileProvider) {
    final savedPath = await _saveToPickedDir(
      context,
      fileName: zipName,
      bytes: bytes,
    );
    if (!context.mounted || savedPath == null) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '已导出 ${items.length} 篇：$savedPath\n${zipMediaHint(format)}',
        ),
        duration: const Duration(seconds: 7),
      ),
    );
    return;
  }

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
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('导出失败：$e')));
    return;
  }
  if (target == null || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        '已导出 ${items.length} 篇：${describeSavedTarget(target)}\n'
        '${zipMediaHint(format)}',
      ),
      duration: const Duration(seconds: 7),
    ),
  );
}

/// 导出**整个文集**（含子文件夹）为压缩包。
///
/// 包内保留目录层级：`文集/子文件夹/标题.docx`。
///
/// 抽成顶层函数是因为它要在三处被调：桌面的文件夹右键菜单、
/// 手机能进的「文件夹管理」页（桌面原本是唯一的入口，手机上根本够不着），
/// 以后别处想加也一样。
Future<void> exportCollection(BuildContext context, Collection col) async {
  final state = context.read<AppState>();
  // 必须走 notesForExport —— 它会把正文一起取出来。
  // listNotes 走的是不含 content 列的轻量查询，直接拿它的结果去导出，
  // 出来的 docx 全是空壳（正文一个字都没有），用户报的正是这个问题。
  final notes = state.repo.notesForExport(collectionId: col.id);
  if (!context.mounted) return;
  if (notes.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('「${col.name}」里还没有笔记'),
        duration: const Duration(seconds: 2),
      ),
    );
    return;
  }

  final format = await pickExportFormat(
    context,
    header: '导出格式',
    // 文集导出默认给 Markdown / 纯文本 / Word：
    // Markdown / 纯文本 / Word 都能保持「一个文件夹一个目录」的整齐结构。
    formats: const <ExportFormat>[
      ExportFormat.markdown,
      ExportFormat.text,
      ExportFormat.docx,
      ExportFormat.pdf,
    ],
  );
  if (format == null || !context.mounted) return;

  await exportZip(
    context,
    items: <({List<String> path, Note note})>[
      for (final n in notes)
        (path: collectionPathOf(n, state.collections), note: n),
    ],
    format: format,
    // 压缩包名用文集名，用户一眼知道这是哪一包
    zipName: '${NoteExporter.safeZipName(col.name)}.zip',
  );
}

/// 弹一个格式选择菜单。单篇和批量共用，免得两处选项对不上。
///
/// [formats] 用来收窄可选项 —— 文集导出会给 Markdown / 纯文本 / Word / PDF。
Future<ExportFormat?> pickExportFormat(
  BuildContext context, {
  String header = '导出为',
  List<ExportFormat>? formats,
}) => showAppMenu<ExportFormat>(
  context,
  header: header,
  items: <AppMenuItem<ExportFormat>>[
    for (final f in formats ?? ExportFormat.values)
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

  // **先讲清楚再让人选位置。** 以前只有导出完的那句 SnackBar 说明媒体去向，
  // 用户点完格式就直接撞上文件保存框，根本不知道图片视频会怎么处理。
  if (!await confirmExportMedia(context, full, format)) return;
  if (!context.mounted) return;
  final suggested = '${NoteExporter.suggestedName(full)}.${format.ext}';
  final imageRoot = state.db.imageRoot.path;

  // file_picker 12.x 的 saveFile 要**传字节**，由它负责落盘，
  // 所以这里先把内容渲染出来，而不是自己去写路径。
  //
  // 渲染这一步必须包 try/catch：以前只有 saveFile 那段有保护，
  // 渲染抛异常就成了未捕获错误 —— 界面一点反应都没有，
  // 用户只能看到"点了没动静"（长文导出 PDF 就是这么卡住的）。
  final Uint8List bytes;
  // 正文里的**外部引用**（设置里开了「只引用原文件」之后，`![](C:\素材\a.png)`
  // 这种）在导出的 .md 里必须改写成包内路径，否则换台机器就断了。
  // docx / pdf 不用改：图片是嵌进文档里的。
  //
  // 顺带把这篇笔记要带走的媒体（图片/视频，内部与外部的都算）整理好：
  // 条目名统一是 `<标题>.files/<原名>`，导出后拷到文件旁边。
  // [folderStem] 留空 = 跟随笔记标题；用户在保存框里改过名字就传新名字，
  // 否则文件夹名和文件名对不上。
  final prepared = NoteExporter.prepareExternal(
    full,
    format,
    imageRoot: imageRoot,
  );
  try {
    if (format == ExportFormat.pdf) {
      bytes = await PdfExporter.renderBytes(
        full,
        font: await loadPdfFont(),
        imageRoot: imageRoot,
        mediaFolder: prepared.mediaFolder,
      );
    } else if (format.isBinary) {
      bytes = NoteExporter.renderDocxBytes(
        full,
        imageRoot: imageRoot,
        videoFolder: prepared.mediaFolder,
      );
    } else {
      bytes = Uint8List.fromList(
        utf8.encode(
          NoteExporter.renderWith(full, format, prepared.content),
        ),
      );
    }
  } catch (e) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('导出失败：${_describeExportError(e)}'),
        duration: const Duration(seconds: 6),
      ),
    );
    return;
  }
  if (!context.mounted) return;

  // 手机：自己挑文件夹 + 自己写盘，这样"文件旁边"是真实目录，
  // 图片/视频才拷得过去（保存框在 Android 上只给 document id）。
  // 桌面：仍用系统保存框，用户能自由选文件名。
  final bool mobile = needsFileProvider;
  final String? savedPath;
  if (mobile) {
    savedPath = await _saveToPickedDir(
      context,
      fileName: suggested,
      bytes: bytes,
    );
    if (!context.mounted || savedPath == null) return;
  } else {
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('导出失败：$e')));
      return;
    }
    if (target == null || !context.mounted) return;
    savedPath = realPathOf(target);
    if (savedPath == null) {
      // 理论上到不了（桌面一定是 file://），但真到了也不能让后面的
      // 媒体拷贝去崩：只报一句"已导出"，位置退回文件名。
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已导出：${describeSavedTarget(target)}'),
          duration: const Duration(seconds: 4),
        ),
      );
      return;
    }
  }

  // docx 里的视频没法嵌进文档，正文只留一行"视频在 XXX.files 文件夹"的说明。
  // 所以导出完要把视频真拷到文档旁边；用户如果改了文件名，正文也要跟着
  // 重写一次，否则那句话指向的是一个不存在的目录。
  //
  // **这里以前全是裸调用**：Android 上 `toFilePath()` 一抛就被外层 catch
  // 吃掉，表现成"docx 导出了，但 .files 文件夹没有，也没报错"。
  // 现在包起来并给出可见提示 —— 媒体没跟过去，用户得知道。
  String? mediaWarning;
  // 提到 try 外面：最后的提示要按它算"媒体在哪、有几张图/几个视频"，
  // 而这段逻辑可能因为改名重算过一次（见下）
  var media = prepared;
  try {
    final savedBase = p.basenameWithoutExtension(savedPath);
    // 用户在保存框里改过文件名：媒体文件夹也得跟着改，否则
    // `我的笔记 (2).pdf` 旁边挂着一个 `我的笔记.files/`，看着就是错的。
    if (savedBase != NoteExporter.suggestedName(full)) {
      media = NoteExporter.prepareExternal(
        full,
        format,
        imageRoot: imageRoot,
        folderStem: savedBase,
      );
      // 二进制文档里那句"该文件已随导出放入「xxx.files」"是按旧名字写的，
      // 得重新渲染一遍才对得上。文本格式的正文由下面的改写覆盖不到
      // （保存框改名时正文不动），但 txt/md 里写的是改名后的相对路径，
      // 这里按媒体文件夹统一拷过去即可。
      if (format == ExportFormat.pdf) {
        File(savedPath).writeAsBytesSync(
          await PdfExporter.renderBytes(
            full,
            font: await loadPdfFont(),
            imageRoot: imageRoot,
            mediaFolder: media.mediaFolder,
          ),
          flush: true,
        );
      } else if (format.isBinary) {
        File(savedPath).writeAsBytesSync(
          NoteExporter.renderDocxBytes(
            full,
            imageRoot: imageRoot,
            videoFolder: media.mediaFolder,
          ),
          flush: true,
        );
      }
    }
    // 不管哪种格式，媒体都拷到导出文件旁边（`<标题>.files/` 下），
    // 和正文/文档里引用的路径逐字对上。
    NoteExporter.copyExtrasNextTo(savedPath, media.extras);
  } catch (e) {
    mediaWarning = '$e';
  }

  // 时间戳跟随笔记：保存框写出来的文件默认是"刚刚"，用户在资源管理器里
  // 按时间找不到这篇，得手动改一遍。这里直接改成笔记的创建/修改时间。
  try {
    applyNoteTimes(
      savedPath,
      created: full.createdAt,
      modified: full.updatedAt,
    );
  } catch (_) {
    // 时间戳失败不影响"文件已经导出成功"这个事实
  }

  if (!context.mounted) return;
  // 媒体怎么处理、放在哪 —— 这句必须跟着"已导出"一起说，否则用户
  // 只看到文档，不知道图片视频在哪（docx/pdf 里它们根本不在正文里）。
  final hint = mediaHintOf(
    format,
    mediaFolder: media.mediaFolder,
    images: media.extras.where((e) => !MediaImporter.isVideoPath(e.target))
        .length,
    videos: media.extras.where((e) => MediaImporter.isVideoPath(e.target))
        .length,
  );
  final head = mediaWarning == null
      ? '已导出：$savedPath'
      : '文档已导出，但图片/视频没跟过去（$mediaWarning）';
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(hint.isEmpty ? head : '$head\n$hint'),
      duration: Duration(seconds: mediaWarning == null ? 6 : 8),
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
        icon: note.isArchived
            ? Icons.unarchive_outlined
            : Icons.archive_outlined,
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
        label: '编辑头图',
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
        SnackBar(content: Text(movingOut ? '已移出隐私空间，回到普通笔记里了' : '已移入隐私空间')),
      );
    case NoteAction.cover:
      if (context.mounted) {
        final full = state.repo.getNote(note.id);
        if (full != null) {
          final changed = await showCoverPicker(context, full);
          // 编辑器里保存的是数据库，列表/详情页手里还是打开时读的旧对象。
          // 不刷新的话用户会看到"保存成功了但画面没变"。
          if (changed) state.refreshListOnly();
        }
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
          content: Text('已删除「${note.title.isEmpty ? '无标题笔记' : note.title}」'),
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
