/// 文件名排序键 —— 对齐 Windows 资源管理器的规则。
///
/// SQLite 的 `ORDER BY title` 是**按码点**比的，和用户在资源管理器里
/// 看到的顺序不一样，最明显的是两类：
///
/// ```
/// 数字：码点序 笔记10, 笔记2      ← "1" < "2"，所以 10 跑到 2 前面
///       资源管理器 笔记2, 笔记10   ← 数字按数值大小
///
/// 中文：码点序 是按部首笔画排的，和拼音毫无关系
///       资源管理器用拼音，阿(a) 在 波(b) 前面
/// ```
///
/// 这里生成一个**可直接用于 SQL 排序**的字符串键，解决三件事：
///   1. **数字按数值排**：数字段补零到固定宽度，`2` → `0000000002`
///   2. **大小写不敏感**：统一转小写
///   3. **中文按拼音**：用 lpinyin 把汉字转成拼音再比
///
/// ⚠️ **多音字会排错**。字典只知道"一个字最常见读什么"，
/// 分不出「银行(háng)」和「行走(xíng)」。这是单字字典的固有限制，
/// 不是 bug —— 要彻底解决得做词组切分，那是另一个量级。
library;

import 'package:lpinyin/lpinyin.dart';

/// 数字段补零到这个宽度。10 位足够覆盖任何现实的文件名编号。
const int _kNumberPad = 10;

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

/// 这个码位是不是需要转拼音的汉字。
///
/// 只认 CJK 基本区 + 扩展 A —— lpinyin 的字典就覆盖这些，
/// 更偏的字它也没有，送进去只会白费一次查表。
bool _isHan(int c) =>
    (c >= 0x4E00 && c <= 0x9FFF) || (c >= 0x3400 && c <= 0x4DBF);

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
      // 超长数字段（比如日期 20230910）不补零：等长时字典序就等于数值序，
      // 硬补会把键撑得很长。
      b.write(
        digits.length >= _kNumberPad
            ? digits
            : digits.padLeft(_kNumberPad, '0'),
      );
      i = j;
      continue;
    }

    if (_isHan(c)) {
      // 连续汉字一次性转 —— 逐个查表会慢好几倍
      var j = i;
      while (j < s.length && _isHan(s.codeUnitAt(j))) {
        j++;
      }
      final han = s.substring(i, j);
      // 分段之间加分隔符：不然「西安(xian)」和「先(xian)」会撞成同一个键
      b.write(_pinyinOf(han));
      b.write('-');
      i = j;
      continue;
    }

    b.writeCharCode(c);
    i++;
  }
  return b.toString();
}

String _pinyinOf(String han) {
  try {
    return PinyinHelper.getPinyinE(
      han,
      separator: '',
      defPinyin: '',
      format: PinyinFormat.WITHOUT_TONE,
    );
  } catch (_) {
    // 字典里查不到就原样返回，至少顺序是稳定的
    return han;
  }
}

/// 直接比较两个标题的"Windows 顺序"。测试和内存排序用。
int windowsCompare(String a, String b) =>
    windowsSortKey(a).compareTo(windowsSortKey(b));
