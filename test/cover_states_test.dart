/// 头图的**三种状态**必须分得开：
///   1. 没设过 / 空串 —— 按正文第一张图自动派生
///   2. 指定了一张    —— 就用那张
///   3. 明确"不设置"  —— 谁都别再自作主张补上
///
/// 抓到的两个真 bug：
///   - 按钮写「移除头图（回到默认：正文第一张图）」，做的却是"彻底不要"
///     （写空串）—— 文字和行为对不上，想做第 1 件事的人会得到第 3 件
///   - 空串被自动派生逻辑当成"没设过"，于是点了"不设置头图"之后
///     **只要再编辑一下正文触发自动保存，头图就自己回来了**
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/models.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';

void main() {
  late AppDatabase db;
  late NoteRepository repo;

  setUp(() {
    db = AppDatabase.inMemory();
    repo = NoteRepository(db);
  });

  tearDown(() => db.close());

  /// 正文里带一张图的笔记。
  int addWithImage() => repo.insertNote(
    title: '带图的',
    // 图片路径要真的能变出头图：insertNote 会从正文派生
    content: '前言\n\n![](7/a.png)\n',
    excerpt: '前言',
    charCount: 10,
    wordCount: 5,
    imageCount: 1,
  );

  group('effectiveCover', () {
    test('三种取值分别对应"没有 / 指定 / 没有"', () {
      expect(effectiveCover(null), isNull);
      expect(effectiveCover(''), isNull);
      expect(effectiveCover(kCoverNone), isNull, reason: '明确不要也是没有');
      expect(effectiveCover('7/a.png'), '7/a.png');
    });

    test('只有 kCoverNone 算"明确不要"', () {
      expect(isCoverDisabled(kCoverNone), isTrue);
      expect(isCoverDisabled(''), isFalse);
      expect(isCoverDisabled(null), isFalse);
      expect(isCoverDisabled('7/a.png'), isFalse);
    });
  });

  test('新建时按正文第一张图自动派生（默认行为不变）', () {
    final id = addWithImage();
    expect(repo.getNote(id)!.coverImage, '7/a.png');
  });

  test('选了「不设置头图」之后，编辑正文也不会把图补回来', () {
    final id = addWithImage();

    // 用户点了"不设置头图"
    repo.updateNote(id: id, coverImage: kCoverNone);
    expect(repo.getNote(id)!.coverImage, kCoverNone);
    expect(effectiveCover(repo.getNote(id)!.coverImage), isNull);

    // 然后随便改一下正文（编辑器自动保存走的就是这条路径）
    repo.updateNote(id: id, content: '前言改了一下\n\n![](7/a.png)\n');
    expect(
      repo.getNote(id)!.coverImage,
      kCoverNone,
      reason: '自动派生把"不要头图"覆盖掉了 —— 用户看到的是头图又冒出来',
    );
  });

  test('「恢复默认」之后，编辑正文能重新派生出第一张图', () {
    final id = addWithImage();
    repo.updateNote(id: id, coverImage: kCoverNone);
    // 用户改主意，点了"恢复默认（用正文第一张图）"
    repo.updateNote(id: id, coverImage: '');
    expect(repo.getNote(id)!.coverImage, '');

    repo.updateNote(id: id, content: '又改了一下\n\n![](7/a.png)\n');
    expect(
      repo.getNote(id)!.coverImage,
      '7/a.png',
      reason: '恢复默认之后应该能重新自动派生',
    );
  });

  test('手动指定的头图不会被自动派生覆盖', () {
    final id = addWithImage();
    repo.updateNote(id: id, coverImage: '9/manual.png');
    repo.updateNote(id: id, content: '改一下\n\n![](7/a.png)\n');
    expect(repo.getNote(id)!.coverImage, '9/manual.png');
    expect(effectiveCover(repo.getNote(id)!.coverImage), '9/manual.png');
  });
}
