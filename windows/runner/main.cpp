#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  // 窗口标题就是应用名（元世界）。以前这里是工程名 yuan_world，
  // 标题栏上显示的是一串英文下划线；运行时 window_manager 还会再设一次
  // （见 main.dart 的 _setupDesktopWindow），这里是首帧之前的那一下。
  //
  // **故意写成 \u 转义而不是直接把中文写进源码**：MSVC 默认按系统本地
  // 代码页读源文件，UTF-8 的中文（没有 BOM 时）会被读成乱码，
  // 直接报 "C2001 常量中有换行符"。转义形式跟编码无关，谁编译都一样。
  if (!window.Create(L"\u5143\u4E16\u754C", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
