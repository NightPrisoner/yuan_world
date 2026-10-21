/// 历史版本 + 未保存草稿的测试。
///
/// 这两块是「保存状态可信」的地基：
///   · 历史版本让用户能找回被自动保存覆盖掉的旧内容
///   · 草稿让保存失败/被强杀之后还有东西可恢复
///
/// 界面层的提示（红字、重试、对话框）另有一组 widget 测试，
/// 这里先把数据层的语义钉死。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/notes/editor/note_editor_page.dart';

void main() {
  group('历史版本', () {
    late AppDatabase db;
    late NoteRepository repo;
    late int id;

    setUp(() async {
      db = AppDatabase.inMemory();
      repo = NoteRepository(db);
      id = repo.insertNote(title: '标题', content: '一', excerpt: '一');
    });
    tearDown(() => db.close());

    test('写一条历史后能读回来，内容与原因都在', () {
      final rid = repo.addRevision(
        noteId: id,
        title: '旧标题',
        content: '旧正文',
        reason: 'save',
      );
      final list = repo.revisionsOf(id);
      expect(list.length, 1);
      expect(list.first.id, rid);
      expect(list.first.title, '旧标题');
      expect(list.first.content, '旧正文');
      expect(list.first.reason, 'save');
      expect(list.first.preview, '旧正文');
    });

    test('历史按时间倒序，新的在前面', () {
      repo.addRevision(noteId: id, title: 't', content: '第一版');
      repo.addRevision(noteId: id, title: 't', content: '第二版');
      repo.addRevision(noteId: id, title: 't', content: '第三版');
      final list = repo.revisionsOf(id);
      expect(list.map((r) => r.content).toList(), ['第三版', '第二版', '第一版']);
    });

    test('超过保留上限时删最旧的，留下最新的 30 条', () {
      for (var i = 0; i < NoteRevisions.kRevisionKeep + 5; i++) {
        repo.addRevision(noteId: id, title: 't', content: '版本 $i');
      }
      expect(repo.revisionCount(id), NoteRevisions.kRevisionKeep);
      final list = repo.revisionsOf(id, limit: 999);
      // 最新的还在，最早的 5 条被轮转掉了
      expect(list.first.content, '版本 ${NoteRevisions.kRevisionKeep + 4}');
      expect(list.last.content, '版本 5');
    });

    test('历史按笔记隔离，另一篇看不到这篇的版本', () {
      final other = repo.insertNote(title: '另一篇', content: '', excerpt: '');
      repo.addRevision(noteId: id, title: 't', content: 'A');
      expect(repo.revisionCount(other), 0);
      expect(repo.revisionCount(id), 1);
    });

    test('删除笔记的历史会连草稿一起删掉', () {
      repo.addRevision(noteId: id, title: 't', content: 'A');
      repo.saveDraft(noteId: id, title: 't', content: '草稿内容');
      expect(repo.totalRevisionCount(), 1);
      repo.deleteRevisionsOf(id);
      expect(repo.revisionCount(id), 0);
      expect(repo.getDraft(id), isNull);
    });

    test('空正文的预览显示占位而不是空白', () {
      repo.addRevision(noteId: id, title: 't', content: '   \n\n ');
      expect(repo.revisionsOf(id).first.preview, '（空）');
    });

    test('长正文的预览截断到 80 字', () {
      final long = 'a' * 200;
      repo.addRevision(noteId: id, title: 't', content: long);
      final preview = repo.revisionsOf(id).first.preview;
      expect(preview.length, 81); // 80 + 省略号
      expect(preview.endsWith('…'), isTrue);
    });
  });

  group('未保存草稿', () {
    late AppDatabase db;
    late NoteRepository repo;
    late int id;

    setUp(() async {
      db = AppDatabase.inMemory();
      repo = NoteRepository(db);
      id = repo.insertNote(title: '标题', content: '正文', excerpt: '正文');
    });
    tearDown(() => db.close());

    test('先写再读，拿到最后一次的内容', () {
      repo.saveDraft(noteId: id, title: '草稿标题', content: '草稿正文');
      final d = repo.getDraft(id)!;
      expect(d.title, '草稿标题');
      expect(d.content, '草稿正文');
    });

    test('同一篇反复写只留一条，不会堆成很多份', () {
      for (var i = 0; i < 5; i++) {
        repo.saveDraft(noteId: id, title: 't', content: '第 $i 次');
      }
      expect(repo.getDraft(id)!.content, '第 4 次');
      final rows = db.db.select('SELECT COUNT(*) AS c FROM note_drafts');
      expect(rows.first['c'], 1);
    });

    test('没有草稿时返回 null', () {
      expect(repo.getDraft(id), isNull);
    });

    test('草稿和库里内容一致时 deleteDraftIfMatches 会清掉它', () {
      repo.saveDraft(noteId: id, title: '标题', content: '正文');
      repo.deleteDraftIfMatches(id, title: '标题', content: '正文');
      expect(repo.getDraft(id), isNull);
    });

    test('草稿和库里内容不一致时 deleteDraftIfMatches 不动它', () {
      repo.saveDraft(noteId: id, title: '标题', content: '改过的正文');
      repo.deleteDraftIfMatches(id, title: '标题', content: '正文');
      expect(repo.getDraft(id)!.content, '改过的正文');
    });
  });

  group('彻底删除连历史草稿一起清', () {
    late AppDatabase db;
    late NoteRepository repo;
    late int id;

    setUp(() async {
      db = AppDatabase.inMemory();
      repo = NoteRepository(db);
      id = repo.insertNote(title: '标题', content: '正文', excerpt: '正文');
      repo.addRevision(noteId: id, title: '标题', content: '旧版本');
      repo.saveDraft(noteId: id, title: '标题', content: '草稿');
    });
    tearDown(() => db.close());

    test('purgeNotes 之后历史与草稿都不在了', () {
      expect(repo.revisionCount(id), 1);
      expect(repo.getDraft(id), isNotNull);
      repo.deleteNote(id);
      repo.purgeNotes([id]);
      expect(repo.revisionCount(id), 0);
      expect(repo.getDraft(id), isNull);
    });

    test('清空回收站之后历史与草稿都不在了', () {
      repo.deleteNote(id);
      repo.purgeAllTrash();
      expect(repo.revisionCount(id), 0);
      expect(repo.getDraft(id), isNull);
    });

    test('只进回收站还没彻底删时，历史仍然留着（能恢复）', () {
      repo.deleteNote(id);
      expect(repo.revisionCount(id), 1);
      expect(repo.getDraft(id), isNotNull);
    });
  });

  group('保存失败的界面反馈', () {
    late AppDatabase db;
    late AppState state;
    late NoteRepository repo;
    late int id;

    /// 让 UPDATE notes 失败，模拟"写库这一步写不进去"（库被占用/磁盘满）。
    /// 用触发器而不是换掉整个仓库：历史、草稿这些旁路仍然真实工作，
    /// 才能验证失败时草稿真的留了底。
    void breakWrites() => db.db.execute(
      "CREATE TRIGGER IF NOT EXISTS fail_note_update BEFORE UPDATE ON notes "
      "BEGIN SELECT RAISE(ABORT, 'database is locked: simulated'); END;",
    );
    void fixWrites() =>
        db.db.execute('DROP TRIGGER IF EXISTS fail_note_update');

    setUp(() async {
      db = AppDatabase.inMemory();
      repo = NoteRepository(db);
      state = AppState(db, repo, ImportService(db, repo));
      await state.init();
      id = repo.insertNote(title: '测试', content: '第一版', excerpt: '第一版');
      breakWrites();
    });
    tearDown(() {
      state.dispose();
      db.close();
    });

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(body: NoteEditorPage(noteId: id, embedded: true)),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('写不进去时提示条变红并写明原因，草稿留底', (tester) async {
      await open(tester);
      final body = find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.controller is TextEditingController &&
            (w.controller as TextEditingController).text.contains('第一版'),
      );
      await tester.enterText(body.first, '改过的内容');
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.pumpAndSettle();
      // 红色提示条出来了，原因是翻译过的人话
      expect(find.textContaining('未保存'), findsOneWidget);
      expect(find.textContaining('数据库正被占用'), findsOneWidget);
      // 库没变，草稿里有现场
      expect(state.repo.getNote(id)!.content, '第一版');
      expect(state.repo.getDraft(id)!.content, '改过的内容');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('恢复写入能力后点提示条重试，内容真正落库、草稿清掉', (tester) async {
      await open(tester);
      final body = find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.controller is TextEditingController &&
            (w.controller as TextEditingController).text.contains('第一版'),
      );
      await tester.enterText(body.first, '改过的内容');
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.pumpAndSettle();
      expect(find.textContaining('未保存'), findsOneWidget);

      fixWrites();
      await tester.tap(find.textContaining('未保存'));
      await tester.pumpAndSettle();
      expect(state.repo.getNote(id)!.content, '改过的内容');
      expect(find.textContaining('未保存'), findsNothing);
      expect(find.text('已自动保存'), findsOneWidget);
      expect(state.repo.getDraft(id), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('失败后自动重试：3 秒后自己就又存上了', (tester) async {
      await open(tester);
      final body = find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.controller is TextEditingController &&
            (w.controller as TextEditingController).text.contains('第一版'),
      );
      await tester.enterText(body.first, '自动重试的内容');
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.pumpAndSettle();
      expect(find.textContaining('未保存'), findsOneWidget);

      fixWrites();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(state.repo.getNote(id)!.content, '自动重试的内容');
      expect(find.textContaining('未保存'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('保存不了也别默默关掉：点完成会弹对话框', (tester) async {
      tester.view.physicalSize = const Size(500, 900); // 手机布局才有「完成」
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: NoteEditorPage(noteId: id),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final body = find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.controller is TextEditingController &&
            (w.controller as TextEditingController).text.contains('第一版'),
      );
      await tester.enterText(body.first, '关不掉的改动');
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
      await tester.pumpAndSettle();
      expect(find.text('这次没有保存成功'), findsOneWidget);
      expect(find.text('先离开'), findsOneWidget);
      expect(find.text('再试一次'), findsOneWidget);
      await tester.tap(find.text('先离开'));
      await tester.pumpAndSettle();
      // 离开后草稿还在，下次能恢复
      expect(state.repo.getDraft(id)!.content, '关不掉的改动');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('编辑器里的历史与草稿入口', () {
    late AppDatabase db;
    late AppState state;
    late int id;

    setUp(() async {
      db = AppDatabase.inMemory();
      final repo = NoteRepository(db);
      state = AppState(db, repo, ImportService(db, repo));
      await state.init();
      id = repo.insertNote(title: '测试', content: '第一版', excerpt: '第一版');
    });
    tearDown(() {
      state.dispose();
      db.close();
    });

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ChangeNotifierProvider<AppState>.value(
          value: state,
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(body: NoteEditorPage(noteId: id, embedded: true)),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('改完正文并等自动保存，旧内容进历史版本', (tester) async {
      await open(tester);
      final body = find.byWidgetPredicate(
        (w) =>
            w is TextField &&
            w.controller is TextEditingController &&
            (w.controller as TextEditingController).text.contains('第一版'),
      );
      await tester.enterText(body.first, '第二版');
      // 自动保存 1.2 秒
      await tester.pump(const Duration(milliseconds: 1300));
      await tester.pumpAndSettle();
      expect(state.repo.getNote(id)!.content, '第二版');
      final revs = state.repo.revisionsOf(id);
      expect(revs.any((r) => r.content == '第一版'), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('历史版本按钮打开对话框，空历史有引导文案', (tester) async {
      await open(tester);
      await tester.tap(find.byTooltip('历史版本'));
      await tester.pumpAndSettle();
      expect(find.text('历史版本'), findsWidgets);
      expect(find.textContaining('还没有历史版本'), findsOneWidget);
      await tester.tapAt(const Offset(20, 20)); // 点遮罩关闭
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('打开时有更新的草稿，弹窗提示可恢复', (tester) async {
      state.repo.saveDraft(noteId: id, title: '测试', content: '没保存上的内容');
      await open(tester);
      await tester.pumpAndSettle();
      expect(find.text('发现未保存的编辑内容'), findsOneWidget);
      await tester.tap(find.text('恢复'));
      await tester.pumpAndSettle();
      final body = tester.widget<TextField>(
        find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              w.controller is TextEditingController &&
              (w.controller as TextEditingController).text == '没保存上的内容',
        ),
      );
      expect(body.controller!.text, '没保存上的内容');
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('草稿和库里一致时不打扰用户', (tester) async {
      state.repo.saveDraft(noteId: id, title: '测试', content: '第一版');
      await open(tester);
      await tester.pumpAndSettle();
      expect(find.text('发现未保存的编辑内容'), findsNothing);
      expect(state.repo.getDraft(id), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
