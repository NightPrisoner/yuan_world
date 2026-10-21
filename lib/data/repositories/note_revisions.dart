/// NoteRepository 的历史版本与草稿部分。
///
/// 为什么单独一个 part：这两块都只在"保存"和"恢复"这两个入口被用到，
/// 塞进 note_mutations.dart 会让那个文件继续膨胀；而它们又必须能直接
/// 用 `_d` 这个私有连接，所以只能留在同一个 library 里（part）。
part of 'note_repository.dart';

/// 一条历史版本。
class NoteRevision {
  const NoteRevision({
    required this.id,
    required this.noteId,
    required this.title,
    required this.content,
    required this.reason,
    required this.createdAt,
  });

  final int id;
  final int noteId;
  final String title;
  final String content;

  /// 'save'（自动保存覆盖了旧内容）/ 'restore'（从历史恢复前先留一份）
  final String reason;
  final DateTime createdAt;

  String get preview {
    final t = content.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (t.isEmpty) return '（空）';
    return t.length <= 80 ? t : '${t.substring(0, 80)}…';
  }
}

/// 一条未保存的编辑草稿。
class NoteDraft {
  const NoteDraft({
    required this.noteId,
    required this.title,
    required this.content,
    required this.updatedAt,
  });

  final int noteId;
  final String title;
  final String content;
  final DateTime updatedAt;
}

extension NoteRevisions on NoteRepository {
  /// 每篇笔记保留多少条历史版本。超过就删最旧的。
  ///
  /// 30 条对一篇几万字的笔记也就几兆；再多用户翻起来也累。
  static const int kRevisionKeep = 30;

  /// 写一条历史版本，并按 [kRevisionKeep] 轮转。
  ///
  /// **由调用方决定要不要写**：保存路径里只有"新内容真的要覆盖旧内容"
  /// 时才调它，否则每次自动保存都追加一条，历史里全是没区别的副本。
  int addRevision({
    required int noteId,
    required String title,
    required String content,
    String reason = 'save',
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _d.execute(
      'INSERT INTO note_revisions (note_id, title, content, reason, created_at) '
      'VALUES (?,?,?,?,?)',
      [noteId, title, content, reason, now],
    );
    final id = _d.lastInsertRowId;
    // 轮转：只留最近 kRevisionKeep 条
    _d.execute(
      'DELETE FROM note_revisions WHERE note_id = ? AND id NOT IN ('
      'SELECT id FROM note_revisions WHERE note_id = ? '
      'ORDER BY created_at DESC, id DESC LIMIT ?)',
      [noteId, noteId, kRevisionKeep],
    );
    return id;
  }

  /// 某篇笔记的历史版本，**新的在前**。
  List<NoteRevision> revisionsOf(int noteId, {int limit = 100}) {
    final rows = _d.select(
      'SELECT id, note_id, title, content, reason, created_at '
      'FROM note_revisions WHERE note_id = ? '
      'ORDER BY created_at DESC, id DESC LIMIT ?',
      [noteId, limit],
    );
    return <NoteRevision>[
      for (final r in rows)
        NoteRevision(
          id: r['id'] as int,
          noteId: r['note_id'] as int,
          title: (r['title'] as String?) ?? '',
          content: (r['content'] as String?) ?? '',
          reason: (r['reason'] as String?) ?? 'save',
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            (r['created_at'] as int?) ?? 0,
          ),
        ),
    ];
  }

  int revisionCount(int noteId) {
    final rows = _d.select(
      'SELECT COUNT(*) AS c FROM note_revisions WHERE note_id = ?',
      [noteId],
    );
    return (rows.isEmpty ? 0 : (rows.first['c'] as int? ?? 0));
  }

  /// 删掉某篇笔记的全部历史（笔记永久删除时调用）。
  void deleteRevisionsOf(int noteId) {
    _d.execute('DELETE FROM note_revisions WHERE note_id = ?', [noteId]);
    _d.execute('DELETE FROM note_drafts WHERE note_id = ?', [noteId]);
  }

  /// 库里所有历史版本占用的行数（设置页显示用）。
  int totalRevisionCount() {
    final rows = _d.select('SELECT COUNT(*) AS c FROM note_revisions');
    return (rows.isEmpty ? 0 : (rows.first['c'] as int? ?? 0));
  }

  /// 清空全部历史版本。
  void clearAllRevisions() {
    _d.execute('DELETE FROM note_revisions');
  }

  // ── 草稿 ────────────────────────────────────────────────────────────────

  /// 存一份"已敲但未确认落库"的现场。没有变化就什么都不做，避免频繁写盘。
  void saveDraft({
    required int noteId,
    required String title,
    required String content,
  }) {
    final existing = getDraft(noteId);
    if (existing != null &&
        existing.title == title &&
        existing.content == content) {
      return;
    }
    _d.execute(
      'INSERT INTO note_drafts (note_id, title, content, updated_at) '
      'VALUES (?,?,?,?) '
      'ON CONFLICT(note_id) DO UPDATE SET '
      'title = excluded.title, content = excluded.content, '
      'updated_at = excluded.updated_at',
      [noteId, title, content, DateTime.now().millisecondsSinceEpoch],
    );
  }

  NoteDraft? getDraft(int noteId) {
    final rows = _d.select(
      'SELECT note_id, title, content, updated_at FROM note_drafts '
      'WHERE note_id = ?',
      [noteId],
    );
    if (rows.isEmpty) return null;
    final r = rows.first;
    return NoteDraft(
      noteId: r['note_id'] as int,
      title: (r['title'] as String?) ?? '',
      content: (r['content'] as String?) ?? '',
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (r['updated_at'] as int?) ?? 0,
      ),
    );
  }

  void deleteDraft(int noteId) {
    _d.execute('DELETE FROM note_drafts WHERE note_id = ?', [noteId]);
  }

  /// 草稿和库里内容一模一样时把它删掉（说明上次其实存上了）。
  void deleteDraftIfMatches(
    int noteId, {
    required String title,
    required String content,
  }) {
    try {
      final d = getDraft(noteId);
      if (d != null && d.title == title && d.content == content) {
        deleteDraft(noteId);
      }
    } catch (_) {
      // 表还没建好之类的边缘情况：草稿清理失败不影响使用
    }
  }
}
