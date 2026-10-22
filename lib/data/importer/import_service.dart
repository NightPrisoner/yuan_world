/// 文集导入服务。
///
/// 流程：解析文档（docx / txt / md）→ 建/取文集 → 落库拿 id →
/// 图片落盘 → 回写正文路径。三种格式只在**解析**这一步不同，
/// 落库、去重、媒体搬运、失败回滚全部共用下面这一条链路。
///
/// 性能注意：数据源里最大的 docx 有 160MB+，解压与 XML 解析都在 CPU 上。
/// 因此解析步骤放进 [Isolate.run]，避免卡住 UI 线程（否则导入时界面直接定住）。
library;

import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

import '../db/app_database.dart';
import '../media/media_counts.dart';
import '../media/media_importer.dart';
import '../repositories/note_repository.dart';
import '../../core/utils/text_stats.dart';
import 'docx_importer.dart';
import 'markdown_importer.dart';
import 'media_refs.dart';
import 'txt_importer.dart';

/// 导入进度回调。
typedef ImportProgress = void Function(ImportStage stage, int done, int total, String label);
typedef ImportCancellation = bool Function();

enum ImportStage { reading, parsing, saving, done }

class ImportSummary {
  ImportSummary();

  int imported = 0;
  int skipped = 0;
  int failed = 0;
  int images = 0;
  int chars = 0;

  /// 本来就导入过、这次**被挪进目标文集**的篇数。
  ///
  /// 和 skipped 分开计：跳过是"没动"，挪动是"动了但没新建"。
  /// 混在一起用户会以为"重新导入文件夹什么也没发生"。
  int moved = 0;

  /// 用户在文件边界请求停止后置为 true。
  bool cancelled = false;

  /// 被跳过的表格数量。
  ///
  /// 表格没有对应的 Markdown 表示，只能整块跳过 ——
  /// 但必须告诉用户，否则他会以为内容好好地导进来了。
  int tables = 0;

  final List<String> errors = <String>[];

  String get report {
    final b = StringBuffer()
      ..write('成功 $imported 篇')
      ..write('，图片 $images 张')
      ..write('，共 $chars 字');
    if (skipped > 0) b.write('，跳过 $skipped 篇');
    if (moved > 0) b.write('，归入文集 $moved 篇');
    if (failed > 0) b.write('，失败 $failed 篇');
    if (tables > 0) b.write('；$tables 个表格未导入');
    if (cancelled) b.write('，已按请求停止');
    return b.toString();
  }
}

class ImportService {
  ImportService(this.db, this.repo);

  final AppDatabase db;
  final NoteRepository repo;

