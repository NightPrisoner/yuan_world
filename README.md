<div align="center">

# 元世界

**本地优先的笔记与知识可视化工具**

数据全部存在你自己的机器上 · 不联网 · 不上传 · 不登录

Flutter · Windows + Android

</div>

---

## 下载

| 平台 | 版本 | 下载 |
|:---|:---|:---|
| **Windows 10/11 x64** | 1.0.0 | [yuan_world-1.0.0-windows-x64-20261026.zip](https://github.com/NightPrisoner/yuan_world/releases/download/v1.0.0/yuan_world-1.0.0-windows-x64-20261026.zip) |
| **Android（arm64-v8a）** | 1.0.0 | [yuan_world-1.0.0-android-arm64-20261026.zip](https://github.com/NightPrisoner/yuan_world/releases/download/v1.0.0/yuan_world-1.0.0-android-arm64-20261026.zip) |

全部版本 → **[Releases](https://github.com/NightPrisoner/yuan_world/releases)**　　使用教程 → **[使用说明.md](使用说明.md)**

两个包都是**空数据包**，第一次打开就是干净的空白库。

**Windows**：解压到任意位置，双击 `元世界.exe`。DLL 和 `data` 目录要跟着，别只拿 exe。

**Android**：装 APK，允许「未知来源」。这个包是 arm64 的，近五年的安卓机基本都是这个架构。

> ⚠️ Android 包用调试证书签名（开源自构建的正常做法）。换构建版本覆盖安装会失败，得先卸载，而卸载会清数据 —— **升级前先备份**。

---

## 它是什么

一个给自己用的笔记软件。写下来、整理好、找得到，数据攥在自己手里。

### 写作

Markdown 风格的纯文本编辑，标题、列表、引用、代码块、图片、视频混排。不必记语法，工具栏点就行。

- 自动保存，写崩了也有草稿兜底
- 历史版本，改坏了能翻回去
- 双链 `[[另一篇笔记]]`，写的时候就串起来
- 中文输入法、跨段选择、连续格式切换都调过

### 组织

- **文件夹树**：任意层嵌套，拖拽整理
- **标签**：一篇可以挂多个，交叉筛选
- **收藏、归档、回收站**：该留的留，该退的退
- **全文搜索**：中文子串检索，两个字也能走索引，不是全表扫

### 看得见的数据

概览、趋势、累计、文件夹占比与对比、活跃热力图、发布时段、篇幅分布、连续天数、长篇排行、标签频率、高频词、自定义参数的数值统计。概览显示哪些项、模块什么顺序，都能自己调。

### 数据安全

- **每日自动快照**：只含数据库，几兆，自动轮转
- **完整备份**：数据库 + 全部图片视频打成一个 zip，可取消
- **异地目录**：再复制一份到移动硬盘或网盘同步目录
- **数据位置可搬移**：换电脑、换盘都行，搬完只留一份
- 所有备份都能一键恢复，恢复前自动留安全副本

### 导入导出

- 导入：`.docx` / `.txt` / `.md`，支持整目录递归、按相对路径还原文件夹层级、自动识别文首的标题作者文集
- 导出：Markdown / 纯文本 / DOCX / HTML，单篇或整个文集

详细用法见 **[使用说明.md](使用说明.md)**。

---

## 平台差异

|  | Windows | Android |
|:---|:---|:---|
| 布局 | 三栏：导航 / 列表 / 正文 | 底部四标签，逐层进入 |
| 菜单 | 贴鼠标弹出 | 底部弹层 |
| 整理 | 直接拖拽 | 长按拖动 |
| 悬停 | 卡片微微上浮 | 无 |
| 快捷键 | `Ctrl+N` 新建、`Ctrl+F` 搜索、`Ctrl+1`~`Ctrl+6` 切分区、`Ctrl+/` 看全部 | 无 |
| 数据位置 | 可自定义 | 应用私有目录 |

---

## 从源码构建

```bash
flutter pub get
flutter test          # 1188 条测试
flutter analyze

# Windows
flutter build windows --release
# 产物：build/windows/x64/runner/Release/元世界.exe

# Android
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk
```

要求 Flutter 3.47+ / Dart 3.13+。Android 还需要 SDK 与 NDK（`third_party` 里的 SQLite 要编）。

### 关于 `third_party/sqlite3/`

`package:sqlite3` 默认会去 GitHub Releases 下载预编译动态库。这个项目改成**从本地 C 源码编译**（`pubspec.yaml` 里 `sqlite3: source: source` + `path: third_party/sqlite3/sqlite3.c`），原因是最初开发时网络访问不了 GitHub Releases。

**如果你的网络正常，可以把它换回默认方式**，仓库能少 9.7 MB：

1. 删掉 `third_party/` 目录
2. 把 `pubspec.yaml` 里 `sqlite3:` 下面那两行（`source: source` / `path: ...`）删掉
3. `flutter pub get` 重来

保留源码编译的好处是完全离线可构建，也不依赖 GitHub 的可达性。

### 目录结构

```
lib/
  core/          主题、动效、快捷键、平台适配、通用组件
  data/          数据库、仓储、导入导出、备份（不依赖 Flutter）
  features/      各页面：笔记、编辑器、统计、设置、导入…
  app_state.dart 全局状态（Provider）
test/            90 个测试文件
third_party/     SQLite amalgamation 源码
tool/            CLI 工具：批量导入、数据库探针、数据修复
android/ windows/  平台工程
```

`lib/data` 不 import Flutter，所以 `tool/import_cli.dart` 这种纯命令行工具能复用同一套逻辑。

---

## 已知限制

- **没有跨设备同步**。两端各自独立，用导出/导入手动搬。
- 自动快照默认和数据在同一块盘上。要真防灾，得在设置里另配一个异地目录。
- Android 用调试签名，不能上架应用商店。
- **没有 iOS 版**。缺 Mac 无法构建和验证，代码层面也还没做适配。
- 导入只支持 docx / txt / md，PDF 和网页剪藏还没有。
- 应用内暂无多语言，只有中文。

---

## 反馈

用着有问题：应用里 设置 → 帮助与诊断 → 导出诊断信息，复制内容贴到 [Issues](https://github.com/NightPrisoner/yuan_world/issues)。

日志在 `data/logs/`，最多保留 30 份。

---

## 许可

[MIT](LICENSE)
