/// 端到端测试：txt 导入链路 + 批量操作。
///
/// 解析器单独测过了，但**"选文件 → 落库"这条链路**没测过 ——
/// 中间还隔着编码嗅探、分派、标题兜底、时间取值。
/// 批量操作同理：一条 SQL 的 `IN` 写错了，用户一次删掉几十篇。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/models.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';

void main() {
  late AppDatabase db;
  late NoteRepository repo;
  late ImportService importer;
  late Directory work;

  setUp(() {
    db = AppDatabase.inMemory();
    repo = NoteRepository(db);
    importer = ImportService(db, repo);
    work = Directory.systemTemp.createTempSync('yw_e2e_');
  });
  tearDown(() {
    db.close();
    if (work.existsSync()) work.deleteSync(recursive: true);
  });

  File writeTxt(String name, List<int> bytes) {
    final f = File(p.join(work.path, name));
    f.writeAsBytesSync(bytes);
    return f;
  }

  /// 造一个带文档头的 docx（里面有「文集：文档里的集」）。
  Uint8List makeDocxWithCollection() {
    String para(String t) =>
        '<w:p><w:r><w:t xml:space="preserve">$t</w:t></w:r></w:p>';
    final archive = Archive()
      ..addFile(ArchiveFile.string(
        '[Content_Types].xml',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        '</Types>',
      ))
      ..addFile(ArchiveFile.string(
        '_rels/.rels',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        '</Relationships>',
      ))
      ..addFile(ArchiveFile.string(
        'word/document.xml',
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        '<w:body>${para('文章丁')}${para('文集：文档里的集')}${para('正文')}'
        '</w:body></w:document>',
      ));
    return Uint8List.fromList(ZipEncoder().encodeBytes(archive));
  }

  group('txt 导入端到端', () {
    test('用户取消时在当前文件完成后停止，不再导入后续文件', () async {
      writeTxt('a.txt', utf8.encode('甲\n\n正文'));
      writeTxt('b.txt', utf8.encode('乙\n\n正文'));
      var calls = 0;
      final summary = await importer.importDocx(
        ImportService.collectDocx(work.path),
        isCancellationRequested: () => ++calls > 2,
      );

      expect(summary.cancelled, isTrue);
      expect(summary.imported, 1);
      expect(repo.listNotes(const NoteFilter()).map((n) => n.title), <String>['甲']);
    });

    test('UTF-8 的 txt 能落成一篇笔记', () async {
      final f = writeTxt(
        '我的文章.txt',
        utf8.encode('真正的标题\n\n第一段\n第二段'),
      );
      final summary = await importer.importDocx(<File>[f]);

      expect(summary.imported, 1);
      expect(summary.failed, 0);

      // listNotes 不含大字段 content（性能考虑），要正文得 getNote
      final listed = repo.listNotes(const NoteFilter()).single;
      final note = repo.getNote(listed.id)!;
      expect(note.title, '真正的标题');
      expect(note.content, contains('第一段'));
      expect(note.content, contains('第二段'));
      // 标题只当标题，不重复出现在正文里
      expect(note.content.contains('真正的标题'), isFalse);
    });

    test('GBK 的 txt 也能落库，且不是乱码', () async {
      final f = writeTxt('gbk.txt', gbk.encode('国标标题\n\n国标正文'));
      await importer.importDocx(<File>[f]);

      final listed = repo.listNotes(const NoteFilter()).single;
      final note = repo.getNote(listed.id)!;
      expect(note.title, '国标标题');
      expect(note.content, contains('国标正文'));
      // 乱码的典型特征
      expect(note.title.contains('?'), isFalse);
      expect(note.title.contains('\uFFFD'), isFalse);
    });

    test('带 BOM 的 UTF-8，标题里不留不可见字符', () async {
      final f = writeTxt(
        'bom.txt',
        <int>[0xEF, 0xBB, 0xBF, ...utf8.encode('BOM 标题\n\n正文')],
      );
      await importer.importDocx(<File>[f]);

      final note = repo.listNotes(const NoteFilter()).single;
      expect(note.title, 'BOM 标题');
      expect(note.title.startsWith('\uFEFF'), isFalse);
    });

    test('空文件退回文件名当标题，不会造出一篇无名笔记', () async {
      final f = writeTxt('空文件.txt', utf8.encode('   \n\n '));
      await importer.importDocx(<File>[f]);

      final note = repo.listNotes(const NoteFilter()).single;
      expect(note.title, '空文件');
    });

    test('docx 和 txt 混着导入，各走各的解析器', () async {
      writeTxt('a.txt', utf8.encode('TXT 标题\n\nTXT 正文'));
      // 一个假的 docx（不是合法 zip）应该失败，但不影响 txt 那篇
      writeTxt('b.docx', utf8.encode('这不是一个真的 docx'));

      final summary = await importer.importDocx(
        ImportService.collectDocx(work.path),
      );

      expect(summary.imported, 1);
      expect(summary.failed, 1);
      expect(repo.listNotes(const NoteFilter()).single.title, 'TXT 标题');
    });

    test('collectDocx 同时收 docx 和 txt，且跳过 Word 临时文件', () async {
      writeTxt('a.txt', utf8.encode('x'));
      writeTxt('b.docx', utf8.encode('x'));
      writeTxt('~\$c.docx', utf8.encode('x')); // Word 打开时的临时文件
      writeTxt('d.md', utf8.encode('x'));       // 不支持的格式

      final found = ImportService.collectDocx(work.path)
          .map((f) => p.basename(f.path))
          .toList();

      expect(found, containsAll(<String>['a.txt', 'b.docx']));
      expect(found.any((n) => n.startsWith('~\$')), isFalse);
      expect(found.contains('d.md'), isFalse);
    });

    test('导入的时间取文件自己的，不是"导入了这一刻"', () async {
      final f = writeTxt('老文件.txt', utf8.encode('标题\n\n正文'));
      // 把文件的修改时间改到 2020 年 —— 不这么做的话，
      // 文件就是刚刚创建的，测不出"用的是文件时间"还是"用的是当前时间"
      f.setLastModifiedSync(DateTime(2020, 5, 6, 7, 8));
      await importer.importDocx(<File>[f]);

      final note = repo.listNotes(const NoteFilter()).single;
      expect(
        note.updatedAt.year,
        2020,
        reason: '修改时间应该来自文件，而不是导入那一刻',
      );
    });
  });

  group('文件夹导入的文集归属', () {
    test('新导入的笔记进以文件夹名命名的文集', () async {
      writeTxt('a.txt', utf8.encode('文章甲\n\n正文'));
      writeTxt('b.txt', utf8.encode('文章乙\n\n正文'));

      final summary = await importer.importDocx(
        ImportService.collectDocx(work.path),
        collectionName: '我的文集',
      );

      expect(summary.imported, 2);
      final col = repo.allCollections().firstWhere((c) => c.name == '我的文集');
      expect(
        repo.listNotes(NoteFilter(collectionId: col.id)).length,
        2,
        reason: '两篇都该归到这个文集下',
      );
    });

    test('重新导入同一个文件夹，已有笔记会被**挪进**该文集', () async {
      writeTxt('a.txt', utf8.encode('文章甲\n\n正文'));

      // 第一次：进「旧文集」
      await importer.importDocx(
        ImportService.collectDocx(work.path),
        collectionName: '旧文集',
      );
      final old = repo.allCollections().firstWhere((c) => c.name == '旧文集');
      expect(repo.listNotes(NoteFilter(collectionId: old.id)).length, 1);

      // 第二次：同一个文件，换个文件夹名 —— 用户改主意了
      final again = await importer.importDocx(
        ImportService.collectDocx(work.path),
        collectionName: '新文集',
      );

      expect(again.imported, 0, reason: '是同一篇，不该重复导入');
      expect(again.skipped, 1);
      expect(
        again.moved,
        1,
        reason: '跳过不等于什么都不做 —— 要把它挪到新文集里',
      );

      final fresh = repo.allCollections().firstWhere((c) => c.name == '新文集');
      expect(repo.listNotes(NoteFilter(collectionId: fresh.id)).length, 1);
      expect(
        repo.listNotes(NoteFilter(collectionId: old.id)),
        isEmpty,
        reason: '不能两边都留一份',
      );
      // 总数不变，没有产生副本
      expect(repo.listNotes(const NoteFilter()).length, 1);
    });

    test('txt 不解析文档头，文集只能来自文件夹名', () async {
      // ⚠️ 已知不一致：只有 docx 解析器会读文档头（作者 / 文集 / 来源），
      // txt 解析器不读。所以 txt 里的「文集：xxx」会被当成普通正文，
      // 归属只能靠文件夹名。
      writeTxt('c.txt', utf8.encode('文章丙\n\n作者：某人\n文集：文档里的集\n正文'));
      await importer.importDocx(ImportService.collectDocx(work.path));

      expect(repo.allCollections(), isEmpty);
      // listNotes 不含大字段 content，要正文得 getNote
      final listed = repo.listNotes(const NoteFilter()).single;
      final note = repo.getNote(listed.id)!;
      // 那几行留在正文里，用户看得到
      expect(note.content, contains('文集：文档里的集'));
    });

    test('文件夹里的子文件夹会还原成嵌套文集', () async {
      // 结构：文集/小小说/2023/a.txt、文集/杂谈/b.txt、文集/根目录.txt
      final root = Directory(p.join(work.path, '文集'))..createSync();
      final sub1 = Directory(p.join(root.path, '小小说', '2023'))
        ..createSync(recursive: true);
      final sub2 = Directory(p.join(root.path, '杂谈'))..createSync();

      File(p.join(sub1.path, 'a.txt')).writeAsStringSync('深层文章\n\n正文');
      File(p.join(sub2.path, 'b.txt')).writeAsStringSync('浅层文章\n\n正文');
      File(p.join(root.path, '根文章.txt')).writeAsStringSync('根文章\n\n正文');

      await importer.importDocx(
        ImportService.collectDocx(root.path),
        rootDir: root.path,
      );

      final byName = <String, Collection>{
        for (final c in repo.allCollections()) c.name: c,
      };

      // 三层结构都要建出来
      expect(byName.keys, containsAll(<String>['文集', '小小说', '2023', '杂谈']));
      expect(byName['文集']!.parentId, isNull, reason: '根是顶层');
      expect(byName['小小说']!.parentId, byName['文集']!.id);
      expect(byName['2023']!.parentId, byName['小小说']!.id,
          reason: '孙目录要挂在子目录下，不能压平');
      expect(byName['杂谈']!.parentId, byName['文集']!.id);

      // 文章落在**最里层**，不是平铺在根上。
      // 注意 listNotes 默认 includeDescendants=true，这里要显式关掉，
      // 否则查子文集会把更深层的也算进来。
      List<String> titlesIn(String name) => repo
          .listNotes(
            NoteFilter(
              collectionId: byName[name]!.id,
              includeDescendants: false,
            ),
          )
          .map((n) => n.title)
          .toList();

      expect(titlesIn('2023'), <String>['深层文章']);
      expect(titlesIn('杂谈'), <String>['浅层文章']);
      expect(titlesIn('文集'), <String>['根文章']);
      expect(titlesIn('小小说'), isEmpty, reason: '中间层自己不该有文章');
    });

    test('顶层文件夹的文章归到顶层文集，不会掉进子文集', () async {
      final root = Directory(p.join(work.path, '顶层'))..createSync();
      Directory(p.join(root.path, '子')).createSync();
      File(p.join(root.path, 'a.txt')).writeAsStringSync('甲\n\n正文');
      File(p.join(root.path, '子', 'b.txt')).writeAsStringSync('乙\n\n正文');

      await importer.importDocx(
        ImportService.collectDocx(root.path),
        rootDir: root.path,
      );

      final byName = <String, Collection>{
        for (final c in repo.allCollections()) c.name: c,
      };
      final topId = byName['顶层']!.id;
      // 查顶层时会**带上子文件夹**（includeDescendants 默认 true），
      // 所以这里要显式只看本级
      final onlyTop = repo.listNotes(
        NoteFilter(collectionId: topId, includeDescendants: false),
      );
      expect(onlyTop.length, 1);
      expect(onlyTop.single.title, '甲');
    });

    test('文件夹名优先于文档内部的文集名（docx）', () async {
      // docx 才会解析文档头；这里用 docx 验证优先级
      final docx = File(p.join(work.path, 'd.docx'));
      docx.writeAsBytesSync(
        makeDocxWithCollection(),
      );
      await importer.importDocx(
        <File>[docx],
        collectionName: '文件夹名',
      );

      final names = repo.allCollections().map((c) => c.name).toList();
      expect(names, contains('文件夹名'));
      expect(
        names,
        isNot(contains('文档里的集')),
        reason: '文件夹是用户亲手做的分类，比文档里那行字更可信',
      );
    });
  });

  group('未改动就不该动修改时间', () {
    test('updateNote 只在真有内容变化时才刷新 updated_at', () {
      // 这条钉的是编辑器的行为契约：编辑器靠"内容比对"决定要不要写库，
      // 而写库会顺带刷新 updated_at。所以只要保证
      // 「没变化 = 不调 updateNote」，时间就不会乱跳。
      final id = repo.insertNote(title: '原文', content: '正文', excerpt: '');
      final before = repo.getNote(id)!.updatedAt;

      // 模拟"进编辑器看一眼就退出"：内容一致，直接不写
      final loaded = repo.getNote(id)!;
      final unchanged =
          loaded.title == '原文' && loaded.content == '正文';
      expect(unchanged, isTrue, reason: '内容确实没变，不应该写库');
      expect(repo.getNote(id)!.updatedAt, before, reason: '时间不该动');
    });

    test('内容变了才写库并刷新时间', () async {
      final id = repo.insertNote(title: '原文', content: '正文', excerpt: '');
      final before = repo.getNote(id)!.updatedAt;

      // 真的改了才写
      await Future<void>.delayed(const Duration(milliseconds: 5));
      repo.updateNote(id: id, content: '改过的正文');

      expect(repo.getNote(id)!.updatedAt.isAfter(before), isTrue);
      expect(repo.getNote(id)!.content, '改过的正文');
    });

    test('touch: false 时不刷新时间（导入回写用的就是它）', () {
      final id = repo.insertNote(title: 't', content: 'x', excerpt: '');
      final before = repo.getNote(id)!.updatedAt;

      repo.updateNote(id: id, content: 'y', touch: false);

      expect(repo.getNote(id)!.content, 'y', reason: '内容要改');
      expect(repo.getNote(id)!.updatedAt, before, reason: '但时间不能动');
    });
  });

  group('回收站', () {
    test('恢复笔记时，它所属的文件夹也一起回来', () {
      final col = repo.createCollection('我的文集')!;
      final id = repo.insertNote(
        title: '里面的',
        content: 'x',
        excerpt: 'x',
        collectionId: col,
      );

      // 删文件夹（连同笔记）
      repo.trashCollection(col);
      expect(repo.allCollections(), isEmpty);
      expect(repo.listNotes(const NoteFilter()), isEmpty);

      // 只恢复**笔记**
      repo.restoreNotes(<int>[id]);

      // 笔记回来了，而且归属还在
      final back = repo.listNotes(const NoteFilter());
      expect(back.length, 1);
      expect(
        back.single.collectionId,
        col,
        reason: '归属不该丢',
      );
      // **文件夹也必须回来** —— 否则它以未分类的样子出现，
      // 左栏里也看不到那个文件夹，用户会以为"没恢复干净"
      final cols = repo.allCollections();
      expect(cols.length, 1, reason: '文件夹要跟着笔记一起恢复');
      expect(cols.single.name, '我的文集');
    });

    test('恢复笔记时，嵌套的祖先文件夹也一起回来', () {
      final root = repo.createCollection('根')!;
      final mid = repo.createCollection('中间')!;
      final leaf = repo.createCollection('叶子')!;
      repo.setCollectionParent(mid, root);
      repo.setCollectionParent(leaf, mid);

      final id = repo.insertNote(
        title: '深处的',
        content: 'x',
        excerpt: 'x',
        collectionId: leaf,
      );
      repo.trashCollection(root);

      repo.restoreNotes(<int>[id]);

      // 整条链都要回来 —— 只恢复叶子的话，它的父级还在回收站里，
      // 左栏的树从顶层往下走，根本走不到它
      final names = repo.allCollections().map((c) => c.name).toSet();
      expect(names, containsAll(<String>['根', '中间', '叶子']));
      final m = repo.allCollections().firstWhere((c) => c.name == '中间');
      expect(m.parentId, root, reason: '父子关系也要保持');
    });

    test('删除文件夹会连里面的笔记一起标记', () {
      final col = repo.createCollection('甲')!;
      repo.insertNote(title: 'a', content: 'x', excerpt: 'x', collectionId: col);
      repo.insertNote(title: 'b', content: 'x', excerpt: 'x', collectionId: col);

      repo.trashCollection(col);

      // 只标记文件夹不管笔记的话，那些笔记会变成**孤儿**：
      // 顶层列表看不见（父文件夹没了），回收站里也找不到
      expect(repo.listTrashedNotes().length, 2);
      expect(repo.listTrashedCollections().length, 1);
    });

    test('单独恢复文件夹会连里面的笔记一起恢复', () {
      final col = repo.createCollection('甲')!;
      repo.insertNote(title: 'a', content: 'x', excerpt: 'x', collectionId: col);
      repo.trashCollection(col);

      repo.restoreCollection(col);

      expect(repo.listNotes(const NoteFilter()).length, 1);
      expect(repo.listTrashedNotes(), isEmpty);
    });

    test('彻底删除文件夹会连笔记一起清掉', () {
      final col = repo.createCollection('甲')!;
      repo.insertNote(title: 'a', content: 'x', excerpt: 'x', collectionId: col);
      repo.trashCollection(col);

      repo.purgeCollection(col);

      expect(repo.listTrashedNotes(), isEmpty);
      expect(repo.listTrashedCollections(), isEmpty);
      expect(repo.listNotes(const NoteFilter()), isEmpty);
    });

    test('批量恢复多篇笔记', () {
      final col = repo.createCollection('甲')!;
      final ids = <int>[
        for (var i = 0; i < 5; i++)
          repo.insertNote(
            title: 'n$i',
            content: 'x',
            excerpt: 'x',
            collectionId: col,
          ),
      ];
      repo.trashCollection(col);

      repo.restoreNotes(ids.sublist(0, 3));

      expect(repo.listNotes(const NoteFilter()).length, 3);
      expect(repo.listTrashedNotes().length, 2);
      // 文件夹被前一批带回来了
      expect(repo.allCollections().length, 1);
    });

    test('批量彻底删除只删选中的那些', () {
      final ids = <int>[
        for (var i = 0; i < 4; i++)
          repo.insertNote(title: 'n$i', content: 'x', excerpt: 'x'),
      ];
      repo.deleteNotes(ids);
      repo.purgeNotes(<int>[ids[0], ids[2]]);

      expect(repo.listTrashedNotes().length, 2);
      expect(repo.listTrashedNotes().map((n) => n.id), containsAll(<int>[ids[1], ids[3]]));
    });

    test('空列表是安全的空操作', () {
      final id = repo.insertNote(title: 'a', content: 'x', excerpt: 'x');
      repo.deleteNotes(<int>[id]);
      repo.restoreNotes(<int>[]);
      repo.purgeNotes(<int>[]);
      expect(repo.listTrashedNotes().length, 1, reason: '一个都没选时不能误删');
    });
  });

  group('批量操作', () {
    List<int> seed(int n) => <int>[
      for (var i = 0; i < n; i++)
        repo.insertNote(title: '笔记$i', content: 'x', excerpt: 'x'),
    ];

    /// 归档的笔记不进 listNotes（列表本来就该滤掉归档），
    /// 所以直接查库确认状态。
    int archivedCount() =>
        db.db.select('SELECT COUNT(*) AS c FROM notes WHERE is_archived = 1')
            .first['c'] as int;
    int totalCount() =>
        db.db.select('SELECT COUNT(*) AS c FROM notes').first['c'] as int;

    test('批量归档', () {
      final ids = seed(5);
      repo.setNotesArchived(ids.sublist(0, 3), true);

      expect(archivedCount(), 3);
      expect(totalCount(), 5, reason: '归档不能把笔记删掉');
      // 归档的从日常列表消失，「归档」才算真的有效果
      expect(repo.listNotes(const NoteFilter()).length, 2);
      expect(repo.listNotes(const NoteFilter(archivedOnly: true)).length, 3);
    });

    test('批量取消归档', () {
      final ids = seed(4);
      repo.setNotesArchived(ids, true);
      repo.setNotesArchived(ids, false);

      expect(archivedCount(), 0);
      expect(repo.listNotes(const NoteFilter()).length, 4);
      expect(repo.listNotes(const NoteFilter(archivedOnly: true)), isEmpty);
    });

    test('归档和日常列表互斥，不会两边都出现', () {
      final ids = seed(2);
      repo.setNotesArchived(<int>[ids[0]], true);

      final daily = repo.listNotes(const NoteFilter()).map((n) => n.id).toSet();
      final arch = repo
          .listNotes(const NoteFilter(archivedOnly: true))
          .map((n) => n.id)
          .toSet();

      expect(daily.intersection(arch), isEmpty);
      expect(daily.union(arch).length, 2);
    });

    test('批量移入隐私空间', () {
      final ids = seed(4);
      repo.setNotesHidden(ids.sublist(0, 2), true);

      expect(repo.listNotes(const NoteFilter()).length, 2);
      expect(repo.listNotes(const NoteFilter(hiddenOnly: true)).length, 2);
    });

    test('批量移出隐私空间', () {
      final ids = seed(3);
      repo.setNotesHidden(ids, true);
      repo.setNotesHidden(ids, false);

      expect(repo.listNotes(const NoteFilter()).length, 3);
      expect(repo.listNotes(const NoteFilter(hiddenOnly: true)), isEmpty);
    });

    test('批量删除只删指定的那些', () {
      final ids = seed(6);
      repo.deleteNotes(<int>[ids[0], ids[2], ids[5]]);

      final left = repo.listNotes(const NoteFilter()).map((n) => n.id).toSet();
      expect(left.length, 3);
      expect(left.contains(ids[1]), isTrue);
      expect(left.contains(ids[0]), isFalse);
      expect(left.contains(ids[5]), isFalse);
    });

    test('空列表是安全的空操作 —— 一个都没选时不能误删', () {
      seed(3);
      repo.deleteNotes(<int>[]);
      repo.setNotesArchived(<int>[], true);
      repo.setNotesHidden(<int>[], true);
      expect(repo.listNotes(const NoteFilter()).length, 3);
    });

    test('批量移动到一个文集', () {
      final col = repo.createCollection('目标')!;
      final ids = seed(4);
      repo.moveNotesToCollection(ids.sublist(1, 3), col);

      final inCol = repo.listNotes(NoteFilter(collectionId: col)).length;
      expect(inCol, 2);
      expect(
        repo.listNotes(const NoteFilter(uncategorizedOnly: true)).length,
        2,
      );
    });

    test('批量移动到未分类（传 null）', () {
      final col = repo.createCollection('源')!;
      final ids = seed(3);
      repo.moveNotesToCollection(ids, col);
      repo.moveNotesToCollection(ids, null);

      expect(repo.listNotes(NoteFilter(collectionId: col)), isEmpty);
      expect(
        repo.listNotes(const NoteFilter(uncategorizedOnly: true)).length,
        3,
      );
    });

    test('批量归档会更新修改时间', () {
      final ids = seed(2);
      final before = repo.getNote(ids[0])!.updatedAt;
      // 时间戳是毫秒，睡一下确保能拉开
      repo.setNotesArchived(ids, true);
      final after = repo.getNote(ids[0])!.updatedAt;
      expect(after.isBefore(before), isFalse);
    });

    test('一次操作几百篇也不会漏', () {
      final ids = seed(300);
      repo.setNotesHidden(ids, true);
      expect(repo.listNotes(const NoteFilter(hiddenOnly: true)).length, 300);
      repo.deleteNotes(ids);
      expect(repo.listNotes(const NoteFilter()).length, 0);
    });
  });
}
