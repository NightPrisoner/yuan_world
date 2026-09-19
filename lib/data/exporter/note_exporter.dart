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
import '../media/media_importer.dart';
import '../models.dart';
import 'note_times.dart';

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

/// 导出到 docx 时收集到的一个外部超链接。
///
/// Word 里 `w:hyperlink` 只有 `r:id`，真正的地址在
/// `word/_rels/document.xml.rels` 里 —— 所以渲染正文时要把它带出来。
class _DocxLink {
  const _DocxLink({required this.relId, required this.target});

  final String relId;
  final String target;
}

class NoteExporter {
  const NoteExporter._();

  /// 单个视频进压缩包的上限。超过就不打包，只在正文里说明。
  ///
  /// 压缩包是在内存里拼好的，用户库里真有 258 MiB 的视频；
  /// 上限给得比较宽松，是为了不让正常大小的录屏被挡在外面。
  static const int kMaxPackedVideoBytes = 512 * 1024 * 1024;

  /// 把多篇笔记打成**一个压缩包**（包里每篇一个文件）。
  ///
  /// [items] 里的 `path` 是**包内的目录层级**（不含文件名），空表示放根目录。
  /// 导出整个文集时把文集层级填进来，解压出来就和应用里看到的目录结构一致
  /// —— 这是"文件夹导出"和"批量导出"唯一的区别，所以合成一个函数，
  /// 免得两处各写一遍、然后有一处漏了层级。
  static Uint8List zipBytes({
    required List<({List<String> path, Note note})> items,
    ExportFormat format = ExportFormat.docx,
    String? imageRoot,
    /// 单个视频进包的上限，默认 [kMaxPackedVideoBytes]。
    /// 测试里压到 1 字节就能造出"超大视频"的场景，不用真写几百 MB 的文件。
    int? maxVideoBytes,
  }) {
    final videoLimit = maxVideoBytes ?? kMaxPackedVideoBytes;
    final archive = Archive();
    final used = <String>{};

    for (final item in items) {
      final note = item.note;

      final dirs = <String>[
        for (final seg in item.path)
          if (_safeSegment(seg).isNotEmpty) _safeSegment(seg),
      ];

      final base = suggestedName(note);
      var full = <String>[...dirs, '$base.${format.ext}'].join('/');
      // 同名笔记（比如两篇都叫「无题」）加序号，否则后面会把前面覆盖掉
      var k = 2;
      while (!used.add(full)) {
        full = <String>[...dirs, '$base ($k).${format.ext}'].join('/');
        k++;
      }
      // 视频目录名跟着**最终**文件名走（含去重后的序号），
      // 否则 docx 正文里写的是 `笔记.files`、包里实际叫 `笔记 (2).files`。
      final stem = full.substring(0, full.length - format.ext.length - 1);
      final videoFolder = '$stem.files';

      // 先算出哪些视频能进包，再渲染正文 ——
      // 正文里那句"该文件已随导出放入 xxx.files"必须和包里真实存在的东西一致，
      // 否则就是在骗人（这正是之前"视频不见了"的同类问题）。
      final packed = <String>[];
      final oversized = <String>[];
      for (final rel in videoRelsOf(note)) {
        final file = imageRoot == null ? File(rel) : File(p.join(imageRoot, rel));
        if (!file.existsSync()) continue;
        // 整包是在内存里拼出来的（`ZipEncoder().encodeBytes`），
        // 一个几 GB 的视频会把内存吃光，最后连整个导出都失败 ——
        // 宁可这一条不打包并在正文里说明，也不要整个文件夹导不出来。
        if (file.lengthSync() > videoLimit) {
          oversized.add(rel);
        } else {
          packed.add(rel);
        }
      }

      final bytes = format.isBinary
          ? renderDocxBytes(
              note,
              imageRoot: imageRoot,
              videoFolder: videoFolder,
              oversizedVideos: oversized,
            )
          : Uint8List.fromList(
              utf8.encode(render(note, format, imageRoot: imageRoot)),
            );
      archive.addFile(
        ArchiveFile(full, bytes.length, bytes)
          // 包内文件的时间 = 笔记最后修改时间，而不是打包那一刻。
          // 不设的话解压出来 500 篇全是同一分钟，按时间排序等于没排。
          ..lastModTime = epochSecondsOf(note.updatedAt),
      );

      // 视频本体跟着一起打包。
      // docx 放 `<笔记名>.files/`（和正文里那行说明对上）；
      // markdown/html 里写的就是原始相对路径，所以原地放，链接才不断。
      for (final rel in packed) {
        final file = imageRoot == null ? File(rel) : File(p.join(imageRoot, rel));
        final data = file.readAsBytesSync();
        final target =
            format.isBinary ? '$videoFolder/${p.basename(rel)}' : rel;
        if (!used.add(target)) continue;
        archive.addFile(
          ArchiveFile(target, data.length, data)
            ..lastModTime = epochSecondsOf(note.updatedAt),
        );
      }
    }

    return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
  }

