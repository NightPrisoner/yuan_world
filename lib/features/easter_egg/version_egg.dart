/// 版本号彩蛋。照着安卓那一套来：
///
///   1. 在设置里连点「版本」几下 —— 每点一下有一点点反馈，但不告诉你还差几次
///   2. 全屏弹出一个大字标，背后放射光，底下是慢慢转的星海
///   3. 长按（或点一下）进去：安卓是个小游戏，这里是个小玩具 ——
///      你开着一艘小飞船，在星海里捡**你自己笔记标题里的字**
///
/// 为什么是"捡自己的字"：这是个笔记软件，没有比把自己写过的东西
/// 变成星星更贴题的彩蛋了。捡到的字会排在上面，攒成一句你自己的话。
///
/// 实现上只有**一个 CustomPaint + 一个 Ticker**：不建 per-粒子 widget。
/// 彩蛋也要守性能规矩，不然它就成了全 app 最卡的地方。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/motion/app_motion.dart';
import '../../core/theme/app_theme.dart';

/// 连点几下才出现。安卓是 3 下（开发者选项那套是 7 下），这里取 3。
const int kEggTapCount = 3;

/// 打开彩蛋。
Future<void> showVersionEgg(
  BuildContext context, {
  required String version,
  List<String> words = const <String>[],
}) => Navigator.of(context).push(
  PageRouteBuilder<void>(
    opaque: true,
    transitionDuration: AppMotion.page,
    reverseTransitionDuration: AppMotion.page,
    pageBuilder: (_, _, _) =>
        VersionEggPage(version: version, words: words),
    transitionsBuilder: (_, anim, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: anim, curve: AppMotion.enter),
      child: child,
    ),
  ),
);

/// 从一堆标题里挑出可以用来捡的字。
///
/// 只留汉字，去重，太长的标题不整句用（飘在星海里会糊成一团）。
List<String> harvestCharacters(Iterable<String> titles, {int limit = 220}) {
  final seen = <String>{};
  final out = <String>[];
  for (final t in titles) {
    for (final r in t.runes) {
      if (out.length >= limit) return out;
      final ch = String.fromCharCode(r);
      if (!_isHan(ch)) continue;
      if (seen.add(ch)) out.add(ch);
    }
  }
  return out;
}

bool _isHan(String ch) {
  final r = ch.runes.first;
  return (r >= 0x4E00 && r <= 0x9FFF) || (r >= 0x3400 && r <= 0x4DBF);
}

class VersionEggPage extends StatefulWidget {
  const VersionEggPage({super.key, required this.version, this.words = const <String>[]});

  final String version;

  /// 可以从星海里捡的字（来自用户自己的笔记标题）。
  final List<String> words;

  @override
  State<VersionEggPage> createState() => _VersionEggPageState();
}