  /// 导入一批 docx 文件。已存在同 source_url 或同标题的会被跳过（幂等）。
  Future<ImportSummary> importDocx(
    List<File> files, {
    ImportProgress? onProgress,
    ImportCancellation? isCancellationRequested,
    String? collectionName,
    String? rootDir,
  }) async {
    final summary = ImportSummary();
    var done = 0;

    for (final file in files) {
      // 取消只在文件边界生效：当前文件的解析/图片落盘完成后，
      // 下一篇开始前退出，避免留下半篇笔记。
      if (isCancellationRequested?.call() ?? false) {
        summary.cancelled = true;
        break;
      }
      done++;
      final name = p.basename(file.path);
      // 这篇已经写进库的笔记 id。建行之后任何环节失败，都要整篇回滚 ——
      // 用户看到的应该要么是一篇完整的笔记，要么是"这篇没导进来"。
      int? createdNoteId;
      try {
        onProgress?.call(ImportStage.reading, done, files.length, name);
        final bytes = await file.readAsBytes();

        onProgress?.call(ImportStage.parsing, done, files.length, name);
        // 大文件解析扔到独立 isolate。
        // fallbackTitle 用文件名兜底：文档里若找不到合适标题，
        // 也能得到一个有意义的名字，而不是空标题或图片占位符。
        final fallback = p.basenameWithoutExtension(file.path);
        final lower = file.path.toLowerCase();
        final isTxt = lower.endsWith('.txt');
        // Markdown 自己就是一整份正文，解析最轻：只剥 front matter 和
        // 开头那个重复的一级标题，正文一个字符都不动。
        final isMarkdown = lower.endsWith('.md') || lower.endsWith('.markdown');
        // 按扩展名分派：docx 走 Word 解析，txt 走纯文本解析（带编码嗅探），
        // md 走 Markdown 解析（同样带编码嗅探 —— 国内的 .md 也常是 GBK）
        final parsed = await Isolate.run(
          () => isMarkdown
              ? MarkdownImporter.parse(bytes, fallbackTitle: fallback)
              : isTxt
              ? TxtImporter.parse(bytes, fallbackTitle: fallback)
              : DocxImporter.parse(bytes, fallbackTitle: fallback),
        );

        onProgress?.call(ImportStage.saving, done, files.length, name);

        // 1) 先确保文集存在。去重判断也要用到它，所以必须先做。
        //
        // **按文件的相对路径还原嵌套结构**：导入
        // `文集/小小说/2023/a.docx` 时，应该建出
        // 「文集 → 小小说 → 2023」三层，而不是把所有文章压进一个平文集。
        //
        // 优先用相对路径（文件夹导入）；没有根目录时退回 collectionName
        // （单个选文件），最后才用文档内部的「文集：xxx」。
        int? collectionId;
        final segments = _collectionPathFor(file, rootDir, collectionName);
        if (segments.isNotEmpty) {
          collectionId = repo.ensureCollectionPath(
            segments,
            color: _collectionColor(repo.allCollections().length),
          );
        } else if (parsed.collection.isNotEmpty) {
          collectionId = repo.ensureCollection(
            parsed.collection,
            color: _collectionColor(repo.allCollections().length),
          );
        }

        // 2) 幂等：同来源链接、或同一文集内同标题的，视为已导入。
        //
        // **但跳过不等于什么都不做**：用户把一个文件夹拖进来，
        // 意思就是"这些文章归到这个文件夹下"。如果只是跳过，
        // 它们会永远留在原来的文集里 —— 用户看到的就是
        // "导入文件夹之后文章根本没出现在那个文件夹下面"。
        final existing = _existingNoteId(parsed, collectionId);
        if (existing != null) {
          summary.skipped++;
          if (collectionId != null && _moveInto(existing, collectionId)) {
            summary.moved++;
          }
          continue;
        }

        // 2) 先插入占位，拿到 id 才能决定图片目录
        final chars = countChars(parsed.markdown);
        final words = countWords(parsed.markdown);

        // 时间一律取**文件本身**的，而不是"导入这一刻"：
        // 文件是什么时候建的，笔记就算什么时候建的；
        // 文件最后一次改是什么时候，笔记的修改时间就是什么时候。
        // 之后在应用里改了内容，修改时间才会更新成当时。
        DateTime? fileCreated;
        DateTime? fileModified;
        try {
          final stat = file.statSync();
          // Dart 3 去掉了 FileStat.created，`changed` 是最接近的替代
          //（文件元数据的变更时间）。拿不准的时候它是安全的：
          // 至少是**文件自己的时间**，而不是"导入这一刻"。
          fileCreated = stat.changed;
          fileModified = stat.modified;
        } catch (_) {
          // 拿不到文件信息就算了，退回文档头 / 现在
        }

        final noteId = repo.insertNote(
          title: parsed.title,
          content: parsed.markdown,
          excerpt: makeExcerpt(parsed.markdown),
          author: parsed.author,
          sourceUrl: parsed.sourceUrl,
          collectionId: collectionId,
          publishedAt: parsed.publishedAt,
          charCount: chars,
          wordCount: words,
          // 文件时间拿不到时，退回文档头里的发布时间，最后才是现在
          createdAt: fileCreated ?? parsed.publishedAt,
          updatedAt: fileModified ?? fileCreated ?? parsed.publishedAt,
        );
        createdNoteId = noteId;

        // 3) 图片落盘：images/<noteId>/<序号>.<ext>
        final relDir = '$noteId';
        final dir = Directory(p.join(db.imageRoot.path, relDir));
        dir.createSync(recursive: true);

        var idx = 0;
        String? cover;
        var content = parsed.markdown;
        for (final img in parsed.images) {
          idx++;
          final fileName = '$idx.${_ext(img.placeholder)}';
          final target = File(p.join(dir.path, fileName));
          await target.writeAsBytes(img.bytes, flush: false);
          cover ??= '$relDir/$fileName';

          // 把占位 images/N.ext 换成真实相对路径
          content = content.replaceAll(img.placeholder, '$relDir/$fileName');
        }

        // 3b) 正文里**按相对路径**引用的本地图片/视频，一并搬进来。
        //
        // docx 内嵌的图上面已经处理了；这里补的是另一种形态：文档旁边
        // （或同级的 assets/、xxx_files/）躺着文件，正文里写着它的相对路径。
        // 不处理的话笔记里会留一个打不开的路径，用户以为图丢了。
        //
        // 走的是**同一条落盘逻辑**（同一个目录、同一个序号、同一次替换），
        // 所以图片和视频在笔记里的表现和内嵌图完全一致。
        for (final ref in resolveLocalMedia(parsed.markdown, file.parent)) {
          idx++;
          final ext = MediaImporter.extensionOf(ref.fileName);
          final fileName = '$idx.$ext';
          final target = File(p.join(dir.path, fileName));
          await target.writeAsBytes(ref.bytes, flush: false);
          cover ??= '$relDir/$fileName';
          content = content.replaceAll(ref.reference, '$relDir/$fileName');
        }

        // 4) 回写正文与统计
        // touch: false —— 这是导入流程的一部分，不是用户编辑。
        // 碰了修改时间的话，insertNote 里按文件设好的值就白设了。
        repo.updateNote(
          id: noteId,
          content: content,
          excerpt: makeExcerpt(content),
          charCount: countChars(content),
          wordCount: countWords(content),
          // image_count 只数**图片**，而且要和统计页现算的口径一致
          // （只认独占一行的图片语法）。以前这里写的是"落盘文件数"，
          // 视频也算进去、行内图也算进去，于是导入的笔记图片数偏高，
          // 跟详情页/统计页对不上。
          imageCount: countNoteMedia(content).images,
          coverImage: cover,
          touch: false,
        );

        // 全部成功，才计入汇总：中途失败时不能让"图片 N 张"/"表格 N 个"
        // 虚高 —— 那篇根本没导进来。
        summary.images += idx;
        summary.tables += parsed.tableCount;
        summary.imported++;
        summary.chars += chars;
        createdNoteId = null;
      } catch (e) {
        // 回滚：删掉这篇已经落库的行、images/<id>/ 目录和历史草稿。
        // 不回滚文集 —— 它可能是用户本来就有的，而且同名文集
        // 下一篇还要接着用。
        if (createdNoteId != null) {
          try {
            repo.purgeNotes(<int>[createdNoteId]);
          } catch (_) {
            // 回滚本身失败也不能吞掉原始错误，继续往下报告
          }
        }
        summary.failed++;
        summary.errors.add('$name: $e');
      }

      if (isCancellationRequested?.call() ?? false) {
        summary.cancelled = true;
        break;
      }
    }

    onProgress?.call(ImportStage.done, done, files.length, '');
    return summary;
  }

