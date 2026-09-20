/// 搜索页。全文检索基于 SQLite FTS5（trigram 分词），中文子串可命中。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_state.dart';
import '../../core/motion/app_motion.dart';
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
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focus = FocusNode();
  Timer? _debounce;

  List<Note> _results = <Note>[];
  bool _searching = false;
  String _lastQuery = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    // 输入防抖，避免每敲一个字都查库
    _debounce = Timer(const Duration(milliseconds: 180), () => _run(q));
  }

  void _run(String q) {
    final state = context.read<AppState>();
    final query = q.trim();
    if (query == _lastQuery) return;
    _lastQuery = query;

    if (query.isEmpty) {
      setState(() {
        _results = <Note>[];
        _searching = false;
      });
      return;
    }

    setState(() => _searching = true);
    final hits = state.repo.search(query, limit: 200);
    setState(() {
      _results = hits;
      _searching = false;
    });
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
                        borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(width: 10),
                          Icon(Icons.search_rounded, size: 17, color: c.tertiaryLabel),
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
                              icon: Icon(Icons.cancel_rounded,
                                  size: 16, color: c.tertiaryLabel),
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
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      physics: const BouncingScrollPhysics(),
      itemCount: _results.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 10),
            child: Text(
              '找到 ${_results.length} 篇',
              style: AppText.caption1.copyWith(color: c.tertiaryLabel),
            ),
          );
        }
        final note = _results[i - 1];
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _SearchResultTile(
            note: note,
            query: _lastQuery,
            onTap: () => Navigator.of(context).push(
              PageRouteBuilder<void>(
                transitionDuration: AppMotion.fast,
                reverseTransitionDuration: AppMotion.fast,
                pageBuilder: (_, _, _) => NoteDetailPage(noteId: note.id),
                transitionsBuilder: (_, a, _, child) => FadeTransition(
                  opacity: CurvedAnimation(parent: a, curve: AppMotion.enter),
                  child: child,
                ),
              ),
            ),
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
            Text(title, style: AppText.title3.copyWith(color: c.secondaryLabel)),
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
              AppText.callout.copyWith(color: c.label, fontWeight: FontWeight.w600),
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
      return Text(text, maxLines: maxLines, overflow: TextOverflow.ellipsis, style: style);
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
      spans.add(TextSpan(
        text: text.substring(idx, idx + q.length),
        style: style.copyWith(
          color: c.tint,
          fontWeight: FontWeight.w700,
          backgroundColor: c.tint.withValues(alpha: 0.12),
        ),
      ));
      start = idx + q.length;
    }
    return Text.rich(
      TextSpan(style: style, children: spans),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}