  /// 压缩包名。文集名可能带 `/ : *` 这些，直接当文件名会存不下来。
  static String safeZipName(String raw) {
    final t = _safeSegment(raw);
    return t.isEmpty ? '元世界导出' : t;
  }

  /// 目录/文件名里不能出现的字符换成下划线。
  ///
  /// 文集名是用户随手起的，`斜杠/反斜杠`、`: * ? " < > |` 这些一旦进了
  /// 压缩包的路径，解压时要么报错、要么被当成层级 —— 名字里带 `/`
  /// 会凭空多出一层目录。
  static String _safeSegment(String s) {
    var t = s.trim().replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
    // Windows 上以点或空格结尾的名字建不出来
    t = t.replaceAll(RegExp(r'[. ]+$'), '');
    if (t.isEmpty) return '';
    // 太长的话有些解压工具会失败
    return t.length > 80 ? t.substring(0, 80) : t;
  }

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

  static Uint8List renderDocxBytes(
    Note note, {
    String? imageRoot,
    String? videoFolder,
    List<String> oversizedVideos = const <String>[],
  }) {
    final blocks = parseContent(note.content);

    // 先把正文里引用到的图片收集起来，编号从 1 开始（rId 也一样）。
    //
    // **视频必须在这里摘出去**：数据库里视频块和图片块是同一个 type
    // （导入时就按 image 存的，界面靠扩展名区分），所以不做区分的话
    // mp4 会被 readAsBytes 当成图片塞进 word/media，Word 里就是红叉/
    // 什么都不显示 —— 用户看到的现象就是"笔记导出后视频不见了"。
    final images = <_DocxImage>[];
    for (final block in blocks) {
      if (block.type != ContentBlockType.image) continue;
      final rel = _imagePathOf(block.text.trim());
      if (rel.isEmpty) continue;
      if (MediaImporter.isVideoPath(rel)) continue;

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
      // **styles.xml 必须在这里登记**，否则 Word 根本不认它
      '<Override PartName="/word/styles.xml" '
      'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>'
      // core.xml（创建/修改时间、标题）同样要登记
      '<Override PartName="/docProps/core.xml" '
      'ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>'
      // 列表定义也要登记
      '<Override PartName="/word/numbering.xml" '
      'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>'
      '</Types>',
    );

    // 正文渲染过程中会把外链登记进来（Word 的链接地址不在正文里，在 rels 里）
    final links = <_DocxLink>[];

    final archive = Archive()
      ..addFile(ArchiveFile.string('[Content_Types].xml', contentTypes.toString()))
      ..addFile(ArchiveFile.string(
        '_rels/.rels',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>'
        '</Relationships>',
      ))
      // 文档属性里带上笔记的创建/修改时间：Word 的「文件 → 信息」显示的就是它，
      // 不写的话 Word 会当成"刚刚创建"，用户从属性里看不出这篇是什么时候写的
      ..addFile(ArchiveFile.string('docProps/core.xml', _coreXml(note)))
      ..addFile(ArchiveFile.string('word/styles.xml', _stylesXml()))
      // 列表要有 numbering.xml 才是**真列表**（Word 里能继续编号、
      // 能调级别）；不写的话项目符号只能手打一个「·」，编号则完全丢失
      ..addFile(ArchiveFile.string('word/numbering.xml', _numberingXml()))
      ..addFile(ArchiveFile.string('word/document.xml',
          _documentXml(note, blocks, images,
              videoFolder: videoFolder,
              oversizedVideos: oversizedVideos,
              links: links)));

    // **document.xml.rels 要无条件生成**：以前只在有图片时才写，
    // 而没有 styles 关系的话 Word 也不会去读 styles.xml。
    final rels = StringBuffer(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
      '<Relationship Id="rIdStyles" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" '
      'Target="styles.xml"/>'
      '<Relationship Id="rIdNumbering" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" '
      'Target="numbering.xml"/>',
    );
    for (final img in images) {
      rels.write(
        '<Relationship Id="${img.relId}" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" '
        'Target="media/${img.fileName}"/>',
      );
      archive.addFile(
        ArchiveFile('word/media/${img.fileName}', img.bytes.length, img.bytes),
      );
    }
    // 正文里的外链：TargetMode="External" 表示地址在文档外面（网址等）
    for (final link in links) {
      rels.write(
        '<Relationship Id="${link.relId}" '
        'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink" '
        'Target="${_xesc(link.target)}" TargetMode="External"/>',
      );
    }
    rels.write('</Relationships>');
    archive.addFile(
      ArchiveFile.string('word/_rels/document.xml.rels', rels.toString()),
    );

    return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
  }

