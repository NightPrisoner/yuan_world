/// 「外部文件」引用：正文里的图片/视频不拷进 `data/images/`，
/// 而是直接写磁盘上的绝对路径。
///
/// 为什么要有这个开关：
///   - 默认仍然是**复制进来**（整个 data 目录拷走就是完整备份，原文件
///     被挪走也不会断）。这是绝大多数人需要的。
///   - 但有人素材库本来就整理得好好的（几百兆的视频、一整个参考图库），
///     拷一份进来等于占两遍空间，改一张还要重新插一次。对他们来说
///     "引用原位置"才是对的。
///
/// 开关是全局的，不做到每一篇：同一个素材库被十几篇笔记引用，
/// 逐篇设一次没人受得了。
///
/// 怎么区分两种引用：**看是不是绝对路径**。
///   - 内部：`7/a.png`（相对 `data/images/`）
///   - 外部：`C:\素材\a.png`、`/sdcard/Pictures/a.png`
///
/// 这个判据不需要在数据库里多存一列，也不会因为老笔记而失效 ——
/// 老笔记里的引用本来就是相对路径。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'media_importer.dart';

class ExternalMedia {
  const ExternalMedia._();

  /// 这条引用是不是"软件之外的文件"。
  ///
  /// `p.isAbsolute` 在 Windows 上认 `C:\x`、`\\nas\x`、`/x`，
  /// 在 Android/Linux 上认 `/x` —— 正好是两端各自的真实路径形态。
  static bool isExternal(String ref) {
    final s = ref.trim();
    if (s.isEmpty) return false;
    if (s.startsWith('file://')) return true;
    return p.isAbsolute(s);
  }

  /// 把引用还原成可以直接 `File(...)` 的路径。
  ///
  /// `file:///E:/a%20b/c.png` 这种（浏览器、剪贴板里常见）要解出来；
  /// 解不开就原样返回，交给调用方去判断存在性。
  static String localPath(String ref) {
    final s = ref.trim();
    if (!s.startsWith('file://')) return s;
    try {
      return Uri.parse(s).toFilePath();
    } catch (_) {
      return s;
    }
  }

  /// 文件在不在。
  static bool exists(String ref) {
    if (!isExternal(ref)) return false;
    try {
      return File(localPath(ref)).existsSync();
    } catch (_) {
      return false;
    }
  }

  /// 给用户看的短名字：外部文件只显示文件名，完整路径放到提示里。
  static String displayName(String ref) {
    final path = localPath(ref);
    final name = p.basename(path);
    return name.isEmpty ? path : name;
  }

  /// 把正文里的引用还原成可以直接打开的绝对路径。
  ///
  /// **内部文件拼 `imageRoot`，外部文件原样用** —— 这一个函数把两种形态
  /// 收在一处，界面层就不用到处写 `isExternal ? … : p.join(…)`。
  /// `p.join` 本身遇到绝对路径会放行，但 `file://` 形态它处理不了，
  /// 而且写成显式判断，读代码的人才知道这里有两条路。
  static String resolve(String imageRoot, String ref) {
    final s = ref.trim();
    if (!isExternal(s)) return p.join(imageRoot, s);
    return localPath(s);
  }

  /// 正文里所有**外部**图片/视频引用（去重、保持出现顺序）。
  ///
  /// 备份和导出都要用它：内部文件跟着 `data/images/` 走，外部文件
  /// 得单独收，否则"备份里少了东西"这件事用户永远发现不了 ——
  /// 等他换台机器恢复完才发现，已经晚了。
  static List<String> refsIn(String markdown) {
    final out = <String>[];
    for (final block in _mediaBlocks(markdown)) {
      if (!isExternal(block)) continue;
      if (!out.contains(block)) out.add(block);
    }
    return out;
  }

  /// 正文里所有外部引用里**图片**那部分（docx 里只能嵌图片）。
  static List<String> imagesIn(String markdown) => refsIn(
    markdown,
  ).where((r) => !MediaImporter.isVideoPath(localPath(r))).toList();

  /// 正文里所有外部引用里**视频**那部分。
  static List<String> videosIn(String markdown) => refsIn(
    markdown,
  ).where((r) => MediaImporter.isVideoPath(localPath(r))).toList();

  /// 逐行找「整行一张图」的引用，和 `imagePathOf` 同一套判据。
  static List<String> _mediaBlocks(String markdown) {
    final out = <String>[];
    final line = RegExp(r'^\s*!\[[^\]]*\]\(([^)]+)\)\s*$');
    for (final raw in markdown.split('\n')) {
      final m = line.firstMatch(raw);
      if (m == null) continue;
      var ref = m.group(1)!.trim();
      if (ref.isEmpty || ref.startsWith('http')) continue;
      // Markdown 允许 `![说明](a.png "标题")`
      final quoteAt = ref.indexOf(RegExp('''\\s+["']'''));
      if (quoteAt > 0) ref = ref.substring(0, quoteAt).trim();
      if (ref.isEmpty) continue;
      out.add(ref);
    }
    return out;
  }
}
