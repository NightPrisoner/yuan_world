# fix_plugin_junctions.ps1
#
# 作用：为 Flutter Windows 项目的插件重建「目录联接（Junction）」。
#
# 为什么需要这个：
#   `flutter build windows` 要求为每个插件创建符号链接，而在 Windows 上
#   创建符号链接需要「开发者模式」或管理员权限。本机两者都没有，
#   于是构建会直接失败：
#       Building with plugins requires symlink support.
#       Please enable Developer Mode in your system settings.
#
#   但 flutter_tools 的逻辑是（见 flutter_plugins.dart:1272）：
#       如果链接已经存在，就跳过创建。
#   而「目录联接」用 mklink /J 即可创建，**不需要任何特权**。
#   所以只要提前把链接建好，构建就能通过。
#
# 什么时候需要跑：
#   - 每次 `flutter pub add` 引入或移除了带 Windows 实现的插件之后
#   - 每次执行 `flutter clean` 之后（会清掉 ephemeral 目录）
#
# 用法：
#   pwsh -File tool\fix_plugin_junctions.ps1 -ProjectDir "E:\deepseek work\yuanworld"
#
# 如果将来开启了开发者模式，就不需要这个脚本了。

param(
    [Parameter(Mandatory = $true)][string]$ProjectDir
)

$ErrorActionPreference = 'Stop'

$depsFile = Join-Path $ProjectDir '.flutter-plugins-dependencies'
if (-not (Test-Path $depsFile)) {
    Write-Host "找不到 $depsFile"
    Write-Host "请先在项目目录执行: flutter pub get"
    exit 1
}

$json = Get-Content $depsFile -Raw | ConvertFrom-Json
$plugins = $json.plugins.windows

$linkDir = Join-Path $ProjectDir 'windows\flutter\ephemeral\.plugin_symlinks'
New-Item -ItemType Directory -Force -Path $linkDir | Out-Null

if (-not $plugins -or $plugins.Count -eq 0) {
    Write-Host '该项目没有 Windows 平台插件，无需处理。'
    exit 0
}

Write-Host "为 $($plugins.Count) 个插件重建目录联接 -> $linkDir"

foreach ($p in $plugins) {
    $name = $p.name
    # JSON 里的路径是双反斜杠转义，且可能带结尾斜杠
    $target = ($p.path -replace '\\\\', '\').TrimEnd('\')
    $link = Join-Path $linkDir $name

    if (Test-Path $link) {
        # 用 rmdir 删除联接本身，不会动到目标目录
        & cmd /c rmdir "`"$link`"" 2>$null
    }

    if (-not (Test-Path $target)) {
        Write-Host "  [跳过] $name —— 目标不存在: $target"
        continue
    }

    New-Item -ItemType Junction -Path $link -Target $target -ErrorAction Stop | Out-Null
    $ok = Test-Path (Join-Path $link 'pubspec.yaml')
    Write-Host "  [OK] $name  (校验: $ok)"
}

Write-Host '完成。现在可以执行 flutter build windows 了。'