class _VersionEggPageState extends State<VersionEggPage>
    with TickerProviderStateMixin {
  /// 0 = 大字标，1 = 星海玩具。中间用同一个 controller 过渡，不切路由。
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 20),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    _loop.dispose();
    super.dispose();
  }

  void _enter() {
    if (_c.value > 0) return;
    HapticFeedback.mediumImpact();
    _c.forward();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF05060A),
      // **两幕的切换必须挂在 AnimatedBuilder 上。**
      //
      // 下面那两个 `if (_c.value ...)` 是在 build 里求值的，而 `_c.forward()`
      // 本身不会触发重建 —— 不包起来的话第一幕永远退不掉、第二幕永远不出现
      // （第一版就是这样，测试直接抓到"长按之后还在第一幕"）。
      body: AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Stack(
          children: [
            // 星海：两幕共用同一层，进场时只是"推近"
            Positioned.fill(
              child: RepaintBoundary(
                child: AnimatedBuilder(
                  animation: Listenable.merge(<Listenable>[_loop, _c]),
                  builder: (context, _) => CustomPaint(
                    painter: _StarfieldPainter(
                      time: _loop.value,
                      zoom: 1 + _c.value * 0.6,
                    ),
                  ),
                ),
              ),
            ),
            // 第一幕：大字标
            if (_c.value < 1)
              Positioned.fill(
                child: IgnorePointer(
                  ignoring: _c.value > 0,
                  child: FadeTransition(
                    opacity: ReverseAnimation(_c),
                    child: _LogoStage(
                      version: widget.version,
                      glow: _loop,
                      onEnter: _enter,
                    ),
                  ),
                ),
              ),
            // 第二幕：飞船
            if (_c.value > 0)
              Positioned.fill(
                child: RepaintBoundary(
                  child: _StarStage(
                    words: widget.words,
                    appear: _c,
                    onExit: () => Navigator.of(context).maybePop(),
                  ),
                ),
              ),
            // 退出按钮：任何时候都能走，别让人困在彩蛋里
            Positioned(
              top: 8,
              right: 8,
              child: SafeArea(
                child: IconButton(
                  tooltip: '离开',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close_rounded),
                  color: Colors.white70,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── 第一幕：大字标 ────────────────────────────────────────────────────────

class _LogoStage extends StatelessWidget {
  const _LogoStage({
    required this.version,
    required this.glow,
    required this.onEnter,
  });

  final String version;
  final Animation<double> glow;
  final VoidCallback onEnter;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onEnter,
      onLongPress: onEnter,
      behavior: HitTestBehavior.opaque,
      child: Center(
        child: AnimatedBuilder(
          animation: glow,
          builder: (context, _) {
            // 呼吸感：0.9 ~ 1.0 来回
            final t = 0.5 + 0.5 * math.sin(glow.value * math.pi * 2);
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 260,
                  height: 260,
                  child: CustomPaint(
                    painter: _RaysPainter(t: glow.value, pulse: t),
                    child: Center(
                      child: ShaderMask(
                        shaderCallback: (r) => const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: <Color>[Color(0xFF8AB4FF), Color(0xFFFFD9A0)],
                        ).createShader(r),
                        child: const Text(
                          '元世界',
                          style: TextStyle(
                            fontSize: 52,
                            height: 1.1,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 2,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '版本 $version',
                  style: AppText.callout.copyWith(color: Colors.white38),
                ),
                const SizedBox(height: 34),
                Opacity(
                  opacity: 0.35 + 0.45 * t,
                  child: Text(
                    '长按进入',
                    style: AppText.footnote.copyWith(
                      color: Colors.white,
                      letterSpacing: 6,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 背后的放射光，像安卓那个大字标。
class _RaysPainter extends CustomPainter {
  _RaysPainter({required this.t, required this.pulse});

  final double t;
  final double pulse;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    // 慢慢转，别转太快晃眼睛
    final spin = t * math.pi / 12;

    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    // 24 道光，长短交替，越外越淡
    for (var i = 0; i < 24; i++) {
      final a = spin + i * math.pi / 12;
      final long = i.isEven;
      final inner = radius * (long ? 0.42 : 0.5);
      final outer = radius * (long ? 0.94 : 0.74) * (0.98 + 0.02 * pulse);
      p
        ..strokeWidth = long ? 2.2 : 1.2
        ..color = Color.lerp(
          const Color(0xFF6EA8FF),
          const Color(0xFFFFC98A),
          (i % 8) / 8,
        )!.withValues(alpha: long ? 0.5 : 0.26);
      canvas.drawLine(
        center + Offset(math.cos(a), math.sin(a)) * inner,
        center + Offset(math.cos(a), math.sin(a)) * outer,
        p,
      );
    }

    // 内圈一层柔光
    canvas.drawCircle(
      center,
      radius * 0.44,
      Paint()
        ..shader = RadialGradient(
          colors: <Color>[
            const Color(0xFF4C7DFF).withValues(alpha: 0.22),
            Colors.transparent,
          ],
        ).createShader(Rect.fromCircle(center: center, radius: radius * 0.44)),
    );
  }

  @override
  bool shouldRepaint(_RaysPainter old) => old.t != t;
}

/// 背景星海。三层视差 + 偶尔一颗流星。
class _StarfieldPainter extends CustomPainter {
  _StarfieldPainter({required this.time, required this.zoom});

  final double time;
  final double zoom;

  /// 固定的伪随机星点。用**固定种子**：每次重绘星星不该乱跳。
  static final List<_Star> _stars = _makeStars();

  static List<_Star> _makeStars() {
    final rnd = math.Random(20260214);
    return <_Star>[
      for (var i = 0; i < 260; i++)
        _Star(
          x: rnd.nextDouble(),
          y: rnd.nextDouble(),
          layer: rnd.nextInt(3),
          phase: rnd.nextDouble() * math.pi * 2,
          size: 0.6 + rnd.nextDouble() * 1.6,
        ),
    ];
  }

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint();
    for (final s in _stars) {
      // 越远的层动得越慢
      final speed = 0.004 + s.layer * 0.007;
      var y = (s.y + time * speed) % 1.0;
      var x = s.x;
      // 进场时"推近"：以中心为原点放大
      if (zoom != 1) {
        x = 0.5 + (x - 0.5) / zoom;
        y = 0.5 + (y - 0.5) / zoom;
      }
      // 闪烁
      final tw = 0.55 + 0.45 * math.sin(s.phase + time * math.pi * 2 * 1.6);
      p.color = Colors.white.withValues(alpha: (0.12 + s.layer * 0.18) * tw);
      canvas.drawCircle(
        Offset(x * size.width, y * size.height),
        s.size,
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_StarfieldPainter old) =>
      old.time != time || old.zoom != zoom;
}

class _Star {
  const _Star({
    required this.x,
    required this.y,
    required this.layer,
    required this.phase,
    required this.size,
  });
  final double x;
  final double y;
  final int layer;
  final double phase;
  final double size;
}

// ── 第二幕：捡字 ──────────────────────────────────────────────────────────

/// 兜底的字。用户还没写过笔记时用这些，别让彩蛋空着。
const List<String> _fallbackWords = <String>[
  '元', '世', '界', '星', '海', '光', '夜', '风', '山', '川',
  '云', '月', '春', '秋', '书', '字', '心', '梦', '远', '行',
];

class _StarStage extends StatefulWidget {
  const _StarStage({
    required this.words,
    required this.appear,
    required this.onExit,
  });

  final List<String> words;
  final Animation<double> appear;
  final VoidCallback onExit;

  @override
  State<_StarStage> createState() => _StarStageState();
}

class _StarStageState extends State<_StarStage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _tick = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat();

  final math.Random _rnd = math.Random();

  /// 飞船位置（0..1 归一化）与目标位置。用插值跟手，别生硬。
  Offset _ship = const Offset(0.5, 0.62);
  Offset _target = const Offset(0.5, 0.62);

  /// 屏幕上飘着的字。
  final List<_Floating> _floaters = <_Floating>[];

  /// 捡到的字（按顺序排在上面）。
  final List<String> _picked = <String>[];

  /// 爆开的粒子。
  final List<_Spark> _sparks = <_Spark>[];

  double _last = 0;

  @override
  void initState() {
    super.initState();
    _tick.addListener(_step);
    // 先摆几个，别让开场空着
    for (var i = 0; i < 6; i++) {
      _spawn(initial: true);
    }
  }

  @override
  void dispose() {
    _tick.removeListener(_step);
    _tick.dispose();
    super.dispose();
  }

  List<String> get _pool =>
      widget.words.isEmpty ? _fallbackWords : widget.words;

  void _spawn({bool initial = false}) {
    _floaters.add(
      _Floating(
        ch: _pool[_rnd.nextInt(_pool.length)],
        x: initial ? _rnd.nextDouble() : (_rnd.nextBool() ? -0.05 : 1.05),
        y: 0.12 + _rnd.nextDouble() * 0.76,
        vy: (_rnd.nextDouble() - 0.5) * 0.03,
        phase: _rnd.nextDouble() * math.pi * 2,
      ),
    );
  }

  void _step() {
    final t = _tick.value;
    var dt = t - _last;
    if (dt < 0) dt += 1; // 回绕
    _last = t;
    // 一帧大约 1/60 秒；用真实帧间隔会让暂停后跳一大步，所以按 tick 计
    final f = (dt * 60).clamp(0.0, 3.0);

    setState(() {
      // 跟手：指数插值，松手也不会飘走
      _ship = Offset.lerp(_ship, _target, 0.12 * f)!;

      for (final o in _floaters) {
        o.y += o.vy * f;
        if (o.y < 0.06) {
          o.y = 0.06;
          o.vy = o.vy.abs();
        }
        if (o.y > 0.9) {
          o.y = 0.9;
          o.vy = -o.vy.abs();
        }
        // 被吸过来：离得近就加速扑向飞船，手感更爽
        final d = (Offset(o.x, o.y) - _ship);
        final dist = d.distance;
        if (dist < 0.16) {
          o.x -= d.dx * 0.16 * f;
          o.y -= d.dy * 0.16 * f;
        }
      }

      // 收字
      final got = <_Floating>[];
      for (final o in _floaters) {
        if ((Offset(o.x, o.y) - _ship).distance < 0.045) got.add(o);
      }
      for (final o in got) {
        _floaters.remove(o);
        _picked.add(o.ch);
        if (_picked.length > 24) _picked.removeAt(0);
        HapticFeedback.selectionClick();
        for (var i = 0; i < 10; i++) {
          final a = _rnd.nextDouble() * math.pi * 2;
          _sparks.add(
            _Spark(
              x: o.x,
              y: o.y,
              vx: math.cos(a) * (0.004 + _rnd.nextDouble() * 0.008),
              vy: math.sin(a) * (0.004 + _rnd.nextDouble() * 0.008),
              life: 1,
            ),
          );
        }
      }

      // 粒子衰减
      for (final s in _sparks) {
        s.x += s.vx * f;
        s.y += s.vy * f;
        s.vx *= 0.94;
        s.vy *= 0.94;
        s.life -= 0.022 * f;
      }
      _sparks.removeWhere((s) => s.life <= 0);

      // 场上保持 6~9 个
      if (_floaters.length < 6) _spawn();
      if (_floaters.length > 9) _floaters.removeLast();
    });
  }

  void _aim(Offset local, Size size) {
    _target = Offset(
      (local.dx / size.width).clamp(0.03, 0.97),
      (local.dy / size.height).clamp(0.06, 0.94),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final size = Size(box.maxWidth, box.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) => _aim(d.localPosition, size),
          onPanUpdate: (d) => _aim(d.localPosition, size),
          onTapDown: (d) => _aim(d.localPosition, size),
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _ToyPainter(
                    floaters: _floaters,
                    sparks: _sparks,
                    ship: _ship,
                    tick: _tick.value,
                  ),
                ),
              ),
              // 捡到的字排在最上面，攒成一句你自己的话
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(56, 18, 56, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _picked.isEmpty
                              ? '拖动飞船，去捡你自己写过的字'
                              : '你捡到了',
                          style: AppText.caption1.copyWith(
                            color: Colors.white38,
                          ),
                        ),
                        const SizedBox(height: 6),
                        if (_picked.isNotEmpty)
                          Text(
                            _picked.join(),
                            style: AppText.title3.copyWith(
                              color: Colors.white,
                              height: 1.4,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Floating {
  _Floating({
    required this.ch,
    required this.x,
    required this.y,
    required this.vy,
    required this.phase,
  });
  final String ch;
  double x;
  double y;
  double vy;
  final double phase;
}

class _Spark {
  _Spark({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.life,
  });
  double x;
  double y;
  double vx;
  double vy;
  double life;
}

/// 飞船 + 飘字 + 粒子 + 尾迹。一张画布画完。
class _ToyPainter extends CustomPainter {
  _ToyPainter({
    required this.floaters,
    required this.sparks,
    required this.ship,
    required this.tick,
  });

  final List<_Floating> floaters;
  final List<_Spark> sparks;
  final Offset ship;
  final double tick;

  @override
  void paint(Canvas canvas, Size size) {
    Offset at(double x, double y) => Offset(x * size.width, y * size.height);

    // ── 飘着的字 ──
    for (final o in floaters) {
      final p = at(o.x, o.y);
      final bob = math.sin(o.phase + tick * math.pi * 2) * 4;
      final tp = TextPainter(
        text: TextSpan(
          text: o.ch,
          style: TextStyle(
            fontSize: 26,
            fontWeight: FontWeight.w600,
            color: Colors.white.withValues(alpha: 0.92),
            shadows: const <Shadow>[
              Shadow(color: Color(0x998AB4FF), blurRadius: 14),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      // 外面一圈光晕，让字看起来是"浮"着的
      canvas.drawCircle(
        p + Offset(0, bob),
        17,
        Paint()
          ..shader = RadialGradient(
            colors: <Color>[
              const Color(0xFF6EA8FF).withValues(alpha: 0.20),
              Colors.transparent,
            ],
          ).createShader(
            Rect.fromCircle(center: p + Offset(0, bob), radius: 17),
          ),
      );
      tp.paint(canvas, p + Offset(-tp.width / 2, -tp.height / 2 + bob));
    }

    // ── 粒子 ──
    for (final s in sparks) {
      canvas.drawCircle(
        at(s.x, s.y),
        2.2 * s.life.clamp(0.0, 1.0) + 0.6,
        Paint()
          ..color = Color.lerp(
            const Color(0xFFFFD9A0),
            const Color(0xFF6EA8FF),
            s.life,
          )!.withValues(alpha: s.life.clamp(0.0, 1.0)),
      );
    }

    // ── 飞船 ──
    final p = at(ship.dx, ship.dy);
    // 尾迹
    canvas.drawCircle(
      p,
      34,
      Paint()
        ..shader = RadialGradient(
          colors: <Color>[
            const Color(0xFF8AB4FF).withValues(alpha: 0.26),
            Colors.transparent,
          ],
        ).createShader(Rect.fromCircle(center: p, radius: 34)),
    );
    final hull = Path()
      ..moveTo(0, -13)
      ..lineTo(9, 10)
      ..lineTo(0, 5)
      ..lineTo(-9, 10)
      ..close();
    canvas.save();
    canvas.translate(p.dx, p.dy);
    canvas.drawPath(
      hull,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[Color(0xFFFFFFFF), Color(0xFF8AB4FF)],
        ).createShader(const Rect.fromLTWH(-10, -14, 20, 26)),
    );
    // 驾驶舱
    canvas.drawCircle(
      const Offset(0, -3),
      2.6,
      Paint()..color = const Color(0xFF1B2A4A),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ToyPainter old) => true;
}
