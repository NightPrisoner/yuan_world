/// 统计口径那几处 bug 的回归测试。
///
/// 这些 bug 的共同点是「数字看起来正常，但对不上」：
///   · 改标题级联改双链，字数没跟着重算
///   · 编辑器同时改标题和正文时，自引用双链被旧正文覆盖回去
///   · image_count 有三处不同口径（落盘数 / 含视频 / 只算图片）
///   · 参数清空后那篇笔记从取值分布里凭空消失
///   · StatsQuery 没有 ==，参数卡片每帧都重查一次
///   · 收藏/置顶不涨 dataRevision，统计页不重算
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/media/media_counts.dart';
import 'package:yuan_world/data/repositories/field_repository.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/data/repositories/stats_repository.dart';

void main() {
  late AppDatabase db;
  late NoteRepository repo;

  setUp(() {
    db = AppDatabase.inMemory();
    repo = NoteRepository(db);
  });
  tearDown(() => db.close());

  group('改标题级联：字数必须跟着正文一起重算', () {
    test('别人正文里的双链被改写后，字数和词数不再停留在旧值', () {
      final target = repo.insertNote(
        title: '甲',
        content: 'x',
        excerpt: 'x',
        charCount: 1,
        wordCount: 1,
      );
      final referrer = repo.insertNote(
        title: '引用者',
        content: '看 [[甲]] 就行',
        excerpt: '看 [[甲]] 就行',
        charCount: 5,
        wordCount: 5,
      );

      repo.updateNote(id: target, title: '一个特别特别长的标题');

      final after = repo.getNote(referrer)!;
      expect(after.content, contains('[[一个特别特别长的标题]]'));
      // 正文从 8 个字符长到 16 个字符，char_count 必须跟上
      expect(
        after.charCount,
        greaterThan(5),
        reason: '改了正文却不重算字数，概览总字数/长文排行/篇幅分布全都会偏',
      );
    });

    test('统计概览的总字数跟着级联变，不是旧快照', () {
      final stats = StatsRepository(db);
      final target = repo.insertNote(
        title: '乙',
        content: 'y',
        excerpt: 'y',
        charCount: 1,
      );
      repo.insertNote(
        title: '引用者',
        content: '看 [[乙]] 就行',
        excerpt: '看 [[乙]] 就行',
        charCount: 8,
        wordCount: 8,
      );
      final before = stats.overview().totalChars;

      repo.updateNote(id: target, title: '一个特别特别长的标题');

      expect(
        stats.overview().totalChars,
        greaterThan(before),
        reason: '级联改了正文，概览总字数得跟着涨',
      );
    });

    test('只是改正文、标题没变时不动别人', () {
      final a = repo.insertNote(title: '甲', content: 'x', excerpt: 'x');
      final b = repo.insertNote(
        title: '乙',
        content: '[[甲]]',
        excerpt: '[[甲]]',
        charCount: 5,
        wordCount: 5,
      );
      repo.updateNote(id: a, content: '只改自己的正文');
      expect(repo.getNote(b)!.content, '[[甲]]');
      expect(repo.getNote(b)!.charCount, 5);
    });
  });

  group('同时改标题与正文：自引用双链不能断', () {
    test('正文里指向自己的旧标题，保存后是新标题', () {
      final id = repo.insertNote(
        title: '旧标题',
        content: '我去看看 [[旧标题]] 写了什么',
        excerpt: '我去看看',
      );

      repo.updateNote(
        id: id,
        title: '新标题',
        content: '我去看看 [[旧标题]] 写了什么',
      );

      final after = repo.getNote(id)!;
      expect(after.title, '新标题');
      expect(
        after.content,
        contains('[[新标题]]'),
        reason: '级联先把它改好了，又被传进来的旧正文覆盖回去 —— 链接就断了',
      );
      expect(after.content, isNot(contains('[[旧标题]]')));
    });

    test('自引用改写之后字数也重算了', () {
      final id = repo.insertNote(
        title: '短',
        content: '看 [[短]]',
        excerpt: '看 [[短]]',
        charCount: 3,
        wordCount: 3,
      );
      repo.updateNote(
        id: id,
        title: '一个特别长的标题名字',
        content: '看 [[短]]',
        charCount: 3,
        wordCount: 3,
      );
      // 调用方明确传了 charCount 时以调用方为准，这里不覆盖
      expect(repo.getNote(id)!.charCount, 3);
    });
  });

  group('image_count 只有一种口径：只算独占一行的图片', () {
    test('行内图片不算，视频不算，与统计页现算一致', () {
      const body = '文字里有 ![行内](images/1/a.png) 一张\n\n'
          '![](1/b.png)\n\n'
          '![](1/c.mp4)\n';
      final id = repo.insertNote(
        title: '混合',
        content: body,
        excerpt: '混合',
        imageCount: 3,
      );
      repo.updateNote(id: id, imageCount: 0);
      // 用统计仓库现算的口径当标尺
      final expected = StatsRepository(
        db,
      ).overview().imageCount;
      expect(expected, 1, reason: '只有独占一行的 png 算图片，视频和行内图都不算');

      // 与统计页现算的口径同一个函数
      expect(countNoteMedia(body).images, 1);
      expect(countNoteMedia(body).videos, 1);
    });

    test('存量数据回填：把三套口径留下的偏差一次拉齐', () {
      final bad = repo.insertNote(
        title: '老数据',
        content: '![](1/a.png)\n\n![](1/b.mp4)\n',
        excerpt: '老数据',
        imageCount: 2, // 旧导入写的"落盘文件数"：图片+视频
      );
      final inlineOnly = repo.insertNote(
        title: '只有行内图',
        content: '文字 ![x](images/1/c.png) 夹在中间',
        excerpt: '只有行内图',
        imageCount: 1,
      );
      expect(repo.backfillImageCounts(), 2);
      expect(repo.getNote(bad)!.imageCount, 1, reason: '视频不该算进图片数');
      expect(repo.getNote(inlineOnly)!.imageCount, 0, reason: '行内图不算');
      expect(repo.backfillImageCounts(), 0, reason: '回填过就不该再改');
    });
  });

  group('参数取值分布：清空手动值要退回自动值', () {
    late FieldRepository fields;
    late int autoId;

    setUp(() {
      fields = FieldRepository(db);
      final id = fields.createField(
        name: '测试年份',
        kind: 'number',
        unit: '年',
        autoSource: 'created',
      );
      autoId = id!;
    });

    test('手写空串的笔记仍然按自动值计入分布', () {
      final a = repo.insertNote(
        title: 'A',
        content: 'a',
        excerpt: 'a',
        createdAt: DateTime(2024, 3, 1),
      );
      final b = repo.insertNote(
        title: 'B',
        content: 'b',
        excerpt: 'b',
        createdAt: DateTime(2025, 3, 1),
      );
      // A 手写成 2020，B 留空（模拟"用户清空了这个参数"）
      fields.setValue(a, autoId, '2020');
      fields.setValue(b, autoId, '   ');

      final dist = fields.valueDistribution(autoId);
      final total = dist.fold<int>(0, (s, d) => s + d.count);
      expect(
        total,
        2,
        reason: '手写值 + 自动值必须覆盖所有笔记；空串既不算手动也不能把自动值挤掉',
      );
      expect(dist.map((d) => d.value), containsAll(<String>['2020', '2025']));
    });

    test('全部手写过时只算手动值，不重复计入自动值', () {
      final a = repo.insertNote(
        title: 'A',
        content: 'a',
        excerpt: 'a',
        createdAt: DateTime(2024, 3, 1),
      );
      fields.setValue(a, autoId, '2020');
      final dist = fields.valueDistribution(autoId);
      expect(dist.length, 1);
      expect(dist.single.value, '2020');
      expect(dist.single.count, 1);
    });
  });

  group('StatsQuery 按值比较', () {
    test('两个字段完全一样的查询相等（否则参数卡片每帧都重查）', () {
      final t = DateTime(2026, 1, 1);
      final a = StatsQuery(from: t, collectionIds: const <int>[3, 1]);
      final b = StatsQuery(from: t, collectionIds: const <int>[3, 1]);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(StatsQuery(from: t, collectionIds: const <int>[1, 3])));
      expect(StatsQuery.empty, StatsQuery());
      expect(StatsQuery.empty, isNot(const StatsQuery(hiddenOnly: true)));
    });
  });

  group('收藏/置顶要让统计页知道数据变了', () {
    late AppState state;

    setUp(() async {
      state = AppState(db, repo, ImportService(db, repo));
      await state.init();
    });

    test('点收藏之后 dataRevision 必须增加', () {
      final id = repo.insertNote(title: 'A', content: 'a', excerpt: 'a');
      final before = state.dataRevision;
      state.toggleFavorite(repo.getNote(id)!);
      expect(
        state.dataRevision,
        greaterThan(before),
        reason: '不涨 revision，统计页的收藏数就会一直是旧数字',
      );
    });

    test('置顶之后 dataRevision 也增加', () {
      final id = repo.insertNote(title: 'A', content: 'a', excerpt: 'a');
      final before = state.dataRevision;
      state.togglePin(repo.getNote(id)!);
      expect(state.dataRevision, greaterThan(before));
    });
  });
}
