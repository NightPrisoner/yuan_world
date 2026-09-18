/// 文件名排序键 —— 对齐 Windows 资源管理器的规则。
///
/// SQLite 的 `ORDER BY title` 是**按码点**比的，和用户在资源管理器里
/// 看到的顺序不一样，最明显的是数字：
///
/// ```
/// 码点序：笔记10, 笔记2, 笔记3      ← "1" < "2"，所以 10 跑到 2 前面
/// 资源管理器：笔记2, 笔记3, 笔记10   ← 数字按数值大小
/// ```
///
/// 这里生成一个**可直接用于 SQL 排序**的字符串键，解决两类问题：
///   1. **数字按数值排**：数字段补零到固定宽度，`2` → `0000000002`
///   2. **大小写不敏感**：统一转小写
///
/// ⚠️ **中文仍按码点排**，不是拼音序。Windows 在中文环境下用拼音，
/// 但那需要一份汉字-拼音对照表（几万条），不适合塞进这里。
/// 同一份笔记库里中文标题的相对顺序至少是**稳定**的。
library;

/// 数字段补零到这个宽度。10 位足够覆盖任何现实的文件名编号。
const int _kNumberPad = 10;

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

/// 把标题变成一个"排出来像资源管理器"的键。
String windowsSortKey(String title) {
  // 首尾空白不参与比较 —— Windows 也忽略它们
  final s = title.trim().toLowerCase();
  if (s.isEmpty) return '';

  final b = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final c = s.codeUnitAt(i);
    if (_isDigit(c)) {
      var j = i;
      while (j < s.length && _isDigit(s.codeUnitAt(j))) {
        j++;
      }
      final digits = s.substring(i, j);
      // 超长数字段（比如一串日期 20230910）不补零，否则会撑爆键长；
      // 等长时按字典序本来就等于按数值序。
      b.write(
        digits.length >= _kNumberPad
            ? digits
            : digits.padLeft(_kNumberPad, '0'),
      );
      i = j;
    } else {
      b.writeCharCode(c);
      i++;
    }
  }
  return b.toString();
}

/// 直接比较两个标题的"Windows 顺序"。测试和内存排序用。
int windowsCompare(String a, String b) =>
    windowsSortKey(a).compareTo(windowsSortKey(b));