  /// `word/numbering.xml`：项目符号（numId=1）和数字编号（numId=2）各一套，
  /// 每套给 5 个级别，对应正文里最多 5 层的缩进。
  ///
  /// 为什么要费这个劲，而不是继续手打「· 」：
  ///   · 有序列表**编号直接丢失**（`1. 2. 3.` 全变成普通段落），正文里
  ///     那段"第一步/第二步"看起来就是一堆散句；
  ///   · 项目符号手打的 `·` 不随级别缩进，嵌套结构看不出来；
  ///   · Word 里没法继续编号（回车不会自动接上）。
  static String _numberingXml() {
    const indent = <int>[420, 840, 1260, 1680, 2100];
    final b = StringBuffer(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">',
    );

    // abstractNum 0：项目符号
    b.write('<w:abstractNum w:abstractNumId="0">');
    for (var i = 0; i < indent.length; i++) {
      b.write(
        '<w:lvl w:ilvl="$i"><w:start w:val="1"/>'
        '<w:numFmt w:val="bullet"/><w:lvlText w:val="•"/>'
        '<w:lvlJc w:val="left"/>'
        '<w:pPr><w:ind w:left="${indent[i]}" w:hanging="420"/></w:pPr>'
        '</w:lvl>',
      );
    }
    b.write('</w:abstractNum>');

    // abstractNum 1：阿拉伯数字，层级用 1. / 1.1 / 1.1.1 这种写法
    b.write('<w:abstractNum w:abstractNumId="1">');
    for (var i = 0; i < indent.length; i++) {
      final pattern = List<String>.generate(i + 1, (k) => '%${k + 1}').join('.');
      b.write(
        '<w:lvl w:ilvl="$i"><w:start w:val="1"/>'
        '<w:numFmt w:val="decimal"/><w:lvlText w:val="$pattern."/>'
        '<w:lvlJc w:val="left"/>'
        '<w:pPr><w:ind w:left="${indent[i]}" w:hanging="420"/></w:pPr>'
        '</w:lvl>',
      );
    }
    b.write('</w:abstractNum>');

    // numId 只是"实例"，指向 abstractNum
    b.write('<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>');
    b.write('<w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>');
    b.write('</w:numbering>');
    return b.toString();
  }

  /// `docProps/core.xml`：文档属性（标题 + 创建/修改时间）。
  ///
  /// 时间取笔记自己的 `createdAt` / `updatedAt`，**不是导出时刻** ——
  /// 用户从 Word 的「文件 → 信息」或资源管理器里看到的应当是他写这篇的时间。
  static String _coreXml(Note note) {
    final created = w3cDate(note.createdAt);
    final modified = w3cDate(note.updatedAt);
    return '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<cp:coreProperties '
        'xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/" '
        'xmlns:dcterms="http://purl.org/dc/terms/" '
        'xmlns:dcmitype="http://purl.org/dc/dcmitype/" '
        'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'
        '<dc:title>${_xesc(note.title.trim())}</dc:title>'
        '<dcterms:created xsi:type="dcterms:W3CDTF">$created</dcterms:created>'
        '<dcterms:modified xsi:type="dcterms:W3CDTF">$modified</dcterms:modified>'
        '</cp:coreProperties>';
  }

