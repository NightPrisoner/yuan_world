/// 进出隐私空间的一层过渡。
///
/// 为什么要有：隐私空间不是"另一个页面"，它是同一条列表换了数据源 ——
/// 点下去的一瞬间标题、笔记、文集全变，看起来像界面抽了一下。
/// 这一层用一把锁把那一帧盖住：遮罩升起 → 锁出现 → 遮罩退去，
/// 露出的是新的内容。既遮住了换数据的瞬间，也给了"进了一个不一样的地方"
/// 的仪式感。
///
/// 只做前台表演，不碰数据 —— 数据切换仍然是 `state.enterPrivacyMode()` 干的。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../core/motion/app_motion.dart';
import '../../core/theme/app_theme.dart';

/// 播一次过渡。`entering = true` 是进隐私空间，false 是出去。
///
/// 开了"减弱动态效果"就直接跳过 —— 没动画比慢动作好。
Future<void> showPrivacyTransition(
  BuildContext context, {
  required bool entering,
}) async {
  if (AppMotion.reduceMotion(context)) return;
  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierLabel: entering ? '进入隐私空间' : '离开隐私空间',
    barrierColor: Colors.transparent,
    transitionDuration: Duration.zero,
    useRootNavigator: true,
    pageBuilder: (_, _, _) => _PrivacyGate(entering: entering),
  );
}

/// 退出隐私空间：先盖遮罩、再换数据。
///
/// 所有退出入口（手机胶囊、桌面侧栏、设置页）都走这一个函数，
/// 免得哪一处忘了加过渡、看起来跟别处不一样。
Future<void> leavePrivacySpace(BuildContext context) async {
  final state = context.read<AppState>();
  final done = showPrivacyTransition(context, entering: false);
  state.exitPrivacyMode();
  await done;
}

class _PrivacyGate extends StatefulWidget {
  const _PrivacyGate({required this.entering});

  final bool entering;

  @override
  State<_PrivacyGate> createState() => _PrivacyGateState();
}

class _PrivacyGateState extends State<_PrivacyGate>
    with SingleTickerProviderStateMixin {
  // 620ms：比页面转场（380）长一点，因为这里要"看清你是谁"，
  // 但又不能长到让人等。
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 620),
  );

  @override
  void initState() {
    super.initState();
    _c.forward().whenComplete(() {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Material(
      color: Colors.transparent,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          final t = _c.value;

          // 遮罩：前 38% 升起，后 26% 退去，中间停住让锁露个脸
          double veil;
          if (t < 0.38) {
            veil = AppMotion.enter.transform(t / 0.38);
          } else if (t > 0.74) {
            veil = 1 - AppMotion.exit.transform((t - 0.74) / 0.26);
          } else {
            veil = 1;
          }

          // 锁：稍晚一点出现，跟着遮罩一起退
          final lockIn = ((t - 0.10) / 0.34).clamp(0.0, 1.0);
          final lockOut = ((t - 0.62) / 0.16).clamp(0.0, 1.0);
          final lockT = AppMotion.enter.transform(lockIn) * (1 - lockOut);

          return Stack(
            children: [
              Positioned.fill(
                child: ColoredBox(
                  color: c.groupedBackground.withValues(alpha: veil),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: Opacity(
                    opacity: lockT,
                    child: Transform.scale(
                      // 从 0.86 长到 1，收的时候不收（跟着淡出）
                      scale: 0.86 + 0.14 * AppMotion.enter.transform(lockIn),
                      child: Transform.translate(
                        offset: Offset(0, -10 * lockOut),
                        child: Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 62,
                                height: 62,
                                decoration: BoxDecoration(
                                  color: c.palette[6].withValues(alpha: 0.14),
                                  borderRadius:
                                      BorderRadius.circular(AppMetrics.radiusLg),
                                ),
                                child: Icon(
                                  widget.entering
                                      ? Icons.lock_rounded
                                      : Icons.lock_open_rounded,
                                  size: 30,
                                  color: c.palette[6],
                                ),
                              ),
                              const SizedBox(height: 14),
                              Text(
                                widget.entering ? '隐私空间' : '已离开隐私空间',
                                style: AppText.callout.copyWith(
                                  color: c.secondaryLabel,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
