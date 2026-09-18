/// 待办页的交互测试。
///
/// 为什么用组件测试而不是手动/自动化点击：
///   1. 能精确断言「点完之后数据真的变了」，而不是靠肉眼看截图；
///   2. 不依赖操作系统的输入注入（本机环境下合成鼠标事件会被系统拦截）；
///   3. 后续重构界面时，这些断言会自动兜住行为回归。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/core/widgets/todo_check.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/todos/todos_page.dart';

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

  Future<void> pumpPage(
    WidgetTester tester, {
    Size size = const Size(1180, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const TodosPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('空库时显示引导文案与输入框', (tester) async {
    await pumpPage(tester);

    expect(find.text('还没有待办'), findsOneWidget);
    expect(find.text('添加待办…'), findsOneWidget);
    // 头部统计
    expect(find.textContaining('未完成 0'), findsOneWidget);
  });

  testWidgets('在输入框回车可以添加待办', (tester) async {
    await pumpPage(tester);

    await tester.enterText(find.byType(TextField), '写完动效打磨');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('写完动效打磨'), findsOneWidget);
    expect(find.text('还没有待办'), findsNothing);
    // 数据层也真的写进去了
    expect(state.todoList.length, 1);
    expect(state.openTodoCount, 1);
    // 输入框应被清空，方便连续录入
    expect(state.todoList.first.content, '写完动效打磨');
  });

  testWidgets('点击圆圈把待办标记为完成', (tester) async {
    state.addTodo('研究 FTS5 分词');
    await pumpPage(tester);

    expect(state.openTodoCount, 1);
    expect(state.doneTodoCount, 0);

    await tester.tap(find.byType(TodoCheck).first);
    await tester.pumpAndSettle();

    expect(state.openTodoCount, 0);
    expect(state.doneTodoCount, 1);
    expect(state.todoList.first.isDone, isTrue);
    // 全部完成时会给出提示
    expect(find.text('全部完成了'), findsOneWidget);
  });

  testWidgets('再次点击可以取消完成', (tester) async {
    state.addTodo('来回切换');
    await pumpPage(tester);

    await tester.tap(find.byType(TodoCheck).first);
    await tester.pumpAndSettle();
    expect(state.doneTodoCount, 1);

    // 完成后该项落到「已完成」区，需要先把折叠区展开。
    // 这里必须用精确文案：头部副标题里也有「已完成 1」，用 textContaining 会命中两个。
    await tester.tap(find.text('已完成 1'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TodoCheck).last);
    await tester.pumpAndSettle();

    expect(state.doneTodoCount, 0);
    expect(state.openTodoCount, 1);
  });

  testWidgets('已完成区默认折叠，点击后可展开', (tester) async {
    final id = state.todos.add('已经做完的事');
    state.todos.setDone(id, true);
    state.refreshTodos();
    state.addTodo('还没做的事');

    await pumpPage(tester);

    // 折叠状态下看不到已完成项的内容
    expect(find.text('已经做完的事'), findsNothing);
    expect(find.text('已完成 1'), findsOneWidget);

    await tester.tap(find.text('已完成 1'));
    await tester.pumpAndSettle();

    expect(find.text('已经做完的事'), findsOneWidget);
  });

  testWidgets('左滑删除待办', (tester) async {
    state.addTodo('待会儿删掉');
    await pumpPage(tester);

    expect(find.text('待会儿删掉'), findsOneWidget);

    // 直接在 Dismissible 上拖，避免点到文字上没有命中手势层
    await tester.drag(find.byType(Dismissible).first, const Offset(-600, 0));
    await tester.pumpAndSettle();

    expect(state.todoList, isEmpty);
  });

  testWidgets('头部显示逾期数量', (tester) async {
    state.todos.add(
      '早就该做了',
      dueAt: DateTime.now().subtract(const Duration(days: 3)),
    );
    state.refreshTodos();
    await pumpPage(tester);

    expect(state.overdueTodoCount, 1);
    // 头部徽标 + 副标题里都会出现「逾期」
    expect(find.textContaining('逾期'), findsWidgets);
  });

  testWidgets('优先级与截止时间会显示成小标签', (tester) async {
    state.todos.add('高优先级任务', priority: 3);
    state.todos.add(
      '明天到期',
      dueAt: DateTime.now().add(const Duration(days: 1)),
    );
    state.refreshTodos();
    await pumpPage(tester);

    expect(find.text('高'), findsOneWidget);
    expect(find.text('明天'), findsOneWidget);
  });

  testWidgets('窄屏（手机）下同样能正常渲染', (tester) async {
    state.addTodo('手机上的待办');
    await pumpPage(tester, size: const Size(400, 800));

    expect(find.text('手机上的待办'), findsOneWidget);
    expect(find.text('添加待办…'), findsOneWidget);
  });
}
