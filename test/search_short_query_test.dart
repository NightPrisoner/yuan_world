/// 短关键词（1~2 个字）必须能搜到**正文**。
///
/// FTS5 的 trigram 分词器要求至少 3 个字符，所以两字词只能走 LIKE ——
/// 而以前那条 LIKE 只覆盖标题和摘要。中文里两字词恰恰最常见
/// （"读书""会议""旅行"），用户的感受就是"明明正文里有，却搜不到"。
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

  int add(String title, String content, {String? excerpt}) => repo.insertNote(
    title: title,
    content: content,
    excerpt: excerpt ?? '摘要里什么都没有',
    publishedAt: DateTime.now(),
  );

  List<String> search(String q) => repo
      .listNotes(NoteFilter(query: q))
      .map((n) => n.title)
      .toList();

  group('两字词', () {
    test('命中正文里的词', () {
      add('无关的标题', '今天去图书馆读书，读了一下午。');
      expect(search('读书'), <String>['无关的标题']);
    });

    test('标题/摘要命中仍然可以', () {
      add('读书笔记', '正文里没有那两个字');
      expect(search('读书'), <String>['读书笔记']);
    });

    test('搜不到的词就是空的（不会因为扫正文而"什么都出一堆"）', () {
      add('甲', '正文内容');
      expect(search('乙丙'), isEmpty);
    });

    test('一个字的词也能搜正文', () {
      add('标题', '这里有猫');
      expect(search('猫'), <String>['标题']);
    });
  });

  group('三字以上走 FTS，行为不变', () {
    test('命中正文里的中文子串', () {
      add('标题', '这是一篇关于知识管理的长文');
      expect(search('知识管理'), <String>['标题']);
    });

    test('搜不存在的长词返回空', () {
      add('标题', '随便写点什么');
      expect(search('量子力学'), isEmpty);
    });
  });

  group('通配符仍然被转义（否则搜 % 会把整库拉出来）', () {
    test('百分号不是通配符', () {
      add('甲', '普通的正文');
      add('乙', '含有 50% 折扣的正文');
      expect(search('50%'), <String>['乙']);
    });

    test('下划线不是单字通配', () {
      add('甲', 'axb 这种');
      add('乙', 'a_b 这种');
      expect(search('a_b'), <String>['乙']);
    });
  });
}
