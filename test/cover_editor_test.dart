/// 头图编辑器面板本身：比例档位、跟随图片、缩放刻度、手机上不许溢出。
///
/// 这一组盯的是"用户在面板里能不能把事做完"：
///   - 九档预设里 9:16 要在（手机拍的竖图）；
///   - 「跟随图片」要能把框型设成图片本身的比例、并且把缩放归 1
///     （否则框型对上了、图还是被放大裁了一刀，等于白设）；
///   - 缩放滑块是**对数刻度**：0.1 到 10 跨两个数量级，线性刻度下
///     0.1~1 这一整段只占不到 10% 的行程，根本点不准；
///   - 390×844 的手机上，「保存」必须在屏幕内（以前会被顶出去）。
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:yuan_world/app_state.dart';
import 'package:yuan_world/core/theme/app_theme.dart';
import 'package:yuan_world/data/db/app_database.dart';
import 'package:yuan_world/data/importer/import_service.dart';
import 'package:yuan_world/data/models.dart';
import 'package:yuan_world/data/repositories/note_repository.dart';
import 'package:yuan_world/features/notes/widgets/cover_picker.dart';

void main() {
  late Directory root;
  late AppDatabase db;
  late AppState state;
  late NoteRepository repo;

  setUp(() async {
    root = Directory.systemTemp.createTempSync('yw_cover_edit_');
    db = AppDatabase.openAt(root.path);
    repo = NoteRepository(db);
    state = AppState(db, repo, ImportService(db, repo));
    await state.init();
  });

  tearDown(() {
    state.dispose();
    db.close();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {
      // Windows 上句柄可能没全放，留着无妨
    }
  });

  /// 一张 3:2 的 PNG（宽 3 高 2）。宽度是真的写进 IHDR 的，
  /// `_loadAspect` 解码出来就是 1.5，用来验证「跟随图片」。
  String addWide(int noteId) {
    final dir = Directory(
      '${db.imageRoot.path}${Platform.pathSeparator}$noteId',
    );
    if (!dir.existsSync()) dir.createSync(recursive: true);
    const bytes = <int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
      0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
      0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x02,
      0x08, 0x02, 0x00, 0x00, 0x00, 0x12, 0x16, 0xF1,
      0x4D, 0x00, 0x00, 0x00, 0x14, 0x49, 0x44, 0x41,
      0x54, 0x78, 0x9C, 0x63, 0x3C, 0x51, 0x61, 0xC3,
      0x00, 0x06, 0x4C, 0x10, 0x8A, 0x81, 0x81, 0x01,
      0x00, 0x1B, 0x80, 0x01, 0x80, 0x15, 0xDA, 0x74,
      0x42, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
      0x44, 0xAE, 0x42, 0x60, 0x82,
    ];
    File('${dir.path}${Platform.pathSeparator}a.png').writeAsBytesSync(bytes);
    return '$noteId/a.png';
  }

  int addNote(String content) => repo.insertNote(
    title: '甲',
    content: content,
    excerpt: content,
    charCount: content.length,
  );

  /// 同一篇里再放一张 3:2 的图（文件名带序号，互不覆盖）。
  String addWide2(int noteId, int index) {
    final dir = Directory(
      '${db.imageRoot.path}${Platform.pathSeparator}$noteId',
    );
    if (!dir.existsSync()) dir.createSync(recursive: true);
    const bytes = <int>[
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
      0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
      0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x02,
      0x08, 0x02, 0x00, 0x00, 0x00, 0x12, 0x16, 0xF1,
      0x4D, 0x00, 0x00, 0x00, 0x14, 0x49, 0x44, 0x41,
      0x54, 0x78, 0x9C, 0x63, 0x3C, 0x51, 0x61, 0xC3,
      0x00, 0x06, 0x4C, 0x10, 0x8A, 0x81, 0x81, 0x01,
      0x00, 0x1B, 0x80, 0x01, 0x80, 0x15, 0xDA, 0x74,
      0x42, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E,
      0x44, 0xAE, 0x42, 0x60, 0x82,
    ];
    File(
      '${dir.path}${Platform.pathSeparator}p$index.png',
    ).writeAsBytesSync(bytes);
    return '$noteId/p$index.png';
  }

  /// 打开编辑器，等图片解码（_loadAspect 是异步的）跑完。
  ///
  /// **必须用 runAsync**：`_loadAspect` 走的是真实的文件 IO + 图片解码，
  /// `pumpAndSettle` 只推假时钟，等不到真 Future —— 不等的话「跟随图片」
  /// 那一档根本还没出现。
  Future<void> openEditor(WidgetTester tester, Note note) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: state,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showCoverPicker(context, note),
                  child: const Text('开'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开'));
    await tester.pump();
    // 解码是**真的文件 IO + 图片解码**，`pumpAndSettle` 只推假时钟等不到它。
    // 用 runAsync 让真实事件循环转起来，再 pump 把落到 FakeAsync 队列里的
    // 回调冲刷出去 —— 两边交替几轮才稳。
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 30));
    }
    await tester.pumpAndSettle();
  }

  /// 点面板里的某个 chip：先滚到可见再点。
  ///
  /// 面板中间那段是 `SingleChildScrollView`（手机上就是这么挤下来的），
  /// 比例行在矮窗口里会落到可视区之外 —— 直接 tap 会点到下面的按钮上。
  Future<void> tapChip(WidgetTester tester, String label) async {
    final finder = find.text(label);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  test('九档预设里包含 9:16 与 3:4', () {
    expect(Note.coverRatioPresets, contains(closeTo(0.5625, 1e-9)));
    expect(Note.coverRatioPresets, contains(closeTo(0.75, 1e-9)));
    expect(Note.coverRatioPresets.length, 7);
  });

  testWidgets('面板上每一档比例都点得到，9:16 点完框真的变竖', (tester) async {
    final rel = addWide(addNote('正文'));
    final note = repo.getNote(repo.listNotes(const NoteFilter()).first.id)!;
    repo.updateNote(id: note.id, coverImage: rel);

    await openEditor(tester, repo.getNote(note.id)!);

    expect(find.text('9:16'), findsOneWidget);
    expect(find.text('跟随图片'), findsOneWidget);
    expect(find.text('自定义'), findsOneWidget);

    await tapChip(tester, '9:16');

    final preview = tester.widget<AspectRatio>(
      find
          .descendant(
            of: find.byKey(const ValueKey<String>('cover-preview')),
            matching: find.byType(AspectRatio),
          )
          .first,
    );
    expect(preview.aspectRatio, closeTo(0.5625, 0.01));
  });

  testWidgets('「跟随图片」把框型设成图片比例，并把缩放归 1', (tester) async {
    final id = addNote('正文');
    final rel = addWide(id);
    repo.updateNote(id: id, coverImage: rel, coverZoom: 2.5);

    await openEditor(tester, repo.getNote(id)!);
    await tester.pumpAndSettle();

    // 先点一个别的比例，确认后面确实被改掉
    await tapChip(tester, '1:1');
    await tapChip(tester, '跟随图片');

    final preview = tester.widget<AspectRatio>(
      find
          .descendant(
            of: find.byKey(const ValueKey<String>('cover-preview')),
            matching: find.byType(AspectRatio),
          )
          .first,
    );
    expect(preview.aspectRatio, closeTo(1.5, 0.02), reason: '3:2 的图应该变成 1.5');

    final scale = tester.widget<Transform>(
      find
          .descendant(
            of: find.byKey(const ValueKey<String>('cover-preview')),
            matching: find.byType(Transform),
          )
          .first,
    );
    expect(scale.transform.getMaxScaleOnAxis(), closeTo(1.0, 1e-6));

    // 存进去也要是 1.5 与 1.0
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final saved = repo.getNote(id)!;
    expect(saved.coverRatio, closeTo(1.5, 0.02));
    expect(saved.coverZoom, closeTo(1.0, 1e-6));
  });

  testWidgets('缩放滑块是对数刻度：0.1 与 10 在两头，1 落在中间偏左', (tester) async {
    final id = addNote('正文');
    final rel = addWide(id);
    repo.updateNote(id: id, coverImage: rel);

    await openEditor(tester, repo.getNote(id)!);

    // 缩放行在滚动区里，先滚到可见
    await tester.ensureVisible(find.byType(Slider).first);
    await tester.pumpAndSettle();

    final slider = tester.widget<Slider>(find.byType(Slider).first);
    // 初值 1.0 落在对数刻度的正中间：log(1/0.1) / log(10/0.1) = 1/2。
    // 线性刻度下这个位置会是 1/9.9 —— 差得很远，这条就是在钉"对数"。
    expect(slider.value, closeTo(0.5, 1e-6));

    // 拖到最左 = 0.1×（读数有两处：预览角标 + 滑块右侧，所以用 findsWidgets）
    slider.onChanged!(0.0);
    await tester.pumpAndSettle();
    expect(find.text('0.10×'), findsWidgets);

    // 拖到最右 = 10×
    final slider2 = tester.widget<Slider>(find.byType(Slider).first);
    slider2.onChanged!(1.0);
    await tester.pumpAndSettle();
    expect(find.text('10.00×'), findsWidgets);
  });

  testWidgets('手机上（390×844）面板不溢出，「保存」在屏幕里', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final id = addNote('正文');
    // **带上一整条候选图**：这才是用户看到的常态（正文里有图）。
    // 只有一张图时图片条很窄，什么都能塞下，测不出"藏起来"。
    final rels = <String>[for (var i = 0; i < 6; i++) addWide2(id, i)];
    final content = <String>[
      '正文',
      for (final rel in rels) '![]($rel)',
    ].join('\n\n');
    repo.updateNote(id: id, content: content, coverImage: rels.first);

    await openEditor(tester, repo.getNote(id)!);
    await tester.pumpAndSettle();

    // **「缩放」不许藏。** 用户的原话是"缩放怎么藏起来了？所有功能不要藏"。
    // 一进来（还没滚动、也没展开自定义）它就必须在屏幕里 —— 之前排在
    // 候选图之后，一屏装不下就被滚出视野，看起来像功能没了。
    final scroll = find.byType(SingleChildScrollView).first;
    final scrollable = find
        .descendant(of: scroll, matching: find.byType(Scrollable))
        .first;
    expect(
      tester.state<ScrollableState>(scrollable).position.pixels,
      0.0,
      reason: '一进来就在顶部',
    );

    final zoom = tester.getRect(
      find.byKey(const ValueKey<String>('cover-zoom')),
    );
    expect(
      zoom.bottom,
      lessThanOrEqualTo(844.0),
      reason: '「缩放」这一行必须一进来就看得见，不能要滚动才出现',
    );
    expect(zoom.top, greaterThanOrEqualTo(0.0));
    expect(
      find.byKey(const ValueKey<String>('cover-ratio-row')),
      findsOneWidget,
      reason: '比例那一排同理，一起放在看得见的地方',
    );

    // 再把自定义展开（最长的那种状态）：不许溢出，按钮也不许被挤出屏幕。
    await tapChip(tester, '自定义');

    expect(tester.takeException(), isNull);

    final save = tester.getRect(find.text('保存'));
    expect(save.bottom, lessThanOrEqualTo(844.0));
    expect(save.top, greaterThanOrEqualTo(0.0));
  });

  testWidgets('正文里的图片很多时，横向一条能滑到最后一张', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // 八张图：手机宽度下一条只放得下三张多，剩下的必须靠滑。
    // 候选图是从**正文**里取的（splitBodySegments），所以正文必须真的
    // 写着这八行 `![](路径)` —— 只往磁盘上放文件，面板里一张都不会有。
    final id = addNote('正文');
    final rels = <String>[for (var i = 0; i < 8; i++) addWide2(id, i)];
    final content = <String>[
      '正文',
      for (final rel in rels) '![]($rel)',
    ].join('\n\n');
    repo.updateNote(id: id, content: content, coverImage: rels.first);

    await openEditor(tester, repo.getNote(id)!);
    await tester.pumpAndSettle();

    expect(find.textContaining('正文里的图片（8）'), findsOneWidget);
    // 图片多了要提示能滑
    expect(find.text('左右滑'), findsOneWidget);

    // 最后一张一开始连建都没建（ListView 懒加载），滑过去才会出现 ——
    // 这本身就是"能滑"的最硬证据。
    final last = find.byKey(ValueKey<String>(rels.last));
    expect(last, findsNothing, reason: '八张图里最后一张不该一开始就在视野里');

    await tester.drag(
      find.byKey(const ValueKey<String>('cover-strip')),
      const Offset(-400, 0),
    );
    await tester.pumpAndSettle();
    expect(last, findsOneWidget, reason: '横向条必须真的能滑，最后一张要能滑出来');
    final rect = tester.getRect(last);
    expect(rect.left, lessThan(390.0), reason: '最后一张要滑进屏幕');
  });

  testWidgets('桌面端：鼠标按住能拖动那条图片', (tester) async {
    // 窗口给足高度，让图片条整个落在可视区里 —— 这里要验的是"鼠标
    // 拖不拖得动"，不是"面板能不能滚"，两件事分开测才不会互相干扰。
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final id = addNote('正文');
    final rels = <String>[for (var i = 0; i < 8; i++) addWide2(id, i)];
    final content = <String>[
      '正文',
      for (final rel in rels) '![]($rel)',
    ].join('\n\n');
    repo.updateNote(id: id, content: content, coverImage: rels.first);

    await openEditor(tester, repo.getNote(id)!);
    await tester.pumpAndSettle();

    // **桌面端的真问题**：Flutter 默认的 ScrollBehavior 在桌面上不把
    // 鼠标算作拖动设备，鼠标按住拖不动任何列表 —— 手机上看着好好的，
    // Windows 上就像"滑不了"。这里用鼠标手势真的拖一次，钉住它。
    final last = find.byKey(ValueKey<String>(rels.last));
    expect(last, findsNothing, reason: '八张图最后一张一开始在视野外');

    final strip = find.byKey(const ValueKey<String>('cover-strip'));
    await tester.drag(
      strip,
      const Offset(-400, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(last, findsOneWidget, reason: '鼠标按住拖，必须也能把后面的图拖出来');
  });

  testWidgets('桌面端：鼠标按住也能把面板内容往上拖', (tester) async {
    // 这一条专门压矮窗口：内容真的溢出，纵向滚动才谈得上"能不能拖"。
    tester.view.physicalSize = const Size(1400, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final id = addNote('正文');
    final rel = addWide(id);
    repo.updateNote(id: id, coverImage: rel);

    await openEditor(tester, repo.getNote(id)!);
    await tester.pumpAndSettle();

    final preview = find.byKey(const ValueKey<String>('cover-preview'));
    final previewRect = tester.getRect(preview);
    final topBefore = previewRect.top;

    // 先确认"真的能滚"：内容没溢出的话，拖动本来就不该有位移，
    // 那种情况下量到的 0 不是 bug 而是这条用例自己没造出场景。
    final scroll = find.byType(SingleChildScrollView).first;
    final scrollable = find
        .descendant(of: scroll, matching: find.byType(Scrollable))
        .first;
    final position = tester.state<ScrollableState>(scrollable).position;
    expect(position.maxScrollExtent, greaterThan(40), reason: '内容要真的溢出');

    // **落点必须避开预览**：预览上那层手势专门抢拖动来调取景，从它上面
    // 拖本来就不该滚页面（那是另一条测试钉的事）。这里取预览正下方一点，
    // 那里是候选图/比例那一带，是纯粹的滚动区域。
    final viewport = tester.getRect(scroll);
    final y = math.min(previewRect.bottom + 12, viewport.bottom - 12);
    expect(y, greaterThan(previewRect.bottom), reason: '落点要在预览之外');

    await tester.dragFrom(
      Offset(viewport.center.dx, y),
      const Offset(0, -120),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      position.pixels,
      greaterThan(20),
      reason: '鼠标按住往上拖，面板内容要跟着滚，不是纹丝不动',
    );
    expect(tester.getRect(preview).top, lessThan(topBefore - 20));
  });

  testWidgets('在预览上拖动取景时，整页不跟着上下滚', (tester) async {
    // 故意用一个矮一点的窗口：内容确实溢出、中间那段真的能滚，
    // 才谈得上"滚不滚"。844 高时内容刚好放得下，两个断言都会假通过。
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final id = addNote('正文');
    final rel = addWide(id);
    repo.updateNote(id: id, coverImage: rel, coverFocusY: 0);

    await openEditor(tester, repo.getNote(id)!);
    await tester.pumpAndSettle();

    double focusY() => repo.getNote(id)!.coverFocusY;

    // 取景值体现在 Transform 的 alignment 上（不是 matrix —— zoom=1 时
    // 缩放矩阵恒为单位阵，量矩阵永远量不出变化）。
    Alignment previewAlign() =>
        tester
                .widget<Transform>(
                  find
                      .descendant(
                        of: find.byKey(
                          const ValueKey<String>('cover-preview'),
                        ),
                        matching: find.byType(Transform),
                      )
                      .first,
                )
                .alignment
            as Alignment;

    final before = previewAlign();
    final beforeRect = tester.getRect(
      find.byKey(const ValueKey<String>('cover-preview')),
    );
    // 在预览上竖直拖 60px
    final preview = find.byKey(const ValueKey<String>('cover-preview'));
    await tester.drag(preview, const Offset(0, -60));
    await tester.pumpAndSettle();

    // 取景跟着动了（说明拖动确实落在预览上，没被页面滚动吃掉）
    expect(previewAlign(), isNot(equals(before)));
    expect(focusY(), 0, reason: '没点保存，库里不该变');

    // 页面本身没被滚走：预览还在原处
    final afterRect = tester.getRect(
      find.byKey(const ValueKey<String>('cover-preview')),
    );
    expect(
      afterRect.top,
      closeTo(beforeRect.top, 0.5),
      reason: '在预览上拖动取景时，整页不许跟着上下滚',
    );

    // 反过来：手指不在预览上时，页面照常能滚。
    //
    // 这里不靠"拖一下看滚不滚"（矮窗口里滚动区很浅，落点稍有偏差就点到
    // 别的控件上，测出来是假红），直接看物理量：按下时切成不可滚、
    // 抬手后换回可滚 —— 这才是页面能不能滚的真正开关。
    ScrollPhysics physicsNow() =>
        tester
                .widget<SingleChildScrollView>(
                  find.byType(SingleChildScrollView).first,
                )
                .physics
            as ScrollPhysics;

    final g = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey<String>('cover-preview'))),
    );
    await tester.pump();
    expect(
      physicsNow(),
      isA<NeverScrollableScrollPhysics>(),
      reason: '手指按在预览上时，整页必须锁住',
    );
    await g.up();
    await tester.pumpAndSettle();
    expect(
      physicsNow(),
      isA<ClampingScrollPhysics>(),
      reason: '抬手之后别的地方要能正常上下翻',
    );
  });

  testWidgets('「恢复默认显示」不用滚动就能看见', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final id = addNote('正文');
    final rel = addWide(id);
    // 先让它"有改动"，按钮才可点
    repo.updateNote(id: id, coverImage: rel, coverRatio: 1.0);

    await openEditor(tester, repo.getNote(id)!);
    await tester.pumpAndSettle();

    final finder = find.text('恢复默认显示');
    expect(finder, findsOneWidget);
    final rect = tester.getRect(finder);
    expect(
      rect.bottom,
      lessThanOrEqualTo(844.0),
      reason: '救急按钮不该藏在滚动区最底下',
    );
    expect(rect.top, greaterThanOrEqualTo(0.0));
  });

  // ── 拖动取景：手指按住的那个点要待在原地 ─────────────────────────────
  //
  // 用户 m280786：「头图编辑里调整位置会有偏移（就是移动开始时某个点在
  // 图片的位置在移动后不要变）」。以前灵敏度是 `delta / 面板宽度 * 2`，
  // 拿面板宽度当基准、系数写死 —— 图一放大，画面走的距离和手指完全不成
  // 比例，按住某个点往右拖，那个点就滑走了。
  //
  // 这里必须挑两个"面板宽度 ≠ 可挪余量"的缩放值：
  //   - 放大 4 倍：可挪余量是面板宽的三倍，旧公式会让画面走 120px；
  //   - 缩到 0.5 倍：可挪余量只有面板宽的一半，旧公式只走 20px。
  // 只有这两个值能把"按手指走"和"按面板宽度走"分开 —— 1.5/2 倍时两者
  // 恰好接近，测不出区别。
  for (final zoom in <double>[4.0, 0.5]) {
    testWidgets('取景拖动跟手指走，不会打滑（$zoom×）', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final id = addNote('正文');
      final rel = addWide(id);
      repo.updateNote(
        id: id,
        coverImage: rel,
        coverRatio: 1.6,
        coverZoom: zoom,
        coverFocusX: 0,
        coverFocusY: 0,
      );

      await openEditor(tester, repo.getNote(id)!);
      await tester.pumpAndSettle();

      Alignment align() =>
          tester
                  .widget<Transform>(
                    find
                        .descendant(
                          of: find.byKey(
                            const ValueKey<String>('cover-preview'),
                          ),
                          matching: find.byType(Transform),
                        )
                        .first,
                  )
                  .alignment
              as Alignment;

      final preview = find.byKey(const ValueKey<String>('cover-preview'));
      final rect = tester.getRect(preview);
      final before = align();

      await tester.drag(preview, const Offset(40, 0));
      await tester.pumpAndSettle();

      final after = align();
      expect(
        after.x,
        isNot(closeTo(before.x, 1e-6)),
        reason: '拖动没生效',
      );

      // 画面在屏幕上挪了多远：alignment.x 从 -1 到 1 扫过的是可挪余量
      // |frameW - imgW*zoom|，所以位移 = Δx / 2 × 余量。这个位移必须
      // 约等于手指的 40px。
      final frameW = rect.width;
      const imgAspect = 1.5; // addWide 是 3:2
      final imgW = (rect.height * imgAspect > frameW)
          ? rect.height * imgAspect
          : frameW;
      final denX = (frameW - imgW * zoom).abs();
      final moved = (after.x - before.x).abs() / 2 * denX;
      expect(
        moved,
        closeTo(40, 40 * 0.15),
        reason: '画面走了 $moved px，手指走了 40px（余量 $denX）',
      );
    });
  }
}
