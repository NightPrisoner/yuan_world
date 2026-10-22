/// 短词（1~2 个字）检索用的**逐字分段索引**。
///
/// ## 为什么需要这一层
///
/// 全文索引 [notes_fts] 用的是 FTS5 的 trigram 分词器 —— 它按三字符滑动
/// 窗口建索引，中文子串检索很好用，但它**只能匹配 3 个字符以上**：
/// `MATCH '"读书"'` 和 `MATCH '"读"'` 都返回空（实测）。
///
/// 于是 1~2 个字的词只能退回 `content LIKE '%读书%'` **全表扫描**。
/// 而中文里两字词恰恰最常见（"读书""会议""旅行""邮件"），笔记一多就卡。
///
/// ## 这一层的做法
///
/// 再建一张 FTS5 表（[note_segments]，`unicode61` 分词器），但**写入的不是
/// 原文，而是切分过的原文**：每个汉字之间插一个空格，拉丁字母和数字按整词
/// 保留。切分后 `unicode61` 会把每个汉字当成独立的 token，于是：
///
/// - 搜「书」→ `MATCH '"书"'` → 命中含「书」的笔记；
/// - 搜「读书」→ `MATCH '"读 书"'` → FTS5 的短语语义要求两个 token
///   **相邻且有序**，所以只命中真正写了「读书」的笔记，
///   「读了一本书」不会误命中 —— 这正是子串语义。
///
/// 索引由 SQLite 自己维护（B 树），比手写「gram 倒排表」紧凑得多：
/// 中文笔记平均每字一个 token，索引大小约为正文的 1~2 倍。
///
/// ## 铁律
///
/// **切分规则必须写入和查询共用**（都走 [searchSegments]），否则索引里的
/// token 和查询请求的 token 对不上，表现就是"某些词搜不到"且极难查。
library;

/// 是否为 CJK 字符（汉字、假名、韩文）。
bool _isCjk(int code) =>
    (code >= 0x4E00 && code <= 0x9FFF) || // 基本汉字
    (code >= 0x3400 && code <= 0x4DBF) || // 扩展 A
    (code >= 0xF900 && code <= 0xFAFF) || // 兼容汉字
    (code >= 0x3040 && code <= 0x30FF) || // 日文假名
    (code >= 0xAC00 && code <= 0xD7AF); // 韩文

/// 拉丁字母 / 数字：这类字符连在一起算一个整词（`ai` 而不是 `a`+`i`）。
bool _isWordChar(int code) =>
    (code >= 0x30 && code <= 0x39) || // 0-9
    (code >= 0x41 && code <= 0x5A) || // A-Z
    (code >= 0x61 && code <= 0x7A); // a-z

/// 把文本切成「逐字 token + 拉丁整词」的中间表示。
///
/// 汉字/假名/韩文：每个字符一个元素；
/// 拉丁字母和数字：连续的一段合成一个元素（原样保留大小写，`unicode61`
/// 会自己小写化）；
/// 其他（空白、标点、符号）：丢弃。
///
/// 例：`'读书记 · AI绘画'` → `['读','书','记','AI','绘','画']`
List<String> searchTokens(String text) {
  final out = <String>[];
  if (text.isEmpty) return out;

  final word = StringBuffer();

  void flushWord() {
    if (word.isEmpty) return;
    out.add(word.toString());
    word.clear();
  }

  for (final code in text.runes) {
    if (_isWordChar(code)) {
      word.writeCharCode(code);
      continue;
    }
    flushWord();
    if (_isCjk(code)) {
      out.add(String.fromCharCode(code));
    }
  }
  flushWord();
  return out;
}

/// 写入 [note_segments] 用的分段文本：token 之间用单个空格连接。
///
/// 存进 FTS5 后，每个汉字都是独立 token，短语查询即为「相邻子串」。
String searchSegments(String text) => searchTokens(text).join(' ');

/// 把用户输入拼成 FTS5 的**短语**查询串（形如 `"读 书"`）。
///
/// 返回 null 表示这个词切不出任何 token（比如用户只输入了标点），
/// 调用方应当直接给出空结果，而不是拿 `""` 去 MATCH ——
/// 那样会抛 `fts5: syntax error`。
///
/// 用短语（而不是 `AND` 连接）是为了保住**顺序与相邻**语义：
/// 「读 书」只命中"读书"，"书…读"或"读了一本书"都不算。
String? searchPhrase(String query) {
  final tokens = searchTokens(query);
  if (tokens.isEmpty) return null;
  // FTS5 的短语里用双引号包裹；字符串内部的 `"` 要双写转义。
  final body = tokens.map((t) => t.replaceAll('"', '""')).join(' ');
  return '"$body"';
}

/// 这个搜索词是否短到 trigram 索引覆盖不了（需要用 [note_segments]）。
///
/// trigram 按**字符**（code point）算窗口，所以判断也按字符数：
/// 3 个及以上走 [notes_fts]，1~2 个走逐字分段索引。
bool needsSegmentIndex(String query) {
  final q = query.trim();
  if (q.isEmpty) return false;
  return q.runes.length < 3;
}
