/// 正文里引用的**本地**图片/视频，按文档所在目录解析出来。
///
/// 为什么需要这一步：
///   - docx 里**内嵌**的图，解析器已经解出来了（`word/media/*` → 占位路径）
///   - 但还有一种很常见的情况：正文里就写着**相对路径**，文件躺在文档旁边，
///     或者在同级的 `xxx_files/`、`assets/`、`images/`、`media/` 里
///     —— 公众号/知乎/B站的各种导出、以及 Markdown 导出的附件目录都是这个形态
///
/// 以前这些引用会被**原样留在正文里**：笔记里看到一个打不开的路径，
/// 而文件其实就在文档旁边。用户看到的是"图片没导进来"。
///
/// 这个文件只做"找出引用 + 定位文件"，落盘和改写路径仍然在 ImportService 里，
/// 和 docx 内嵌图走同一条路 —— 两条路最后必须归到一套逻辑上，
/// 否则迟早出现"内嵌的能导、相对路径的不能导"这种半边可用。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../media/media_importer.dart';

/// 一条解析出来的本地媒体引用。
class LocalMediaRef {
  const LocalMediaRef({
    required this.reference,
    required this.file,
    required this.bytes,
  });

  /// 正文里原样的引用文本，用来做替换。
  final String reference;

  /// 磁盘上的源文件。
  final File file;

  final Uint8List bytes;

  /// 原始文件名（保留扩展名，决定落盘后的后缀）。
  String get fileName => p.basename(file.path);
}

/// 正文里可能引用本地文件的写法。
///
/// 覆盖三种：
///   1. Markdown 图片 `![alt](path)`
///   2. Markdown 链接/视频 `[文字](path)` —— 视频在 Markdown 里就是普通链接
///   3. HTML `<img src="...">` / `<video src="...">` / `<source src="...">`
final RegExp _mdLink = RegExp(r'!?\[[^\]]*\]\(\s*([^)\s]+)\s*\)');
final RegExp _htmlSrc = RegExp(
  '<(?:img|video|source|audio)[^>]*?src\\s*=\\s*["\']([^"\']+)["\']',
  caseSensitive: false,
);

/// 这些开头的引用一律不当本地文件：网络地址、内嵌数据、页内锚点。
bool _isRemote(String ref) {
  final s = ref.trim().toLowerCase();
  return s.isEmpty ||
      s.startsWith('http://') ||
      s.startsWith('https://') ||
      s.startsWith('data:') ||
      s.startsWith('mailto:') ||
      s.startsWith('#') ||
      s.startsWith('//');
}

/// 去掉 `?query` 和 `#fragment`，并把 `%XX` 解出来。
///
/// **不用 `Uri.decodeComponent`**：正文里的路径经常是"中文 + `%20`"混在一起
/// （`assets/图%201.png`），它在含非 ASCII 字符时会抛，抛了就退回原样 ——
/// 于是 `图%201.png` 这个文件名永远匹配不上真实存在的 `图 1.png`。
/// 这里自己按字节收 `%XX`、最后整体 utf8 解，两种字符都能正确处理。
String _cleanTarget(String raw) {
  var s = raw.trim();
  final q = s.indexOf('?');
  if (q >= 0) s = s.substring(0, q);
  final h = s.indexOf('#');
  if (h >= 0) s = s.substring(0, h);
  return _percentDecode(s);
}

String _percentDecode(String s) {
  final bytes = <int>[];
  final runes = s.runes.toList();
  for (var i = 0; i < runes.length; i++) {
    final c = runes[i];
    if (c == 0x25 && i + 2 < runes.length) {
      final b = int.tryParse(
        String.fromCharCodes(runes.sublist(i + 1, i + 3)),
        radix: 16,
      );
      if (b != null) {
        bytes.add(b);
        i += 2;
        continue;
      }
    }
    bytes.addAll(utf8.encode(String.fromCharCode(c)));
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// 常见附件目录名。导出工具各有各的习惯，多试几个比让用户手动搬文件强。
const List<String> _assetDirs = <String>[
  'assets',
  'images',
  'media',
  'files',
  'attachments',
  'img',
];

/// 找出 [markdown] 里引用的本地图片/视频，并读出字节。
///
/// [docDir] 是文档所在目录 —— 相对路径是相对**它**解析的。
/// 不存在的文件静默跳过：正文里留一个打不开的路径，总好过让整篇导入失败。
List<LocalMediaRef> resolveLocalMedia(String markdown, Directory docDir) {
  final seen = <String>{};
  final out = <LocalMediaRef>[];

  final refs = <String>[
    for (final m in _mdLink.allMatches(markdown)) m.group(1)!,
    for (final m in _htmlSrc.allMatches(markdown)) m.group(1)!,
  ];

  for (final raw in refs) {
    if (_isRemote(raw) || !seen.add(raw)) continue;
    final target = _cleanTarget(raw);
    if (_isRemote(target)) continue;

    final ext = MediaImporter.extensionOf(target);
    if (!MediaImporter.imageExts.contains(ext) &&
        !MediaImporter.videoExts.contains(ext)) {
      continue;
    }

    final file = _locate(docDir, target);
    if (file == null) continue;

    try {
      out.add(
        LocalMediaRef(
          reference: raw,
          file: file,
          bytes: file.readAsBytesSync(),
        ),
      );
    } catch (_) {
      // 读不出来（权限、被占用）就当没引用过
    }
  }
  return out;
}

/// 按几个候选位置找文件，找到第一个存在的。
File? _locate(Directory docDir, String target) {
  // Windows 上正文里可能写反斜杠
  final norm = target.replaceAll('\\', '/');
  final base = p.basename(norm);

  final candidates = <String>[
    // 1) 相对文档目录（`./a.png`、`sub/a.png`）
    p.join(docDir.path, p.joinAll(norm.split('/'))),
    // 2) 文档目录下一层（`assets/`、`xxx_files/` …）
    for (final d in _assetDirs) p.join(docDir.path, d, base),
    // 3) 就放在文档旁边
    p.join(docDir.path, base),
  ];

  for (final path in candidates) {
    final f = File(path);
    if (f.existsSync()) return f;
  }

  // 4) 兜底：把文档目录下面**一层子目录**都扫一遍，按文件名找。
  //
  // 导出工具的附件目录名五花八门（`文章名_files`、`文章名.assets`…），
  // 穷举名字迟早漏。按文件名找一层，比让用户手动去搬文件强，
  // 也比"猜名字"更可靠。**只扫一层**：再深就该让用户自己整理了。
  try {
    for (final e in docDir.listSync()) {
      if (e is! Directory) continue;
      final f = File(p.join(e.path, base));
      if (f.existsSync()) return f;
    }
  } catch (_) {
    // 目录读不了就算了
  }
  return null;
}
