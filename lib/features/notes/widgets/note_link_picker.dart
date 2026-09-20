/// 插入「内部链接」时挑目标笔记的那个页面。
///
/// 为什么要有这一页：双链的语法是 `[[标题]]`，以前只能靠用户**手打标题** ——
/// 慢、容易打错，打错了还只是"点了没反应"。实际要的是"搜一下/翻一下，
/// 选中就插进去"，所以做成一个带搜索框的笔记列表。
///
/// 它只负责"挑一篇笔记"，插入的事交给调用方（编辑器），这样别的地方
/// （以后的"引用到当前笔记"之类）也能复用同一页。
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../app_state.dart';
import '../../../core/motion/app_motion.dart';
import '../../../core/motion/apple_page_route.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/repositories/note_repository.dart';

/// 弹页选一篇笔记。取消返回 null。
Future<({int id, String title})?> pickNoteToLink(
  BuildContext context, {
  int? excludeNoteId,
}) =>
    Navigator.of(context).push<({int id, String title})>(
      ApplePageRoute<({int id, String title})>(
        pageBuilder: (_) => NoteLinkPickerPage(excludeNoteId: excludeNoteId),
        fullscreenDialog: true,
      ),
    );

class NoteLinkPickerPage extends StatefulWidget {
  const NoteLinkPickerPage({super.key, this.excludeNoteId});

  /// 排除自己：给自己的正文插一条"链接到自己"没有意义。
  final int? excludeNoteId;

  @override
  State<NoteLinkPickerPage> createState() => _NoteLinkPickerPageState();
}

class _NoteLinkPickerPageState extends State<NoteLinkPickerPage> {
  final _query = TextEditingController();
  List<({int id, String title, String excerpt})> _all = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    // 标题 + 摘要一把取出来，本地过滤。
    //
    // 不用 FTS 搜索：那是给"全文检索"用的（三元组、有最短长度限制），
    // 这里只是"在标题里找一篇"，几千篇的列表本地筛是瞬时的，而且
    // 输入一个字就能匹配（FTS 的 trigram 至少要三个字才走索引）。
    final rows = state.repo.noteTitlesForPicker();
    if (!mounted) return;
    setState(() {
      _all = <({int id, String title, String excerpt})>[
        for (final r in rows)
          if (r.id != widget.excludeNoteId)
            (id: r.id, title: r.title, excerpt: r.excerpt),
      ];
      _loading = false;
    });
  }

  List<({int id, String title, String excerpt})> get _hits {
    final q = _query.text.trim().toLowerCase();
    if (q.isEmpty) return _all;
    return <({int id, String title, String excerpt})>[
      for (final n in _all)
        if (n.title.toLowerCase().contains(q) ||
            n.excerpt.toLowerCase().contains(q))
          n,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hits = _hits;

    return Scaffold(
      backgroundColor: c.groupedBackground,
      appBar: AppBar(
        backgroundColor: c.groupedBackground,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.close_rounded, size: 20),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          '选择要链接的笔记',
          style: AppText.headline.copyWith(color: c.label),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: TextField(
              controller: _query,
              autofocus: true,
              style: AppText.callout.copyWith(color: c.label),
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: '搜标题或正文片段',
                hintStyle: AppText.callout.copyWith(color: c.tertiaryLabel),
                prefixIcon: Icon(Icons.search_rounded,
                    size: 20, color: c.tertiaryLabel),
                filled: true,
                fillColor: c.secondaryBackground,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppMetrics.radiusMd),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          if (_loading)
            const Expanded(child: Center(child: CircularProgressIndicator()))
          else if (hits.isEmpty)
            Expanded(
              child: Center(
                child: Text(
                  _query.text.trim().isEmpty ? '还没有别的笔记' : '没有匹配的笔记',
                  style: AppText.callout.copyWith(color: c.secondaryLabel),
                ),
              ),
            )
          else
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 30),
                itemCount: hits.length,
                itemBuilder: (context, i) {
                  final n = hits[i];
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Pressable(
                      scale: 0.99,
                      opacity: 0.7,
                      onTap: () => Navigator.of(context)
                          .pop((id: n.id, title: n.title)),
                      child: Container(
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                        decoration: BoxDecoration(
                          color: c.secondaryBackground,
                          borderRadius:
                              BorderRadius.circular(AppMetrics.radiusMd),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    n.title.isEmpty ? '无标题笔记' : n.title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppText.callout.copyWith(
                                      color: c.label,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  if (n.excerpt.isNotEmpty) ...[
                                    const SizedBox(height: 3),
                                    Text(
                                      n.excerpt,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppText.caption1
                                          .copyWith(color: c.tertiaryLabel),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            Icon(Icons.add_link_rounded,
                                size: 20, color: c.tint),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}
