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
#include "perf_mark.h"
#include "window_setup.h"

// Thread-safe queue for files dropped via WM_DROPFILES
static std::mutex g_dropMutex;
static std::queue<std::string> g_droppedFiles;
static HWND g_flutterHwnd = nullptr;

// Original child window WndProc (restored in OnDestroy)
static WNDPROC g_originalChildProc = nullptr;

// Debug: write timestamped message to file (%TEMP%\esw_drop_debug.txt)
// Note: an older build hardcoded C:\Users\Administrator\Desktop\drop_debug.txt and
// skipped null checks; fopen fails for non-Administrator users so FILE* was NULL and
// fprintf crashed -> root cause of the Win10 2-second crash.
static void DropDebug(const char* msg) {
  char tmp[MAX_PATH] = {};
  if (GetTempPathA(MAX_PATH, tmp) == 0) return;
  std::string logPath = std::string(tmp) + "esw_drop_debug.txt";
  FILE* f = nullptr;
  if (fopen_s(&f, logPath.c_str(), "a") == 0 && f != nullptr) {
    SYSTEMTIME st;
    GetLocalTime(&st);
    fprintf(f, "%02d:%02d:%02d.%03d  %s\n",
            st.wHour, st.wMinute, st.wSecond, st.wMilliseconds, msg);
    fclose(f);
  }
}

