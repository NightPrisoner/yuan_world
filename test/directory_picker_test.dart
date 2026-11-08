import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/features/importer/directory_picker_page.dart';

/// 选文件夹的界面**要把文件也列出来**。
///
/// 起因是一个很具体的困惑：导出时选目录，界面上只有一个个文件夹，
/// 完全看不出「这个目录里已经有一份同名的导出文件」—— 于是要么
/// 反复导出、要么覆盖了自己不知道。列表里带上文件，这件事才有答案。
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('yw_picker_');
    Directory(p.join(root.path, '子目录A')).createSync();
    Directory(p.join(root.path, '子目录B')).createSync();
    // 系统藏起来的那些不该出现（Android 目录、点开头的）
    Directory(p.join(root.path, 'Android')).createSync();
    Directory(p.join(root.path, '.hidden')).createSync();

    File(p.join(root.path, '报告.docx')).writeAsBytesSync(List<int>.filled(2048, 7));
    File(p.join(root.path, '笔记.md')).writeAsStringSync('# 标题');
    File(p.join(root.path, '片子.mp4')).writeAsBytesSync(List<int>.filled(4096, 1));
    File(p.join(root.path, '.DS_Store')).writeAsStringSync('x');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<void> pumpPicker(WidgetTester tester) async {
    tester.view.physicalSize = const Size(430, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: DirectoryPickerPage(startPath: root.path),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('子文件夹和文件都要列出来，文件夹在前', (tester) async {
    await pumpPicker(tester);

    expect(find.text('子目录A'), findsOneWidget);
    expect(find.text('子目录B'), findsOneWidget);
    expect(find.text('报告.docx'), findsOneWidget);
    expect(find.text('笔记.md'), findsOneWidget);
    expect(find.text('片子.mp4'), findsOneWidget);

    // 文件夹排在文件前面：选目录时最常干的事是往里走。
    final dirY = tester.getCenter(find.text('子目录A')).dy;
    final fileY = tester.getCenter(find.text('报告.docx')).dy;
    expect(dirY, lessThan(fileY));
  });

  testWidgets('系统藏起来的目录和文件不出现', (tester) async {
    await pumpPicker(tester);

    expect(find.text('Android'), findsNothing);
    expect(find.text('.hidden'), findsNothing);
    expect(find.text('.DS_Store'), findsNothing);
  });

  testWidgets('文件行带大小，且点不进去', (tester) async {
    await pumpPicker(tester);

    // 2048 字节 → 2 KB
    expect(find.text('2 KB'), findsOneWidget);

    await tester.tap(find.text('报告.docx'));
    await tester.pumpAndSettle();
    // 还在原目录，路径栏没变
    expect(find.text(root.path), findsOneWidget);
    expect(find.text('子目录A'), findsOneWidget);
  });

  testWidgets('点文件夹能进去，再点向上能回来', (tester) async {
    await pumpPicker(tester);

    await tester.tap(find.text('子目录A'));
    await tester.pumpAndSettle();
    expect(find.text(p.join(root.path, '子目录A')), findsOneWidget);
    // 空目录里既没有子文件夹也没有文件
    expect(find.textContaining('这个文件夹是空的'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();
    expect(find.text(root.path), findsOneWidget);
    expect(find.text('报告.docx'), findsOneWidget);
  });
}