  /// 算出这个文件应该归到哪条文集路径上。
  ///
  /// 有 [rootDir] 时按**相对路径**还原层级：根目录名 + 中间的子目录。
  /// 没有时退回 [collectionName]（单个选文件的场景）。
  List<String> _collectionPathFor(
    File file,
    String? rootDir,
    String? collectionName,
  ) {
    if (rootDir == null || rootDir.isEmpty) {
      final name = collectionName?.trim() ?? '';
      return name.isEmpty ? const <String>[] : <String>[name];
    }

    final parts = p.split(p.relative(file.path, from: rootDir));
    // 最后一段是文件名，去掉；剩下的就是子目录层级
    final dirs = parts.length > 1 ? parts.sublist(0, parts.length - 1) : <String>[];
    // 相对路径里不含根目录自己的名字，所以补在最前面
    final rootName = p.basename(rootDir);
    final out = <String>[
      if (rootName.isNotEmpty && rootName != '.') rootName,
      ...dirs.where((d) => d.isNotEmpty && d != '.'),
    ];
    return out;
  }

  /// 已经导入过的笔记 id；没导入过返回 null。
  int? _existingNoteId(ParsedDocument d, int? collectionId) {
    if (d.sourceUrl.isNotEmpty) {
      final hit = db.db.select(
        'SELECT id FROM notes WHERE source_url = ? AND deleted_at IS NULL LIMIT 1',
        [d.sourceUrl],
      );
      if (hit.isNotEmpty) return hit.first['id'] as int;
    }
    // 标题必须和文集组合起来判断：
    // 数据源里每个文集文件夹都放了一个「00 文集说明.docx」，
    // 只按标题去重会把后面几个文集误判成重复而全部跳过。
    final rows = collectionId == null
        ? db.db.select(
            'SELECT id FROM notes WHERE title = ? AND collection_id IS NULL '
            'AND deleted_at IS NULL LIMIT 1',
            <Object?>[d.title],
          )
        : db.db.select(
            'SELECT id FROM notes WHERE title = ? AND collection_id = ? '
            'AND deleted_at IS NULL LIMIT 1',
            <Object?>[d.title, collectionId],
          );
    if (rows.isNotEmpty) return rows.first['id'] as int;

    // 兜底：**标题 + 正文完全一样**就算同一篇。
    //
    // 没有来源链接的文件（比如 txt）换一个文件夹重新导入时，
    // 上面两条都匹配不上，会凭空多出一份副本。
    // 正文逐字相同基本可以断定是同一个文件。
    final byContent = db.db.select(
      'SELECT id FROM notes WHERE title = ? AND content = ? '
      'AND deleted_at IS NULL LIMIT 1',
      <Object?>[d.title, d.markdown],
    );
    return byContent.isEmpty ? null : byContent.first['id'] as int;
  }

