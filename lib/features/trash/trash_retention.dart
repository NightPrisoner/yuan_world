/// 回收站「保留多久」的选择器。
///
/// 这条设置有两个入口：回收站页面顶部那行小字，和设置页「回收站」那一行
/// 尾巴上的胶囊。逻辑只有一份，放这里给两边共用 —— 之前是各写一遍，
/// 改的时候很容易只改一处。
library;

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/app_menu.dart';
import '../../data/repositories/note_repository.dart';

/// 可选的保留天数。0 = 永不自动清理。
const List<int> kTrashRetentionOptions = <int>[0, 7, 14, 30, 60, 90, 180];

/// 弹菜单选保留天数。0 = 永不清理。
Future<void> pickTrashRetention(BuildContext context, AppState state) async {
  final current = state.trashRetentionDays;
  final picked = await showAppMenu<int>(
    context,
    header: '回收站保留多久',
    anchor: AppMenuAnchor(context: context),
    items: <AppMenuItem<int>>[
      for (final d in kTrashRetentionOptions)
        AppMenuItem(
          value: d,
          label: d == 0 ? '一直不删，手动清理' : '$d 天',
          icon: d == current ? Icons.check_circle_rounded : Icons.circle_outlined,
          color: d == current ? context.colors.tint : null,
        ),
    ],
  );
  if (picked == null || !context.mounted) return;
  state.setTrashRetentionDays(picked);
  // 改成更短的保留期，当场就把超期的清掉 —— 否则用户以为立刻生效，
  // 结果要等下次启动才清。改为 0（永不清理）时什么也不做。
  if (picked > 0) {
    state.repo.purgeTrashOlderThan(picked);
    state.refreshTrash();
  }
}

/// 保留天数的短标签，给胶囊和副标题共用。
String trashRetentionLabel(int days) =>
    days > 0 ? '保留 $days 天' : '一直不删';
