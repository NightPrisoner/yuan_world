/// 核心逻辑测试。
///
/// 覆盖三块容易出错、且后续会反复改动的地方：
///   1. 中文文本统计（字符数 / 词数 / 摘要生成）
///   2. Markdown 正文分块解析
///   3. DOCX 元信息抽取与图片提取
///   4. SQLite 仓储层与 FTS5 中文全文检索
///
/// 运行：flutter test
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yuan_world/core/utils/text_stats.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/docx_importer.dart';
import 'package:yuan_world/data/models.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/data/repositories/todo_repository.dart';

void main() {
  // ── 文本统计 ────────────────────────────────────────────────────────────
  group('文本统计', () {
    test('countChars 不计空白字符', () {
      expect(countChars('你好 世界'), 4);
      expect(countChars('a b\nc\td'), 4);
      expect(countChars(''), 0);
      expect(countChars('标点，也要算。'), 7);
    });

    test('countWords 对中文逐字计数、英文按词计数', () {
      // 4 个汉字
      expect(countWords('你好世界'), 4);
      // 2 个汉字 + 1 个英文词
      expect(countWords('你好 world'), 3);
      // 英文按空格分词
      expect(countWords('hello world foo'), 3);
      // 中英混排：我/用 + Flutter + 开/发 + 应/用 = 7
      expect(countWords('我用 Flutter 开发 应用'), 7);
      // 连续标点不产生额外词
      expect(countWords('你好，，，世界'), 4);
    });

    test('makeExcerpt 去掉 Markdown 标记', () {
      const md = '# 标题\n\n这是**正文**内容，包含 ![图片](images/1.png) '
          '和 [链接](https://example.com)。';
      final e = makeExcerpt(md);
      expect(e.contains('#'), isFalse);
      expect(e.contains('**'), isFalse);
      expect(e.contains('!['), isFalse);
      expect(e.contains('图片'), isFalse); // 图片整段被移除
      expect(e.contains('正文'), isTrue);
      expect(e.contains('链接'), isTrue); // 链接保留文字
    });

    test('makeExcerpt 超长时截断并加省略号', () {
      final long = '啊' * 300;
      final e = makeExcerpt(long, maxLength: 50);
      expect(e.length, 51); // 50 + 省略号
      expect(e.endsWith('…'), isTrue);
    });
  });

  // ── 正文分块 ────────────────────────────────────────────────────────────
  group('正文分块解析', () {
    test('识别标题 / 段落 / 列表 / 引用 / 图片 / 分隔线', () {
      const md = '''
# 一级标题
## 二级标题

这是一段正文。

- 项目一
- 项目二

> 一段引用

![](images/1.png)

---
''';
      final blocks = parseContent(md);
      final types = blocks.map((b) => b.type).toList();

      expect(types.contains(ContentBlockType.heading), isTrue);
      expect(types.contains(ContentBlockType.paragraph), isTrue);
      expect(types.contains(ContentBlockType.bullet), isTrue);
      expect(types.contains(ContentBlockType.quote), isTrue);
      expect(types.contains(ContentBlockType.image), isTrue);
      expect(types.contains(ContentBlockType.divider), isTrue);

      final h1 = blocks.firstWhere((b) => b.type == ContentBlockType.heading);
      expect(h1.level, 1);
      expect(h1.text, '一级标题');

      final img = blocks.firstWhere((b) => b.type == ContentBlockType.image);
      expect(img.text, 'images/1.png');
    });

    test('任务列表去掉 Markdown 复选框并保留完成状态', () {
      final blocks = parseContent('- [ ] 未完成\n- [x] 已完成');
      expect(blocks, hasLength(2));
      expect(blocks[0].type, ContentBlockType.bullet);
      expect(blocks[0].isTodo, isTrue);
      expect(blocks[0].checked, isFalse);
      expect(blocks[0].text, '未完成');
      expect(blocks[1].isTodo, isTrue);
      expect(blocks[1].checked, isTrue);
      expect(blocks[1].text, '已完成');
    });

    test('有序列表保留原始序号，阅读态和编辑态不乱号', () {
      final blocks = parseContent('3. 第三步\n4. 第四步');
      expect(blocks.map((b) => b.listNumber), <int?>[3, 4]);
      expect(blocks.map((b) => b.text), <String>['第三步', '第四步']);
    });
  });

  // ── DOCX 解析 ───────────────────────────────────────────────────────────
  group('DOCX 解析', () {
    test('标题一律取**文件名**，不再从正文里猜', () {
      final docx = _buildDocx(
        paragraphs: <String>[
          '我喜欢B站，的同时也讨厌B站',
          '作者：梦之夜囚',
          '发布时间：编辑于 2023年09月10日 05:13',
          '文集：杂碎记',
          '来源：https://www.bilibili.com/read/cv26421497',
          '正文第一段。',
          '正文第二段。',
        ],
      );

      final doc = DocxImporter.parse(docx, fallbackTitle: '我的文章');

      expect(doc.title, '我的文章', reason: '标题就是文件名');
      // 文档头那几行**原样留在正文里** —— 不抽取、不剔除
      expect(doc.markdown.contains('作者：梦之夜囚'), isTrue);
      expect(doc.markdown.contains('文集：杂碎记'), isTrue);
      expect(doc.markdown.contains('来源：'), isTrue);
      expect(doc.markdown.contains('正文第一段。'), isTrue);
      // 以前会被当成标题的那一行，现在只是普通正文
      expect(doc.markdown.contains('我喜欢B站，的同时也讨厌B站'), isTrue);
    });

    test('没有文件名时给「未命名」，不会拿正文首行凑数', () {
      final docx = _buildDocx(
        paragraphs: <String>['作者：某人', '真正的标题', '正文。'],
      );
      final doc = DocxImporter.parse(docx);
      expect(doc.title, '未命名');
      // 全文都在正文里
      expect(doc.markdown, contains('作者：某人'));
      expect(doc.markdown, contains('真正的标题'));
    });

    test('文档头有没有都不影响解析', () {
      final withHeader = DocxImporter.parse(
        _buildDocx(
          paragraphs: <String>['作者：某人', '发布时间：编辑于 2023年09月10日 05:13', '正文。'],
        ),
        fallbackTitle: '甲',
      );
      final noHeader = DocxImporter.parse(
        _buildDocx(paragraphs: <String>['正文。']),
        fallbackTitle: '乙',
      );

      // 两种文档的**正文结构一致**：都只是把段落原样拼起来。
      // 这正是废除文档头依赖的目的 —— 有头没头不再产生两套结果。
      expect(withHeader.title, '甲');
      expect(noHeader.title, '乙');
      expect(noHeader.markdown.contains('正文。'), isTrue);
      expect(withHeader.markdown.contains('正文。'), isTrue);
    });

    test('图片被抽出并替换成占位路径', () {
      final docx = _buildDocx(
        paragraphs: <String>['标题', '看图：'],
        withImage: true,
      );
      final doc = DocxImporter.parse(docx);
      expect(doc.images.length, 1);
      expect(doc.images.first.placeholder, 'images/1.png');
      expect(doc.markdown.contains('![](images/1.png)'), isTrue);
    });

    test('非 docx 内容抛 FormatException', () {
      expect(
        () => DocxImporter.parse(Uint8List.fromList(utf8.encode('not a zip'))),
        throwsA(isA<Exception>()),
      );
    });
  });

  // ── 仓储层 + 全文检索 ───────────────────────────────────────────────────
  group('仓储层与 FTS5 检索', () {
    late AppDatabase db;
    late NoteRepository repo;

    setUp(() {
      db = AppDatabase.inMemory();
      repo = NoteRepository(db);
    });

    tearDown(() => db.close());

    test('插入并读回笔记', () {
      final id = repo.insertNote(
        title: '元世界',
        content: '这是一段正文',
        excerpt: '这是一段正文',
        charCount: 6,
        wordCount: 6,
      );
      final note = repo.getNote(id);
      expect(note, isNotNull);
      expect(note!.title, '元世界');
      expect(note.content, '这是一段正文');
    });

    test('trigram 分词支持中文子串检索', () {
      repo.insertNote(
        title: '元世界',
        content: '本地笔记与知识可视化',
        excerpt: '',
      );
      repo.insertNote(
        title: '另一个世界',
        content: '完全无关的内容',
        excerpt: '',
      );

      // 三字以上的中文子串——这是 unicode61 做不到的
      final hits = repo.search('知识可视');
      expect(hits.length, 1);
      expect(hits.first.title, '元世界');

      // 标题命中
      expect(repo.search('另一个').length, 1);

      // 无命中
      expect(repo.search('不存在的词').length, 0);
    });

    test('不足三字时回退到 LIKE', () {
      repo.insertNote(title: '火车', content: '圣地巡礼', excerpt: '');
      // trigram 最少要 3 个字符，短查询走 LIKE 分支
      expect(repo.search('火车').length, 1);
    });

    test('文集归类与计数', () {
      final cid = repo.ensureCollection('杂碎记');
      repo.insertNote(title: 'A', content: 'a', excerpt: '', collectionId: cid);
      repo.insertNote(title: 'B', content: 'b', excerpt: '', collectionId: cid);
      repo.insertNote(title: 'C', content: 'c', excerpt: '');

      final cols = repo.allCollections();
      expect(cols.length, 1);
      expect(cols.first.name, '杂碎记');
      expect(cols.first.noteCount, 2);

      final filtered = repo.listNotes(const NoteFilter(collectionId: null));
      expect(filtered.length, 3);

      final only = repo.listNotes(NoteFilter(collectionId: cols.first.id));
      expect(only.length, 2);
    });

    test('标签写入与统计', () {
      final id = repo.insertNote(
        title: '带标签',
        content: 'x',
        excerpt: '',
        tags: <String>['影评', '游戏'],
      );
      final note = repo.getNote(id);
      expect(note!.tags.toSet(), <String>{'影评', '游戏'});

      final tags = repo.allTags();
      expect(tags.length, 2);
      expect(tags.every((t) => t.count == 1), isTrue);
    });

    test('收藏与置顶影响排序', () {
      final a = repo.insertNote(title: 'A', content: 'a', excerpt: '');
      repo.insertNote(title: 'B', content: 'b', excerpt: '');
      repo.setPinned(a, true);

      final list = repo.listNotes(const NoteFilter());
      expect(list.first.title, 'A'); // 置顶排最前
    });

    test('overview 汇总正确', () {
      final cid = repo.ensureCollection('文集一');
      repo.insertNote(
        title: 'A',
        content: 'a',
        excerpt: '',
        collectionId: cid,
        charCount: 100,
        wordCount: 80,
        imageCount: 2,
      );
      repo.insertNote(
        title: 'B',
        content: 'b',
        excerpt: '',
        charCount: 50,
        wordCount: 40,
      );

      final o = repo.overview();
      expect(o.noteCount, 2);
      expect(o.totalChars, 150);
      expect(o.totalWords, 120);
      expect(o.imageCount, 2);
      expect(o.collectionCount, 1);
    });

    test('设置项读写', () {
      expect(repo.getSetting('themeMode'), isNull);
      repo.setSetting('themeMode', 'dark');
      expect(repo.getSetting('themeMode'), 'dark');
      repo.setSetting('themeMode', 'light');
      expect(repo.getSetting('themeMode'), 'light');
    });

    test('删除进回收站：数据留着，只是从列表消失', () {
      final id = repo.insertNote(
        title: '待删除',
        content: 'x',
        excerpt: '',
        tags: <String>['临时'],
      );
      // 图片是**磁盘上的文件**（`images/<id>/`），不是数据库里的行 ——
      // 以前这里往 note_images 那张死表里插一行来"代表图片"，
      // 而那张表从来没被任何代码用过，v9 已经删了。
      final mediaDir = Directory(p.join(db.imageRoot.path, '$id'))
        ..createSync(recursive: true);
      File(p.join(mediaDir.path, '1.png')).writeAsBytesSync(const <int>[1, 2, 3]);

      repo.deleteNote(id);

      // **软删除**：笔记还在，只是从普通列表里消失了。
      // 这是回收站能工作的前提 —— 真删掉就捞不回来了。
      expect(repo.getNote(id), isNotNull, reason: '删进回收站不等于抹掉');
      expect(repo.listNotes(const NoteFilter()), isEmpty, reason: '列表里不该再出现');
      expect(repo.listTrashedNotes().length, 1);
      // 图片文件也还在：回收站里的笔记还原之后图还得能显示
      expect(mediaDir.existsSync(), isTrue, reason: '软删除不能碰磁盘上的图');
      // 标签关联也要留着，否则恢复之后标签就没了
      final joins =
          db.db.select('SELECT * FROM note_tags WHERE note_id = ?', <Object?>[id]);
      expect(joins.length, 1);
    });

    test('彻底删除才真的清掉图片与标签关联', () {
      final id = repo.insertNote(
        title: '待清空',
        content: 'x',
        excerpt: '',
        tags: <String>['临时'],
      );
      final mediaDir = Directory(p.join(db.imageRoot.path, '$id'))
        ..createSync(recursive: true);
      File(p.join(mediaDir.path, '1.png')).writeAsBytesSync(const <int>[1, 2, 3]);

      repo.deleteNote(id);
      repo.purgeNotes(<int>[id]);

      expect(repo.getNote(id), isNull);
      expect(mediaDir.existsSync(), isFalse, reason: '彻底删除要连图一起清掉');
      final joins =
          db.db.select('SELECT * FROM note_tags WHERE note_id = ?', <Object?>[id]);
      expect(joins.length, 0);
      expect(repo.allTags().length, 0); // 没有引用了所以统计为 0
    });

    test('从回收站恢复之后，笔记和标签都回来', () {
      final id = repo.insertNote(
        title: '误删的',
        content: 'x',
        excerpt: '',
        tags: <String>['重要'],
      );
      repo.deleteNote(id);
      expect(repo.listNotes(const NoteFilter()), isEmpty);

      repo.restoreNotes(<int>[id]);

      final back = repo.listNotes(const NoteFilter());
      expect(back.length, 1);
      expect(back.single.tags, contains('重要'));
    });
  });

  // ── 待办清单 ────────────────────────────────────────────────────────────
  group('待办清单', () {
    late AppDatabase db;
    late TodoRepository todos;

    setUp(() {
      db = AppDatabase.inMemory();
      todos = TodoRepository(db);
    });

    tearDown(() => db.close());

    test('添加并读回', () {
      final id = todos.add('写周报');
      final list = todos.allTodos();
      expect(list.length, 1);
      expect(list.first.id, id);
      expect(list.first.content, '写周报');
      expect(list.first.isDone, isFalse);
    });

    test('勾选后沉到列表末尾', () {
      todos.add('第一件');
      final second = todos.add('第二件');
      todos.add('第三件');

      // 初始顺序 = 添加顺序
      expect(todos.allTodos().map((t) => t.content).toList(),
          <String>['第一件', '第二件', '第三件']);

      todos.setDone(second, true);

      // 未完成在前，已完成在后
      final after = todos.allTodos();
      expect(after.last.content, '第二件');
      expect(after.last.isDone, isTrue);
      expect(after.length, 3);
    });

    test('取消勾选后回到未完成区', () {
      final id = todos.add('来回切换');
      todos.setDone(id, true);
      expect(todos.allTodos().first.isDone, isTrue);

      todos.setDone(id, false);
      final t = todos.allTodos().first;
      expect(t.isDone, isFalse);
      expect(t.doneAt, isNull);
    });

    test('counts 统计未完成 / 已完成 / 逾期', () {
      final a = todos.add('会逾期', dueAt: DateTime.now().subtract(const Duration(days: 1)));
      todos.add('正常');
      final c = todos.add('已完成');
      todos.setDone(c, true);

      final n = todos.counts();
      expect(n.open, 2);
      expect(n.done, 1);
      expect(n.overdue, 1);

      // 把逾期那条完成掉，逾期数应归零
      todos.setDone(a, true);
      expect(todos.counts().overdue, 0);
    });

    test('拖拽排序按传入顺序落库', () {
      final a = todos.add('A');
      final b = todos.add('B');
      final c = todos.add('C');

      expect(todos.allTodos().map((t) => t.content).toList(),
          <String>['A', 'B', 'C']);

      final list = todos.allTodos();
      // C, A, B
      todos.reorder(<int>[c, a, b]);
      final after = todos.allTodos();
      expect(after.map((t) => t.content).toList(), <String>['C', 'A', 'B']);
      expect(list.length, 3);
    });

    test('清空已完成只删已完成项', () {
      todos.add('保留');
      final d1 = todos.add('完成一');
      final d2 = todos.add('完成二');
      todos.setDone(d1, true);
      todos.setDone(d2, true);

      final removed = todos.clearCompleted();
      expect(removed, 2);
      expect(todos.allTodos().length, 1);
      expect(todos.allTodos().first.content, '保留');
    });

    test('截止时间的展示文案', () {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);

      final t1 = Todo.fromRow(<String, Object?>{
        'id': 1,
        'content': 'x',
        'is_done': 0,
        'due_at': today.millisecondsSinceEpoch,
        'priority': 0,
        'sort_index': 0,
        'created_at': now.millisecondsSinceEpoch,
        'updated_at': now.millisecondsSinceEpoch,
      });
      expect(t1.dueLabel, '今天');
      expect(t1.isDueToday, isTrue);
      expect(t1.isOverdue, isFalse);

      final t2 = Todo.fromRow(<String, Object?>{
        'id': 2,
        'content': 'y',
        'is_done': 0,
        'due_at': today.add(const Duration(days: 1)).millisecondsSinceEpoch,
        'priority': 0,
        'sort_index': 0,
        'created_at': now.millisecondsSinceEpoch,
        'updated_at': now.millisecondsSinceEpoch,
      });
      expect(t2.dueLabel, '明天');

      final t3 = Todo.fromRow(<String, Object?>{
        'id': 3,
        'content': 'z',
        'is_done': 0,
        'due_at': today.subtract(const Duration(days: 2)).millisecondsSinceEpoch,
        'priority': 0,
        'sort_index': 0,
        'created_at': now.millisecondsSinceEpoch,
        'updated_at': now.millisecondsSinceEpoch,
      });
      expect(t3.isOverdue, isTrue);
    });

    test('修改内容与优先级', () {
      final id = todos.add('原始');
      todos.setContent(id, '改过了');
      todos.setPriority(id, 3);
      final t = todos.allTodos().first;
      expect(t.content, '改过了');
      expect(t.priority, 3);
    });
  });

  // ── 文集（文件夹）管理 ──────────────────────────────────────────────────
  group('文集管理', () {
    late AppDatabase db;
    late NoteRepository repo;

    setUp(() {
      db = AppDatabase.inMemory();
      repo = NoteRepository(db);
    });

    tearDown(() => db.close());

    test('新建文集', () {
      final id = repo.createCollection('读书笔记', color: 0xFF34C759);
      expect(id, isNotNull);
      final list = repo.allCollections();
      expect(list.length, 1);
      expect(list.first.name, '读书笔记');
      expect(list.first.color, 0xFF34C759);
    });

    test('重名不会创建第二份', () {
      expect(repo.createCollection('重复名'), isNotNull);
      expect(repo.createCollection('重复名'), isNull);
      expect(repo.allCollections().length, 1);
    });

    test('空名字不会创建', () {
      expect(repo.createCollection('   '), isNull);
      expect(repo.allCollections(), isEmpty);
    });

    test('重命名', () {
      final id = repo.createCollection('旧名字')!;
      expect(repo.renameCollection(id, '新名字'), isTrue);
      expect(repo.allCollections().first.name, '新名字');
    });

    test('重命名撞到已有名字会被拒绝', () {
      repo.createCollection('甲');
      final b = repo.createCollection('乙')!;
      expect(repo.renameCollection(b, '甲'), isFalse);
      // 名字保持原样
      expect(
        repo.allCollections().map((c) => c.name).toSet(),
        <String>{'甲', '乙'},
      );
    });

    test('改颜色', () {
      final id = repo.createCollection('彩色')!;
      repo.setCollectionColor(id, 0xFFFF2D55);
      expect(repo.allCollections().first.color, 0xFFFF2D55);
    });

    test('删除文集不会删掉里面的笔记，而是移出到未分类', () {
      final id = repo.createCollection('会被删掉')!;
      repo.insertNote(title: 'A', content: 'a', excerpt: '', collectionId: id);
      repo.insertNote(title: 'B', content: 'b', excerpt: '', collectionId: id);
      repo.insertNote(title: 'C', content: 'c', excerpt: '');

      final moved = repo.deleteCollection(id);

      expect(moved, 2);
      expect(repo.allCollections(), isEmpty);
      // 笔记都还在，只是不再属于任何文集
      final all = repo.listNotes(const NoteFilter());
      expect(all.length, 3);
      expect(all.every((n) => n.collectionId == null), isTrue);

      // 「未分类」筛选能查到它们
      final uncategorized =
          repo.listNotes(const NoteFilter(uncategorizedOnly: true));
      expect(uncategorized.length, 3);
    });

    test('把笔记移动到另一个文集', () {
      final a = repo.createCollection('甲')!;
      final b = repo.createCollection('乙')!;
      final noteId =
          repo.insertNote(title: 'X', content: 'x', excerpt: '', collectionId: a);

      repo.moveNoteToCollection(noteId, b);
      expect(repo.getNote(noteId)!.collectionId, b);

      // 移出到未分类
      repo.moveNoteToCollection(noteId, null);
      expect(repo.getNote(noteId)!.collectionId, isNull);
    });

    test('批量移动', () {
      final a = repo.createCollection('甲')!;
      final b = repo.createCollection('乙')!;
      final n1 = repo.insertNote(title: '1', content: '', excerpt: '', collectionId: a);
      final n2 = repo.insertNote(title: '2', content: '', excerpt: '', collectionId: a);

      repo.moveNotesToCollection(<int>[n1, n2], b);
      expect(repo.getNote(n1)!.collectionId, b);
      expect(repo.getNote(n2)!.collectionId, b);
    });

    test('拖拽排序按传入顺序落库', () {
      final a = repo.createCollection('A')!;
      final b = repo.createCollection('B')!;
      final c = repo.createCollection('C')!;

      repo.reorderCollections(<int>[c, a, b]);
      expect(
        repo.allCollections().map((x) => x.name).toList(),
        <String>['C', 'A', 'B'],
      );
    });

    test('ensureCollection 幂等，重复调用返回同一个 id', () {
      final first = repo.ensureCollection('导入时自动建');
      final second = repo.ensureCollection('导入时自动建');
      expect(first, second);
      expect(repo.allCollections().length, 1);
    });
  });
}

