/// 笔记导出：把笔记渲染成常见文本格式。
///
/// 渲染写成纯函数（笔记 → 字符串），和文件写入分开 ——
/// 格式对不对是能直接测的，而"存到哪个目录"测起来麻烦得多。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../../core/utils/text_stats.dart';
import '../../core/utils/toc.dart';
import '../models.dart';

/// 支持的导出格式。
enum ExportFormat {
  markdown('Markdown', 'md'),
  text('纯文本', 'txt'),
  docx('Word 文档', 'docx'),
  html('网页', 'html');

  const ExportFormat(this.label, this.ext);
  final String label;
  final String ext;

  /// 是不是二进制格式（不能按字符串写文件）。
  bool get isBinary => this == ExportFormat.docx;

  static ExportFormat? byExt(String e) {
    for (final f in values) {
      if (f.ext == e) return f;
    }
    return null;
  }
}

/// 导出到 docx 时收集到的一张图片。
class _DocxImage {
  const _DocxImage({
    required this.relId,
    required this.fileName,
    required this.bytes,
    required this.size,
    required this.sourceRel,
  });

  final String relId;
  final String fileName;
  final Uint8List bytes;
  final ({int width, int height}) size;

  /// 正文里原始的相对路径，用来把 block 和图片对上。
  final String sourceRel;
}

class NoteExporter {
  const NoteExporter._();

  /// 渲染单篇。[imageRoot] 用于 HTML 里把图片写成绝对路径。
  static String render(
    Note note,
    ExportFormat format, {
    String? imageRoot,
  }) =>
      switch (format) {
        ExportFormat.markdown => _markdown(note),
        ExportFormat.text => _plainText(note),
        ExportFormat.html => _html(note, imageRoot),
        // docx 是二进制，走 renderDocxBytes；这里给个占位避免漏判
        ExportFormat.docx => _markdown(note),
      };

  // ── Word（.docx） ────────────────────────────────────────────────────────
  //
  // docx 本质是个 zip。除了三份必需的 part，**嵌图片还要三样东西**：
  //   word/media/imageN.png          图片本体
  //   word/_rels/document.xml.rels   把 rId 映射到图片
  //   [Content_Types].xml 里声明 png/jpeg 的默认类型
  // 少任何一样，Word 都会报"文件已损坏"或者图片变成红叉。

  static Uint8List renderDocxBytes(Note note, {String? imageRoot}) {
    final blocks = parseContent(note.content);

    // 先把正文里引用到的图片收集起来，编号从 1 开始（rId 也一样）
    final images = <_DocxImage>[];
    for (final block in blocks) {
      if (block.type != ContentBlockType.image) continue;
      final rel = _imagePathOf(block.text.trim());
      if (rel.isEmpty) continue;

      final file = imageRoot == null ? File(rel) : File(p.join(imageRoot, rel));
      if (!file.existsSync()) continue;

      final bytes = file.readAsBytesSync();
      final ext = p.extension(rel).toLowerCase().replaceFirst('.', '');
      images.add(
        _DocxImage(
          relId: 'rIdImg${images.length + 1}',
          fileName: 'image${images.length + 1}.${ext.isEmpty ? 'png' : ext}',
          bytes: bytes,
          size: _imageSize(bytes),
          sourceRel: rel,
        ),
      );
    }

    final contentTypes = StringBuffer(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
      '<Default Extension="xml" ContentType="application/xml"/>',
    );
    // 每种实际用到的图片扩展名都要声明，否则 Word 不认识 media 里的文件
    for (final ext in images.map((i) => p.extension(i.fileName).substring(1)).toSet()) {
      contentTypes.write(
        '<Default Extension="$ext" ContentType="${_mimeOf(ext)}"/>',
      );
    }
    contentTypes.write(
      '<Override PartName="/word/document.xml" '
      'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
      '</Types>',
    );

    final archive = Archive()
      ..addFile(ArchiveFile.string('[Content_Types].xml', contentTypes.toString()))
      ..addFile(ArchiveFile.string(
        '_rels/.rels',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '</Relationships>',
      ))
      ..addFile(ArchiveFile.string('word/document.xml', _documentXml(note, blocks, images)));

    if (images.isNotEmpty) {
      final rels = StringBuffer(
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
      );
      for (final img in images) {
        rels.write(
          '<Relationship Id="${img.relId}" '
          'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" '
          'Target="media/${img.fileName}"/>',
        );
        archive.addFile(ArchiveFile('word/media/${img.fileName}', img.bytes.length, img.bytes));
      }
      rels.write('</Relationships>');
      archive.addFile(
        ArchiveFile.string('word/_rels/document.xml.rels', rels.toString()),
      );
    }

    return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
  }