  /// `word/styles.xml`：定义 Normal 和 Heading1~6。
  ///
  /// **这是"Word 导航窗格能看到目录"的关键。** 之前正文标题虽然写了
  /// `w:pStyle w:val="Heading2"`，但整个包**没有 styles.xml** ——
  /// 那个样式根本没定义，Word 除了显示成普通文字，也拿不到大纲级别，
  /// 于是侧栏里空空如也。用户的原话就是"在 word 文档里侧栏看不到目录"。
  ///
  /// 两点必须给对：
  ///   1. `w:outlineLvl`（0 起）—— Word 的导航窗格认的是它，不是字号
  ///   2. `w:name` 用 Word 内置名（`heading 1`…）—— 这样"引用→目录"
  ///      那些内置功能也能识别，而且在别的阅读器里一样有层级
  static String _stylesXml() {
    const sizes = <int>[36, 32, 28, 26, 24, 22]; // 半磅：18/16/14/13/12/11pt
    final b = StringBuffer(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
      '<w:docDefaults><w:rPrDefault><w:rPr>'
      '<w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="宋体" w:cs="Calibri"/>'
      '<w:sz w:val="21"/><w:szCs w:val="21"/>'
      '</w:rPr></w:rPrDefault>'
      '<w:pPrDefault><w:pPr>'
      '<w:spacing w:after="120" w:line="360" w:lineRule="auto"/>'
      '</w:pPr></w:pPrDefault></w:docDefaults>'
      '<w:style w:type="paragraph" w:default="1" w:styleId="Normal">'
      '<w:name w:val="Normal"/><w:qFormat/></w:style>'
      '<w:style w:type="character" w:styleId="Hyperlink">'
      '<w:name w:val="Hyperlink"/><w:qFormat/>'
      '<w:rPr><w:color w:val="3B82F6"/><w:u w:val="single"/></w:rPr></w:style>',
    );
    for (var i = 0; i < 6; i++) {
      final lvl = i + 1;
      b.write(
        '<w:style w:type="paragraph" w:styleId="Heading$lvl">'
        '<w:name w:val="heading $lvl"/><w:basedOn w:val="Normal"/>'
        '<w:next w:val="Normal"/><w:qFormat/>'
        '<w:pPr><w:keepNext/>'
        '<w:spacing w:before="${240 - i * 20}" w:after="120"/>'
        '<w:outlineLvl w:val="$i"/></w:pPr>'
        '<w:rPr><w:b/><w:sz w:val="${sizes[i]}"/>'
        '<w:szCs w:val="${sizes[i]}"/></w:rPr></w:style>',
      );
    }
    b.write('</w:styles>');
    return b.toString();
  }

