/// 搜索的 LIKE 兜底**必须转义通配符**。
///
/// FTS5 的 trigram 分词器要求至少 3 个字符，所以 1-2 个字的查询会走
/// `title LIKE ?` 兜底。而 `%` 和 `_` 在 LIKE 里是通配符 ——
/// 不转义的话搜一个 `%` 会命中整库，搜 `a_b` 也会命中 `axb`。
/// 用户的感受是"搜什么都出一堆"，而且完全想不到是这两个字符的原因。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';

void main() {
  late AppDatabase db;
  late NoteRepository repo;

  setUp(() {
    db = AppDatabase.inMemory();
    repo = NoteRepository(db);
  });

  tearDown(() => db.close());

  int add(String title, [String excerpt = '']) => repo.insertNote(
    title: title,
    content: 'x' * 20,
    excerpt: excerpt.isEmpty ? '正文内容' : excerpt,
    charCount: 20,
    wordCount: 10,
  );

  /// 走的是 LIKE 兜底（FTS 要 3 个字符以上）。
  List<String> shortSearch(String q) =>
      repo.search(q).map((n) => n.title).toList();

  test('搜 % 只命中真的含 % 的，不是整库', () {
    add('进度 100% 了');
    add('完全无关的一篇');
    add('还有一篇');

    final hits = shortSearch('%');
    expect(hits, <String>['进度 100% 了'], reason: '% 被当成通配符了');
  });

  test('搜 _ 只命中真的含下划线的', () {
    add('文件名 a_b.txt');
    add('axb 这个不该被命中');

    final hits = shortSearch('_');
    expect(hits, <String>['文件名 a_b.txt'], reason: '_ 被当成单字符通配了');
  });

  test('下划线不会跨字符匹配', () {
    add('a_b');
    add('axb');
    add('ayb');
    expect(shortSearch('a_'), <String>['a_b']);
  });

  test('反斜杠本身也能被搜到（转义符自己要先转义）', () {
    add(r'路径 C:\temp');
    add('普通标题');
    expect(shortSearch(r'\'), <String>[r'路径 C:\temp']);
  });

  test('摘要里的匹配同样受转义保护', () {
    add('标题无关', '摘要里有 50% 这个数');
    expect(shortSearch('%'), <String>['标题无关']);
  });

  test('正常的短词照常能搜到（别把转义做过头）', () {
    add('今天天气不错');
    add('别的');
    expect(shortSearch('天气'), <String>['今天天气不错']);
  });
}
