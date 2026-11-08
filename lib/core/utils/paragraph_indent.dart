import 'package:flutter/widgets.dart';

/// 首行缩进用的两个全角空格 —— **只是可见的那部分**。
///
/// 中文排版里的"空两格"就是两个汉字宽，而汉字宽度随字号、字体回退、
/// 系统字号缩放变，所以不能写死像素：13 号正文和 20 号正文缩进不一样宽。
/// 量一次 `TextPainter` 比算 `fontSize * 2` 更准（等宽字体、半角字体下差别明显）。
const String kIndentPad = '\u3000\u3000';

/// 粘在 [kIndentPad] 后面的**零宽词连接符**（WORD JOINER）。
///
/// 为什么非要它：`U+3000`（表意空格）在 Unicode 里是可断行空白（行断行类
/// BA），所以「两个全角空格」和后面的字之间**允许断行**。一行正好排到屏幕
/// 边缘时，断点就落在这两个空格后面 —— 第一行只剩两个空格、正文整个掉到
/// 第二行顶格，再打几个字又"正常"回来，看上去像缩进错位。
///
/// 实测（真实中文字体 NotoSansSC，正文用不会断行的数字串，376 宽）：
///   · `\u3000\u3000` + 37~40 个数字 → 第一行只剩 34 宽的两个空格 ✗
///   · `\u3000\u3000\u2060` + 同样的正文 → 从不出现 ✗ 现象 ✓
/// 而 `U+2060` 本身零宽、不算字数，只做"不许在这里断行"这一件事。
///
/// 阅读页不受影响（它把 pad 换成等宽 `WidgetSpan`），这条纯粹是给编辑器
/// 的纯文本渲染兜底 —— `TextField` 塞不了 `WidgetSpan`（会让
/// `value.text` 与 TextPainter 的纯文本索引错开一个字符，光标/选区/输入法
/// 全歪，见 flutter#12255 / #161014）。
const String kIndentGuard = '\u2060';

/// 编辑器真正写进正文的段首标记：[kIndentPad] + [kIndentGuard]。
const String kIndentMark = '$kIndentPad$kIndentGuard';

/// 这一行是不是缩进段。
///
/// 只认 [kIndentPad]：老数据里没有 [kIndentGuard]（加它之前存下的正文），
/// 也得照样认出来，否则升级一次旧笔记的缩进就全丢了。
bool hasIndentMark(String line) => line.startsWith(kIndentPad);

/// 去掉行首的段首标记，返回正文本身。
///
/// 老数据（只有两个全角空格）与新数据（空格 + 零宽连接符）都要处理干净，
/// 否则零宽连接符会跟着正文一起进 `_parseInline`，虽然看不见，但复制出来
/// 会带一个莫名其妙的字符。
String stripIndentMark(String line) {
  if (!line.startsWith(kIndentPad)) return line;
  var rest = line.substring(kIndentPad.length);
  if (rest.startsWith(kIndentGuard)) {
    rest = rest.substring(kIndentGuard.length);
  }
  return rest;
}

/// 段落缩进该多宽 —— **按当前字体量两个全角空格**。
double paragraphIndentWidth(BuildContext context, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: kIndentPad, style: style),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final w = painter.width;
  painter.dispose();
  return w;
}
