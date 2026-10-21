import 'media_importer.dart';

/// 与编辑器的整行媒体语法一致，从正文区分图片和视频。
/// 不依赖历史 image_count（早期版本把两种媒体混在该列）。
({int images, int videos}) countNoteMedia(String markdown) {
  var images = 0;
  var videos = 0;
  final linePattern = RegExp(r'^\s*!\[[^\]]*\]\(([^)]+)\)\s*$');
  for (final line in markdown.split('\n')) {
    final match = linePattern.firstMatch(line);
    if (match == null) continue;
    var path = match.group(1)!.trim();
    final titleAt = path.indexOf(RegExp('''\\s+["']'''));
    if (titleAt > 0) path = path.substring(0, titleAt);
    if (path.isEmpty || path.startsWith('http')) continue;
    if (MediaImporter.isVideo(path)) {
      videos++;
    } else {
      images++;
    }
  }
  return (images: images, videos: videos);
}
