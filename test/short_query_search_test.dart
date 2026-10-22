import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/data/search_grams.dart';

void main() {
  group('分段切分：汉字逐字、拉丁整词', () {
    test('中文每个字一个 token', () {
      expect(searchTokens('读书'), <String>['读', '书']);
    });

    test('拉丁字母和数字连成整词，不拆成单字母', () {
      // 拆开的话搜 "ai" 会把所有含 a 和 i 的笔记都捞出来，全是噪声
      expect(searchTokens('AI绘画2026'), <String>['AI', '绘', '画', '2026']);
    });

    test('标点、空白、符号都不进 token', () {
      expect(searchTokens('读，书 · 笔记！'), <String>['读', '书', '笔', '记']);
    });

    test('空串与纯标点切不出 token', () {
      expect(searchTokens(''), isEmpty);
      expect(searchTokens('，。！？——'), isEmpty);
    });

    test('searchSegments 用单空格连接', () {
      expect(searchSegments('读书记'), '读 书 记');
    });
  });

  group('查询短语', () {
    test('两字词拼成相邻短语', () {
      expect(searchPhrase('读书'), '"读 书"');
    });

    test('只有一个字也是合法短语', () {
      expect(searchPhrase('书'), '"书"');
    });

    test('切不出 token 时返回 null（不能拿空串去 MATCH）', () {
      expect(searchPhrase('，。'), isNull);
      expect(searchPhrase('   '), isNull);
    });

    test('needsSegmentIndex 按字符数判断三字以下', () {
      expect(needsSegmentIndex('读'), isTrue);
      expect(needsSegmentIndex('读书'), isTrue);
      expect(needsSegmentIndex('读书笔记'), isFalse);
      // 按 rune 算而不是 UTF-16 长度：一个 emoji 是 1 个字符，
      // 三个 emoji 就是 3 个字符 —— 走 trigram 分支。
      // （顺带记一笔：emoji 在两套索引里都切不出 token，搜不到，
      //   这是已知限制，这里只钉住字符数口径。）
      expect(needsSegmentIndex('📚📚📚'), isFalse);
      expect(needsSegmentIndex('📚📚'), isTrue);
    });
  });

  group('短词检索真的走索引并对齐子串语义', () {
    late AppDatabase db;
    late NoteRepository repo;

    setUp(() {
      db = AppDatabase.inMemory();
      repo = NoteRepository(db);
    });

    tearDown(() => db.close());

    int add(String title, String content) => repo.insertNote(
      title: title,
      content: content,
      excerpt: content,
    );

    test('单字能搜到正文里的字', () {
      final id = add('随便', '今天读了一本书');
      expect(repo.listNotes(const NoteFilter(query: '书')).map((n) => n.id), <int>[id]);
    });

    test('两字相邻能命中', () {
      final id = add('随便', '今天读书');
      expect(repo.listNotes(const NoteFilter(query: '读书')).map((n) => n.id), <int>[id]);
    });

    test('两字不相邻不命中（子串语义，不是"都出现过"）', () {
      add('随便', '读了一本好书');
      // "读"和"书"都在，但不是"读书"两个字
      expect(repo.listNotes(const NoteFilter(query: '读书')), isEmpty);
    });

    test('顺序反了不命中', () {
      add('随便', '书读完了');
      expect(repo.listNotes(const NoteFilter(query: '读书')), isEmpty);
    });

    test('标题里的短词也能搜到', () {
      final id = add('读书笔记', '正文不含那个词');
      expect(repo.listNotes(const NoteFilter(query: '读书')).map((n) => n.id), <int>[id]);
    });

    test('拉丁短词按整词匹配', () {
      final ai = add('AI绘画', '用 AI 生成的图');
      add('别的', 'raining in the city');
      // "ai" 不该命中 raining 里的 "ai"
      expect(repo.listNotes(const NoteFilter(query: 'ai')).map((n) => n.id), <int>[ai]);
    });

    test('改正文后索引跟着变', () {
      final id = add('标题', '原来有读书两个字');
      expect(repo.listNotes(const NoteFilter(query: '读书')).map((n) => n.id), <int>[id]);
      repo.updateNote(id: id, content: '现在没有了');
      expect(repo.listNotes(const NoteFilter(query: '读书')), isEmpty);
      expect(repo.listNotes(const NoteFilter(query: '没有')).map((n) => n.id), <int>[id]);
    });

    test('改标题后索引跟着变', () {
      final id = add('旧标题', '正文');
      repo.updateNote(id: id, title: '读书');
      expect(repo.listNotes(const NoteFilter(query: '读书')).map((n) => n.id), <int>[id]);
    });

    test('删掉后不再命中', () {
      final id = add('标题', '读书');
      repo.deleteNote(id);
      expect(repo.listNotes(const NoteFilter(query: '读书')), isEmpty);
    });

    test('归档的不进普通列表，但归档列表里能搜到', () {
      final id = add('标题', '读书');
      repo.setArchived(id, true);
      expect(repo.listNotes(const NoteFilter(query: '读书')), isEmpty);
      expect(
        repo.listNotes(const NoteFilter(query: '读书', archivedOnly: true)).map((n) => n.id),
        <int>[id],
      );
    });

    test('三字以上仍然走 trigram，一条不漏', () {
      final id = add('标题', '图书馆里读书');
      expect(repo.listNotes(const NoteFilter(query: '图书馆')).map((n) => n.id), <int>[id]);
      // 三字子串跨在分段边界上也要能命中（trigram 和分段索引是两套，
      // 这里确认走前者的那条路径没被改坏）
      expect(repo.listNotes(const NoteFilter(query: '馆里读')).map((n) => n.id), <int>[id]);
    });

    test('countNotes 与列表同口径（短词也一致）', () {
      add('一', '读书');
      add('二', '读书写字');
      add('三', '无关');
      expect(repo.countNotes(const NoteFilter(query: '读书')), 2);
      expect(repo.listNotes(const NoteFilter(query: '读书')).length, 2);
    });

    test('纯标点的查询退化成 LIKE 兜底，不抛 fts5 语法错误', () {
      final id = add('标题', '这里有，。这个符号');
      // 标点切不出 token → 走 LIKE；能搜到真的含有它的那篇
      expect(repo.listNotes(const NoteFilter(query: '，。')).map((n) => n.id), <int>[id]);
      expect(repo.countNotes(const NoteFilter(query: '，。')), 1);
      // 搜一个库里没有的符号 → 空结果，不崩
      expect(repo.listNotes(const NoteFilter(query: '【】')), isEmpty);
    });
  });

  group('老库升级会回填分段索引', () {
    test('v10 老库里的笔记升级后能被短词搜到', () {
      final tmp = Directory.systemTemp.createTempSync('yw_seg_');
      addTearDown(() => tmp.deleteSync(recursive: true));

      // 先正常建库、写一篇笔记，然后把索引清空、版本号调回 10，
      // 模拟"这篇笔记是在 v10 时代存的，那时还没有分段索引"。
      final first = AppDatabase.openAt(tmp.path);
      NoteRepository(first).insertNote(
        title: '老笔记',
        content: '正文里写了读书两个字',
        excerpt: '正文里写了读书两个字',
      );
      first.db.execute('DELETE FROM note_segments');
      first.db.execute('PRAGMA user_version = 10');
      first.close();

      // 重新打开 → _migrate 跑 v11 → 回填存量笔记
      final upgraded = AppDatabase.openAt(tmp.path);
      addTearDown(upgraded.close);
      final repo = NoteRepository(upgraded);

      final hits = repo.listNotes(const NoteFilter(query: '读书'));
      expect(hits, hasLength(1), reason: '升级时应当把存量笔记回填进分段索引');
      expect(hits.single.title, '老笔记');

      // 回填之后触发器也要正常工作（升级路径里触发器是 IF NOT EXISTS 建的）
      repo.insertNote(title: '新笔记', content: '也是读书', excerpt: '也是读书');
      expect(repo.listNotes(const NoteFilter(query: '读书')), hasLength(2));
    });
  });
}
