#include "flutter_window.h"

#include <optional>
#include <shellapi.h>
#include <cstdio>
#include <mutex>
#include <queue>
#include <string>

// Fallback defines
#ifndef MSGFLT_ALLOW
#define MSGFLT_ALLOW 1
#endif
#ifndef WM_COPYGLOBALDATA
#define WM_COPYGLOBALDATA 0x0049
#endif

#include "flutter/generated_plugin_registrant.h"

// Thread-safe queue for files dropped via WM_DROPFILES
static std::mutex g_dropMutex;
static std::queue<std::string> g_droppedFiles;
static HWND g_flutterHwnd = nullptr;

// Original child window WndProc (restored in OnDestroy)
static WNDPROC g_originalChildProc = nullptr;

// Debug: write timestamped message to file
static void DropDebug(const char* msg) {
  FILE* f = nullptr;
  fopen_s(&f, "C:\\Users\\Administrator\\Desktop\\drop_debug.txt", "a");
  if (f) {
    SYSTEMTIME st;
    GetLocalTime(&st);
    fprintf(f, "%02d:%02d:%02d.%03d  %s\n",
            st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, msg);
    fclose(f);
  }
}

// Replacement WndProc for Flutter child window (direct hook via GWLP_WNDPROC)
static LRESULT CALLBACK ChildWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_DROPFILES) {
    HDROP hDrop = reinterpret_cast<HDROP>(wp);
    UINT count = DragQueryFileW(hDrop, 0xFFFFFFFF, nullptr, 0);
    {
      char buf[256];
      snprintf(buf, sizeof(buf), "ChildWndProc: WM_DROPFILES received, %u file(s)", count);
      DropDebug(buf);
      FILE* f2 = nullptr;
      fopen_s(&f2, "C:\\Users\\Administrator\\Desktop\\drop_debug.txt", "a");
      if (f2) {
        for (UINT i = 0; i < count; i++) {
          wchar_t wbuf[MAX_PATH];
          DragQueryFileW(hDrop, i, wbuf, MAX_PATH);
          fprintf(f2, "  [%u] %S\n", i, wbuf);
          std::lock_guard<std::mutex> lock(g_dropMutex);
          char nbuf[MAX_PATH];
          WideCharToMultiByte(CP_UTF8, 0, wbuf, -1, nbuf, sizeof(nbuf), nullptr, nullptr);
          g_droppedFiles.push(nbuf);
        }
        fclose(f2);
      }
    }
    DragFinish(hDrop);
    return 0;
  }
  return CallWindowProc(g_originalChildProc, hwnd, msg, wp, lp);
}

extern "C" __declspec(dllexport) const char* get_dropped_file() {
  std::lock_guard<std::mutex> lock(g_dropMutex);
  if (g_droppedFiles.empty()) return nullptr;
  static thread_local std::string last;
  last = std::move(g_droppedFiles.front());
  g_droppedFiles.pop();
  return last.c_str();
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  // Enable file drag-and-drop via WM_DROPFILES on parent and child windows
  HWND parentHwnd = GetHandle();
  DragAcceptFiles(parentHwnd, TRUE);
  // Allow WM_DROPFILES through UIPI (User Interface Privilege Isolation)
  ChangeWindowMessageFilterEx(parentHwnd, WM_DROPFILES, MSGFLT_ALLOW, nullptr);
  ChangeWindowMessageFilterEx(parentHwnd, WM_COPYGLOBALDATA, MSGFLT_ALLOW, nullptr);

  HWND flutterHwnd = flutter_controller_->view()->GetNativeWindow();
  if (flutterHwnd) {
    g_flutterHwnd = flutterHwnd;
    DragAcceptFiles(flutterHwnd, TRUE);
    ChangeWindowMessageFilterEx(flutterHwnd, WM_DROPFILES, MSGFLT_ALLOW, nullptr);
    ChangeWindowMessageFilterEx(flutterHwnd, WM_COPYGLOBALDATA, MSGFLT_ALLOW, nullptr);

    // Direct WndProc hook (not SetWindowSubclass — more reliable with Flutter engine)
    g_originalChildProc = reinterpret_cast<WNDPROC>(
        SetWindowLongPtr(flutterHwnd, GWLP_WNDPROC,
                         reinterpret_cast<LONG_PTR>(ChildWndProc)));
    {
      char buf[256];
      snprintf(buf, sizeof(buf),
               "OnCreate: parent=0x%p child=0x%p origChildProc=0x%p",
               parentHwnd, flutterHwnd, g_originalChildProc);
      DropDebug(buf);
    }
  }

  return true;
}

void FlutterWindow::OnDestroy() {
  if (g_flutterHwnd && g_originalChildProc) {
    SetWindowLongPtr(g_flutterHwnd, GWLP_WNDPROC,
                     reinterpret_cast<LONG_PTR>(g_originalChildProc));
    g_originalChildProc = nullptr;
    DropDebug("OnDestroy: restored original child WndProc");
  }
  g_flutterHwnd = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Handle WM_DROPFILES before Flutter engine processes it
  if (message == WM_DROPFILES) {
    HDROP hDrop = reinterpret_cast<HDROP>(wparam);
    UINT count = DragQueryFileW(hDrop, 0xFFFFFFFF, nullptr, 0);
    {
      char buf[256];
      snprintf(buf, sizeof(buf),
               "ParentHandler: WM_DROPFILES received, %u file(s)", count);
      DropDebug(buf);
      FILE* f2 = nullptr;
      fopen_s(&f2, "C:\\Users\\Administrator\\Desktop\\drop_debug.txt", "a");
      if (f2) {
        for (UINT i = 0; i < count; i++) {
          wchar_t wbuf[MAX_PATH];
          DragQueryFileW(hDrop, i, wbuf, MAX_PATH);
          fprintf(f2, "  [%u] %S\n", i, wbuf);
          std::lock_guard<std::mutex> lock(g_dropMutex);
          char nbuf[MAX_PATH];
          WideCharToMultiByte(CP_UTF8, 0, wbuf, -1, nbuf, sizeof(nbuf), nullptr, nullptr);
          g_droppedFiles.push(nbuf);
        }
        fclose(f2);
      }
    }
    DragFinish(hDrop);
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
