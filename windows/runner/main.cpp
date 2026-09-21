#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <string>
#include <cstdio>

#include "flutter_window.h"
#include "utils.h"

// Crash log fallback: any unhandled native exception is written to
// %TEMP%\esw_crash.log so a silent crash can still be diagnosed
// (used for Win10 compatibility investigation).
static void WriteCrashInfo(const char* stage, DWORD code = 0) {
  char tmp[MAX_PATH] = {};
  if (GetTempPathA(MAX_PATH, tmp) == 0) return;
  std::string logPath = std::string(tmp) + "esw_crash.log";
  FILE* f = nullptr;
  if (fopen_s(&f, logPath.c_str(), "a") == 0 && f != nullptr) {
    SYSTEMTIME st;
    GetLocalTime(&st);
    fprintf(f, "%04d-%02d-%02d %02d:%02d:%02d.%03d  %s  code=0x%08X\n",
            st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond,
            st.wMilliseconds, stage, code);
    fclose(f);
  }
}

static LONG WINAPI CrashFilter(EXCEPTION_POINTERS* ep) {
  WriteCrashInfo("unhandled exception",
                 ep ? ep->ExceptionRecord->ExceptionCode : 0);
  return EXCEPTION_EXECUTE_HANDLER;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Register unhandled exception filter: log native crash then exit.
  SetUnhandledExceptionFilter(CrashFilter);

  // Explicitly enable Per-Monitor V2 DPI awareness to support older Win10
  // builds that may not honor the manifest.
  using SetProcessDpiAwarenessContextFn = BOOL(WINAPI*)(DPI_AWARENESS_CONTEXT);
  if (auto fn = reinterpret_cast<SetProcessDpiAwarenessContextFn>(
          GetProcAddress(GetModuleHandleA("user32.dll"),
                         "SetProcessDpiAwarenessContext"))) {
    fn(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  }

  WriteCrashInfo("startup");

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

  // Append version to window title (strip "+build" suffix, e.g. 1.5.2+4 -> 1.5.2)
  std::string ver(FLUTTER_VERSION);
  const size_t plusPos = ver.find('+');
  if (plusPos != std::string::npos) {
    ver = ver.substr(0, plusPos);
  }
  std::wstring wver(ver.begin(), ver.end());
  std::wstring title = L"\u771F\u9898\u8BFE\u6807\u8BCD v" + wver;
  if (!window.Create(title, origin, size)) {
    WriteCrashInfo("window.Create failed", GetLastError());
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
