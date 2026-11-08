/// 笔记导出成 PDF。
///
/// 为什么单独一个文件：PDF 的排版模型和另外三种格式完全不同 ——
/// markdown/txt 是"把标记拼成字符串"，docx 是"拼 XML 塞进 zip"，
/// 而 PDF 要自己算每一行放哪儿、什么时候换页。混在 note_exporter.dart
/// 里会把那个文件撑成两千行。
///
/// **字体必须由调用方传进来**：中文字形得嵌进 PDF（PDF 不像网页那样
/// 能借系统字体），而 `rootBundle` 属于 Flutter 层，`lib/data` 这一层
/// 刻意不依赖 Flutter（`tool/import_cli.dart` 也在这里跑）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../core/utils/text_stats.dart';
import '../media/external_media.dart';
import '../media/media_importer.dart';
import '../models.dart';

/// 把一篇笔记渲染成 PDF 字节。
class PdfExporter {
  const PdfExporter._();

  /// A4，左右各 44pt（约 15.5mm）留白 —— 再窄中文会显得挤，
  /// 再宽一行塞太多字，读起来要来回摆头。
  static const double _margin = 44;

  /// 正文基准字号。11pt 在 A4 上约等于 Word 的"小四"再小一点，
  /// 中文密集段落读着不累。
  static const double _bodySize = 11;

  /// 单张图能占的最大高度（pt）。
  ///
  /// A4 高 842pt，上下各留 44 ⇒ 一页可用 754pt。这里给 520（约七成），
  /// 剩下的留给图前后的文字 —— 图独占整页时观感也很差。
  /// **必须给这个上限**：`pw.Image` 拿到有界高度会直接把 maxHeight 当成
  /// 目标高度，竖长图按宽度等比缩放后会撑破一页，`MultiPage` 抛异常。
  static const double _maxImageHeight = 520;

  /// 没传 [mediaFolder] 时正文里那句说明用的占位名。
  ///
  /// 真正导出时总会传（跟着笔记标题走），这里是给测试和
  /// 直接调 `PdfExporter.renderBytes` 的场景兜底。
  static const String kVideoFolderHint = '附件';

