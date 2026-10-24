#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <string>
#include <cstdio>

#include "flutter_window.h"
#include "perf_mark.h"
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

// ---------------- 运行环境自检（跨机器可运行性） ----------------
// 发布包必须自带 data\ 资源与 tesseract\ OCR 组件，且一律按「exe 同级相对路径」
// 定位。这里在窗口创建前做一次存在性检查：缺文件时弹出明确清单并退出，
// 而不是让界面起来之后因资源缺失闪退或功能静默失效。
// 仅在 Release 布局（data\app.so 存在）下生效，避免影响 flutter run 的 Debug 产物。
static void AppendMissingPath(std::wstring* out, const std::wstring& base,
                              const wchar_t* rel) {
  const std::wstring full = base + rel;
  if (GetFileAttributesW(full.c_str()) == INVALID_FILE_ATTRIBUTES) {
    if (!out->empty()) out->append(L"\n");
    out->append(L"  · ");
    out->append(rel);
  }
}

static bool PreflightRuntimeCheck() {
  wchar_t exe_path[MAX_PATH] = {};
  if (GetModuleFileNameW(nullptr, exe_path, MAX_PATH) == 0) return true;
  std::wstring dir(exe_path);
  const size_t slash = dir.find_last_of(L"\\/");
  if (slash == std::wstring::npos) return true;
  dir = dir.substr(0, slash + 1);  // 末尾保留分隔符

  // Debug/Profile 产物没有 app.so，直接放行。
  const std::wstring app_so = dir + L"data\\app.so";
  if (GetFileAttributesW(app_so.c_str()) == INVALID_FILE_ATTRIBUTES) return true;

  const wchar_t* kRequired[] = {
      L"data\\icudtl.dat",
      L"data\\app.so",
      L"data\\flutter_assets\\assets\\ecdict.db",
      L"data\\flutter_assets\\assets\\standard_words.json",
      L"tesseract\\tesseract.exe",
      L"tesseract\\tessdata\\chi_sim.traineddata",
      L"tesseract\\tessdata\\eng.traineddata",
  };
  const wchar_t* kRequiredDlls[] = {
      L"flutter_windows.dll",
      L"window_manager_plugin.dll",
      L"pdfrx.dll",
      L"pdfium.dll",
      L"sqlite3.dll",
      L"sqlite3_flutter_libs_plugin.dll",
      L"charset_converter_plugin.dll",
      L"file_selector_windows_plugin.dll",
      L"screen_retriever_windows_plugin.dll",
      L"url_launcher_windows_plugin.dll",
  };

  std::wstring missing;
  for (const wchar_t* rel : kRequired) AppendMissingPath(&missing, dir, rel);
  for (const wchar_t* rel : kRequiredDlls) AppendMissingPath(&missing, dir, rel);
  if (missing.empty()) return true;

  const std::wstring msg =
      L"程序缺少必要的运行文件，无法启动。\n\n缺失清单：\n" + missing +
      L"\n\n请使用完整的发布包：解压后保持 exe、data、tesseract 在同一目录，"
      L"不要单独复制 exe。\n\n当前程序目录：\n" + dir;
  MessageBoxW(nullptr, msg.c_str(), L"真题课标词 · 运行环境不完整",
              MB_ICONERROR | MB_OK);
  return false;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // 启动探针（仅 ESW_PERF_PROBE 时落盘）：进程创建 -> 此处已包含 CRT 与
  // 各导入 DLL 的加载时间，是 Dart 侧探针看不到的一段。
  EswCxxPerfMark("wWinMain.enter");

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

  // 运行环境自检：缺 data\ / tesseract\ / 插件 DLL 时明确提示后退出。
  if (!PreflightRuntimeCheck()) {
    WriteCrashInfo("preflight.missing_runtime_files");
    ::CoUninitialize();
    return EXIT_FAILURE;
  }

  flutter::DartProject project(L"data");
  EswCxxPerfMark("dartProject.ready");

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
  EswCxxPerfMark("window.Create.return");

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