// ── 测试辅助：在内存里拼一个最小的合法 docx ──────────────────────────────

/// 构造一个可被 [DocxImporter] 解析的最小 docx。
///
/// 结构参照真实的 Word 文档：
///   [Content_Types].xml
///   word/document.xml          正文与图片引用
///   word/_rels/document.xml.rels   rId → media 映射
///   word/media/image1.png      可选图片
Uint8List _buildDocx({
  required List<String> paragraphs,
  bool withImage = false,
}) {
  final rels = StringBuffer()
    ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
    ..writeln('<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">');
  if (withImage) {
    rels.writeln(
      '<Relationship Id="rId9" '
      'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" '
      'Target="media/image1.png"/>',
    );
  }
  rels.writeln('</Relationships>');

  final body = StringBuffer();
  for (final text in paragraphs) {
    body.writeln('<w:p><w:r><w:t xml:space="preserve">${_esc(text)}</w:t></w:r></w:p>');
  }
  if (withImage) {
    body.writeln(
      '<w:p><w:r><w:drawing>'
      '<a:blip r:embed="rId9"/>'
      '</w:drawing></w:r></w:p>',
    );
  }

  final document = '<?xml version="1.0" encoding="UTF-8"?>'
      '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" '
      'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" '
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
      '<w:body>$body</w:body></w:document>';

  final contentTypes = '<?xml version="1.0" encoding="UTF-8"?>'
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
      '<Default Extension="xml" ContentType="application/xml"/>'
      '<Default Extension="png" ContentType="image/png"/>'
      '</Types>';

  // 1x1 透明 PNG，用于占位
  final png = Uint8List.fromList(<int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
  ]);

  final archive = Archive()
    ..addFile(ArchiveFile.string('[Content_Types].xml', contentTypes))
    ..addFile(ArchiveFile.string('word/document.xml', document))
    ..addFile(ArchiveFile.string('word/_rels/document.xml.rels', rels.toString()));
  if (withImage) {
    archive.addFile(ArchiveFile.bytes('word/media/image1.png', png));
  }

  return ZipEncoder().encodeBytes(archive);
}

String _esc(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');