  static String _documentXml(
    Note note,
    List<ContentBlock> blocks,
    List<_DocxImage> images, {
    String? videoFolder,
    List<String> oversizedVideos = const <String>[],
    List<_DocxLink>? links,
  }) {
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

    // **正文前面不写目录。**
    //
    // 以前这里会插一份带超链接的目录，理由是"导出的文件离开了应用，
    // 阅读器里没有那个目录面板"。用户的反馈是不要：导出的文档应该和笔记
    // 长得一样，正文第一行就该是正文，而不是先看一遍标题清单。
    //
    // 导航并没有因此丢失：标题用的是 Word 内置的 Heading 样式 +
    // `w:outlineLvl`，Word 的**导航窗格**照样能列出大纲并跳转，
    // 想要正文里带目录的话用「引用 → 目录」自己插一份（那是 Word 的正确做法，
    // 标题改了它会跟着更新，而我们手写的那份是死的）。

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
        // 视频：Word 没有可移植的"内嵌可播放视频"做法（在线视频要能联网的
        // URL，OLE 对象要 Word 原生支持且换台机器就失效），所以正文里留一行
        // 能看见的说明，真正的视频文件由 zipBytes 放进制表同名 .files 目录。
        if (MediaImporter.isVideoPath(rel)) {
          b.write(_para(_videoNote(
            rel,
            videoFolder ?? _videoFolderOf(note),
            skipped: oversizedVideos.contains(rel),
          )));
        } else {
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
        }
      } else {
        b.write(_paragraphXml(block, links));
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
  ///
  /// [links] 非空时，`[文字](地址)` 和裸网址会登记成**可真点的超链接**
  /// （Word 的外链要靠 document.xml.rels 里的关系，所以要往外带）。
  static String _runs(String text, [List<_DocxLink>? links]) {
    // 段落里的软换行要变成 `<w:br/>`：`w:t` 里的 `\n` 在 Word 里
    // **不是换行**，会被直接吞掉，多行正文挤成一坨
    return text
        .split('\n')
        .map((line) => _runsLine(line, links))
        .join('<w:r><w:br/></w:r>');
  }

  static String _runsLine(String text, List<_DocxLink>? links) {
    final out = StringBuffer();
    final re = RegExp(
      r'(\*\*[^*]+\*\*|~~[^~]+~~|\*[^*]+\*|`[^`]+`|\[[^\]]+\]\([^)]+\)|https?://\S+)',
    );
    var last = 0;
    void plain(String s) {
      if (s.isEmpty) return;
      out.write('<w:r><w:t xml:space="preserve">${_xesc(s)}</w:t></w:r>');
    }

    void link(String label, String target) {
      if (links == null) {
        plain(label);
        return;
      }
      final id = 'rIdLink${links.length + 1}';
      links.add(_DocxLink(relId: id, target: target));
      out.write('<w:hyperlink r:id="$id">'
          '<w:r><w:rPr><w:rStyle w:val="Hyperlink"/></w:rPr>'
          '<w:t xml:space="preserve">${_xesc(label)}</w:t></w:r>'
          '</w:hyperlink>');
    }

    for (final m in re.allMatches(text)) {
      plain(text.substring(last, m.start));
      final t = m.group(0)!;
      if (t.startsWith('**')) {
        out.write('<w:r><w:rPr><w:b/></w:rPr>'
            '<w:t xml:space="preserve">${_xesc(t.substring(2, t.length - 2))}</w:t></w:r>');
      } else if (t.startsWith('~~')) {
        out.write('<w:r><w:rPr><w:strike/></w:rPr>'
            '<w:t xml:space="preserve">${_xesc(t.substring(2, t.length - 2))}</w:t></w:r>');
      } else if (t.startsWith('`')) {
        out.write('<w:r><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/>'
            '<w:shd w:val="clear" w:fill="F2F2F7"/></w:rPr>'
            '<w:t xml:space="preserve">${_xesc(t.substring(1, t.length - 1))}</w:t></w:r>');
      } else if (t.startsWith('[')) {
        final md = RegExp(r'^\[([^\]]+)\]\(([^)]+)\)$').firstMatch(t)!;
        link(md.group(1)!, md.group(2)!);
      } else if (t.startsWith('http')) {
        // 裸网址也做成可点的 —— 笔记里贴链接是常态，导出后点不动很别扭
        link(t, t);
      } else {
        out.write('<w:r><w:rPr><w:i/></w:rPr>'
            '<w:t xml:space="preserve">${_xesc(t.substring(1, t.length - 1))}</w:t></w:r>');
      }
      last = m.end;
    }
    plain(text.substring(last));
    return out.toString();
  }

  static String _paragraphXml(ContentBlock block, [List<_DocxLink>? links]) {
    final text = block.text.trim();
    switch (block.type) {
      case ContentBlockType.image:
        final rel = _imagePathOf(text);
        return _para(
          MediaImporter.isVideoPath(rel)
              ? '[视频] ${p.basename(rel)}'
              : '[图片] $rel',
        );
      case ContentBlockType.divider:
        return _para('————————');
      case ContentBlockType.heading:
        final level = block.level.clamp(1, 6);
        // 标题用 Word 内置的 Heading 样式：导航窗格认的是它（样式里带
        // `w:outlineLvl`），行内标记要清掉，否则标题里会露出 `**`
        return '<w:p><w:pPr><w:pStyle w:val="Heading$level"/></w:pPr>'
            '${_runs(stripInline(text))}</w:p>';
      case ContentBlockType.bullet:
        return _listXml(text, level: block.level, numId: 1, links: links);
      case ContentBlockType.ordered:
        return _listXml(text, level: block.level, numId: 2, links: links);
      case ContentBlockType.quote:
        // 引用加个左边框，Word 里看得出是引文
        return '<w:p><w:pPr><w:pBdr><w:left w:val="single" w:sz="18" '
            'w:space="8" w:color="3B82F6"/></w:pBdr>'
            '<w:ind w:left="240"/></w:pPr>${_runs(text, links)}</w:p>';
      case ContentBlockType.code:
        return '<w:p><w:r><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas"/></w:rPr>'
            '<w:t xml:space="preserve">${_xesc(text)}</w:t></w:r></w:p>';
      case ContentBlockType.paragraph:
        return '<w:p>${_runs(text, links)}</w:p>';
    }
  }

  /// 列表项：交给 Word 的编号机制（numbering.xml），
  /// 编号/项目符号和缩进都由它算，而不是我们手打进正文。
  static String _listXml(
    String text, {
    required int level,
    required int numId,
    List<_DocxLink>? links,
  }) {
    final ilvl = level.clamp(0, 4);
    return '<w:p><w:pPr><w:numPr><w:ilvl w:val="$ilvl"/>'
        '<w:numId w:val="$numId"/></w:numPr></w:pPr>'
        '${_runs(text, links)}</w:p>';
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
  // **导出的正文里不再有目录。** 以前会在正文前插一份（docx 里还是真超链接），
  // 理由是"文件离开了应用、阅读器里没有目录面板"；用户的反馈是不要：
  // 导出的文档应当和笔记本身长得一样，第一行就该是正文。
  //
  // 导航能力没有丢：docx 用 Word 内置 Heading 样式 + `w:outlineLvl`，
  // Word 的导航窗格照常列出大纲并能跳；正文里想要目录就用「引用 → 目录」，
  // 那是 Word 的正确做法（标题改了会跟着更新，我们手写的那份是死的）。
  // 应用内的目录面板也还在，那是阅读时用的，和导出无关。

  /// 标题文字 → HTML 锚点 id。
  ///
  /// 标题的 id 保留：用户自己在笔记里写 `[跳过去](#某标题)` 时要能落地。
  static String _slug(String raw) => stripInline(raw)
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

    // 有序列表的序号要自己数：block 里只有文字（`1. ` 在解析时就剥掉了）。
    // 之前 txt 里所有列表项都写成 `  xxx`，序号全丢 —— 步骤类的笔记
    // 导出成 txt 就再也看不出先后了。
    var orderedSeq = 0;
    for (final block in parseContent(note.content)) {
      // 关键：block.text 是**原始 Markdown**，直接写出去 txt 里就还是一堆星号
      final text = stripInline(block.text.trim());
      final indent = '  ' * (block.level + 1);
      if (block.type != ContentBlockType.ordered) orderedSeq = 0;
      switch (block.type) {
        case ContentBlockType.image:
          // 视频块和图片块在正文里是同一个 type，纯文本里也要分开写，
          // 否则导出后的 txt/html 会把 mp4 说成"图片"
          final rel = _imagePathOf(block.text.trim());
          b.writeln(
            MediaImporter.isVideoPath(rel) ? '[视频] $rel' : '[图片] $rel',
          );
        case ContentBlockType.divider:
          b.writeln('-' * 40);
        case ContentBlockType.heading:
          b
            ..writeln()
            ..writeln(text)
            ..writeln('-' * text.runes.length);
        case ContentBlockType.bullet:
          b.writeln('$indent· $text');
        case ContentBlockType.ordered:
          orderedSeq++;
          b.writeln('$indent$orderedSeq. $text');
        case ContentBlockType.quote:
          b.writeln('$indent> $text');
        case ContentBlockType.code:
          b.writeln('$indent  $text');
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

    final blocks = parseContent(note.content);
    // 连续的列表项要合进同一个 <ul>/<ol>：一个 <li> 包一个 <ul> 的话，
    // 序号会各自从 1 重新开始，浏览器给的缩进也会乱
    var i = 0;
    while (i < blocks.length) {
      final type = blocks[i].type;
      if (type == ContentBlockType.bullet || type == ContentBlockType.ordered) {
        final ordered = type == ContentBlockType.ordered;
        final tag = ordered ? 'ol' : 'ul';
        b.writeln('<$tag>');
        while (i < blocks.length && blocks[i].type == type) {
          b.writeln('<li>${_inline(blocks[i].text.trim())}</li>');
          i++;
        }
        b.writeln('</$tag>');
        continue;
      }
      b.writeln(_htmlBlock(blocks[i], imageRoot));
      i++;
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
        // 视频不能走 `_dataUri`：那是把文件 base64 塞进 HTML，
        // 一段 mp4 能撑出几十 MB 的 html，而且 `<img>` 也放不出来。
        // 交给浏览器原生播放器，src 用相对路径（视频文件随包一起导出）。
        if (MediaImporter.isVideoPath(rel)) {
          return '<video controls preload="metadata" src="${_esc(rel)}" '
              'style="max-width:100%;border-radius:12px;"></video>';
        }
        return '<img src="${_esc(_dataUri(rel, imageRoot))}" alt="">';
      case ContentBlockType.divider:
        return '<hr>';
      case ContentBlockType.heading:
        final level = block.level.clamp(1, 6);
        // 带 id 才能被目录里的锚点跳到
        return '<h$level id="${_slug(text)}">${_inline(text)}</h$level>';
      case ContentBlockType.bullet:
      case ContentBlockType.ordered:
        // 列表项在 _html 里成组合并，这里只是单个 block 的兜底
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
    // 删除线（要在 ** 之后处理，否则 ~~ 里的内容会被当普通文字）
    out = out.replaceAllMapped(
      RegExp(r'~~([^~]+)~~'),
      (m) => '<del>${m.group(1)}</del>',
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

  // ── 视频 ────────────────────────────────────────────────────────────────
  //
  // Word 文档里**放不了可播放的视频**，这一点没有绕过办法：
  //   · "在线视频" 需要公网 URL，而且要 Word 2013+ 联网；
  //   · OLE 嵌入的对象换台机器/换个阅读器就失效。
  // 所以导出的做法是：正文里留一行看得见的 `[视频] 文件名` 说明，
  // 视频文件本身跟着压缩包一起走，放在同名 `.files` 目录里。

  /// 这篇笔记的视频在压缩包里放的目录名（相对该笔记文件所在目录）。
  static String videoFolderOf(Note note) => _videoFolderOf(note);

  static String _videoFolderOf(Note note) =>
      '${_safeSegment(suggestedName(note))}.files';

  static String _videoNote(String rel, String folder, {bool skipped = false}) {
    final name = p.basename(rel);
    if (skipped) {
      // **不能写"已放入 xxx 文件夹"** —— 这个文件因为太大没进包，
      // 那样写就是在骗人。宁可说清楚"没打包、原文件在哪"。
      return '[视频] $name（文件超过 '
          '${NoteExporter.kMaxPackedVideoBytes ~/ (1024 * 1024)} MB，'
          '未随导出打包；原文件在应用的媒体目录里）';
    }
    return folder.isEmpty
        ? '[视频] $name'
        : '[视频] $name（Word 不能内嵌视频，该文件已随导出放入「$folder」文件夹）';
  }

  /// 正文里引用到的所有视频文件（相对路径，去重、保持出现顺序）。
  static List<String> videoRelsOf(Note note) {
    final out = <String>[];
    for (final block in parseContent(note.content)) {
      if (block.type != ContentBlockType.image) continue;
      final rel = _imagePathOf(block.text.trim());
      if (rel.isEmpty || !MediaImporter.isVideoPath(rel)) continue;
      if (!out.contains(rel)) out.add(rel);
    }
    return out;
  }

  /// 单篇导出后，把正文里的视频**拷到 docx 旁边**的同名 `.files` 目录里。
  /// 单篇导出走的是「选保存位置」这条路，没有压缩包可放视频 ——
  /// 而 docx 正文里已经写了"视频放在 XXX.files 文件夹"，
  /// 不把文件夹真的建出来，那句话就是骗人的。
  ///
  /// 返回拷了几个文件。
  static int copyVideosNextTo(
    String docxPath,
    Note note, {
    String? imageRoot,
  }) {
    final savedBase = p.basenameWithoutExtension(docxPath);
    final dir = Directory(p.join(p.dirname(docxPath), '$savedBase.files'));
    var count = 0;
    for (final rel in videoRelsOf(note)) {
      final src = imageRoot == null ? File(rel) : File(p.join(imageRoot, rel));
      if (!src.existsSync()) continue;
      dir.createSync(recursive: true);
      src.copySync(p.join(dir.path, p.basename(rel)));
      count++;
    }
    return count;
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
    applyNoteTimes(
      file.path,
      created: note.createdAt,
      modified: note.updatedAt,
    );
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
        // 落盘后把创建/修改时间改回笔记的时间
        applyNoteTimes(
          file.path,
          created: note.createdAt,
          modified: note.updatedAt,
        );
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
