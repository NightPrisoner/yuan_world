/// 头图（封面）的测试。
///
/// 规则：**默认取正文里的第一张图**。用户不用特意去设，写了图自然就有头图；
/// 但手动选过的不能被自动逻辑覆盖掉。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/core/utils/text_stats.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';

void main() {
  group('从正文取第一张图', () {
    test('取第一张，忽略后面的', () {
      expect(
        firstImageOf('前言\n\n![](1/a.png)\n\n后面还有 ![](1/b.png)'),
        '1/a.png',
      );
    });

    test('剥掉导入阶段遗留的 images/ 前缀', () {
      expect(firstImageOf('![](images/45/1.png)'), '45/1.png');
    });

    test('没有图片返回 null', () {
      expect(firstImageOf('纯文字，没有图'), isNull);
      expect(firstImageOf(''), isNull);
    });

    test('外链图片不算头图', () {
      // 网络图不能当本地封面用，取它只会得到一个裂图
      expect(firstImageOf('![](https://example.com/a.png)'), isNull);
    });

    test('空路径不算', () {
      expect(firstImageOf('![]()'), isNull);
    });
  });

  group('写入时自动派生', () {
    late AppDatabase db;
    late NoteRepository repo;

    setUp(() {
      db = AppDatabase.inMemory();
      repo = NoteRepository(db);
    });

    tearDown(() => db.close());

    test('新建时没给头图，就用正文第一张图', () {
      final id = repo.insertNote(
        title: 't',
        content: '正文\n\n![](9/1.png)',
        excerpt: '',
        imageCount: 1,
      );
      expect(repo.getNote(id)!.coverImage, '9/1.png');
    });

    test('正文没图就不设头图', () {
      final id = repo.insertNote(title: 't', content: '纯文字', excerpt: '');
      expect(repo.getNote(id)!.coverImage, isNull);
    });

    test('改正文会自动补上头图', () {
      final id = repo.insertNote(title: 't', content: '还没图', excerpt: '');
      expect(repo.getNote(id)!.coverImage, isNull);

      repo.updateNote(id: id, content: '加了图\n\n![](3/x.png)');
      expect(repo.getNote(id)!.coverImage, '3/x.png');
    });

    test('手动选过的头图不会被自动逻辑覆盖', () {
      // 这是最容易写错的地方：每次自动保存都重算的话，
      // 用户精心挑的头图会被正文第一张图顶掉
      final id = repo.insertNote(
        title: 't',
        content: '![](1/first.png)',
        excerpt: '',
        coverImage: '1/manual.png',
      );
      expect(repo.getNote(id)!.coverImage, '1/manual.png');

      repo.updateNote(id: id, content: '![](1/first.png)\n\n又写了点东西');
      expect(repo.getNote(id)!.coverImage, '1/manual.png',
          reason: '自动保存不能把手动选的头图改掉');
    });

    test('显式传空字符串可以清掉头图', () {
      final id = repo.insertNote(
        title: 't',
        content: '![](1/a.png)',
        excerpt: '',
        coverImage: '1/a.png',
      );
      repo.updateNote(id: id, coverImage: '');
      expect(repo.getNote(id)!.coverImage, '');
    });
  });

  group('存量数据补齐', () {
    late AppDatabase db;
    late NoteRepository repo;

    setUp(() {
      db = AppDatabase.inMemory();
      repo = NoteRepository(db);
    });

    tearDown(() => db.close());

    test('给有图但没头图的老笔记补上头图', () {
      final id = repo.insertNote(
        title: '老笔记',
        content: '![](7/old.png)',
        excerpt: '',
        imageCount: 1,
      );
      // 模拟老数据：直接清掉头图
      db.db.execute('UPDATE notes SET cover_image = NULL WHERE id = ?', <Object?>[id]);

      expect(repo.backfillCovers(), 1);
      expect(repo.getNote(id)!.coverImage, '7/old.png');
    });

    test('没有图片的笔记不会被碰', () {
      final id = repo.insertNote(title: '纯文字', content: 'x', excerpt: '');
      expect(repo.backfillCovers(), 0);
      expect(repo.getNote(id)!.coverImage, isNull);
    });

    test('已经有头图的不会被覆盖', () {
      final id = repo.insertNote(
        title: 't',
        content: '![](1/a.png)',
        excerpt: '',
        imageCount: 1,
        coverImage: '1/picked.png',
      );
      repo.backfillCovers();
      expect(repo.getNote(id)!.coverImage, '1/picked.png');
    });

    test('重复跑是幂等的', () {
      final id = repo.insertNote(
        title: 't',
        content: '![](1/a.png)',
        excerpt: '',
        imageCount: 1,
      );
      db.db.execute('UPDATE notes SET cover_image = NULL WHERE id = ?', <Object?>[id]);

      expect(repo.backfillCovers(), 1);
      expect(repo.backfillCovers(), 0, reason: '第二次没有需要补的了');
      expect(repo.getNote(id)!.coverImage, '1/a.png');
    });
  });
}
