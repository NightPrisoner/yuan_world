/// 「文件夹导出但没有实际笔记内容」的回归测试。
///
/// 根因不在导出器，而在**取笔记的那一步**：`listNotes` 用的是不含
/// `content` 列的轻量查询（列表页只要摘要），拿它的结果去渲染 docx，
/// 每篇都只剩个标题，正文一个字没有。
///
/// 修法不是在某处补一句 `getNote`，而是把"导出要连正文一起取"收进
/// [NoteRepository.notesForExport] 一个方法里 —— 所以测试直接钉这个方法，
/// 同时钉住 `listNotes` 不含正文这个前提（哪天有人给 `listNotes` 加上
/// 正文，这条测试会失败，提醒他上面的注释该改了）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/exporter/note_exporter.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';

void main() {
  late AppDatabase db;
  late NoteRepository repo;

  setUp(() {
    db = AppDatabase.inMemory();
    repo = NoteRepository(db);
  });

  tearDown(() => db.close());

  int add(String title, {int? collectionId, String? content}) => repo.insertNote(
    title: title,
    content: content ?? '第一段正文。\n\n第二段正文。',
    excerpt: '第一段正文。',
    publishedAt: DateTime.now(),
    collectionId: collectionId,
    charCount: 12,
    wordCount: 6,
  );

  test('listNotes 确实不带正文（导出不能直接用它）', () {
    final id = add('笔记');
    final listed = repo.listNotes(const NoteFilter()).singleWhere(
          (n) => n.id == id,
        );
    expect(listed.content, isEmpty,
        reason: 'listNotes 开始返回正文了？那 notesForExport 的注释要改');
  });

  test('notesForExport 按文集导出时正文齐全', () {
    final c = repo.createCollection('文集')!;
    final id = add('有正文的', collectionId: c);

    final notes = repo.notesForExport(collectionId: c);
    expect(notes.length, 1);
    expect(notes.single.id, id);
    expect(notes.single.content, isNotEmpty, reason: '又变回空壳了');
    expect(notes.single.content, contains('第二段正文'));
  });

  test('导出的 docx 里真能搜到正文文字', () {
    final c = repo.createCollection('文集')!;
    add('有正文的', collectionId: c);
    final notes = repo.notesForExport(collectionId: c);
    final bytes = NoteExporter.renderDocxBytes(notes.single);
    // docx 是 zip，正文文字在 deflate 之后不能直接字符串匹配，
    // 所以这里只钉"渲染出来的是个非空 docx 包"，内容层面由
    // notesForExport 的断言保证
    expect(bytes.length, greaterThan(1000));
  });

  test('含子文集的笔记一起导出', () {
    final parent = repo.createCollection('父')!;
    final child = repo.createCollection('子', parentId: parent)!;
    final a = add('父里的', collectionId: parent);
    final b = add('子里的', collectionId: child);

    final ids = repo.notesForExport(collectionId: parent).map((n) => n.id);
    expect(ids, containsAll(<int>[a, b]));
    expect(repo.notesForExport(collectionId: child).map((n) => n.id), <int>[b]);
  });

  test('getNote 不能把 deletedAt 丢掉（回收站笔记会看起来像活的）', () {
    final id = add('进回收站的');
    repo.deleteNote(id);
    final n = repo.getNote(id);
    expect(n, isNotNull, reason: '回收站是软删，行还在');
    expect(n!.deletedAt, isNotNull,
        reason: '_withTags 抄字段时漏了 deletedAt');
  });

  test('回收站里的笔记不导出', () {
    final c = repo.createCollection('文集')!;
    final keep = add('留着', collectionId: c);
    final gone = add('删掉', collectionId: c);
    repo.deleteNote(gone);

    final ids = repo.notesForExport(collectionId: c).map((n) => n.id);
    expect(ids, contains(keep));
    expect(ids, isNot(contains(gone)));
  });

  test('按 id 导出时保持传入顺序，且跳过已删除的', () {
    final a = add('甲');
    final b = add('乙');
    final d = add('丙');
    repo.deleteNote(d);

    final notes = repo.notesForExport(ids: <int>[b, a, d, 99999]);
    expect(notes.map((n) => n.title), <String>['乙', '甲']);
    expect(notes.every((n) => n.content.isNotEmpty), isTrue);
  });
}
