/// 导出文件的时间戳：让文档的"创建/修改时间"跟随笔记本身。
///
/// ## 为什么必须做
///
/// 导出后资源管理器里显示的是**导出那一刻**，500 篇导出来时间全一样，
/// 按时间排序等于没排；Word 的"文件属性"里也看不出这篇是什么时候写的。
/// 笔记本身是有真实创建/修改时间的，导出应当把它带出去。
///
/// ## 各处的落点
///
///   · 压缩包内每个条目：`ArchiveFile.lastModTime`（DOS 格式，见 [dosTimeOf]）
///   · 落盘到目录/单篇保存：文件系统的修改时间（[applyNoteTimes]）
///   · docx 内部：`docProps/core.xml` 的 `dcterms:created/modified`
///     —— Word 打开后"文件 → 信息"看到的就是这个
///
/// ## 创建时间为什么需要 FFI
///
/// Dart 只有 `File.setLastModified`（改的是**修改**时间），没有设置创建时间的
/// API，而 Windows 上"创建日期"恰恰是资源管理器默认显示的那一列。
/// 所以 Windows 走 `SetFileTime`；其它平台文件系统没有"创建时间"这个概念
/// （Linux/Android 只有 ctime，且**不允许**用户改写），设置修改时间即可。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// 把 [path] 的时间戳改成笔记的时间。
///
/// [created] / [modified] 为空时该项不动。任何一步失败都**静默跳过**：
/// 时间戳只是元信息，绝不能因为它把导出本身搞失败。
void applyNoteTimes(
  String path, {
  DateTime? created,
  DateTime? modified,
}) {
  if (modified != null) {
    try {
      File(path).setLastModifiedSync(modified);
    } catch (_) {
      // 文件系统不支持或没权限，无所谓
    }
  }
  if (created != null && Platform.isWindows) {
    _setWindowsCreationTime(path, created, modified);
  }
}

/// DateTime → zip 条目要的时间戳（**Unix 纪元秒**）。
///
/// 注意这里踩过一个坑：`archive` 包里**编码和解码用的不是同一个单位** ——
///   · 编码：[ArchiveFile.lastModTime] 会被 `×1000` 当成毫秒时间戳
///     （`ZipEncoder` 里 `DateTime.fromMillisecondsSinceEpoch(lastModTime * 1000)`），
///     所以传进去的必须是**纪元秒**；
///   · 解码：`ZipDecoder` 给出的却是 DOS 打包值（`date << 16 | time`）。
/// 按 DOS 值去设，写出来的日期会变成 2010 年那种莫名其妙的年份。
int epochSecondsOf(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;

/// 把 zip 条目里的 DOS 时间戳拆成年月日时分（测试用，也方便排查）。
///
/// DOS 布局：高位 16 bit 是日期 `年(7) 月(4) 日(5)`（年从 1980 起），
/// 低位 16 bit 是时间 `时(5) 分(6) 秒(5)`（秒的粒度是 2 秒）。
({int year, int month, int day, int hour, int minute, int second})
    parseDosTime(int packed) => (
      year: ((packed >> 25) & 0x7f) + 1980,
      month: (packed >> 21) & 0x0f,
      day: (packed >> 16) & 0x1f,
      hour: (packed >> 11) & 0x1f,
      minute: (packed >> 5) & 0x3f,
      second: (packed & 0x1f) * 2,
    );

/// DateTime → OOXML 的 W3CDTF 时间串（`2026-01-01T00:00:00Z`）。
///
/// 统一按 UTC 输出：core.xml 里带 `Z` 才是明确的时刻，
/// 不带时区的本地时间在别的机器上会被解读成当地时刻。
String w3cDate(DateTime t) {
  final u = t.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}'
      'T${two(u.hour)}:${two(u.minute)}:${two(u.second)}Z';
}

// ── Windows 创建时间 ──────────────────────────────────────────────────────

/// FILETIME 起点（1601-01-01 UTC）到 Unix 纪元的微秒数。
const int _kFiletimeEpochOffsetUs = 11644473600000000;

