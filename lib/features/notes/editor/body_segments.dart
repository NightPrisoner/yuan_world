/// 把正文按图片行拆成「文字段 ↔ 图片」交替的块。
///
/// 为什么需要：编辑器是纯文本输入框，画不出真图。要让图片在正文里显示，
/// 就得把它切成若干段 —— 文字段各是一个输入框，图片段渲染成真正的图。
///
/// **生命线是「拆分 → 拼回」必须无损**：只要有一处对不上，
/// 每次编辑都会悄悄改坏用户的正文。所以这套逻辑写成纯函数并单独测。
library;

import '../../../data/media/media_importer.dart';

/// 一段正文。
sealed class BodySegment {
  const BodySegment();
}

/// 一段文字（可能含换行，但不含整行的图片）。
class TextSegment extends BodySegment {
  const TextSegment(this.text);
  final String text;

  @override
  bool operator ==(Object other) =>
      other is TextSegment && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

/// 一整行就是一张图。
class ImageSegment extends BodySegment {
  const ImageSegment(this.raw, this.path);

  /// 原始那一行，拼回时原样写回去。
  ///
  /// 不能只存路径再重新生成 —— 用户可能写了 `![说明](a.png "标题")`，
  /// 重新生成会把说明和标题丢掉。
  final String raw;

  /// 相对图片根目录的路径，渲染用。
  final String path;

  @override
  bool operator ==(Object other) =>
      other is ImageSegment && other.raw == raw && other.path == path;

  @override
  int get hashCode => Object.hash(raw, path);
}

/// 整行图片的正则：允许前后空白。
final RegExp _imageLine = RegExp(r'^\s*!\[[^\]]*\]\(([^)]+)\)\s*$');

bool isImageLine(String line) => _imageLine.hasMatch(line);

/// 从一整行里取出图片路径；不是图片行返回 null。
///
/// 外链（http）返回 null —— 那是网络图，本地渲染不了。
String? imagePathOf(String line) {
  final m = _imageLine.firstMatch(line);
  if (m == null) return null;
  var path = m.group(1)!.trim();
  if (path.isEmpty || path.startsWith('http')) return null;
  // Markdown 允许 `![说明](a.png "标题")`，标题不属于路径
  final quoteAt = path.indexOf(RegExp('''\\s+["']'''));
  if (quoteAt > 0) path = path.substring(0, quoteAt).trim();
  if (path.isEmpty) return null;
  // 导入阶段遗留的占位前缀
  if (path.startsWith('images/')) path = path.substring('images/'.length);
  return path;
}

/// 拆分。空正文返回空列表。
List<BodySegment> splitBodySegments(String body) {
  if (body.isEmpty) return const <BodySegment>[];

  final out = <BodySegment>[];
  final buffer = <String>[];

  void flush() {
    if (buffer.isEmpty) return;
    out.add(TextSegment(buffer.join('\n')));
    buffer.clear();
  }

  for (final line in body.split('\n')) {
    final path = imagePathOf(line);
    if (path == null) {
      buffer.add(line);
      continue;
    }
    flush();
    out.add(ImageSegment(line, path));
  }
  flush();
  return out;
}

/// 保证至少有一个**文字段**。
///
/// 编辑器必须调它，否则会出现"想打字没地方打"：
///   - **空笔记** → 分段结果是空列表 → 一个输入框都没渲染
///   - **正文全是图片** → 只有图片段，同样没有落笔的地方
///
/// 这个 bug 真出现过：新建笔记后完全无法输入。
List<BodySegment> ensureTextSegment(List<BodySegment> segments) {
  if (segments.any((s) => s is TextSegment)) return segments;
  return <BodySegment>[...segments, const TextSegment('')];
}

/// 拼回。与 [splitBodySegments] 严格互逆。
String joinBodySegments(List<BodySegment> segments) => segments
    .map((s) => switch (s) {
          TextSegment(:final text) => text,
          ImageSegment(:final raw) => raw,
        })
    .join('\n');

/// 图片段的展示位置（第几张图），用于显示 "图 1 / 3"。
int imageIndexOf(List<BodySegment> segments, int segmentIndex) {
  var n = 0;
  for (var i = 0; i <= segmentIndex && i < segments.length; i++) {
    if (segments[i] is ImageSegment) n++;
  }
  return n;
}

int imageCountOf(List<BodySegment> segments) =>
    segments.whereType<ImageSegment>().length;

/// 正文里所有媒体的数量（图片 + 动图 + 视频）。
///
/// 视频在正文里和图片用同一套 `![](路径)` 语法，所以这里一并统计 ——
/// 从"这篇里有多少个可视素材"的角度看，它们是一回事。
int mediaCountOf(String markdown) => imageCountOf(splitBodySegments(markdown));

/// 分开数：图片（含动图）与视频各多少。
///
/// 详情页那行要分别显示，用户才知道"2 图 1 视频"而不是笼统的"3 个"。
({int images, int videos}) mediaBreakdown(String markdown) {
  var images = 0;
  var videos = 0;
  for (final seg in splitBodySegments(markdown)) {
    if (seg is! ImageSegment) continue;
    if (MediaImporter.isVideo(seg.path)) {
      videos++;
    } else {
      images++;
    }
  }
  return (images: images, videos: videos);
}
