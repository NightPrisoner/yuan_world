import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/backup/backup_service.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/importer/media_refs.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/notes/editor/note_editor_page.dart';
import 'package:yuan_world/features/notes/notes_page.dart';
import 'package:yuan_world/features/shell/home_shell.dart';

void main() {
  late Directory root;
  late AppDatabase db;
  late NoteRepository repo;
  late AppState state;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('yw_audit_');
    db = AppDatabase.openAt(root.path);
    repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
  });

  tearDown(() {
    state.dispose();
    db.close();
    root.deleteSync(recursive: true);
  });

  int add(String title, {int? collectionId, List<String> tags = const []}) =>
      repo.insertNote(
        title: title,
        content: '正文',
        excerpt: '正文',
        collectionId: collectionId,
        tags: tags,
      );

  test('恢复子文件夹时祖先也恢复，未选中的兄弟仍在回收站', () async {
    final parent = repo.createCollection('父')!;
    final child = repo.createCollection('子', parentId: parent)!;
    final sibling = repo.createCollection('兄弟', parentId: parent)!;
    final note = add('子笔记', collectionId: child);
    repo.trashCollection(parent);
    await state.restoreCollections([child]);
    expect(state.collections.map((c) => c.id), containsAll([parent, child]));
    expect(state.collections.map((c) => c.id), isNot(contains(sibling)));
    expect(repo.getNote(note)!.deletedAt, isNull);
  });

  test('当前标签改名后筛选跟随，排序和列表不丢失', () async {
    final note = add('带标签', tags: ['旧名']);
    final id = repo.allTags().single.id;
    state.selectTag('旧名');
    await state.renameTag(id, '新名');
    expect(state.filter.tag, '新名');
    expect(state.notes.map((n) => n.id), contains(note));
  });

  test('隐私空间新建未分类笔记不会泄漏到普通空间', () async {
    state.enterPrivacyMode();
    final id = state.createNote();
    expect(repo.getNote(id)!.isHidden, isTrue);
    await state.refresh();
    expect(state.notes.map((n) => n.id), contains(id));
    state.exitPrivacyMode();
    expect(state.notes.map((n) => n.id), isNot(contains(id)));
  });

  test('隐私空间新建文件夹继承隐私状态', () async {
    state.enterPrivacyMode();
    final id = await state.createCollection('私密新文件夹');
    expect(state.collections.map((c) => c.id), contains(id));
    state.exitPrivacyMode();
    expect(state.collections.map((c) => c.id), isNot(contains(id)));
  });

  test('重新导入回收站里的笔记不应跳过到仍不可见', () async {
    final file = File('${root.path}/重导入.txt')..writeAsStringSync('正文');
    final first = await state.importer.importDocx([file]);
    expect(first.imported, 1);
    final id = repo.listNotes(const NoteFilter()).single.id;
    repo.deleteNote(id);
    await state.importer.importDocx([file]);
    expect(repo.listNotes(const NoteFilter()), isNotEmpty);
  });

  test('恢复看似数据库但无法迁移的备份不会损坏现有库', () {
    final id = add('必须保留');
    final f = File('${root.path}/broken.db');
    final bad = sqlite3.open(f.path);
    bad.execute('CREATE TABLE notes (id INTEGER PRIMARY KEY, title TEXT)');
    bad.execute("INSERT INTO notes VALUES (1, '坏备份')");
    bad.execute('CREATE TABLE collections (id INTEGER PRIMARY KEY)');
    bad.close();
    expect(() => BackupService(db).restore(f), throwsA(anything));
    expect(repo.getNote(id)!.title, '必须保留');
    expect(
      repo.insertNote(title: '仍可写入', content: '', excerpt: ''),
      isPositive,
    );
  });

  test('恢复更新版本数据库会被拒绝且原笔记保持不变', () {
    final id = add('原笔记');
    final f = BackupService(db).snapshot();
    final future = sqlite3.open(f.path);
    future.execute('PRAGMA user_version = 999');
    future.close();
    expect(() => BackupService(db).restore(f), throwsA(isA<StateError>()));
    expect(repo.getNote(id)!.title, '原笔记');
  });

  test('恢复媒体中途失败会回滚数据库和已经覆盖的图片', () {
    final id = add('备份时');
    final snapshot = BackupService(db).snapshot();
    final a = File('${db.imageRoot.path}/1/a.png');
    a.parent.createSync(recursive: true);
    a.writeAsBytesSync([1, 2]);
    Directory('${db.imageRoot.path}/1/blocked.png').createSync();
    repo.updateNote(id: id, title: '恢复前最新内容');
    final zip = Archive()
      ..addFile(
        ArchiveFile(
          'yuanworld.db',
          snapshot.lengthSync(),
          snapshot.readAsBytesSync(),
        ),
      )
      ..addFile(ArchiveFile('images/1/a.png', 2, [8, 9]))
      ..addFile(ArchiveFile('images/1/blocked.png', 2, [8, 9]));
    final f = File('${root.path}/media-failure.zip')
      ..writeAsBytesSync(ZipEncoder().encodeBytes(zip));
    expect(() => BackupService(db).restore(f), throwsA(anything));
    expect(repo.getNote(id)!.title, '恢复前最新内容');
    expect(a.readAsBytesSync(), [1, 2]);
  });

  test('隐私空间文件夹计数包含其隐藏笔记', () {
    final parent = repo.createCollection('私密父')!;
    final child = repo.createCollection('私密子', parentId: parent)!;
    add('私密笔记', collectionId: child);
    repo.setCollectionHidden(parent, true);
    final cols = repo.allCollections(includeHidden: true);
    expect(cols.firstWhere((c) => c.id == parent).noteCount, 1);
    expect(cols.firstWhere((c) => c.id == child).noteCount, 1);
  });

  test('按文档内文集名导入会恢复同名回收站文件夹', () {
    final id = repo.createCollection('从文档头读取')!;
    repo.trashCollection(id);
    expect(repo.ensureCollection('从文档头读取'), id);
    expect(repo.allCollections().map((c) => c.id), contains(id));
  });

  test('导入附件路径含 emoji 和百分号空格时仍能找到图片', () {
    File('${root.path}/图😀 1.png').writeAsBytesSync([1, 2]);
    final refs = resolveLocalMedia('![](图😀%201.png)', root);
    expect(refs, hasLength(1));
  });

  testWidgets('移动端切换标签页保留笔记页状态', (tester) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(theme: AppTheme.light(), home: const HomeShell()),
      ),
    );
    await tester.pumpAndSettle();
    final initial = tester.state(find.byType(NotesPage));
    await tester.tap(find.text('待办').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('笔记').last);
    await tester.pumpAndSettle();
    expect(identical(tester.state(find.byType(NotesPage)), initial), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('桌面编辑器在自动保存前被替换也保留最后输入', (tester) async {
    final id = add('编辑');
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
    final body = find
        .byType(TextField)
        .evaluate()
        .where((e) => (e.widget as TextField).controller?.text == '正文')
        .single;
    await tester.enterText(find.byWidget(body.widget), '尚未自动保存的正文');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(repo.getNote(id)!.content, '尚未自动保存的正文');
  });
}
