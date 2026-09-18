/// 热力图时间窗口、篇幅分布坐标轴、选择器收纳。
///
/// 这三件事都是"用户明确要的旋钮"，所以每条都盯住两件事：
/// 旋钮在不在、拧了到底有没有效果。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/data/repositories/stats_repository.dart';
import 'package:yuan_world/features/stats/stats_charts.dart';
import 'package:yuan_world/features/stats/stats_page.dart';

void main() {
  group('热力图窗口', () {
    final now = DateTime(2026, 5, 20, 14, 30);

    test('每个档位都给得出合法的起止（含首尾、首不晚于尾）', () {
      for (final w in HeatWindow.values) {
        final r = w.resolve(now);
        expect(r.from.isBefore(r.to), isTrue, reason: '${w.label} 起止反了');
        // 都是"当天"零点，不带时分秒 —— 否则补周的时候会错开一天
        expect(<int>[r.from.hour, r.from.minute, r.from.second], <int>[0, 0, 0]);
        expect(<int>[r.to.hour, r.to.minute, r.to.second], <int>[0, 0, 0]);
      }
    });

    test('今年 = 1 月 1 日到今天', () {
      final r = HeatWindow.ytd.resolve(now);
      expect(r.from, DateTime(2026, 1, 1));
      expect(r.to, DateTime(2026, 5, 20));
    });

    test('去年 = 整年，且不包含今年', () {
      final r = HeatWindow.lastYear.resolve(now);
      expect(r.from, DateTime(2025, 1, 1));
      expect(r.to, DateTime(2025, 12, 31));
      expect(r.to.isBefore(DateTime(2026, 1, 1)), isTrue);
    });

    test('最近一年约 365 天', () {
      final r = HeatWindow.y1.resolve(now);
      expect(r.to.difference(r.from).inDays, 364);
    });

    test('窗口长度递增：三个月 < 半年 < 一年', () {
      int days(HeatWindow w) =>
          w.resolve(now).to.difference(w.resolve(now).from).inDays;
      expect(days(HeatWindow.m3), lessThan(days(HeatWindow.m6)));
      expect(days(HeatWindow.m6), lessThan(days(HeatWindow.y1)));
    });

    test('跨年边界不会算反（1 月 1 日看去年）', () {
      final jan1 = DateTime(2026, 1, 1);
      final r = HeatWindow.lastYear.resolve(jan1);
      expect(r.from, DateTime(2025, 1, 1));
      expect(r.to, DateTime(2025, 12, 31));
      // 今年档位在 1 月 1 日就只有一天
      final ytd = HeatWindow.ytd.resolve(jan1);
      expect(ytd.from, ytd.to);
    });
  });

  late AppDatabase db;
  late AppState state;

  setUp(() async {
    db = AppDatabase.inMemory();
    final repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
  });

  tearDown(() => db.close());

  group('篇幅分档', () {
    test('三套档位都无缝、且最后一档封顶', () {
      for (final s in LengthScale.values) {
        // 相邻两档首尾相接，中间不能有缝 —— 有缝的字数会凭空消失
        expect(s.bands.first.$2, 0, reason: '${s.label}：第一档要从 0 起');
        for (var i = 1; i < s.bands.length; i++) {
          expect(
            s.bands[i].$2,
            s.bands[i - 1].$3,
            reason: '${s.label} 第 $i 档和上一档没接上',
          );
        }
        expect(
          s.bands.last.$3,
          greaterThan(1000000),
          reason: '${s.label}：最后一档必须封顶',
        );
      }
    });

    test('每篇笔记都能落进恰好一个档位', () {
      final stats = StatsRepository(db);
      for (final chars in <int>[0, 1, 299, 300, 1999, 20000, 999999]) {
        state.repo.insertNote(
          title: '$chars 字',
          content: 'x' * (chars == 0 ? 1 : chars),
          excerpt: 'x',
          publishedAt: DateTime.now(),
          charCount: chars,
          wordCount: chars ~/ 2,
        );
      }
      for (final s in LengthScale.values) {
        final buckets = stats.lengthDistribution(scale: s);
        final sum = buckets.fold<int>(0, (a, b) => a + b.count);
        expect(sum, 7, reason: '${s.label}：有笔记没被算进去');
      }
    });

    test('0 字笔记不会凭空消失', () {
      final stats = StatsRepository(db);
      state.repo.insertNote(
        title: '空笔记',
        content: 'x',
        excerpt: 'x',
        publishedAt: DateTime.now(),
        charCount: 0,
        wordCount: 0,
      );
      final buckets = stats.lengthDistribution();
      expect(buckets.first.count, 1, reason: '0 字要落进第一档');
    });

    test('换分档之后档位数量和标签都变', () {
      final stats = StatsRepository(db);
      for (final c in <int>[200, 900, 4000, 30000]) {
        state.repo.insertNote(
          title: '$c',
          content: 'x' * c,
          excerpt: 'x',
          publishedAt: DateTime.now(),
          charCount: c,
          wordCount: c ~/ 2,
        );
      }
      final coarse = stats.lengthDistribution(scale: LengthScale.coarse);
      final fine = stats.lengthDistribution(scale: LengthScale.fine);
      expect(coarse.length, 4);
      expect(fine.length, 9);
      // 200 和 900 在粗分档里是同一档，在细分档里是两档
      expect(coarse.first.count, 2);
      expect(fine.take(3).fold<int>(0, (a, b) => a + b.count), 2);
    });
  });

  /// 造笔记；[count] 篇都落在 [at]。
  void addAt(DateTime at, {int count = 1, int chars = 1000}) {
    for (var i = 0; i < count; i++) {
      state.repo.insertNote(
        title: '笔记 $i',
        content: 'x' * chars,
        excerpt: '深夜写作的时候最有感觉',
        publishedAt: at,
        charCount: chars,
        wordCount: chars ~/ 2,
      );
    }
  }

  Future<void> pumpStats(
    WidgetTester tester, {
    Size size = const Size(1300, 9000),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(theme: AppTheme.light(), home: const StatsPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// 铺一批跨年数据。
  void seed() {
    final now = DateTime.now();
    addAt(DateTime(now.year, now.month, 5), count: 4, chars: 300);
    addAt(DateTime(now.year - 1, 6, 5), count: 3, chars: 2500);
    addAt(DateTime(now.year - 1, 2, 5), count: 2, chars: 9000);
    addAt(DateTime(now.year - 2, 3, 5), count: 1, chars: 25000);
  }

  testWidgets('热力图有窗口选择器，换档位会改卡片上的起止', (tester) async {
    seed();
    await pumpStats(tester);

    expect(find.text('发布热力图'), findsOneWidget);
    expect(find.text('最近一年'), findsWidgets);

    // 切到「去年」——卡片 trailing 的起止要跟着变
    await tester.tap(find.text('最近一年').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('去年').last);
    await tester.pumpAndSettle();

    final y = DateTime.now().year - 1;
    expect(find.text('$y.1 – $y.12'), findsOneWidget);
    expect(state.repo.getSetting('stats.heatWindow'), 'lastYear');
  });

  testWidgets('热力图数据不带页面时间范围（换窗口还能看到老数据）', (tester) async {
    seed();
    await pumpStats(tester);

    // 页面范围切成「近三个月」，热力图窗口仍能看到去年
    await tester.tap(find.text('全部').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('近 3 个月').last);
    await tester.pumpAndSettle();

    // 找到热力图卡片里的"共 N 篇有发布记录"——不该是 0
    final footer = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>()
        .firstWhere((s) => s.contains('篇有发布记录'), orElse: () => '');
    expect(footer, isNotEmpty);
    expect(footer, isNot(contains('共 0 篇')));
  });

  testWidgets('篇幅分布：X 轴能换分档，Y 轴能换单位', (tester) async {
    seed();
    await pumpStats(tester);

    expect(find.text('篇幅分布'), findsOneWidget);
    // 默认标准分档
    expect(find.text('标准分档'), findsWidgets);

    await tester.tap(find.text('标准分档').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('细分档').last);
    await tester.pumpAndSettle();
    expect(state.repo.getSetting('stats.lenScale'), 'fine');

    // Y 轴换占比。按钮上只有图标，标签在弹出菜单里
    await tester.tap(find.byIcon(Icons.tag_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('占比').last);
    await tester.pumpAndSettle();
    expect(state.repo.getSetting('stats.lenPercent'), '1');

    // 纵轴读数带上了百分号 —— 证明真的换单位了，不只是按钮变色
    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((t) => t.data)
        .whereType<String>();
    expect(texts.any((s) => s.contains('%') && s.contains(' – ')), isTrue);
  });

  testWidgets('篇幅分布：纵轴能放大缩小，倍率到顶不越界', (tester) async {
    seed();
    await pumpStats(tester);

    final bar = find.byKey(const Key('stats-length-zoom-bar'));
    expect(bar, findsOneWidget);

    Finder btn(IconData icon) =>
        find.descendant(of: bar, matching: find.byIcon(icon));

    await tester.tap(btn(Icons.add_rounded));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: bar, matching: find.text('2×')),
      findsOneWidget,
    );

    for (var i = 0; i < 10; i++) {
      await tester.tap(btn(Icons.add_rounded));
      await tester.pumpAndSettle();
    }
    expect(
      find.descendant(of: bar, matching: find.text('12×')),
      findsOneWidget,
    );
  });

  testWidgets('篇幅分布：换分档之后档位标签跟着变', (tester) async {
    seed();
    await pumpStats(tester);

    // 横轴标签按空格拆成多行渲染（'≥ 2万' 会拆成 '≥' 和 '2万'），
    // 所以挑**不带空格**的那几档来认
    expect(find.text('500–2000'), findsWidgets, reason: '标准分档有这一档');

    await tester.tap(find.text('标准分档').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('细分档').last);
    await tester.pumpAndSettle();

    expect(find.text('500–2000'), findsNothing, reason: '细分档没有这一档');
    expect(find.text('300–800'), findsWidgets, reason: '细分档有这一档');
  });

  testWidgets('文件夹选择器：子文件夹能收起来、也能再展开', (tester) async {
    final parent = await state.createCollection('父文集');
    await state.createCollection('子文集', parentId: parent);
    addAt(DateTime.now(), count: 2);
    await pumpStats(tester);

    await tester.tap(find.text('全部文件夹'));
    await tester.pumpAndSettle();
    expect(find.text('选择文件夹'), findsOneWidget);

    // **必须限定在对话框里找** —— 页面上的 _MiniSelect 也有一个
    // expand_more，直接 find.byIcon 会点到弹窗外面那个；
    // 文集分布模块的图例里也有同名文集，find.text 同样会撞上。
    Finder inDialog(Finder matching) =>
        find.descendant(of: find.byType(Dialog), matching: matching);
    Finder dText(String s) => inDialog(find.text(s));

    expect(dText('子文集'), findsOneWidget, reason: '默认是展开的');

    // 收起
    await tester.tap(inDialog(find.byIcon(Icons.expand_more_rounded)).first);
    await tester.pumpAndSettle();
    expect(dText('子文集'), findsNothing);
    expect(dText('父文集'), findsOneWidget);

    // 再展开
    await tester.tap(inDialog(find.byIcon(Icons.chevron_right_rounded)).first);
    await tester.pumpAndSettle();
    expect(dText('子文集'), findsOneWidget);
  });

  testWidgets('收起来的父节点会提示底下勾了几个', (tester) async {
    final parent = await state.createCollection('父文集');
    await state.createCollection('子文集', parentId: parent);
    addAt(DateTime.now(), count: 2);
    await pumpStats(tester);

    await tester.tap(find.text('全部文件夹'));
    await tester.pumpAndSettle();

    // 勾上子文集
    await tester.tap(
      find.descendant(of: find.byType(Dialog), matching: find.text('子文集')),
    );
    await tester.pumpAndSettle();

    // 收起父节点 —— 勾选不能就这么"消失"了
    await tester.tap(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.byIcon(Icons.expand_more_rounded),
      ).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('含 1 个已选'), findsOneWidget);
  });
}