/// FILETIME 的单位是 100 纳秒，所以是微秒数 ×10。
int _filetimeOf(DateTime t) =>
    (t.toUtc().microsecondsSinceEpoch + _kFiletimeEpochOffsetUs) * 10;

const int _kFileWriteAttributes = 0x0100;
const int _kFileShareAll = 0x00000001 | 0x00000002 | 0x00000004;
const int _kOpenExisting = 3;
const int _kInvalidHandle = -1;

typedef _CreateFileWNative = IntPtr Function(
  Pointer<Utf16> lpFileName,
  Uint32 dwDesiredAccess,
  Uint32 dwShareMode,
  Pointer<Void> lpSecurityAttributes,
  Uint32 dwCreationDisposition,
  Uint32 dwFlagsAndAttributes,
  IntPtr hTemplateFile,
);
typedef _CreateFileWDart = int Function(
  Pointer<Utf16> lpFileName,
  int dwDesiredAccess,
  int dwShareMode,
  Pointer<Void> lpSecurityAttributes,
  int dwCreationDisposition,
  int dwFlagsAndAttributes,
  int hTemplateFile,
);

typedef _SetFileTimeNative = Int32 Function(
  IntPtr hFile,
  Pointer<Uint64> lpCreationTime,
  Pointer<Uint64> lpLastAccessTime,
  Pointer<Uint64> lpLastWriteTime,
);
typedef _SetFileTimeDart = int Function(
  int hFile,
  Pointer<Uint64> lpCreationTime,
  Pointer<Uint64> lpLastAccessTime,
  Pointer<Uint64> lpLastWriteTime,
);

typedef _CloseHandleNative = Int32 Function(IntPtr hObject);
typedef _CloseHandleDart = int Function(int hObject);

/// 用 `SetFileTime` 改写创建时间。
///
/// 三个参数依次是**创建 / 访问 / 写入**。传 `nullptr` 表示该项不动 ——
/// 这里访问时间不动、写入时间按 [modified] 设。
///
/// （踩过的坑：三个参数全传同一个指针，等于把"最后写入时间"也改成了创建时间，
/// 结果文件显示"创建 2024、修改 2024"，修改时间那一栏白白丢了。）
void _setWindowsCreationTime(String path, DateTime created, DateTime? modified) {
  try {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final createFile =
        kernel32.lookupFunction<_CreateFileWNative, _CreateFileWDart>(
      'CreateFileW',
    );
    final setFileTime =
        kernel32.lookupFunction<_SetFileTimeNative, _SetFileTimeDart>(
      'SetFileTime',
    );
    final closeHandle =
        kernel32.lookupFunction<_CloseHandleNative, _CloseHandleDart>(
      'CloseHandle',
    );

    final namePtr = path.toNativeUtf16();
    final createdPtr = calloc<Uint64>();
    final modifiedPtr = modified == null ? nullptr : calloc<Uint64>();
    var handle = _kInvalidHandle;
    try {
      // 只要 FILE_WRITE_ATTRIBUTES：改时间戳不需要写数据的权限
      handle = createFile(
        namePtr,
        _kFileWriteAttributes,
        _kFileShareAll,
        nullptr,
        _kOpenExisting,
        0,
        0,
      );
      if (handle == _kInvalidHandle) return;

      createdPtr.value = _filetimeOf(created);
      if (modified != null) {
        modifiedPtr.value = _filetimeOf(modified);
      }
      setFileTime(
        handle,
        createdPtr,
        nullptr,
        modified == null ? nullptr : modifiedPtr,
      );
    } finally {
      if (handle != _kInvalidHandle) closeHandle(handle);
      calloc.free(namePtr);
      calloc.free(createdPtr);
      if (modified != null) calloc.free(modifiedPtr);
    }
  } catch (_) {
    // 拿不到 kernel32 / 调用失败都算了，时间戳不值得让导出失败
  }
}
