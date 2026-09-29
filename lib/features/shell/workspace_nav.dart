/// 左栏：品牌头 / 分类导航 / 收起后的图标轨道。
///
/// 这里是 `desktop_workspace.dart` 的一部分（`part of`），理由见
/// workspace_actions.dart 的说明。
part of 'desktop_workspace.dart';

extension _WsNav on _DesktopWorkspaceState {
  /// 品牌标。用**真 logo 资源**，不再是手画的渐变色块。
  ///
  /// 以前这里是一个 `LinearGradient` 色块 + `Icons.auto_awesome` 的占位图，
  /// 和 exe 图标（`assets/branding/logo.png` 生成的那套）长得完全不一样 ——
  /// 用户看到的是一个紫色小方块，而不是自己给的 logo。
  ///
  /// 资源读不出来时退回那个占位色块：侧栏左上角空一块比图标不精致更糟。
  Widget _brandMark(AppColors c) => Image.asset(
    'assets/branding/logo.png',
    width: _kBrandMarkSize,
    height: _kBrandMarkSize,
    // logo 自带圆角和透明外角，直接用就好，不用再裁
    fit: BoxFit.cover,
    filterQuality: FilterQuality.medium,
    errorBuilder: (_, _, _) => Container(
      width: _kBrandMarkSize,
      height: _kBrandMarkSize,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [c.palette[0], c.palette[4]],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.auto_awesome, size: 15, color: Colors.white),
    ),
  );

  /// 左栏顶部的标识。隐私空间里换成醒目的提示 + 退出按钮 ——
  /// 「现在看的是哪一套数据」必须一眼可见，否则容易误操作。
  Widget _brandHeader(AppColors c, AppState state) {
    if (!state.privacyMode) {
      return Padding(
        padding: _kBrandPad,
        child: Row(
          children: [
            _brandMark(c),
            const SizedBox(width: 9),
            Text('元世界', style: AppText.title3.copyWith(color: c.label)),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: c.palette[6].withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
        ),
        child: Row(
          children: [
            Icon(Icons.lock_rounded, size: 16, color: c.palette[6]),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '隐私空间',
                style: AppText.callout.copyWith(
                  color: c.palette[6],
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Pressable(
              onTap: state.exitPrivacyMode,
              scale: 0.94,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: Text(
                  '退出',
                  style: AppText.footnote.copyWith(
                    color: c.palette[6],
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _navPane(BuildContext context, AppState state) {
    final c = context.colors;
    final f = state.filter;

    final allSelected =
        _section == _Section.notes &&
        f.collectionId == null &&
        !f.favoritesOnly &&
        !f.uncategorizedOnly;

    return Container(
      decoration: BoxDecoration(
        color: c.isDark ? const Color(0xFF141416) : const Color(0xFFF7F7FA),
      ),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── 标识（隐私空间里换成锁形提示） ──
            _brandHeader(c, state),

            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // ── 固定区：常用入口（不随文件夹列表滚动） ──
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // **收起开关放在最上面，且两种状态同一个位置。**
                        //
                        // 以前它夹在"视图"和"文件夹"两组中间，而收起后的
                        // 展开按钮在最顶上 —— 同一个开关点一下会跳到另一个
                        // 高度，很难受。放到固定区第一个，两边 y 就一致了。
                        _NavRow(
                          icon: Icons.chevron_left_rounded,
                          label: '收起侧栏',
                          selected: false,
                          onTap: () => _setNavCollapsed(true),
                        ),
                        _NavRow(
                          icon: Icons.article_rounded,
                          label: '全部笔记',
                          count: state.overview?.noteCount ?? 0,
                          selected: allSelected,
                          onTap: () {
                            state.selectAll();
                            _goSection(_Section.notes);
                          },
                        ),
                        // 未分类也是一个投放目标：把笔记拖出去就从文件夹里移出来了
                        _DropZone(
                          onNote: (note) async {
                            await state.moveNoteToCollection(note.id, null);
                          },
                          child: _NavRow(
                            icon: Icons.inbox_rounded,
                            label: '未分类',
                            color: c.palette[2],
                            selected:
                                _section == _Section.notes &&
                                f.uncategorizedOnly,
                            onTap: () {
                              state.selectUncategorized();
                              _goSection(_Section.notes);
                            },
                          ),
                        ),
                        _NavRow(
                          icon: Icons.star_rounded,
                          label: '收藏',
                          color: c.palette[7],
                          count: state.overview?.favoriteCount ?? 0,
                          selected:
                              _section == _Section.notes && f.favoritesOnly,
                          onTap: () {
                            state.selectAll();
                            state.toggleFavorites();
                            _goSection(_Section.notes);
                          },
                        ),
                      ],
                    ),
                  ),

                  // ── 分组分隔：上面三个是「视图」，下面是「我的文件夹」 ──
                  // 一条细线 + 上下留白，让两组一眼分得开
                  const SizedBox(height: 10),
                  Divider(
                    height: 1,
                    indent: 14,
                    endIndent: 14,
                    color: c.separator,
                  ),
                  const SizedBox(height: 6),

                  // ── 固定：文件夹标题（新建按钮始终够得着） ──
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: _NavGroupLabel(
                      '我的文件夹',
                      onAdd: () async {
                        final created = await showCollectionEditor(context);
                        // 弹窗挂在根 Navigator 上，等它关掉的这段时间里
                        // 窗口被拖窄到 1000px 以下会让这个 workspace 被销毁
                        if (created != null && mounted) {
                          _goSection(_Section.notes);
                        }
                      },
                    ),
                  ),

                  // ── 可滚动：文件夹列表 ──
                  // 文件夹可能很多（还支持嵌套），让它自己滚：
                  // 上下的固定项就不会被顶出屏幕、不用满世界找。
                  //
                  // 外面套一层自动滚动：拖着一个文件夹靠近上下边缘时列表
                  // 自己滚，否则想把文件夹拖到列表另一端根本做不到 ——
                  // 手一松就掉回原处。
                  Expanded(
                    child: _AutoScrollWhenDragging(
                      child: ListView(
                        controller: _folderScroll,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        physics: const BouncingScrollPhysics(),
                        children: [
                          for (final (_, col, depth) in _flattenTree(
                            state.collections,
                          ))
                            // key 按文件夹 id 给：树在动画里增删行时，
                            // element 必须跟着**同一行**走，不能顺位复用 ——
                            // 复用到的可能是别人播到"看不见"的那个状态。
                            Builder(
                              key: ValueKey<int>(col.id),
                              builder: (rowCtx) => _collectionRow(
                                rowCtx,
                                state,
                                col,
                                depth,
                                f.collectionId,
                                // 有子文件夹的才给收起/展开的小三角
                                hasKids: state.collections.any(
                                  (x) => x.parentId == col.id,
                                ),
                                // 父文件夹正在收起 → 这一行该滑出去了
                                exiting: _collapsingRows(state.collections)
                                    .contains(col.id),
                              ),
                            ),
                          if (state.collections.isEmpty)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(22, 4, 10, 4),
                              child: Text(
                                '还没有文件夹',
                                style: AppText.caption1.copyWith(
                                  color: c.quaternaryLabel,
                                ),
                              ),
                            )
                          else
                            // 拖到这里 = 升到顶层。没有这块的话，
                            // 文件夹全都嵌套着时就没地方把它拎出来了。
                            _DropZone(
                              onCollectionDrop: (dragged, _) =>
                                  _dropToTopLevel(context, state, dragged),
                              child: SizedBox(
                                height: 26,
                                child: Center(
                                  child: Text(
                                    '拖到此处移到顶层',
                                    style: AppText.caption2.copyWith(
                                      color: c.quaternaryLabel,
                                    ),
                                  ),
                                ),
                              ),
                            ),

                          // ── 标签 ──
                          //
                          // 和文件夹一起放在**滚动区**里：两者都可能很长，固定
                          // 哪一边都会把另一边挤没。标签是"多对多"的横切分类，
                          // 和树状的文件夹本来就是两回事，所以中间拉一条分隔线。
                          if (state.tags.isNotEmpty) ...[
                            const SizedBox(height: 10),
                            Divider(height: 1, color: c.separator),
                            const SizedBox(height: 8),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                              child: Row(
                                children: [
                                  Text(
                                    '标签',
                                    style: AppText.caption2.copyWith(
                                      color: c.quaternaryLabel,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const Spacer(),
                                  Pressable(
                                    onTap: () => _openTagManager(context),
                                    scale: 0.9,
                                    child: Tooltip(
                                      message: '标签管理',
                                      child: Padding(
                                        padding: const EdgeInsets.all(2),
                                        child: Icon(
                                          Icons.tune_rounded,
                                          size: 14,
                                          color: c.tertiaryLabel,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            for (final t in state.tags)
                              _NavRow(
                                icon: Icons.label_rounded,
                                label: t.name,
                                count: t.count,
                                color: Color(t.color),
                                selected:
                                    _section == _Section.notes &&
                                    f.tag == t.name,
                                onTap: () {
                                  state.selectTag(t.name);
                                  _goSection(_Section.notes);
                                },
                              ),
                          ],
                        ],
                      ),
                    ),
                  ),

                  // ── 分组分隔：文件夹区 / 功能区（待办、归档、回收站…） ──
                  Divider(
                    height: 1,
                    indent: 14,
                    endIndent: 14,
                    color: c.separator,
                  ),
                  const SizedBox(height: 6),

                  // ── 固定区：待办 / 统计 ──
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(height: 6),
                        Divider(color: c.separator, height: 1),
                        const SizedBox(height: 6),
                        _NavRow(
                          icon: Icons.check_circle_rounded,
                          label: '待办',
                          count: state.openTodoCount,
                          color: c.palette[1],
                          selected: _section == _Section.todos,
                          onTap: () => _goSection(_Section.todos),
                        ),
                        _NavRow(
                          icon: Icons.archive_outlined,
                          label: '归档',
                          color: c.palette[4],
                          selected: _section == _Section.archived,
                          onTap: () => _goSection(_Section.archived),
                        ),
                        _NavRow(
                          icon: Icons.delete_outline_rounded,
                          label: '回收站',
                          count: state.trashedNotes.length,
                          color: c.palette[3],
                          selected: _section == _Section.trash,
                          onTap: () => _goSection(_Section.trash),
                        ),
                        _NavRow(
                          icon: Icons.insights_rounded,
                          label: '统计',
                          color: c.palette[5],
                          selected: _section == _Section.stats,
                          onTap: () => _goSection(_Section.stats),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // ── 导入文集（在设置上面） ──
            //
            // **用 _NavRow，不要手写一行。** 之前这里是手搓的
            // `Pressable > _HoverTint > Row`，而 _HoverTint 的左内边距是
            // 22px（那是给缩进的子文件夹用的），_NavRow 是 10px ——
            // 于是"导入文集"整体比同级右移了 12px，一眼就看得出来没对齐。
            // 复用 _NavRow 之后几何由同一份代码决定，不可能再走偏。
            //
            // 顺带保住了原来的意图：selected 传 false，静息态没有底色，
            // 悬停才浮现 —— 它是"动作"，不是"当前所在"，不该看着像被按住。
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 0),
              child: _NavRow(
                icon: Icons.download_rounded,
                label: '导入文集',
                selected: false,
                onTap: () => Navigator.of(context).push(
                  ApplePageRoute<void>(
                    pageBuilder: (_) => const ImportPage(),
                    fullscreenDialog: true,
                  ),
                ),
              ),
            ),

            // ── 底部固定：设置（不随任何列表滚动，永远在左下角） ──
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 2, 10, 6),
              child: _NavRow(
                icon: Icons.tune_rounded,
                label: '设置',
                selected: _section == _Section.settings,
                onTap: () => _goSection(_Section.settings),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 左栏收起后的窄条。
  ///
  /// 只留图标、去掉文字和文件夹树 —— 收起的意义就是"把地方让给正文"，
  /// 所以它必须真的窄。点顶部的箭头展开。
  Widget _navRail(BuildContext context, AppState state) {
    final c = context.colors;
    final f = state.filter;

    Widget item(IconData icon, String tip, bool active, VoidCallback onTap) =>
        Tooltip(
          message: tip,
          child: Pressable(
            onTap: onTap,
            scale: 0.92,
            child: Container(
              width: 38,
              height: 38,
              margin: const EdgeInsets.symmetric(vertical: 2),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: active
                    ? c.tint.withValues(alpha: c.isDark ? 0.24 : 0.14)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(
                icon,
                size: 18,
                color: active ? c.tint : c.secondaryLabel,
              ),
            ),
          ),
        );

    return Container(
      decoration: BoxDecoration(
        color: c.isDark ? const Color(0xFF141416) : const Color(0xFFF7F7FA),
        border: Border(right: BorderSide(color: c.separator, width: 0.5)),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // ── 头部：只留 logo 标，**高度和展开态一模一样** ──
            //
            // 这是"收起/展开开关同一条水平线"的关键。以前这里只有
            // `SizedBox(height: 10)`，而展开态开关上面压着整个品牌头
            // （18 + 26 + 12 = 56），于是点一下开关，它自己往上跳 48px。
            // 留出同样高度的头部之后，两种状态下开关的 y 就一致了。
            Padding(
              // 不能 const：常量对象上取不到 .top（Dart 的常量求值限制）
              padding: EdgeInsets.only(
                top: _kBrandPad.top,
                bottom: _kBrandPad.bottom,
              ),
              child: SizedBox(
                height: _kBrandMarkSize,
                child: Center(child: _brandMark(c)),
              ),
            ),
            Tooltip(
              message: '展开侧栏',
              child: Pressable(
                onTap: () => _setNavCollapsed(false),
                scale: 0.9,
                child: Container(
                  // **和展开态那个 _NavRow 用同一套 margin + padding**。
                  //
                  // 只对齐外框是不够的：展开态的箭头是包在
                  // `margin 1 + padding 7` 里的行内图标，收起态原来是个
                  // 光秃秃的 38px 方块 —— 外框差了 8px，图标中心也跟着差。
                  // 补齐这两层之后，两边的箭头中心才落在同一条水平线上。
                  margin: const EdgeInsets.symmetric(vertical: 1),
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: SizedBox(
                    width: 38,
                    child: Center(
                      child: Icon(
                        Icons.chevron_right_rounded,
                        size: 16,
                        color: c.secondaryLabel,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 展开态里开关下面紧跟着第一项，这里也留同样的间距
            const SizedBox(height: 6),
            item(
              Icons.article_rounded,
              '全部笔记',
              _section == _Section.notes &&
                  f.collectionId == null &&
                  !f.favoritesOnly &&
                  !f.uncategorizedOnly,
              () {
                state.selectCollection(null);
                _goSection(_Section.notes);
              },
            ),
            item(Icons.star_rounded, '收藏', f.favoritesOnly, () {
              state.selectAll();
              state.toggleFavorites();
              _goSection(_Section.notes);
            }),
            const Spacer(),
            item(
              Icons.check_circle_rounded,
              '待办',
              _section == _Section.todos,
              () => _goSection(_Section.todos),
            ),
            item(
              Icons.archive_outlined,
              '归档',
              _section == _Section.archived,
              () => _goSection(_Section.archived),
            ),
            item(
              Icons.delete_outline_rounded,
              '回收站',
              _section == _Section.trash,
              () => _goSection(_Section.trash),
            ),
            item(
              Icons.insights_rounded,
              '统计',
              _section == _Section.stats,
              () => _goSection(_Section.stats),
            ),
            item(
              Icons.tune_rounded,
              '设置',
              _section == _Section.settings,
              () => _goSection(_Section.settings),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
