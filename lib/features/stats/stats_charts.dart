/// 统计页用的各种图表。
///
/// 全部基于 fl_chart 自绘，不引入额外依赖。
/// 每个图表都尽量提供多种画法，让用户自己挑顺眼的。
library;

import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/material.dart';

import '../../core/motion/app_motion.dart';
import '../../core/theme/app_theme.dart';
import '../../data/repositories/stats_repository.dart';

part 'stats_heatmap.dart';
part 'stats_small_charts.dart';
part 'stats_share_chart.dart';
part 'stats_trend_chart.dart';