  /// 把一篇已有笔记挪进文集。返回是否真的动了。
  bool _moveInto(int noteId, int collectionId) {
    final cur = db.db.select(
      'SELECT collection_id FROM notes WHERE id = ?',
      <Object?>[noteId],
    );
    if (cur.isEmpty) return false;
    if (cur.first['collection_id'] == collectionId) return false;
    db.db.execute(
      'UPDATE notes SET collection_id = ? WHERE id = ?',
      <Object?>[collectionId, noteId],
    );
    return true;
  }

  /// 递归收集目录下所有可导入的文档（.docx / .txt / .md）。
  static List<File> collectDocx(String root) {
    final dir = Directory(root);
    if (!dir.existsSync()) return <File>[];
    final out = <File>[];
    for (final e in dir.listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final lower = e.path.toLowerCase();
      if (!isImportablePath(lower)) continue;
      // 跳过 Word 的临时文件（~$ 开头）
      if (p.basename(e.path).startsWith('~\$')) continue;
      out.add(e);
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  /// 这个路径能不能导入。
  ///
  /// 收集目录、文件选择器过滤、拖拽判断三处**必须**共用这一份 ——
  /// 否则会出现"文件夹导入能收 .md，拖一个 .md 进来却被拒"这种自相矛盾。
  static bool isImportablePath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.docx') ||
        lower.endsWith('.txt') ||
        lower.endsWith('.md') ||
        lower.endsWith('.markdown');
  }

  static String _ext(String placeholder) {
    final dot = placeholder.lastIndexOf('.');
    return dot < 0 ? 'png' : placeholder.substring(dot + 1);
  }

  /// 给文集轮换一个好看的颜色。
  static int _collectionColor(int index) {
    const colors = <int>[
      0xFF007AFF, // 蓝
      0xFF34C759, // 绿
      0xFFFF9500, // 橙
      0xFFFF2D55, // 洋红
      0xFFAF52DE, // 紫
      0xFF5856D6, // 靛
      0xFF00C7BE, // 青
      0xFFFFCC00, // 黄
    ];
    return colors[index % colors.length];
  }
}
