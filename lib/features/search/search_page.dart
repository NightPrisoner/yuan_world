/// 搜索页。全文检索基于 SQLite FTS5（trigram 分词），中文子串可命中。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../core/motion/app_motion.dart';
import '../../core/motion/apple_page_route.dart';
import '../../core/theme/app_theme.dart';
import '../../data/models.dart';
import '../notes/note_detail_page.dart';
import '../../data/repositories/note_repository.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends State<SearchPage> {
  /// 一页取多少条。取小一点：搜索结果卡片不算高，30 条已经能滚两屏，
  /// 而用户往往在第 3 条就停下来了。
  static const int _kPageSize = 30;

  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  final ScrollController _scroll = ScrollController();
  Timer? _debounce;

  List<Note> _results = <Note>[];
  bool _searching = false;
  bool _loadingMore = false;
  String _lastQuery = '';

  /// 命中总数，由 `countNotes` 数出来，**不是** `_results.length`。
  /// 以前页面拿「这一页取到多少条」当总数，超过 200 条就是个假数字。
  int _total = 0;

  /// 请求代号：翻页和改关键词可能交替发生，只认最后一次请求的结果。
  int _generation = 0;

  bool get _hasMore => _results.length < _total;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    // 还剩半屏就开始取下一页，滚到底时不至于明显卡一下
    if (_scroll.position.pixels >=
        _scroll.position.maxScrollExtent - 320) {
      _loadMore();
    }
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    // 输入防抖，避免每敲一个字都查库
    _debounce = Timer(const Duration(milliseconds: 180), () => _run(q));
  }

  /// 跑一次搜索（从第一页开始）。
  ///
  /// [force] 为真时即使关键词没变也重查 —— 「编辑完返回」必须走这条路：
  /// 正文可能改了，命中集合也就可能变了，而 `_lastQuery` 拦着不让重查，
  /// 用户看到的就是一份陈旧的列表。以前这里没有这个开关，返回后列表不动。
  void _run(String q, {bool force = false}) {
    final state = context.read<AppState>();
    final query = q.trim();
    if (!force && query == _lastQuery) return;
    _lastQuery = query;
    final generation = ++_generation;

    if (query.isEmpty) {
      setState(() {
        _results = <Note>[];
        _total = 0;
        _searching = false;
        _loadingMore = false;
      });
      return;
    }

    setState(() {
      _searching = true;
      _loadingMore = false;
    });
    final page = state.repo.searchPage(query, limit: _kPageSize);
    if (!mounted || generation != _generation) return;
    setState(() {
      _results = page.notes;
      _total = page.total;
      _searching = false;
    });
  }

  /// 取下一页，接在已有结果后面。
  void _loadMore() {
    if (_searching || _loadingMore || !_hasMore) return;
    final state = context.read<AppState>();
    final generation = _generation;
    setState(() => _loadingMore = true);
    final page = state.repo.searchPage(
      _lastQuery,
      limit: _kPageSize,
      offset: _results.length,
    );
    if (!mounted || generation != _generation) return;
    setState(() {
      _results = <Note>[..._results, ...page.notes];
      _total = page.total;
      _loadingMore = false;
    });
  }

  /// 进详情再回来：重查一次，否则刚编辑过的内容在结果里还是旧的。
  Future<void> _openNote(Note note) async {
    await Navigator.of(context).push(
      ApplePageRoute<void>(
        pageBuilder: (_) => NoteDetailPage(noteId: note.id),
      ),
    );
    if (!mounted) return;
    _run(_controller.text, force: true);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;

    return Scaffold(
      backgroundColor: c.groupedBackground,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 38,
                      decoration: BoxDecoration(
                        color: c.fill,
                        borderRadius: BorderRadius.circular(
                          AppMetrics.radiusMd,
                        ),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(width: 10),
                          Icon(
                            Icons.search_rounded,
                            size: 17,
                            color: c.tertiaryLabel,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: TextField(
                              controller: _controller,
                              focusNode: _focus,
                              onChanged: _onChanged,
                              textInputAction: TextInputAction.search,
                              style: AppText.callout.copyWith(color: c.label),
                              decoration: InputDecoration(
                                isDense: true,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                filled: false,
                                contentPadding: EdgeInsets.zero,
                                hintText: '搜索标题与正文',
                                hintStyle: AppText.callout.copyWith(
                                  color: c.tertiaryLabel,
                                ),
                              ),
                            ),
                          ),
                          if (_controller.text.isNotEmpty)
                            IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 30,
                                minHeight: 30,
                              ),
                              icon: Icon(
                                Icons.cancel_rounded,
                                size: 16,
                                color: c.tertiaryLabel,
                              ),
                              onPressed: () {
                                _controller.clear();
                                _run('');
                                setState(() {});
                              },
                            ),
                          const SizedBox(width: 4),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text(
                      '取消',
                      style: AppText.callout.copyWith(color: c.tint),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: _buildBody(c)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(AppColors c) {
    if (_controller.text.trim().isEmpty) {
      return _buildHint(
        c,
        icon: Icons.manage_search_rounded,
        title: '全文搜索',
        subtitle: '支持中文子串检索，标题与正文都会命中\n例如搜「火车」「宫崎骏」「AI绘画」',
      );
    }
    if (_searching) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_results.isEmpty) {
      return _buildHint(
        c,
        icon: Icons.search_off_rounded,
        title: '没有找到结果',
        subtitle: '换个词试试，或者搜更短的关键词',
      );
    }

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      physics: const BouncingScrollPhysics(),
      // 多出来的一格是底部状态行（「还有更多」或「加载中」）
      itemCount: _results.length + (_hasMore || _loadingMore ? 2 : 1),
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 10),
            child: Text(
              // 总数是查库数出来的；达到上限时也要如实显示，别再糊一个
              // 「找到 200 篇」骗人。
              _total > _results.length
                  ? '找到 $_total 篇 · 已显示 ${_results.length} 篇'
                  : '找到 $_total 篇',
              style: AppText.caption1.copyWith(color: c.tertiaryLabel),
            ),
          );
        }
        if (i > _results.length) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(0, 6, 0, 10),
            child: Center(
              child: _loadingMore
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(
                      '继续往下滚动加载更多',
                      style: AppText.caption1.copyWith(
                        color: c.quaternaryLabel,
                      ),
                    ),
            ),
          );
        }
        final note = _results[i - 1];
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _SearchResultTile(
            note: note,
            query: _lastQuery,
            // 和其他入口用同一条转场：右侧推入、返回时原路退回。
            // 以前这里是裸 PageRouteBuilder + 纯淡入，从搜索结果进正文和
            // 从列表、统计、设置里进正文的观感对不上。
            onTap: () => _openNote(note),
          ),
        );
      },
    );
  }

  Widget _buildHint(
    AppColors c, {
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 40, color: c.quaternaryLabel),
            const SizedBox(height: 14),
            Text(
              title,
              style: AppText.title3.copyWith(color: c.secondaryLabel),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: AppText.footnote.copyWith(
                color: c.tertiaryLabel,
                height: 1.7,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchResultTile extends StatelessWidget {
  const _SearchResultTile({
    required this.note,
    required this.query,
    required this.onTap,
  });

  final Note note;
  final String query;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Pressable(
      onTap: onTap,
      scale: 0.985,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: c.secondaryBackground,
          borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _highlight(
              note.title.isEmpty ? '无标题笔记' : note.title,
              query,
              AppText.callout.copyWith(
                color: c.label,
                fontWeight: FontWeight.w600,
              ),
              c,
            ),
            if (note.excerpt.isNotEmpty) ...[
              const SizedBox(height: 5),
              _highlight(
                note.excerpt,
                query,
                AppText.footnote.copyWith(color: c.secondaryLabel, height: 1.5),
                c,
                maxLines: 2,
              ),
            ],
            const SizedBox(height: 6),
            Text(
              [
                if (note.collectionName != null) note.collectionName!,
                if (note.author.isNotEmpty) note.author,
                '${note.charCount} 字',
              ].join(' · '),
              style: AppText.caption1.copyWith(color: c.tertiaryLabel),
            ),
          ],
        ),
      ),
    );
  }

  /// 把命中的关键词标成主题色，方便一眼看到为什么匹配。
  Widget _highlight(
    String text,
    String query,
    TextStyle style,
    AppColors c, {
    int maxLines = 1,
  }) {
    if (query.isEmpty) {
      return Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    final lower = text.toLowerCase();
    final q = query.toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    while (true) {
      final idx = lower.indexOf(q, start);
      if (idx < 0) {
        spans.add(TextSpan(text: text.substring(start)));
        break;
      }
      if (idx > start) spans.add(TextSpan(text: text.substring(start, idx)));
      spans.add(
        TextSpan(
          text: text.substring(idx, idx + q.length),
          style: style.copyWith(
            color: c.tint,
            fontWeight: FontWeight.w700,
            backgroundColor: c.tint.withValues(alpha: 0.12),
          ),
        ),
      );
      start = idx + q.length;
    }
    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}