  /// 渲染成 PDF。
  ///
  /// [font] 是内嵌的中文字体（见 `assets/fonts/`）。[imageRoot] 是媒体
  /// 文件根目录，正文里的 `![](xxx.png)` 会从这儿找。
  static Future<Uint8List> renderBytes(
    Note note, {
    required ByteData font,
    String? imageRoot,
    String? mediaFolder,
  }) async {
    final ttf = pw.Font.ttf(font);
    final blocks = parseContent(note.content);

    final doc = pw.Document(
      title: note.title,
      author: '元世界',
      creator: '元世界',
      producer: '元世界',
    );

    // 四个字重全指向同一份字体。
    //
    // **不这么做会崩**：`ThemeData.withFont` 没给的槽位会退回 Helvetica，
    // 那是只有拉丁字母的字体，正文里一个中文就让 ttf_writer 抛
    // "Missing glyph for character ..."。宁可加粗看起来和正文一样重，
    // 也不能让整篇导不出来。
    final theme = pw.ThemeData.withFont(
      base: ttf,
      bold: ttf,
      italic: ttf,
      boldItalic: ttf,
    );

    final style = pw.TextStyle(
      font: ttf,
      fontSize: _bodySize,
      lineSpacing: 4,
      color: PdfColors.grey900,
    );

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(_margin),
        theme: theme,
        footer: (ctx) => _footer(ctx, ttf),
        // 默认上限是 20 页，而它只在 assert 里检查（debug 构建才抛）。
        // 一本几万字的长文轻松超过 20 页 —— debug 下会直接
        // "This widget created more than 20 pages"，release 又不检查，
        // 同一个文件在不同构建里行为不一样。索性放开这个上限。
        maxPages: 2000,
        build: (ctx) => <pw.Widget>[
          _header(note, style, ttf),
          pw.SizedBox(height: 14),
          for (final block in blocks)
            ..._block(block, style, ttf, imageRoot, mediaFolder),
        ],
      ),
    );

    return doc.save();
  }

  // ── 页眉 / 页脚 ──────────────────────────────────────────────────────────

  static pw.Widget _header(Note note, pw.TextStyle style, pw.Font font) {
    final meta = <String>[
      _date(note.createdAt),
      if (note.charCount > 0) '${note.charCount} 字',
    ].join(' · ');
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: <pw.Widget>[
        pw.Text(
          _sanitize(note.title.isEmpty ? '无标题' : note.title),
          style: style.copyWith(
            fontSize: 20,
            lineSpacing: 3,
            color: PdfColors.black,
          ),
        ),
        pw.SizedBox(height: 6),
        pw.Text(
          meta,
          style: style.copyWith(fontSize: 9, color: PdfColors.grey600),
        ),
        pw.SizedBox(height: 10),
        pw.Divider(height: 1, thickness: 0.6, color: PdfColors.grey400),
      ],
    );
  }

  static pw.Widget _footer(pw.Context ctx, pw.Font font) {
    // 页码放右下角。不加"共 N 页"：MultiPage 渲染时还不知道总页数，
    // 硬凑要两遍渲染，为一行小字不值当。
    return pw.Align(
      alignment: pw.Alignment.centerRight,
      child: pw.Text(
        '${ctx.pageNumber}',
        style: pw.TextStyle(
          font: font,
          fontSize: 8,
          color: PdfColors.grey500,
        ),
      ),
    );
  }

  // ── 块级排版 ────────────────────────────────────────────────────────────

  static List<pw.Widget> _block(
    ContentBlock block,
    pw.TextStyle style,
    pw.Font font,
    String? imageRoot,
    String? mediaFolder,
  ) {
    switch (block.type) {
      case ContentBlockType.heading:
        final level = block.level.clamp(1, 6);
        final size = switch (level) {
          1 => 17.0,
          2 => 15.0,
          3 => 13.0,
          4 => 12.0,
          _ => 11.5,
        };
        return <pw.Widget>[
          pw.SizedBox(height: level <= 2 ? 14 : 10),
          pw.Text(
            _sanitize(stripInline(block.text.trim())),
            style: style.copyWith(
              fontSize: size,
              lineSpacing: 3,
              color: PdfColors.black,
            ),
            // `span` 让这个 Text 变成 SpanningWidget，高度超过一页时
            // 由 MultiPage 拆到下一页继续排。默认的 `visible` 不行：
            // 那种情况下 MultiPage 会直接抛
            // "Widget won't fit into the page as its height ... exceed
            // a page height"，长文章必然踩到。
            overflow: pw.TextOverflow.span,
          ),
          pw.SizedBox(height: 4),
        ];

      case ContentBlockType.divider:
        return <pw.Widget>[
          pw.SizedBox(height: 8),
          pw.Divider(height: 1, thickness: 0.5, color: PdfColors.grey400),
          pw.SizedBox(height: 8),
        ];

      case ContentBlockType.image:
        return _image(block, font, imageRoot, mediaFolder);

      case ContentBlockType.code:
        return <pw.Widget>[
          pw.SizedBox(height: 4),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: const pw.BoxDecoration(
              color: PdfColors.grey100,
              borderRadius: pw.BorderRadius.all(pw.Radius.circular(4)),
            ),
            child: pw.Text(
              _sanitize(block.text),
              style: style.copyWith(fontSize: 9.5, lineSpacing: 3),
              // 代码块经常一屏放不下，同样得能跨页。
              overflow: pw.TextOverflow.span,
            ),
          ),
          pw.SizedBox(height: 6),
        ];

      case ContentBlockType.quote:
        return <pw.Widget>[
          pw.SizedBox(height: 3),
          pw.Container(
            padding: const pw.EdgeInsets.only(left: 10),
            decoration: const pw.BoxDecoration(
              border: pw.Border(
                left: pw.BorderSide(color: PdfColors.grey400, width: 2.5),
              ),
            ),
            child: pw.RichText(
              text: pw.TextSpan(
                style: style.copyWith(color: PdfColors.grey700),
                children: _spans(block.text.trim(), style),
              ),
              overflow: pw.TextOverflow.span,
            ),
          ),
          pw.SizedBox(height: 3),
        ];

      case ContentBlockType.bullet:
        return <pw.Widget>[
          _listRow(
            // 用 □/■ 而不是 ☐/☑：后两个不在内嵌字体的 cmap 里，
            // pdf 包会打一行 "Unable to find a font to draw" 然后画空白。
            marker: block.isTodo ? (block.checked ? '■' : '□') : '•',
            text: block.text.trim(),
            level: block.level,
            style: style,
            font: font,
          ),
        ];

      case ContentBlockType.ordered:
        return <pw.Widget>[
          _listRow(
            marker: '${block.listNumber ?? 1}.',
            text: block.text.trim(),
            level: block.level,
            style: style,
            font: font,
          ),
        ];

      case ContentBlockType.paragraph:
        return <pw.Widget>[
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 5),
            child: pw.RichText(
              text: pw.TextSpan(
                style: style,
                children: _spans(block.text.trim(), style),
              ),
              overflow: pw.TextOverflow.span,
            ),
          ),
        ];
    }
  }

  /// 列表行：标记和正文分开两个宽度固定的格子。
  ///
  /// 直接拼成 "• 正文" 的话，换行后的第二行会顶到最左边，
  /// 缩进就丢了 —— 中文长段落几乎必然折行，所以必须拆开。
  ///
  /// 用 [pw.Partitions] 而不是 [pw.Row]：`Row` 横向布局，没法跨页；
  /// 一条很长的列表项（比如一整段引用式条目）高度超过一页时，
  /// MultiPage 会抛 "Widget won't fit into the page"。`Partitions`
  /// 的子项能各自向下续排，正好是"左边一列标记 + 右边一列正文"。
  static pw.Widget _listRow({
    required String marker,
    required String text,
    required int level,
    required pw.TextStyle style,
    required pw.Font font,
  }) {
    final indent = 14.0 * level.clamp(0, 4);
    return pw.Padding(
      padding: pw.EdgeInsets.only(left: indent, bottom: 4),
      child: pw.Partitions(
        children: <pw.Partition>[
          pw.Partition(
            width: 16,
            child: pw.Text(
              marker,
              style: style.copyWith(color: PdfColors.grey600),
              overflow: pw.TextOverflow.span,
            ),
          ),
          pw.Partition(
            child: pw.RichText(
              text: pw.TextSpan(style: style, children: _spans(text, style)),
              overflow: pw.TextOverflow.span,
            ),
          ),
        ],
      ),
    );
  }

  static List<pw.Widget> _image(
    ContentBlock block,
    pw.Font font,
    String? imageRoot,
    String? mediaFolder,
  ) {
    final rel = _imagePathOf(block.text.trim());
    if (rel.isEmpty) return const <pw.Widget>[];

    // 视频没法塞进 PDF（和 docx 一个道理），正文里只留一行说明。
    // **但视频本体要跟着导出走**：单篇导出时会拷到 PDF 旁边的
    // `<标题>.files/` 里（见 `NoteExporter.copyVideosNextTo`），
    // 文件夹名由 [mediaFolder] 决定 —— 和 docx 用同一个名字，
    // 用户拿到的两套导出物结构一致。
    if (MediaImporter.isVideoPath(rel)) {
      final folder = mediaFolder ?? kVideoFolderHint;
      return <pw.Widget>[
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 5),
          child: pw.Text(
            '[视频] ${_basename(rel)}（PDF 不能内嵌视频，该文件已随导出放入「$folder」文件夹）',
            style: pw.TextStyle(font: font, fontSize: 9, color: PdfColors.grey600),
          ),
        ),
      ];
    }

    final file = imageRoot == null
        ? null
        : _fileAt(imageRoot, rel);
    final bytes = file != null && file.existsSync()
        ? file.readAsBytesSync()
        : null;
    if (bytes == null) return const <pw.Widget>[];

    final isJpeg =
        rel.toLowerCase().endsWith('.jpg') || rel.toLowerCase().endsWith('.jpeg');
    final isPng = rel.toLowerCase().endsWith('.png');
    // pdf 包只认 PNG/JPEG 的原始字节。webp、gif 得先转码，
    // 那要拉 image 包进来解一遍 —— 为一张图不值得，直接说明白。
    if (!isJpeg && !isPng) {
      return <pw.Widget>[
        pw.Padding(
          padding: const pw.EdgeInsets.only(bottom: 5),
          child: pw.Text(
            '[图片] ${_basename(rel)}（这种格式没法嵌进 PDF）',
            style: pw.TextStyle(font: font, fontSize: 9, color: PdfColors.grey600),
          ),
        ),
      ];
    }

    return <pw.Widget>[
      pw.SizedBox(height: 4),
      pw.Center(
        child: pw.ConstrainedBox(
          // **高度也必须给上限**：`pw.Image` 的 layout 在"高度有界"时
          // 直接拿 `constraints.maxHeight` 当目标高度，`BoxFit.contain`
          // 再按它缩放。竖长图（手机截图 1080×2400）按 400 宽算出来
          // 高约 889pt，比 A4 一页能放的高度还大，`MultiPage` 就抛
          // `Widget won't fit into the page` —— 用户看到的是
          // "有一段内容太高，一页放不下"。
          //
          // 用 `_maxImageHeight` 而不是写死一个数：页面尺寸可以换，
          // 图最多只能占一页的七成，剩下留给它前后的文字。
          constraints: const pw.BoxConstraints(
            maxWidth: 400,
            maxHeight: _maxImageHeight,
          ),
          child: pw.Image(pw.MemoryImage(bytes), fit: pw.BoxFit.contain),
        ),
      ),
      // 图注紧贴图片下方，居中小字 —— 和阅读页的排版对齐，
      // 导出的 PDF 看起来才像同一份文档。
      if (block.caption.isNotEmpty)
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 5, bottom: 2),
          child: pw.Text(
            _sanitize(block.caption),
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(font: font, fontSize: 9, color: PdfColors.grey700),
          ),
        ),
      pw.SizedBox(height: 8),
    ];
  }

  // ── 行内标记 ────────────────────────────────────────────────────────────
  //
  // 正则和 docx 那份**保持同一套**：`**粗**`、`~~删~~`、`*斜*`、`` `码` ``、
  // `[文字](地址)`、裸网址。两边要是各写一份，早晚会有一边漏掉一种。

  static final RegExp _inlineRe = RegExp(
    r'(\*\*[^*]+\*\*|~~[^~]+~~|\*[^*]+\*|`[^`]+`|\[[^\]]+\]\([^)]+\)|https?://\S+)',
  );

  static List<pw.InlineSpan> _spans(String text, pw.TextStyle style) {
    final out = <pw.InlineSpan>[];
    var last = 0;

    void plain(String s) {
      if (s.isEmpty) return;
      out.add(pw.TextSpan(text: _sanitize(s)));
    }

    for (final m in _inlineRe.allMatches(text)) {
      plain(text.substring(last, m.start));
      final t = m.group(0)!;
      if (t.startsWith('**')) {
        // 只有一份字体，粗体靠"描边+填充"假装 —— 视觉上确实更重，
        // 而且不依赖第二个字体文件（省 2.4 MB）。
        out.add(
          pw.TextSpan(
            text: _sanitize(t.substring(2, t.length - 2)),
            style: style.copyWith(
              renderingMode: PdfTextRenderingMode.fillAndStroke,
            ),
          ),
        );
      } else if (t.startsWith('~~')) {
        out.add(
          pw.TextSpan(
            text: _sanitize(t.substring(2, t.length - 2)),
            style: style.copyWith(decoration: pw.TextDecoration.lineThrough),
          ),
        );
      } else if (t.startsWith('`')) {
        out.add(
          pw.TextSpan(
            text: _sanitize(t.substring(1, t.length - 1)),
            style: style.copyWith(
              color: PdfColors.blueGrey700,
              background: const pw.BoxDecoration(color: PdfColors.grey200),
            ),
          ),
        );
      } else if (t.startsWith('[')) {
        final md = RegExp(r'^\[([^\]]+)\]\(([^)]+)\)$').firstMatch(t);
        final label = md?.group(1) ?? t;
        final target = md?.group(2) ?? '';
        out.add(
          pw.TextSpan(
            text: _sanitize(label),
            style: style.copyWith(color: PdfColors.blue700),
            annotation: target.isEmpty ? null : pw.AnnotationUrl(target),
          ),
        );
      } else if (t.startsWith('http')) {
        out.add(
          pw.TextSpan(
            text: _sanitize(t),
            style: style.copyWith(color: PdfColors.blue700),
            annotation: pw.AnnotationUrl(t),
          ),
        );
      } else {
        out.add(
          pw.TextSpan(
            text: _sanitize(t.substring(1, t.length - 1)),
            style: style.copyWith(fontStyle: pw.FontStyle.italic),
          ),
        );
      }
      last = m.end;
    }
    plain(text.substring(last));
    return out;
  }

  // ── 小工具 ──────────────────────────────────────────────────────────────

  /// 字体里一定没有的字符换成安全的样子。
  ///
  /// 内嵌的是 Noto Sans SC 的 GBK 子集，**不含 emoji**。pdf 包碰到缺字
  /// 不是画方框，而是直接抛 `Missing glyph for character ...`，整篇
  /// 导出就废了。所以这里先把它们清掉：
  ///   · emoji / 各种图形符号 → 删掉
  ///   · 变体选择符（FE0F）和组合附加符（0300-036F）→ 删掉
  ///   · 不间断空格 → 普通空格（否则会被当成缺字）
  static String _sanitize(String s) {
    if (s.isEmpty) return s;
    final b = StringBuffer();
    for (final rune in s.runes) {
      if (rune == 0x00A0 || rune == 0x3000) {
        b.write(' ');
        continue;
      }
      if (rune == 0x0009) {
        b.write('    ');
        continue;
      }
      if (_unsupported(rune)) continue;
      b.writeCharCode(rune);
    }
    return b.toString();
  }

  static bool _unsupported(int r) {
    // 控制字符
    if (r < 0x20 && r != 0x0A) return true;
    // 变体选择符、组合附加符
    if (r >= 0xFE00 && r <= 0xFE0F) return true;
    if (r >= 0x0300 && r <= 0x036F) return true;
    if (r == 0x200D || r == 0x20E3) return true; // ZWJ、组合键帽
    // emoji 与图形符号（Noto Sans SC 里没有）
    if (r >= 0x1F000 && r <= 0x1FAFF) return true;
    if (r >= 0x2600 && r <= 0x27BF) return true;
    if (r >= 0x2B00 && r <= 0x2BFF) return true;
    // 数学字母数字、带圈字母
    if (r >= 0x1D400 && r <= 0x1D7FF) return true;
    if (r >= 0x2460 && r <= 0x24FF) return true;
    // 音标扩展、修饰符
    if (r >= 0x1D00 && r <= 0x1DBF) return true;
    if (r >= 0x02B0 && r <= 0x02FF) return true;
    return false;
  }

  static String _date(DateTime t) =>
      '${t.year}-${_two(t.month)}-${_two(t.day)}';

  static String _two(int v) => v.toString().padLeft(2, '0');

  static String _basename(String rel) {
    final i = rel.lastIndexOf(RegExp(r'[/\\]'));
    return i < 0 ? rel : rel.substring(i + 1);
  }

  static String _imagePathOf(String line) {
    final m = RegExp(r'!\[[^\]]*\]\(([^)]+)\)').firstMatch(line);
    var path = (m?.group(1) ?? line).trim();
    if (path.startsWith('images/')) path = path.substring('images/'.length);
    return path;
  }

  /// 媒体文件的绝对路径。
  ///
  /// 两种引用都要认：
  ///   · 内部引用是相对 `imageRoot` 的（`7/a.png`），`/` 要换成平台的
  ///     分隔符；
  ///   · 外部引用是用户机器上的绝对路径或 `file://`（设置里开了
  ///     「图片视频只引用原文件」之后正文里存的就是这种），原样用 ——
  ///     以前这里一律拼 `root`，于是拼出 `...\images\C:\素材\a.png`，
  ///     图永远找不到。
  static File? _fileAt(String root, String rel) {
    if (ExternalMedia.isExternal(rel)) {
      return File(ExternalMedia.localPath(rel));
    }
    final sep = Platform.pathSeparator;
    return File('$root$sep${rel.replaceAll('/', sep)}');
  }
}