// Replacement WndProc for Flutter child window (direct hook via GWLP_WNDPROC)
static LRESULT CALLBACK ChildWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  // 父窗口是「客户区 = 整窗」的无边框窗口，四边/四角缩放热区落在 Flutter
  // 子窗口覆盖范围内，子窗口默认会把 WM_NCHITTEST 判成 HTCLIENT，父窗口的
  // 缩放判定永远收不到。这里把边缘命中以 HTTRANSPARENT 转回同一线程的父窗口，
  // 由父窗口的 HandleNcHitTest 返回 HTLEFT / HTBOTTOMRIGHT 等，恢复四边缩放。
  if (msg == WM_NCHITTEST) {
    HWND parent = ::GetParent(hwnd);
    if (parent != nullptr) {
      RECT window_rect = {};
      if (::GetWindowRect(parent, &window_rect)) {
        const POINT pt = {GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
        // ① 顶部自绘标题栏空白带（扣除右侧窗口三键交互区）：以 HTTRANSPARENT
        //    把命中测试透传给父窗口，由父窗口返回 HTCAPTION —— 拖动移动窗口、
        //    双击最大化/还原全部回到系统标准非客户区流程。
        //    这是「窗口拖不动」的修复点：去掉 WS_CAPTION 后系统不再提供标题栏
        //    非客户区，Dart 侧 startDragging()（SC_MOVE|HTCAPTION）落在客户区内
        //    同样无效；三键区继续保持 HTCLIENT 交给 Flutter 处理点击。
        if (esw_window_setup::IsPointInTitleBarDragBand(parent, pt)) {
          return HTTRANSPARENT;
        }
        if (!::IsZoomed(parent)) {
          const int border = esw_window_setup::ResizeBorderWidth(parent);
          if (pt.x < window_rect.left + border ||
              pt.x >= window_rect.right - border ||
              pt.y < window_rect.top + border ||
              pt.y >= window_rect.bottom - border) {
            return HTTRANSPARENT;
          }
        }
      }
    }
  }
  if (msg == WM_DROPFILES) {
    HDROP hDrop = reinterpret_cast<HDROP>(wp);
    UINT count = DragQueryFileW(hDrop, 0xFFFFFFFF, nullptr, 0);
    {
      char buf[256];
      snprintf(buf, sizeof(buf), "ChildWndProc: WM_DROPFILES received, %u file(s)", count);
      DropDebug(buf);
              for (UINT i = 0; i < count; i++) {
          wchar_t wbuf[MAX_PATH];
          DragQueryFileW(hDrop, i, wbuf, MAX_PATH);
          std::lock_guard<std::mutex> lock(g_dropMutex);
          char nbuf[MAX_PATH];
          WideCharToMultiByte(CP_UTF8, 0, wbuf, -1, nbuf, sizeof(nbuf), nullptr, nullptr);
          g_droppedFiles.push(nbuf);
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
  EswCxxPerfMark("onCreate.enter");
  if (!Win32Window::OnCreate()) {
    return false;
  }
  EswCxxPerfMark("onCreate.win32WindowReady");

  RECT frame = GetClientArea();

  // Guard: client area may be 0 when DPI is abnormal or the window is not yet
  // laid out; fall back to a default size to avoid a crash from initializing
  // FlutterViewController with a zero size (rare on Win10 high-DPI).
  int width = frame.right - frame.left;
  int height = frame.bottom - frame.top;
  if (width <= 0 || height <= 0) {
    width = 1280;
    height = 720;
  }

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      width, height, project_);
  EswCxxPerfMark("onCreate.viewControllerCreated");
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  EswCxxPerfMark("onCreate.pluginsRegistered");
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  EswCxxPerfMark("onCreate.childContentSet");

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    EswCxxPerfMark("firstFrame.nativeShow");
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

    // Direct WndProc hook (not SetWindowSubclass - more reliable with Flutter engine)
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
  // 最小窗口尺寸必须在最前处理：window_manager 插件同样会消费
  // WM_GETMINMAXINFO（无条件下返回 0），若先交给插件，原生设定的最小尺寸
  // 就不会生效。这里一次设定后直接返回，替代 Dart 侧 setMinimumSize 往返。
  if (message == WM_GETMINMAXINFO) {
    if (esw_window_setup::ApplyMinTrackSize(
            hwnd, reinterpret_cast<MINMAXINFO*>(lparam))) {
      return 0;
    }
  }

  // 非客户区计算必须由原生层接管：去掉 WS_CAPTION 后若继续交给系统 / 插件，
  // 客户区仍会从窗口外框内缩一圈非客户边框，顶部那圈未绘制区域就是用户看到的
  // ~7px 深色横条。同样放在插件之前，避免 window_manager 的无边框逻辑覆盖。
  if (message == WM_NCCALCSIZE) {
    if (esw_window_setup::HandleNcCalcSize(hwnd, wparam, lparam)) {
      return 0;
    }
  }

  // 客户区 = 整窗后，四边/四角缩放热区由自己判定（Flutter 子窗口会先把边缘
  // 命中以 HTTRANSPARENT 转回本窗口，见 ChildWndProc）。
  if (message == WM_NCHITTEST) {
    const LRESULT hit = esw_window_setup::HandleNcHitTest(hwnd, lparam);
    if (hit != HTCLIENT) {
      return hit;
    }
  }

  // 圆角随「尺寸 / DPI / 最大化状态」刷新：Win11 由 DWM 自动处理最大化直角，
  // Win10 回退路径需要这里的 WM_SIZE 钩子 —— 最大化时清掉圆角区域（否则四角
  // 缺块、贴屏留缝），还原时按新宽高重新生成圆角区域。
  if (message == WM_SIZE || message == WM_DPICHANGED) {
    esw_window_setup::ApplyRoundedCorners(hwnd);
  }

  // 激活/退出尺寸循环后强制引擎出一帧：
  // 系统对话框（保存/打开）关闭、或从最大化还原后，窗口可能带着「激活前」
  // 的合成缓存回到前台，Flutter 侧又没有触发重绘，顶栏就会停一帧旧像素。
  // 这里显式请求一帧，保证回到前台的第一帧就是当前状态，顶栏不再残留旧条带。
  if (message == WM_ACTIVATE || message == WM_EXITSIZEMOVE) {
    if (message == WM_EXITSIZEMOVE || LOWORD(wparam) != WA_INACTIVE) {
      if (flutter_controller_ && flutter_controller_->engine()) {
        flutter_controller_->ForceRedraw();
      }
    }
  }

  // Handle WM_DROPFILES before Flutter engine processes it
  if (message == WM_DROPFILES) {
    HDROP hDrop = reinterpret_cast<HDROP>(wparam);
    UINT count = DragQueryFileW(hDrop, 0xFFFFFFFF, nullptr, 0);
    {
      char buf[256];
      snprintf(buf, sizeof(buf),
               "ParentHandler: WM_DROPFILES received, %u file(s)", count);
      DropDebug(buf);
              for (UINT i = 0; i < count; i++) {
          wchar_t wbuf[MAX_PATH];
          DragQueryFileW(hDrop, i, wbuf, MAX_PATH);
          std::lock_guard<std::mutex> lock(g_dropMutex);
          char nbuf[MAX_PATH];
          WideCharToMultiByte(CP_UTF8, 0, wbuf, -1, nbuf, sizeof(nbuf), nullptr, nullptr);
          g_droppedFiles.push(nbuf);
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