  static String _documentXml(
    Note note,
    List<ContentBlock> blocks,
    List<_DocxImage> images,
  ) {
    var imgIndex = 0;
    final b = StringBuffer()      ..write('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
      ..write('<w:document '
          'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
          'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" '
          'xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" '
          'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
          'xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">'
          '<w:body>');

    if (note.title.trim().isNotEmpty) {
      // 用 Word 的「标题」样式，而不是手动加粗放大 ——
      // 这样在 Word 里能生成导航目录
      b.write('<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr>'
          '<w:r><w:t xml:space="preserve">${_xesc(note.title.trim())}</w:t></w:r></w:p>');
    }

    // 目录写在正文之前 —— 长文拿到 docx 之后不用一路滚到底
    final toc = tocOf(note);
    if (toc.isNotEmpty) {
      b.write(_para('目录'));
      final minLevel =
          toc.map((e) => e.level).reduce((a, b) => a < b ? a : b);
      for (final e in toc) {
        // 缩进用 twips：360 twips = 0.25 英寸
        final indent = (e.level - minLevel) * 360;
        b.write('<w:p><w:pPr><w:ind w:left="$indent"/></w:pPr>'
            '<w:r><w:t xml:space="preserve">'
            '${_xesc(stripInlineMarkers(e.text).trim())}</w:t></w:r></w:p>');
      }
    }

    // 连续的 Markdown 表格行要合成一个**真正的 Word 表格**。
    // 不合成的话，往返一趟表格就退化成一行行带竖线的文字。
    var i = 0;
    while (i < blocks.length) {
      final block = blocks[i];

      if (_isTableRow(block)) {
        final rows = <List<String>>[];
        while (i < blocks.length && _isTableRow(blocks[i])) {
          final cells = _splitTableRow(blocks[i].text.trim());
          // `| --- | --- |` 是表头分隔行，Word 里不需要
          final isSeparator = cells.isNotEmpty &&
              cells.every((cell) => RegExp(r'^:?-{2,}:?$').hasMatch(cell.trim()));
          if (!isSeparator) rows.add(cells);
          i++;
        }
        if (rows.isNotEmpty) b.write(_tableXml(rows));
        continue;
      }

      if (block.type == ContentBlockType.image) {
        final rel = _imagePathOf(block.text.trim());
        _DocxImage? img;
        for (final candidate in images) {
          if (candidate.sourceRel == rel) {
            img = candidate;
            break;
          }
        }
        if (img == null) {
          // 图片文件找不到（可能被删了），退化成一行文字说明，
          // 总比整篇导出失败强
          b.write(_para('[图片] $rel'));
        } else {
          imgIndex++;
          b.write(_imageXml(img, imgIndex));
        }
      } else {
        b.write(_paragraphXml(block));
      }
      i++;
    }

    b.write('<w:sectPr/></w:body></w:document>');
    return b.toString();
  }

  /// 这一块是不是 Markdown 表格的一行。
  static bool _isTableRow(ContentBlock block) {
    if (block.type != ContentBlockType.paragraph) return false;
    final t = block.text.trim();
    return t.startsWith('|') && t.endsWith('|') && t.length > 2;
  }

  /// 拆 `| a | b |` → `['a', 'b']`。
  static List<String> _splitTableRow(String line) {
    var body = line;
    if (body.startsWith('|')) body = body.substring(1);
    if (body.endsWith('|')) body = body.substring(0, body.length - 1);
    // 转义过的竖线先占位，免得被当成列分隔
    const placeholder = '\u0001';
    body = body.replaceAll(r'\|', placeholder);
    return body
        .split('|')
        .map((c) => c.replaceAll(placeholder, '|').trim())
        .toList();
  }

  /// 一个 Word 表格。
  static String _tableXml(List<List<String>> rows) {
    final width = rows.map((r) => r.length).reduce((a, b) => a > b ? a : b);
    final b = StringBuffer(
      '<w:tbl>'
      '<w:tblPr><w:tblW w:w="0" w:type="auto"/><w:tblBorders>'
      '<w:top w:val="single" w:sz="4" w:color="BFBFBF"/>'
      '<w:left w:val="single" w:sz="4" w:color="BFBFBF"/>'
      '<w:bottom w:val="single" w:sz="4" w:color="BFBFBF"/>'
      '<w:right w:val="single" w:sz="4" w:color="BFBFBF"/>'
      '<w:insideH w:val="single" w:sz="4" w:color="BFBFBF"/>'
      '<w:insideV w:val="single" w:sz="4" w:color="BFBFBF"/>'
      '</w:tblBorders></w:tblPr>',
    );

    for (var r = 0; r < rows.length; r++) {
      final cells = <String>[
        ...rows[r],
        ...List<String>.filled(width - rows[r].length, ''),
      ];
      b.write('<w:tr>');
      for (final cell in cells) {
        // 第一行当表头，加粗
        final runProps = r == 0 ? '<w:rPr><w:b/></w:rPr>' : '';
        b.write('<w:tc><w:tcPr><w:tcW w:w="0" w:type="auto"/></w:tcPr>'
            '<w:p><w:r>$runProps'
            '<w:t xml:space="preserve">${_xesc(cell)}</w:t></w:r></w:p></w:tc>');
      }
      b.write('</w:tr>');
    }

    b.write('</w:tbl>');
    // Word 里表格后面必须跟一个普通段落，否则紧挨着的表格会粘在一起
    b.write('<w:p/>');
    return b.toString();
  }

  /// 一张内嵌图片。EMU 是 Word 的长度单位：1 英寸 = 914400 EMU。
  static String _imageXml(_DocxImage img, int index) {
    // 按 14cm 宽等比缩放；页面正文宽度大概就是这个量级
    const maxWidthEmu = 5040000;
    final w = img.size.width;
    final h = img.size.height;
    final cx = w > 0 && h > 0 ? maxWidthEmu : maxWidthEmu;
    final cy = w > 0 && h > 0 ? (maxWidthEmu * h / w).round() : 2835000;

    return '<w:p><w:r><w:drawing>'
        '<wp:inline distT="0" distB="0" distL="0" distR="0">'
        '<wp:extent cx="$cx" cy="$cy"/>'
        '<wp:docPr id="$index" name="图片 $index"/>'
        '<a:graphic><a:graphicData '
        'uri="http://schemas.openxmlformats.org/drawingml/2006/picture">'
        '<pic:pic>'
        '<pic:nvPicPr><pic:cNvPr id="$index" name="${img.fileName}"/>'
        '<pic:cNvPicPr/></pic:nvPicPr>'
        '<pic:blipFill><a:blip r:embed="${img.relId}"/>'
        '<a:stretch><a:fillRect/></a:stretch></pic:blipFill>'
        '<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="$cx" cy="$cy"/></a:xfrm>'
        '<a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>'
        '</pic:pic></a:graphicData></a:graphic>'
        '</wp:inline></w:drawing></w:r></w:p>';
  }

  static String _mimeOf(String ext) => switch (ext) {
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'bmp' => 'image/bmp',
    'webp' => 'image/webp',
    _ => 'image/png',
  };

  /// 从字节里读出图片宽高。
  ///
  /// docx 的 drawing 必须给宽高，否则 Word 会把它压成一条线。
  /// 只认 PNG 和 JPEG —— 笔记里的图基本就这两种；
  /// 认不出来就返回 0，交给调用方按 16:9 兜底。
  static ({int width, int height}) _imageSize(Uint8List b) {
    // PNG：第 16..24 字节就是宽高（大端）
    if (b.length > 24 &&
        b[0] == 0x89 &&
        b[1] == 0x50 &&
        b[2] == 0x4E &&
        b[3] == 0x47) {
      int be(int o) => (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
      return (width: be(16), height: be(20));
    }

    // JPEG：从头扫 SOF 段（0xFFC0~0xFFCF，跳过 C4/C8/CC）
    if (b.length > 4 && b[0] == 0xFF && b[1] == 0xD8) {
      var i = 2;
      while (i + 9 < b.length) {
        if (b[i] != 0xFF) {
          i++;
          continue;
        }
        final marker = b[i + 1];
        if (marker >= 0xC0 &&
            marker <= 0xCF &&
            marker != 0xC4 &&
            marker != 0xC8 &&
            marker != 0xCC) {
          final h = (b[i + 5] << 8) | b[i + 6];
          final w = (b[i + 7] << 8) | b[i + 8];
          return (width: w, height: h);
        }
        i += 2 + ((b[i + 2] << 8) | b[i + 3]);
      }
    }

    return (width: 0, height: 0);
  }

  /// 行内标记 → 一组带格式的 run。
  ///
  /// 之前整段当一个 run 输出，**加粗斜体全丢了**。
  static String _runs(String text) {
    final out = StringBuffer();
    final re = RegExp(r'(\*\*[^*]+\*\*|\*[^*]+\*|`[^`]+`|https?://\S+)');
    var last = 0;
    void plain(String s) {
      if (s.isEmpty) return;
      out.write('<w:r><w:t xml:space="preserve">${_xesc(s)}</w:t></w:r>');
    }

    for (final m in re.allMatches(text)) {
      plain(text.substring(last, m.start));
      final t = m.group(0)!;
      if (t.startsWith('**')) {
        out.write('<w:r><w:rPr><w:b/></w:rPr>'
            '<w:t xml:space="preserve">${_xesc(t.substring(2, t.length - 2))}</w:t></w:r>');
      } else if (t.startsWith('`')) {
        out.write('<w:r><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/>'
            '<w:shd w:val="clear" w:fill="F2F2F7"/></w:rPr>'
            '<w:t xml:space="preserve">${_xesc(t.substring(1, t.length - 1))}</w:t></w:r>');
      } else if (t.startsWith('http')) {
        out.write('<w:r><w:t xml:space="preserve">${_xesc(t)}</w:t></w:r>');
      } else {
        out.write('<w:r><w:rPr><w:i/></w:rPr>'
            '<w:t xml:space="preserve">${_xesc(t.substring(1, t.length - 1))}</w:t></w:r>');
      }
      last = m.end;
    }
    plain(text.substring(last));
    return out.toString();
  }

  static String _paragraphXml(ContentBlock block) {
    final text = block.text.trim();
    switch (block.type) {
      case ContentBlockType.image:
        return _para('[图片] ${_imagePathOf(block.text.trim())}');
      case ContentBlockType.divider:
        return _para('————————');
      case ContentBlockType.heading:
        final level = block.level.clamp(1, 6);
        final headingText = stripInlineMarkers(text);
        return '<w:p><w:pPr><w:pStyle w:val="Heading$level"/></w:pPr>'
            '<w:r><w:t xml:space="preserve">${_xesc(headingText)}</w:t></w:r></w:p>';
      case ContentBlockType.bullet:
        return '<w:p><w:r><w:t xml:space="preserve">· </w:t></w:r>'
            '${_runs(text)}</w:p>';
      case ContentBlockType.ordered:
        return '<w:p>${_runs(text)}</w:p>';
      case ContentBlockType.quote:
        // 引用加个左边框，Word 里看得出是引文
        return '<w:p><w:pPr><w:pBdr><w:left w:val="single" w:sz="18" '
            'w:space="8" w:color="3B82F6"/></w:pBdr>'
            '<w:ind w:left="240"/></w:pPr>${_runs(text)}</w:p>';
      case ContentBlockType.code:
        return '<w:p><w:r><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/></w:rPr>'
            '<w:t xml:space="preserve">${_xesc(text)}</w:t></w:r></w:p>';
      case ContentBlockType.paragraph:
        return '<w:p>${_runs(text)}</w:p>';
    }
  }

  /// 普通段落。`xml:space="preserve"` 不能省，否则 Word 会吃掉首尾空格。
  static String _para(String text) =>
      '<w:p><w:r><w:t xml:space="preserve">${_xesc(text)}</w:t></w:r></w:p>';

  /// XML 转义。控制字符也要去掉 —— Word 遇到会直接判定文件损坏。
  static String _xesc(String s) => s
      .replaceAll(RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]'), '')
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  // ── 目录 ────────────────────────────────────────────────────────────────
  //
  // 导出的文件是**离开这个应用**的，阅读器里不会再有那个可拖动的目录面板。
  // 所以长文必须把目录写进文件本身，否则拿到 docx 的人只能一路滚到底。

  /// 抽目录。条目太少或只有一层时不生成 —— 那种"目录"只是把标题
  /// 又抄了一遍，纯属噪音。
  static List<TocEntry> tocOf(Note note) {
    final entries = extractToc(note.content);
    if (entries.length < 3) return const <TocEntry>[];
    final levels = entries.map((e) => e.level).toSet();
    // 只有一层且条目不多：不值得单独列一份
    if (levels.length < 2 && entries.length < 6) return const <TocEntry>[];
    return entries;
  }

  /// Markdown 目录：带锚点链接，多数 Markdown 阅读器能直接跳。
  static String _tocMarkdown(List<TocEntry> entries) {
    final b = StringBuffer()
      ..writeln('## 目录')
      ..writeln();
    final minLevel = entries.map((e) => e.level).reduce((a, b) => a < b ? a : b);
    for (final e in entries) {
      final indent = '  ' * (e.level - minLevel);
      final text = stripInlineMarkers(e.text).trim();
      b.writeln('$indent- [$text](#${_slug(text)})');
    }
    b.writeln();
    return b.toString();
  }

  /// 网页目录：带 id 的锚点，点一下直接跳。
  static String _tocHtml(List<TocEntry> entries) {
    final b = StringBuffer('<nav class="toc"><div class="toc-title">目录</div>');
    final minLevel = entries.map((e) => e.level).reduce((a, b) => a < b ? a : b);
    for (final e in entries) {
      final depth = e.level - minLevel;
      b.writeln(
        '<div style="margin-left:${depth * 18}px">'
        '<a href="#${_slug(e.text)}">${_esc(stripInlineMarkers(e.text).trim())}</a></div>',
      );
    }
    b.write('</nav>');
    return b.toString();
  }

  /// 纯文本目录：没有链接可点，靠缩进表达层级。
  static String _tocText(List<TocEntry> entries) {
    final b = StringBuffer()
      ..writeln('目录')
      ..writeln('-' * 20);
    final minLevel = entries.map((e) => e.level).reduce((a, b) => a < b ? a : b);
    for (final e in entries) {
      b.writeln('${'    ' * (e.level - minLevel)}'
          '${stripInlineMarkers(e.text).trim()}');
    }
    b.writeln();
    return b.toString();
  }

  static String _slug(String raw) => stripInlineMarkers(raw)
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w\u4e00-\u9fa5]+'), '-')
      .replaceAll(RegExp(r'^-|-$'), '');

  // ── Markdown ────────────────────────────────────────────────────────────

  static String _markdown(Note note) {
    final b = StringBuffer();
    if (note.title.trim().isNotEmpty) {
      b.writeln('# ${note.title.trim()}');
      b.writeln();
    }
    final toc = tocOf(note);
    if (toc.isNotEmpty) b.write(_tocMarkdown(toc));
    b.write(note.content);
    if (!note.content.endsWith('\n')) b.writeln();
    return b.toString();
  }

  /// 纯文本：去掉 Markdown 标记，图片变成一行说明。
  ///
  /// 不直接输出原文——用户要 .txt 就是想拿去别处用，
  /// 满屏的 `**` 和 `#` 只会碍事。
  static String _plainText(Note note) {
    final b = StringBuffer();
    if (note.title.trim().isNotEmpty) {
      b.writeln(note.title.trim());
      // 用等长下划线做标题分割，纯文本里也看得出层级
      b.writeln('=' * (note.title.trim().runes.length));
      b.writeln();
    }

    final toc = tocOf(note);
    if (toc.isNotEmpty) b.write(_tocText(toc));

    for (final block in parseContent(note.content)) {
      // 关键：block.text 是**原始 Markdown**，直接写出去 txt 里就还是一堆星号
      final text = stripInlineMarkers(block.text.trim());
      switch (block.type) {
        case ContentBlockType.image:
          b.writeln('[图片] ${_imagePathOf(block.text.trim())}');
        case ContentBlockType.divider:
          b.writeln('-' * 40);
        case ContentBlockType.heading:
          b
            ..writeln()
            ..writeln(text)
            ..writeln('-' * text.runes.length);
        case ContentBlockType.bullet:
          b.writeln('  · $text');
        case ContentBlockType.ordered:
          b.writeln('  $text');
        case ContentBlockType.quote:
          b.writeln('  > $text');
        case ContentBlockType.code:
          b.writeln('    $text');
        case ContentBlockType.paragraph:
          b
            ..writeln(text)
            ..writeln();
      }
    }
    return '${b.toString().trimRight()}\n';
  }

  // ── HTML ────────────────────────────────────────────────────────────────

  static String _html(Note note, String? imageRoot) {
    final b = StringBuffer()
      ..writeln('<!DOCTYPE html>')
      ..writeln('<html lang="zh-CN">')
      ..writeln('<head>')
      ..writeln('<meta charset="utf-8">')
      ..writeln('<title>${_esc(note.title)}</title>')
      ..writeln('<style>')
      ..writeln(
        'body{max-width:760px;margin:40px auto;padding:0 20px;'
        'font-family:-apple-system,"PingFang SC","Microsoft YaHei",sans-serif;'
        'font-size:17px;line-height:1.85;color:#1c1c1e;}',
      )
      ..writeln('h1{font-size:28px;line-height:1.35;margin:0 0 8px;}')
      ..writeln('h2{font-size:22px;margin:32px 0 12px;}')
      ..writeln('h3{font-size:19px;margin:26px 0 10px;}')
      ..writeln('p{margin:0 0 16px;}')
      ..writeln('blockquote{margin:16px 0;padding:8px 16px;'
          'border-left:3px solid #3b82f6;color:#6b7280;background:#f7f7fa;}')
      ..writeln('img{max-width:100%;border-radius:12px;display:block;margin:18px 0;}')
      ..writeln('code{background:#f2f2f7;padding:2px 5px;border-radius:4px;'
          'font-family:Consolas,monospace;font-size:15px;}')
      ..writeln('.meta{color:#8e8e93;font-size:14px;margin-bottom:28px;}')
      ..writeln('hr{border:none;border-top:1px solid #e5e5ea;margin:28px 0;}')
      ..writeln('a{color:#3b82f6;}')
      ..writeln('</style>')
      ..writeln('</head>')
      ..writeln('<body>');

    if (note.title.trim().isNotEmpty) {
      b.writeln('<h1>${_esc(note.title.trim())}</h1>');
    }
    b.writeln('<div class="meta">${_esc(_metaLine(note))}</div>');

    final toc = tocOf(note);
    if (toc.isNotEmpty) b.writeln(_tocHtml(toc));

    for (final block in parseContent(note.content)) {
      b.writeln(_htmlBlock(block, imageRoot));
    }

    b
      ..writeln('</body>')
      ..writeln('</html>');
    return b.toString();
  }

  static String _htmlBlock(ContentBlock block, String? imageRoot) {
    final text = block.text.trim();
    switch (block.type) {
      case ContentBlockType.image:
        final rel = _imagePathOf(text);
        return '<img src="${_esc(_dataUri(rel, imageRoot))}" alt="">';
      case ContentBlockType.divider:
        return '<hr>';
      case ContentBlockType.heading:
        final level = block.level.clamp(1, 6);
        // 带 id 才能被目录里的锚点跳到
        return '<h$level id="${_slug(text)}">${_inline(text)}</h$level>';
      case ContentBlockType.bullet:
        return '<p>· ${_inline(text)}</p>';
      case ContentBlockType.ordered:
        return '<p>${_inline(text)}</p>';
      case ContentBlockType.quote:
        return '<blockquote>${_inline(text)}</blockquote>';
      case ContentBlockType.code:
        return '<p><code>${_esc(text)}</code></p>';
      case ContentBlockType.paragraph:
        return '<p>${_inline(text)}</p>';
    }
  }

  /// 行内标记 → HTML。
  static String _inline(String s) {
    var out = _esc(s);
    // 顺序要紧：先处理 ** 再处理 *，否则加粗会被拆成两个斜体
    out = out.replaceAllMapped(
      RegExp(r'\*\*([^*]+)\*\*'),
      (m) => '<strong>${m.group(1)}</strong>',
    );
    out = out.replaceAllMapped(
      RegExp(r'\*([^*]+)\*'),
      (m) => '<em>${m.group(1)}</em>',
    );
    out = out.replaceAllMapped(
      RegExp(r'`([^`]+)`'),
      (m) => '<code>${m.group(1)}</code>',
    );
    // 链接：先标记转换，再处理裸链接
    out = out.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\((https?://[^)]+)\)'),
      (m) => '<a href="${m.group(2)}">${m.group(1)}</a>',
    );
    out = out.replaceAllMapped(
      RegExp(r'(?<!["=>])(https?://[^\s<>()（）【】]+)'),
      (m) => '<a href="${m.group(1)}">${m.group(1)}</a>',
    );
    return out;
  }

  /// 图片内嵌成 data URI。
  ///
  /// **必须内嵌**：导出的是一个单独的 .html 文件，用 `file://` 绝对路径的话，
  /// 文件一挪到别的机器、或者发给别人，图片就全断了 ——
  /// 而 html 导出最常见的用途恰恰就是"发出去"。
  ///
  /// 超过 4MB 的单图退回路径引用：内嵌会让 html 膨胀成几十兆，
  /// 浏览器打开会卡死，那比图裂更糟。
  static String _dataUri(String rel, String? imageRoot) {
    if (imageRoot == null || rel.isEmpty) return rel;
    final file = File(p.join(imageRoot, rel));
    if (!file.existsSync()) return rel;
    try {
      final bytes = file.readAsBytesSync();
      if (bytes.length > 4 * 1024 * 1024) {
        return Uri.file(file.path).toString();
      }
      final ext = rel.contains('.')
          ? rel.split('.').last.toLowerCase()
          : 'png';
      return 'data:${_mimeOf(ext)};base64,${base64.encode(bytes)}';
    } catch (_) {
      return rel;
    }
  }

  static String _metaLine(Note note) {
    final d = note.displayTime;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)} · ${note.charCount} 字';
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  /// 从图片 block 里取路径。
  ///
  /// `parseContent` 对图片 block 给出的 text **可能已经是纯路径**、
  /// 也可能还是 `![](path)` 原文，两种都要认，否则导出的 HTML 里图片全断。
  static String _imagePathOf(String line) {
    final m = RegExp(r'!\[[^\]]*\]\(([^)]+)\)').firstMatch(line);
    var path = (m?.group(1) ?? line).trim();
    if (path.startsWith('images/')) path = path.substring('images/'.length);
    return path;
  }

  // ── 落盘 ────────────────────────────────────────────────────────────────

  /// 导出**单篇**到指定文件。
  ///
  /// 和批量导出的区别：路径由用户直接选定（含文件名），
  /// 所以不再做重名加序号 —— 用户既然指定了名字，就照他说的写。
  static void exportToOne({
    required Note note,
    required ExportFormat format,
    required String path,
    String? imageRoot,
  }) {
    final file = File(path);
    final parent = file.parent;
    if (!parent.existsSync()) parent.createSync(recursive: true);

    if (format.isBinary) {
      file.writeAsBytesSync(renderDocxBytes(note, imageRoot: imageRoot), flush: true);
    } else {
      file.writeAsStringSync(
        render(note, format, imageRoot: imageRoot),
        flush: true,
      );
    }
  }

  /// 建议的文件名（不含扩展名），给保存对话框做默认值。
  static String suggestedName(Note note) =>
      _safeFileName(note, <String>{});

  /// 把若干篇导出到目录，每篇一个文件。返回实际写出的文件数。
  static int exportToDirectory({
    required List<Note> notes,
    required ExportFormat format,
    required String dir,
    String? imageRoot,
  }) {
    final target = Directory(dir);
    if (!target.existsSync()) target.createSync(recursive: true);

    var written = 0;
    final used = <String>{};

    for (final note in notes) {
      final name = _safeFileName(note, used);
      final file = File(p.join(dir, '$name.${format.ext}'));
      try {
        if (format.isBinary) {
          file.writeAsBytesSync(renderDocxBytes(note, imageRoot: imageRoot), flush: true);
        } else {
          file.writeAsStringSync(
            render(note, format, imageRoot: imageRoot),
            flush: true,
          );
        }
        written++;
      } catch (_) {
        // 一篇写不出去不该让整批失败
      }
    }
    return written;
  }

  /// 文件名的安全处理：去掉非法字符、截断、重名加序号。
  static String _safeFileName(Note note, Set<String> used) {
    var base = note.title.trim().isEmpty ? '无标题笔记' : note.title.trim();
    // Windows 不允许这些字符出现在文件名里
    base = base.replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), '_');
    if (base.runes.length > 60) {
      base = String.fromCharCodes(base.runes.take(60));
    }
    base = base.trim();
    if (base.isEmpty) base = '无标题笔记';

    var candidate = base;
    var n = 2;
    while (used.contains(candidate.toLowerCase())) {
      candidate = '$base ($n)';
      n++;
    }
    used.add(candidate.toLowerCase());
    return candidate;
  }
}
