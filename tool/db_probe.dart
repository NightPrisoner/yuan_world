// 探针：确认 sqlite3 v3 在当前环境可用，且 FTS5 全文检索可用。
// 运行: dart run tool/db_probe.dart
// ignore_for_file: avoid_print

import 'package:sqlite3/sqlite3.dart';

void main() {
  print('sqlite3 库版本: ${sqlite3.version}');

  final db = sqlite3.openInMemory();

  // 1) 基础读写
  db.execute('''
    CREATE TABLE t (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      body TEXT NOT NULL
    );
  ''');
  final ins = db.prepare('INSERT INTO t (title, body) VALUES (?, ?)');
  ins.execute(['元世界', '本地笔记与知识可视化，支持全文检索']);
  ins.execute(['另一个世界', '这是一段用于测试的中文内容']);
  ins.close();

  print('基础查询行数: ${db.select('SELECT COUNT(*) AS c FROM t').first['c']}');

  // 2) FTS5 全文检索（中文需要 trigram 或 unicode61 分词）
  try {
    db.execute("CREATE VIRTUAL TABLE fts USING fts5(title, body, tokenize='unicode61')");
    db.execute('INSERT INTO fts (title, body) SELECT title, body FROM t');
    final hit = db.select("SELECT title FROM fts WHERE fts MATCH '笔记'");
    print('FTS5(unicode61) 命中: ${hit.length} 条 -> ${hit.map((r) => r['title']).toList()}');
  } catch (e) {
    print('FTS5 unicode61 失败: $e');
  }

  // 3) trigram 分词（对中文子串检索更友好）
  try {
    db.execute("CREATE VIRTUAL TABLE fts_tri USING fts5(title, body, tokenize='trigram')");
    db.execute('INSERT INTO fts_tri (title, body) SELECT title, body FROM t');
    final hit = db.select("SELECT title FROM fts_tri WHERE fts_tri MATCH '知识可视'");
    print('FTS5(trigram) 命中: ${hit.length} 条 -> ${hit.map((r) => r['title']).toList()}');
  } catch (e) {
    print('FTS5 trigram 失败: $e');
  }

  // 4) JSON1 扩展
  try {
    final j = db.select("SELECT json_extract('{\"a\":123}', '\$.a') AS v").first['v'];
    print('JSON1 可用: $j');
  } catch (e) {
    print('JSON1 不可用: $e');
  }

  db.close();
  print('OK');
}
