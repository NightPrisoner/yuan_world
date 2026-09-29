/// 框选文字后弹出的那排操作必须是中文（Windows + 安卓都是）。
///
/// 用户报的是：编辑笔记时框选文字，弹出的操作全是英文
/// （Cut / Copy / Paste / Select all）。根因不在编辑器，而在 `MaterialApp`
/// 没接 `GlobalMaterialLocalizations` —— 框架自带的这批文案跟着**系统语言**走，
/// 英文系统上就是英文。本应用其余文案全是手写中文，所以必须钉死 zh-CN。
///
/// 三条锁死：
///   1) 中文委托给出来的确实是中文（并对照英文资源，证明差别真在这里）；
///   2) 真实的 `YuanWorldApp` 装上了这套委托（以后有人从 main.dart 删掉就会红）；
///   3) 编辑器里真的框选文字，弹出来的菜单就是中文。
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/app_localization.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/notes/editor/note_editor_page.dart';
import 'package:yuan_world/main.dart';

void main() {
  late AppDatabase db;
  late AppState state;

  setUp(() async {
    db = AppDatabase.inMemory();
    final repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
  });

  tearDown(() => db.close());

  test('框架自带的这批文案，中文委托给的就是中文', () async {
    final zh = await GlobalMaterialLocalizations.delegate.load(kAppLocale);
    expect(zh.cutButtonLabel, '剪切');
    expect(zh.copyButtonLabel, '复制');
    expect(zh.pasteButtonLabel, '粘贴');
    expect(zh.selectAllButtonLabel, '全选');

    // 对照：英文资源确实是英文 —— 说明"菜单是英文"的根因就是没接委托，
    // 而不是别的地方写死了英文。
    final en =
        await GlobalMaterialLocalizations.delegate.load(const Locale('en'));
    expect(en.cutButtonLabel, 'Cut');
    expect(en.copyButtonLabel, 'Copy');
    expect(en.selectAllButtonLabel, 'Select all');
  });

  testWidgets('YuanWorldApp 装上了中文委托（整个应用都跟着中文）', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: const YuanWorldApp(),
      ),
    );
    await tester.pumpAndSettle();

    final ctx = tester.element(find.byType(Scaffold).first);
    expect(Localizations.localeOf(ctx).languageCode, 'zh',
        reason: '语言必须钉死中文，不能跟随系统');
    final l10n = MaterialLocalizations.of(ctx);
    expect(l10n.copyButtonLabel, '复制');
    expect(l10n.selectAllButtonLabel, '全选');
  });

  testWidgets('编辑器里框选文字，弹出的菜单是中文', (tester) async {
    final id = state.repo.insertNote(
      title: '框选测试标题',
      content: '正文内容',
      excerpt: '正文内容',
      publishedAt: DateTime.now(),
      charCount: 4,
    );
    await state.refresh();

    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 和 main.dart 用**同一份**委托配置：这里就是"用户看到的那套"
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          locale: kAppLocale,
          supportedLocales: kAppSupportedLocales,
          localizationsDelegates: kAppLocalizationsDelegates,
          theme: AppTheme.light(),
          home: NoteEditorPage(noteId: id),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 长按标题里的字 → 选中 → 弹出操作菜单。
    // 注意落点：必须压在这一行的**字上**。`tester.longPress(找组件)` 点的是
    // 组件矩形正中（420 宽输入框里的空白处），那里只会把光标放到行尾、
    // 给不出选区，工具条也就不会出来 —— 这一点是实测出来的，不是猜的。
    final rect = tester.getRect(find.byType(TextField).first);
    await tester.longPressAt(Offset(rect.left + 30, rect.center.dy));
    await tester.pumpAndSettle();

    expect(find.text('复制'), findsOneWidget);
    expect(find.text('剪切'), findsOneWidget);
    expect(find.text('全选'), findsOneWidget);
    expect(find.text('Cut'), findsNothing);
    expect(find.text('Copy'), findsNothing);
    expect(find.text('Select all'), findsNothing);
  });
}
