/// 应用的语言设置：不只是给翻译用的，**框架自带的文案全靠它**。
///
/// 起因：编辑笔记时框选文字，弹出的那排操作在英文系统上是
/// Cut / Copy / Paste / Select all —— 因为 `MaterialApp` 没接
/// `GlobalMaterialLocalizations`，这些字就跟着系统语言走。
/// 本应用其余文案全是手写中文，所以这里把语言**钉死成 zh-CN**（不跟随系统），
/// 顺带把日期选择器、无障碍语义标签也一起变成中文。
///
/// 抽成常量而不是写死在 `main.dart` 里，是为了让测试能拿到**同一份配置**：
/// 测试用这些常量搭一个 MaterialApp，就能验证"框选后的菜单真的是中文"，
/// 而不是只验证某个字符串常量。
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

/// 界面语言。钉死中文：英文系统上也要出中文菜单。
const Locale kAppLocale = Locale('zh', 'CN');

/// 声明支持的语言（en 只是兜底，避免第三方控件在极端情况下找不到资源）。
const List<Locale> kAppSupportedLocales = <Locale>[kAppLocale, Locale('en')];

/// 三个框架委托缺一不可：
///   · Material —— 文字框选后的剪切/复制/粘贴/全选、日期时间选择器、对话框默认按钮；
///   · Widgets  —— 滚动、语义（无障碍朗读）等通用文案；
///   · Cupertino—— iOS 风格控件（选择菜单、返回按钮）的文案。
const List<LocalizationsDelegate<dynamic>> kAppLocalizationsDelegates =
    <LocalizationsDelegate<dynamic>>[
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];
