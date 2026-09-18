/// 纯文本（.txt）导入。
///
/// 比 docx 简单得多，但**编码**是唯一的坑：中文 txt 在国内 Windows 上
/// 大量是 GBK，直接按 UTF-8 解会得到一屏乱码。所以按优先级依次尝试：
///   BOM（UTF-8 / UTF-16）→ 严格 UTF-8 → GBK
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';

import 'docx_importer.dart';

class TxtImporter {
  const TxtImporter._();

  /// 解码字节流。BOM 优先，其次严格 UTF-8，最后退回 GBK。
  static String decodeText(Uint8List bytes) {
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return utf8.decode(bytes.sublist(3), allowMalformed: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return _utf16(bytes.sublist(2), littleEndian: true);
    }
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return _utf16(bytes.sublist(2), littleEndian: false);
    }

    // 没有 BOM：先按严格 UTF-8 试。
    // 用严格模式而不是 allowMalformed —— 后者对 GBK 字节不会抛错，
    // 而是静静地解出一堆问号，我们就再也没机会退回 GBK 了。
    try {
      return utf8.decode(bytes);
    } on FormatException {
      try {
        return gbk.decode(bytes);
      } catch (_) {
        // GBK 也解不了（可能是别的编码），尽力而为，别让导入失败
        return utf8.decode(bytes, allowMalformed: true);
      }
    }
  }

  static String _utf16(Uint8List b, {required bool littleEndian}) {
    final codes = <int>[];
    for (var i = 0; i + 1 < b.length; i += 2) {
      codes.add(littleEndian ? b[i] | (b[i + 1] << 8) : (b[i] << 8) | b[i + 1]);
    }
    return String.fromCharCodes(codes);
  }

  /// 解析成和 docx 相同的结构，后面的导入流程完全复用。
  static ParsedDocument parse(Uint8List bytes, {String? fallbackTitle}) {
    final raw = decodeText(bytes);
    // 统一换行，免得正文里混着 \r\n 影响后续按行处理
    final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    final lines = text.split('\n');
    var titleIndex = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim().isEmpty) continue;
      titleIndex = i;
      break;
    }

    // 标题取第一行非空内容；整篇都是空的就退回文件名
    var title = titleIndex >= 0 ? lines[titleIndex].trim() : '';
    if (title.runes.length > 60) {
      title = String.fromCharCodes(title.runes.take(60));
    }
    if (title.isEmpty) title = fallbackTitle?.trim() ?? '未命名';

    // 正文从标题的**下一行**开始，标题本身不重复写进正文
    final body = titleIndex >= 0
        ? lines.sublist(titleIndex + 1).join('\n').trim()
        : '';

    return ParsedDocument(
      title: title,
      markdown: body,
      images: const <ParsedImage>[],
    );
  }
}
