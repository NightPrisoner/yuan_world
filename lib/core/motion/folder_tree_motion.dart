import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_motion.dart';

/// Shared folder behavior. Each subtree owns its completion timer so toggling
/// another folder cannot strand rows halfway through a collapse.
class FolderTreeMotion extends ChangeNotifier {
  static const duration = Duration(milliseconds: 200);
  static const stagger = Duration(milliseconds: 28);
  static const maxStagger = 8;

  final Set<int> collapsed = {};
  final Map<int, _FolderTransition> _pending = {};
  final Map<int, Timer> _timers = {};

  Set<int> get collapsing => {
    for (final entry in _pending.entries)
      if (!entry.value.opening) entry.key,
  };

  Map<int, int> get revealOrder => {
    for (final transition in _pending.values)
      for (var i = 0; i < transition.rows.length; i++)
        transition.rows[i]: transition.opening
            ? i
            : transition.rows.length - i - 1,
  };

  void toggle(int id, List<int> descendants, {required bool reduceMotion}) {
    final opening = collapsed.contains(id) || collapsing.contains(id);
    // An ancestor takes over the descendants' reveal; unrelated trees continue.
    for (final root in _pending.keys.toList()) {
      if (root != id && !descendants.contains(root)) continue;
      final previous = _pending.remove(root)!;
      _timers.remove(root)?.cancel();
      if (!previous.opening && root != id) collapsed.add(root);
    }
    if (opening) collapsed.remove(id);
    if (reduceMotion) {
      settle();
      if (!opening) collapsed.add(id);
      notifyListeners();
      return;
    }
    if (descendants.isEmpty) {
      if (!opening) collapsed.add(id);
      notifyListeners();
      return;
    }
    _pending[id] = _FolderTransition(opening, List.of(descendants));
    final last = math.min(descendants.length - 1, maxStagger);
    _timers[id] = Timer(duration + stagger * last, () {
      final transition = _pending.remove(id);
      _timers.remove(id);
      if (transition != null && !transition.opening) collapsed.add(id);
      notifyListeners();
    });
    notifyListeners();
  }

  void settle() {
    for (final root in collapsing) {
      collapsed.add(root);
    }
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _pending.clear();
  }

  @override
  void dispose() {
    settle();
    super.dispose();
  }
}

class _FolderTransition {
  const _FolderTransition(this.opening, this.rows);
  final bool opening;
  final List<int> rows;
}

/// Both folder views use the same local motion, while their layouts and page
/// transitions remain independent.
class FolderTreeReveal extends StatefulWidget {
  const FolderTreeReveal({
    super.key,
    required this.child,
    this.order,
    this.exiting = false,
  });

  final Widget child;
  final int? order;
  final bool exiting;

  @override
  State<FolderTreeReveal> createState() => _FolderTreeRevealState();
}

class _FolderTreeRevealState extends State<FolderTreeReveal>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: FolderTreeMotion.duration,
    value: widget.order == null ? 1 : 0,
  );
  Timer? _delay;

  void _schedule() {
    _delay?.cancel();
    final rank = math.min(widget.order ?? 0, FolderTreeMotion.maxStagger);
    void run() {
      if (!mounted) return;
      widget.exiting ? _controller.reverse() : _controller.forward();
    }

    if (rank == 0) {
      run();
    } else {
      _delay = Timer(FolderTreeMotion.stagger * rank, run);
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.order != null) _schedule();
  }

  @override
  void didUpdateWidget(covariant FolderTreeReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.exiting != oldWidget.exiting ||
        widget.order != oldWidget.order) {
      if (widget.order == null && !widget.exiting) {
        _delay?.cancel();
        _controller.value = 1;
      } else {
        // Reverse from the current frame, never reset an already visible row.
        _schedule();
      }
    }
  }

  @override
  void dispose() {
    _delay?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (AppMotion.reduceMotion(context)) return widget.child;
    return IgnorePointer(
      ignoring: widget.exiting,
      child: AnimatedBuilder(
        animation: _controller,
        child: widget.child,
        builder: (context, child) {
          final t = AppMotion.enter.transform(_controller.value);
          return ClipRect(
            child: Align(
              alignment: Alignment.topLeft,
              heightFactor: t,
              child: Opacity(
                opacity: t.clamp(0.0, 1.0),
                child: Transform.translate(
                  offset: Offset(-10 * (1 - t), 0),
                  child: child,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
