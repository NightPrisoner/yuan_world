import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:provider/provider.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'app_state.dart';
import 'core/app_localization.dart';
import 'core/app_paths.dart';
import 'core/media/poster_maker.dart';
import 'core/theme/app_theme.dart';
import 'data/db/app_database.dart';
import 'data/importer/import_service.dart';
import 'data/repositories/note_repository.dart';
import 'features/notes/editor/note_editor_page.dart';
import 'features/shell/home_shell.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // media_kit 必须在用任何播放器之前初始化，否则一开视频就崩
  MediaKit.ensureInitialized();

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await _setupDesktopWindow();
  }

  final db = AppDatabase.openAt(await resolveAppRoot());
  final repo = NoteRepository(db);
  final importer = ImportService(db, repo);
  final state = AppState(db, repo, importer);
  await state.init();

  final navKey = GlobalKey<NavigatorState>();

  runApp(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: YuanWorldApp(navigatorKey: navKey),
    ),
  );

  if (kDebugMode) _maybeOpenEditorForTesting(navKey);
  if (kDebugMode) _maybeMakePosterProbe();

  // 每日自动快照：放在界面已经可用之后跑。它只拷数据库（几兆），
  // 而且内部自己吞掉异常 —— 备份失败绝不能挡住启动。
  state.snapshotIfDue();
}

/// 调试用：`YW_MAKE_POSTER=<视频绝对路径>` 抓一帧存成 PNG 然后退出。
///
/// 和 `YW_EDIT_NOTE` 一个道理：抓首帧这条路只有真 exe 里能跑通
/// （测试环境没有 libmpv），留个钩子才能验证它到底行不行。
///
/// **必须等到界面起来之后再抓**：`VideoController` 自己就是靠
/// "下一帧"（`addPostFrameCallback`）去创建原生画面输出的，
/// 在 `runApp` 之前建会永远等不到那一帧（实测直接卡死在 `open()`）。
void _maybeMakePosterProbe() {
  final path = Platform.environment['YW_MAKE_POSTER'];
  if (path == null || path.isEmpty) return;
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    final poster = PosterMaker.posterNameFor(path);
    stdout.writeln('YW_MAKE_POSTER 开始：$path');
    final ok = await PosterMaker.make(videoPath: path, posterPath: poster)
        .timeout(const Duration(seconds: 50), onTimeout: () {
      stdout.writeln('YW_MAKE_POSTER 超时（50 秒还没抓完）');
      return false;
    });
    stdout.writeln('YW_MAKE_POSTER ok=$ok poster=$poster');
    exit(0);
  });
}

/// 调试用：`YW_EDIT_NOTE=<笔记id>` 启动后直接进入该笔记的编辑器。
///
/// 纯 GUI 应用在自动化里很难"点"到深层页面（本机还禁止了合成输入），
/// 这个钩子让截图验证编辑器这类页面变得可行。仅 debug 构建生效。
void _maybeOpenEditorForTesting(GlobalKey<NavigatorState> navKey) {
  final id = int.tryParse(Platform.environment['YW_EDIT_NOTE'] ?? '');
  if (id == null) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    navKey.currentState?.push(
      MaterialPageRoute<void>(builder: (_) => NoteEditorPage(noteId: id)),
    );
  });
}

/// 桌面端窗口初始化。
///
/// 这里有个坑：`WindowOptions.size` 是**逻辑像素**，而屏幕尺寸拿到的也是逻辑像素，
/// 但两者一旦不一致（高分屏缩放、多显示器、Windows 的 DPI 虚拟化），
/// 直接写死 1180×800 就可能生成一个**比屏幕还大**的窗口，
/// 导致侧边栏底部、工具栏右侧被推到屏幕外，用户根本点不到。
///
/// 所以这里按主显示器的可用尺寸做钳制，保证窗口一定能完整显示。
Future<void> _setupDesktopWindow() async {
  await windowManager.ensureInitialized();

  var width = 1180.0;
  var height = 800.0;
  try {
    final display = await screenRetriever.getPrimaryDisplay();
    final sw = display.size.width;
    final sh = display.size.height;
    if (sw > 0 && sh > 0) {
      // 留出任务栏与窗口边框的余量
      width = math.min(width, sw * 0.86);
      height = math.min(height, sh * 0.86);
    }
  } catch (_) {
    // 拿不到屏幕信息就退回默认尺寸
  }

  final opts = WindowOptions(
    size: Size(width, height),
    minimumSize: const Size(420, 560),
    center: true,
    title: '元世界',
    titleBarStyle: TitleBarStyle.normal,
    backgroundColor: Colors.transparent,
  );
  await windowManager.waitUntilReadyToShow(opts, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}

/// 是否显示 Flutter 的性能叠加层（右上角那两个条：UI 线程 / 光栅线程）。
///
/// 编译期开关：`flutter build apk --profile --dart-define=YW_PERF=true`。
/// 平时不编译进去，所以对用户零成本；要量"到底卡在哪一段"时再打开，
/// 截图就能看到 UI / raster 各占多少毫秒。
const bool kShowPerfOverlay = bool.fromEnvironment('YW_PERF');

class YuanWorldApp extends StatelessWidget {
  const YuanWorldApp({super.key, this.navigatorKey});

  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return MaterialApp(
      title: '元世界',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      // 框架自带的文案（框选后的剪切/复制/粘贴/全选、日期选择器、
      // 无障碍标签）必须显式接上中文，否则跟随系统语言 —— 英文系统上
      // 就是英文。定义在 core/app_localization.dart，测试拿的是同一份常量。
      locale: kAppLocale,
      supportedLocales: kAppSupportedLocales,
      localizationsDelegates: kAppLocalizationsDelegates,
      // 只有带 --dart-define=YW_PERF=true 的构建才有，见 kShowPerfOverlay
      showPerformanceOverlay: kShowPerfOverlay,
      themeMode: state.themeMode,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      // 字号缩放放在这里一处生效：不改 AppText 里的每个字号，
      // 也让第三方组件（对话框、滚轮、Toast）跟着一起缩放。
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        minScaleFactor: state.textScale,
        maxScaleFactor: state.textScale,
        child: child ?? const SizedBox.shrink(),
      ),
      home: const _Bootstrap(),
    );
  }
}

/// 等待数据库加载完成，加载期间显示启动态。
class _Bootstrap extends StatelessWidget {
  const _Bootstrap();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    if (state.loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
      );
    }
    return const HomeShell();
  }
}
