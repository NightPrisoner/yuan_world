/// 隐私空间 + 文件夹嵌套的测试。
///
/// 这两块的共同风险是「漏」：隐藏的东西但凡有一个入口没过滤掉，
/// 就等于没藏住；嵌套但凡有一处没算上子文件夹，数字就是错的。
/// 所以这里重点测「到处都看不到」和「子文件夹是否被算进去」。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/repositories/field_repository.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/data/repositories/stats_repository.dart';
import 'package:yuan_world/features/privacy/privacy_page.dart';

void main() {
  late AppDatabase db;
  late NoteRepository repo;
  late StatsRepository stats;
  late FieldRepository fields;

  setUp(() {
    db = AppDatabase.inMemory();
    repo = NoteRepository(db);
    stats = StatsRepository(db);
    fields = FieldRepository(db);
  });

  tearDown(() => db.close());

  int add(String title, {int chars = 100, int? collectionId, List<String> tags = const []}) =>
      repo.insertNote(
        title: title,
        content: 'x' * chars,
        excerpt: title,
        collectionId: collectionId,
        charCount: chars,
        tags: tags,
      );

  // ── 隐私空间 ────────────────────────────────────────────────────────────

  group('隐私空间', () {
    test('隐藏的笔记在列表、搜索、统计里全都看不到', () {
      final secret = add('秘密笔记');
      add('公开笔记');

      repo.setNoteHidden(secret, true);

      expect(repo.listNotes(const NoteFilter()).length, 1);
      expect(repo.listNotes(const NoteFilter()).first.title, '公开笔记');

      // 搜索
      expect(repo.search('秘密'), isEmpty);

      // 统计：概览、排行、词频、热力图
      expect(repo.overview().noteCount, 1);
      expect(repo.overview().totalChars, 100);
      expect(repo.topNotesByLength().length, 1);
      expect(stats.trend().fold<int>(0, (s, p) => s + p.notes), 1);
      // 「秘密」只出现在被藏起来那篇里，它不该出现在词频中
      expect(
        stats.keywords(minCount: 1).map((k) => k.word),
        isNot(contains('秘密')),
      );
      expect(stats.dailyDensity().values.fold<int>(0, (s, v) => s + v), 1);
    });

    test('隐藏的笔记在隐私空间里能看到', () {
      final secret = add('秘密笔记');
      add('公开笔记');
      repo.setNoteHidden(secret, true);

      final hidden = repo.listNotes(const NoteFilter(hiddenOnly: true));
      expect(hidden.length, 1);
      expect(hidden.first.title, '秘密笔记');
      expect(hidden.first.isHidden, isTrue);
    });

    test('移出后立刻恢复可见', () {
      final id = add('来回横跳');
      repo.setNoteHidden(id, true);
      expect(repo.listNotes(const NoteFilter()), isEmpty);

      repo.setNoteHidden(id, false);
      expect(repo.listNotes(const NoteFilter()).length, 1);
      expect(repo.overview().noteCount, 1);
    });

    test('隐藏文件夹会把子文件夹和里面的笔记一起藏起来', () {
      final parent = repo.createCollection('私密父级')!;
      final child = repo.createCollection('私密子级')!;
      repo.setCollectionParent(child, parent);
      add('父级里的', collectionId: parent);
      add('子级里的', collectionId: child);
      add('外面的');

      repo.setCollectionHidden(parent, true);

      // 左栏看不到
      expect(repo.allCollections().map((c) => c.name), <String>[]);
      // 笔记列表也看不到
      expect(repo.listNotes(const NoteFilter()).length, 1);
      expect(repo.listNotes(const NoteFilter()).first.title, '外面的');
      // 统计也跟着排除
      expect(repo.overview().noteCount, 1);
      // 隐私空间里两个文件夹都在
      expect(repo.hiddenCounts().collections, 2);
      expect(repo.hiddenCounts().notes, 2);
    });

    test('移出文件夹后子文件夹和笔记一并恢复', () {
      final parent = repo.createCollection('父')!;
      final child = repo.createCollection('子')!;
      repo.setCollectionParent(child, parent);
      add('a', collectionId: parent);
      add('b', collectionId: child);

      repo.setCollectionHidden(parent, true);
      expect(repo.listNotes(const NoteFilter()), isEmpty);

      repo.setCollectionHidden(parent, false);
      expect(repo.allCollections().length, 2);
      expect(repo.listNotes(const NoteFilter()).length, 2);
    });

    test('标签与词频也会排除隐藏内容', () {
      final secret = add('深夜秘密', tags: <String>['私密']);
      add('深夜公开', tags: <String>['公开']);

      expect(repo.allTags().map((t) => t.name), contains('私密'));
      repo.setNoteHidden(secret, true);
      expect(repo.allTags().map((t) => t.name), isNot(contains('私密')));

      final words = stats.keywords(minCount: 1).map((k) => k.word).toSet();
      expect(words, contains('深夜'), reason: '公开那篇还有');
      expect(stats.tagFrequency().map((t) => t.name), isNot(contains('私密')));
    });
  });

  // ── 密码 ────────────────────────────────────────────────────────────────

  group('隐私密码', () {
    test('口令不进明文', () {
      final h = hashPassword('123456');
      expect(h.contains('123456'), isFalse, reason: '绝不能存明文');
      expect(h, startsWith('pbkdf2\$'));
    });

    test('同样的口令两次散列**不同**（加了随机盐）', () {
      // 老实现（FNV-1a）是确定性的，翻一眼数据库就能看出
      // "这两个地方设的是同一个密码"。加盐之后看不出来了。
      expect(
        hashPassword('123456') == hashPassword('123456'),
        isFalse,
        reason: '没有盐就等于告诉别人哪些密码是一样的',
      );
    });

    test('口令不同散列不同，且都能各自验过', () {
      final a = hashPassword('123456');
      final b = hashPassword('123457');
      expect(a == b, isFalse);
      expect(verifySecret('123456', a).ok, isTrue);
      expect(verifySecret('123457', a).ok, isFalse);
    });

    test('前缀相同的口令不会互相验过', () {
      final h = hashPassword('abc');
      expect(verifySecret('abcd', h).ok, isFalse);
      expect(verifySecret('ab', h).ok, isFalse);
      expect(verifySecret('abc', h).ok, isTrue);
    });
  });

  // ── 嵌套 ────────────────────────────────────────────────────────────────

  group('文件夹嵌套', () {
    test('子文件夹的笔记数会累加到父文件夹上', () {
      final parent = repo.createCollection('父')!;
      final child = repo.createCollection('子')!;
      repo.setCollectionParent(child, parent);
      add('a', collectionId: parent);
      add('b', collectionId: child);
      add('c', collectionId: child);

      final all = repo.allCollections();
      expect(all.firstWhere((c) => c.id == parent).noteCount, 3,
          reason: '父文件夹要显示 3，不能只算自己那 1 篇');
      expect(all.firstWhere((c) => c.id == child).noteCount, 2);
    });

    test('选中父文件夹时列表包含子文件夹里的笔记', () {
      final parent = repo.createCollection('父')!;
      final child = repo.createCollection('子')!;
      repo.setCollectionParent(child, parent);
      add('父里的', collectionId: parent);
      add('子里的', collectionId: child);
      add('外面的');

      final under = repo.listNotes(NoteFilter(collectionId: parent));
      expect(under.map((n) => n.title).toSet(), <String>{'父里的', '子里的'});

      // 也可以只要本级
      final direct =
          repo.listNotes(NoteFilter(collectionId: parent, includeDescendants: false));
      expect(direct.map((n) => n.title).toList(), <String>['父里的']);
    });

    test('descendantCollectionIds 递归取全后代', () {
      final a = repo.createCollection('A')!;
      final b = repo.createCollection('B')!;
      final c = repo.createCollection('C')!;
      repo.setCollectionParent(b, a);
      repo.setCollectionParent(c, b);

      expect(repo.descendantCollectionIds(a).toSet(), <int>{b, c});
      expect(repo.descendantCollectionIds(c), isEmpty);
    });

    test('不允许把文件夹挂到自己的后代里', () {
      final a = repo.createCollection('A')!;
      final b = repo.createCollection('B')!;
      repo.setCollectionParent(b, a);

      expect(repo.setCollectionParent(a, b), isFalse);
      expect(repo.setCollectionParent(a, a), isFalse);
      // 结构没被破坏
      expect(repo.allCollections().firstWhere((c) => c.id == b).parentId, a);
    });

    test('collectionPath 给出从根到目标的路径', () {
      final a = repo.createCollection('A')!;
      final b = repo.createCollection('B')!;
      repo.setCollectionParent(b, a);

      expect(repo.collectionPath(b).map((c) => c.name).toList(), <String>['A', 'B']);
    });

    test('新建的文件夹排在置顶之下、其它非置顶之上', () {
      repo.createCollection('甲');
      repo.createCollection('乙');
      final bing = repo.createCollection('丙')!;

      // 新建的出现在最上面（置顶之下第一个位置），而不是追加到末尾
      expect(
        repo.allCollections().map((c) => c.name).toList(),
        <String>['丙', '乙', '甲'],
      );

      repo.setCollectionPinned(bing, true);
      expect(
        repo.allCollections().map((c) => c.name).toList(),
        <String>['丙', '乙', '甲'],
        reason: '置顶本来就排最前，位置不该反而变差',
      );
    });

    test('置顶状态会被读出来', () {
      final id = repo.createCollection('钉住的')!;
      repo.setCollectionPinned(id, true);
      expect(repo.allCollections().first.isPinned, isTrue);
      expect(repo.allCollections().firstWhere((c) => c.id == id).name, '钉住的');
    });

    test('后置顶的把先置顶的顶下去', () {
      final a = repo.createCollection('A')!;
      final b = repo.createCollection('B')!;

      repo.setCollectionPinned(a, true);
      expect(repo.allCollections().first.name, 'A');

      // 再置顶 B —— 它要压在 A 上面
      repo.setCollectionPinned(b, true);
      expect(
        repo.allCollections().take(2).map((c) => c.name).toList(),
        <String>['B', 'A'],
        reason: '最新置顶的排最上面，依次类推',
      );

      final c2 = repo.createCollection('C')!;
      repo.setCollectionPinned(c2, true);
      expect(
        repo.allCollections().take(3).map((c) => c.name).toList(),
        <String>['C', 'B', 'A'],
      );
    });

    test('新建的文件夹排在置顶之下、其它非置顶之上', () {
      final pinned = repo.createCollection('钉住的')!;
      repo.setCollectionPinned(pinned, true);
      repo.createCollection('旧的甲');
      repo.createCollection('旧的乙');

      repo.createCollection('刚建的');

      final names = repo.allCollections().map((c) => c.name).toList();
      expect(names.first, '钉住的', reason: '置顶永远在最前');
      expect(names[1], '刚建的', reason: '新的是"置顶之下的第一个位置"');
    });

    test('取消置顶后不再是置顶', () {
      final a = repo.createCollection('A')!;
      repo.setCollectionPinned(a, true);
      repo.setCollectionPinned(a, false);
      expect(repo.allCollections().first.isPinned, isFalse);
    });

    test('新建的文件夹默认不置顶', () {
      repo.createCollection('新的');
      expect(repo.allCollections().first.isPinned, isFalse);
    });

    test('删除父文件夹时子文件夹上浮，不会一起没掉', () {
      final a = repo.createCollection('A')!;
      final b = repo.createCollection('B')!;
      repo.setCollectionParent(b, a);
      add('B 里的', collectionId: b);

      repo.deleteCollection(a);

      final rest = repo.allCollections();
      expect(rest.length, 1);
      expect(rest.first.name, 'B');
      expect(rest.first.parentId, isNull, reason: '子文件夹应该上浮到顶层');
      // 笔记没被删
      expect(repo.listNotes(const NoteFilter()).length, 1);
    });
  });

  // ── 拖拽排序 / 改层级 ───────────────────────────────────────────────────

  group('文件夹拖拽', () {
    test('落在行的上边缘 = 同级排到前面', () {
      final a = repo.createCollection('甲')!;
      final b = repo.createCollection('乙')!;
      final c = repo.createCollection('丙')!;

      // 把「丙」拖到「甲」前面。
      // 初始顺序是「丙, 乙, 甲」（后建的在前），所以丙插到甲前面之后
      // 落在乙和甲之间。
      repo.moveCollection(c, a, asChild: false);

      expect(
        repo.allCollections().map((x) => x.name).toList(),
        <String>['乙', '丙', '甲'],
      );
      expect(repo.allCollections().every((x) => x.parentId == null), isTrue);
      expect(b, isNotNull);
    });

    test('落在行的下边缘 = 同级排到后面', () {
      final a = repo.createCollection('甲')!;
      final b = repo.createCollection('乙')!;
      final c = repo.createCollection('丙')!;

      // 把「甲」拖到「丙」后面。初始「丙, 乙, 甲」→ 甲跟着丙走
      repo.moveCollection(a, c, asChild: false, after: true);

      expect(
        repo.allCollections().map((x) => x.name).toList(),
        <String>['丙', '甲', '乙'],
      );
      expect(b, isNotNull);
    });

    test('落在行的中间 = 变成子文件夹', () {
      final a = repo.createCollection('甲')!;
      final b = repo.createCollection('乙')!;

      repo.moveCollection(b, a, asChild: true);

      expect(repo.allCollections().firstWhere((x) => x.id == b).parentId, a);
    });

    test('把嵌套的文件夹拖到顶层文件夹前面，会升到顶层而不是变成子级', () {
      // 这条正是「置顶不起作用」那个 bug：
      // 之前拖到别的文件夹上一律变成子文件夹，所以永远排不上去。
      final top = repo.createCollection('顶层')!;
      final parent = repo.createCollection('父')!;
      final deep = repo.createCollection('深藏的')!;
      repo.setCollectionParent(deep, parent);

      // 拖到「顶层」的上边缘
      repo.moveCollection(deep, top, asChild: false);

      final after = repo.allCollections();
      final moved = after.firstWhere((x) => x.id == deep);
      expect(moved.parentId, isNull, reason: '应该升到顶层');
      expect(
        after.map((x) => x.name).toList(),
        <String>['父', '深藏的', '顶层'],
        reason: '并且排在顶层那个的前面',
      );
    });

    test('同一层里重排不会影响其它层级的顺序', () {
      final a = repo.createCollection('A')!;
      final b = repo.createCollection('B')!;
      final child1 = repo.createCollection('c1')!;
      final child2 = repo.createCollection('c2')!;
      repo.setCollectionParent(child1, a);
      repo.setCollectionParent(child2, a);

      // 在 A 的子层里把 c2 挪到 c1 前面
      repo.moveCollection(child2, child1, asChild: false);

      final all = repo.allCollections();
      expect(
        repo.childCollections(a).map((x) => x.name).toList(),
        <String>['c2', 'c1'],
      );
      // B 仍是顶层且存在
      expect(all.firstWhere((x) => x.id == b).parentId, isNull);
    });

    test('不能拖进自己的后代（防成环）', () {
      final a = repo.createCollection('A')!;
      final b = repo.createCollection('B')!;
      repo.setCollectionParent(b, a);

      repo.moveCollection(a, b, asChild: true);
      // 结构没被破坏
      expect(repo.allCollections().firstWhere((x) => x.id == b).parentId, a);
      expect(repo.allCollections().firstWhere((x) => x.id == a).parentId, isNull);
    });

    test('拖到自己身上是空操作', () {
      final a = repo.createCollection('A')!;
      repo.moveCollection(a, a, asChild: true);
      expect(repo.allCollections().length, 1);
      expect(repo.allCollections().first.parentId, isNull);
    });

    test('moveCollectionToTopLevel 会升到顶层并排到最后', () {
      final top = repo.createCollection('顶层')!;
      final parent = repo.createCollection('父')!;
      final deep = repo.createCollection('深的')!;
      repo.setCollectionParent(deep, parent);

      repo.moveCollectionToTopLevel(deep);

      final all = repo.allCollections();
      expect(all.firstWhere((x) => x.id == deep).parentId, isNull);
      // 「拖到此处移到顶层」那个投放区在列表**末尾**，
      // 所以落进去就是排到最后，和投放区的视觉位置一致。
      expect(all.map((x) => x.name).toList(), <String>['父', '顶层', '深的']);
      expect(top, isNotNull);
    });

    test('先"移到顶层"再排到某个子文件夹后面：落在它的同级，不会再陷进去', () {
      // 用户报的现象：「移到顶层后再放到子文件夹后会出现这个bug」。
      // 拖到某个子文件夹**后面**，落点应该是那一层的同级（跟它平级），
      // 而不是继续往下钻一层 —— 层级错了，行缩进就会和旁边的对不齐。
      final top = repo.createCollection('顶层')!;
      final sub = repo.createCollection('子')!;
      repo.setCollectionParent(sub, top);
      final moving = repo.createCollection('搬家的')!;
      repo.setCollectionParent(moving, sub); // 原本嵌在子文件夹里

      repo.moveCollectionToTopLevel(moving);
      expect(
        repo.allCollections().firstWhere((x) => x.id == moving).parentId,
        isNull,
        reason: '第一步要真的升到顶层',
      );

      repo.moveCollection(moving, sub, asChild: false, after: true);

      expect(
        repo.allCollections().firstWhere((x) => x.id == moving).parentId,
        top,
        reason: '第二步是「子的同级」，不是变成「子」的子文件夹',
      );
      expect(
        repo.childCollections(top).map((x) => x.name).toList(),
        <String>['子', '搬家的'],
      );
    });
  });

  // ── 统计筛选 ────────────────────────────────────────────────────────────

  group('统计筛选', () {
    test('按文件夹统计时包含子文件夹', () {
      final parent = repo.createCollection('父')!;
      final child = repo.createCollection('子')!;
      repo.setCollectionParent(child, parent);
      add('p', collectionId: parent, chars: 100);
      add('c', collectionId: child, chars: 300);
      add('other', chars: 999);

      final t = stats.trend(query: StatsQuery(collectionId: parent));
      expect(t.fold<int>(0, (s, p) => s + p.notes), 2);
      expect(t.fold<int>(0, (s, p) => s + p.chars), 400);
    });

    test('自定义起止日期会排除范围外的笔记', () {
      final now = DateTime.now();
      add('范围内', chars: 10);
      repo.insertNote(
        title: '很久以前',
        content: 'x',
        excerpt: 'x',
        charCount: 10,
        publishedAt: DateTime(now.year - 5, 1, 1),
      );

      final t = stats.trend(
        query: StatsQuery(from: DateTime(now.year, now.month - 1, 1)),
      );
      expect(t.fold<int>(0, (s, p) => s + p.notes), 1);
    });

    test('结束日期包含当天全天', () {
      final now = DateTime.now();
      final day = DateTime(now.year, now.month, 5);
      repo.insertNote(
        title: '5 号晚上写的',
        content: 'x',
        excerpt: 'x',
        charCount: 10,
        publishedAt: DateTime(day.year, day.month, 5, 23, 30),
      );
      repo.insertNote(
        title: '6 号写的',
        content: 'x',
        excerpt: 'x',
        charCount: 10,
        publishedAt: DateTime(day.year, day.month, 6, 9, 0),
      );

      final t = stats.trend(
        query: StatsQuery(
          from: DateTime(day.year, day.month, 1),
          to: DateTime(day.year, day.month, 5),
        ),
      );
      expect(t.fold<int>(0, (s, p) => s + p.notes), 1,
          reason: '选到 5 号就应该包含 5 号 23:30 那篇');
    });

    test('文件夹对比会给出各个顶层文件夹的产出', () {
      final a = repo.createCollection('甲')!;
      final b = repo.createCollection('乙')!;
      add('a1', collectionId: a, chars: 100);
      add('a2', collectionId: a, chars: 300);
      add('b1', collectionId: b, chars: 50);
      add('无归属');

      final cmp = stats.compareCollections();
      final byName = {for (final x in cmp) x.name: x};

      expect(byName['甲']!.notes, 2);
      expect(byName['甲']!.chars, 400);
      expect(byName['甲']!.avgChars, 200);
      expect(byName['乙']!.notes, 1);
      expect(byName['未分类']!.notes, 1);
      // 按篇数倒序
      expect(cmp.first.name, '甲');
    });

    test('统计也做数据隔离：隐私空间只看隐藏内容', () {
      add('公开的', chars: 100);
      final secret = add('藏起来的', chars: 900);
      repo.setNoteHidden(secret, true);

      // 普通空间
      final normal = stats.trend(query: const StatsQuery());
      expect(normal.fold<int>(0, (s, p) => s + p.notes), 1);
      expect(normal.fold<int>(0, (s, p) => s + p.chars), 100);

      // 隐私空间：换成只看隐藏内容，而不是变成一片空白
      final priv = stats.trend(query: const StatsQuery(hiddenOnly: true));
      expect(priv.fold<int>(0, (s, p) => s + p.notes), 1);
      expect(priv.fold<int>(0, (s, p) => s + p.chars), 900,
          reason: '隐私空间统计的应该是藏起来那批，不是外面的');
    });

    test('概览在隐私空间里只数隐藏内容', () {
      add('公开的', chars: 100);
      final secret = add('藏起来的', chars: 900);
      repo.setNoteHidden(secret, true);

      expect(repo.overview().noteCount, 1);
      expect(repo.overview().totalChars, 100);

      expect(repo.overview(hiddenOnly: true).noteCount, 1);
      expect(repo.overview(hiddenOnly: true).totalChars, 900);
    });

    test('文集分布与文件夹对比也跟着隔离', () {
      final visible = repo.createCollection('公开集')!;
      final hidden = repo.createCollection('私密集')!;
      add('a', collectionId: visible);
      final s = add('b', collectionId: hidden);
      repo.setNoteHidden(hidden, true);
      repo.setCollectionHidden(hidden, true);
      repo.setNoteHidden(s, true);

      final normal = stats.collectionShare(query: const StatsQuery());
      expect(normal.map((x) => x.name), contains('公开集'));
      expect(normal.map((x) => x.name), isNot(contains('私密集')));

      final priv =
          stats.collectionShare(query: const StatsQuery(hiddenOnly: true));
      expect(priv.map((x) => x.name), contains('私密集'));
      expect(priv.map((x) => x.name), isNot(contains('公开集')));

      final cmp =
          stats.compareCollections(query: const StatsQuery(hiddenOnly: true));
      expect(cmp.map((x) => x.name), contains('私密集'));
      expect(cmp.map((x) => x.name), isNot(contains('公开集')));
    });

    test('参数统计也隔离', () {
      final id = fields.createField(name: '心情')!;
      final a = add('公开的');
      final b = add('藏起来的');
      fields.setValue(a, id, '公开值');
      fields.setValue(b, id, '隐藏值');
      repo.setNoteHidden(b, true);

      final normal = fields.valueDistribution(id);
      expect(normal.map((x) => x.value), contains('公开值'));
      expect(normal.map((x) => x.value), isNot(contains('隐藏值')));

      final priv = fields.valueDistribution(id, hiddenOnly: true);
      expect(priv.map((x) => x.value), contains('隐藏值'));
      expect(priv.map((x) => x.value), isNot(contains('公开值')));
    });

    test('文件夹对比不含隐私空间的内容', () {
      final a = repo.createCollection('甲')!;
      add('公开', collectionId: a);
      final secret = add('私密', collectionId: a);

      repo.setNoteHidden(secret, true);
      final cmp = stats.compareCollections();
      expect(cmp.firstWhere((x) => x.name == '甲').notes, 1);
    });
  });
}
