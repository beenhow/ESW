#ifndef RUNNER_WINDOW_SETUP_H_
#define RUNNER_WINDOW_SETUP_H_

#include <windows.h>
#include <windowsx.h>

#include <flutter_windows.h>

// 启动期「原生一次性窗口设定」。
//
// 背景：1.5.7 及以前的启动路径是 —— Dart 侧 runApp 之前用 window_manager 依次
// 发起 setTitleBarStyle / setTitle / setSize / setAlignment / setMinimumSize
// 五个平台调用（Future.wait 并行）。每个往返都要等平台线程回到消息循环，实测
// 合计把「窗口可见」推迟 300ms 以上；而且 size / alignment 是在原生窗口与
// Flutter 视图创建之后才生效，必然多触发一次重排版。
//
// 现在改为：客户区尺寸（1200×680 DIP）、最小尺寸（900×600 DIP）、屏幕居中、
// 隐藏系统标题栏，全部在 Win32Window::Create 内部、FlutterViewController 创建
// 之前一次性用 Win32 API 完成 —— Dart 侧不再有任何窗口设置平台调用，视图尺寸
// 一次到位，不存在「创建后再改尺寸」引发的重排版。
//
// 开关：ESW_NATIVE_WIN_SETUP=0 时整体关闭（仅用于 A/B 对照，复现旧行为）。
namespace esw_window_setup {

// 前置声明：圆角刷新在文件末尾定义（依赖 DPI / 最大化状态），
// 启动期一次性设定里需要调用一次。
inline void ApplyRoundedCorners(HWND hwnd);

// 设计基准（DIP）：与 Dart 侧 GlassTheme 的 1200×680 保持一致。
constexpr int kWidthDip = 1200;
constexpr int kHeightDip = 680;
// 最小窗口尺寸（DIP）：缩放下限 0.75 时仍能完整容纳主界面骨架。
constexpr int kMinWidthDip = 900;
constexpr int kMinHeightDip = 600;

// 是否启用原生一次性窗口设定（默认启用）。
inline bool NativeSetupEnabled() {
  char buf[8] = {};
  const DWORD len =
      ::GetEnvironmentVariableA("ESW_NATIVE_WIN_SETUP", buf, sizeof(buf));
  return !(len == 1 && buf[0] == '0');
}

// 取窗口当前 DPI（Win10 1607+ 用 GetDpiForWindow，老系统按所在显示器兜底）。
inline UINT DpiForWindowSafe(HWND hwnd) {
  using GetDpiForWindowFn = UINT(WINAPI*)(HWND);
  static GetDpiForWindowFn fn = reinterpret_cast<GetDpiForWindowFn>(
      ::GetProcAddress(::GetModuleHandleA("user32.dll"), "GetDpiForWindow"));
  if (fn != nullptr && hwnd != nullptr) {
    const UINT dpi = fn(hwnd);
    if (dpi != 0) {
      return dpi;
    }
  }
  return FlutterDesktopGetDpiForMonitor(
      ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST));
}

// 按给定样式/DPI 把「客户区尺寸」换算成「窗口外框尺寸」。
inline void ClientToWindowRect(HWND hwnd, LONG_PTR style, DWORD ex_style,
                               int client_width, int client_height, RECT* out) {
  out->left = 0;
  out->top = 0;
  out->right = client_width;
  out->bottom = client_height;
  const UINT dpi = DpiForWindowSafe(hwnd);
  using AdjustForDpiFn = BOOL(WINAPI*)(LPRECT, DWORD, BOOL, DWORD, UINT);
  static AdjustForDpiFn adjust_for_dpi = reinterpret_cast<AdjustForDpiFn>(
      ::GetProcAddress(::GetModuleHandleA("user32.dll"),
                       "AdjustWindowRectExForDpi"));
  if (adjust_for_dpi != nullptr) {
    adjust_for_dpi(out, static_cast<DWORD>(style), FALSE, ex_style, dpi);
  } else {
    ::AdjustWindowRectEx(out, static_cast<DWORD>(style), FALSE, ex_style);
  }
}

// 一次性设定：去系统标题栏 + 客户区尺寸 + 屏幕居中。
// 必须在 FlutterViewController 创建之前调用（即 Win32Window::Create 内、
// OnCreate 之前），此时窗口尚未 Show，用户无感知，且不会触发任何重排版。
inline void ApplyOneShotWindowSetup(HWND hwnd) {
  if (hwnd == nullptr || !NativeSetupEnabled()) {
    return;
  }

  const UINT dpi = DpiForWindowSafe(hwnd);
  const double scale = static_cast<double>(dpi) / 96.0;

  const LONG_PTR style_before = ::GetWindowLongPtr(hwnd, GWL_STYLE);
  const LONG_PTR ex_style = ::GetWindowLongPtr(hwnd, GWL_EXSTYLE);
  // ① 去掉系统标题栏（界面用自绘顶栏），保留 WS_THICKFRAME —— 缩放边框、
  //    投影、Aero Snap 全部保留；窗口文本仍作为任务栏/Alt+Tab 标题。
  const LONG_PTR style = style_before & ~static_cast<LONG_PTR>(WS_CAPTION);
  if (style != style_before) {
    ::SetWindowLongPtr(hwnd, GWL_STYLE, style);
  }

  // ② 客户区目标尺寸 = 1200×680 DIP，按新样式反算外框尺寸。
  RECT rect = {};
  ClientToWindowRect(hwnd, style, static_cast<DWORD>(ex_style),
                     static_cast<int>(kWidthDip * scale + 0.5),
                     static_cast<int>(kHeightDip * scale + 0.5), &rect);
  const int win_width = rect.right - rect.left;
  const int win_height = rect.bottom - rect.top;

  // ③ 在窗口所在显示器的工作区内居中（多显示器时跟随窗口实际所在屏）。
  RECT work = {0, 0, ::GetSystemMetrics(SM_CXSCREEN),
               ::GetSystemMetrics(SM_CYSCREEN)};
  MONITORINFO monitor_info = {};
  monitor_info.cbSize = sizeof(monitor_info);
  if (::GetMonitorInfoW(::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                        &monitor_info)) {
    work = monitor_info.rcWork;
  }
  const int x = work.left + ((work.right - work.left) - win_width) / 2;
  const int y = work.top + ((work.bottom - work.top) - win_height) / 2;

  // 单次 SetWindowPos 完成位置 + 尺寸 + 样式生效（SWP_FRAMECHANGED）。
  ::SetWindowPos(hwnd, nullptr, x, y, win_width, win_height,
                 SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED);

  // ④ 圆角：Win11 走 DWM 原生圆角，Win10 回退 SetWindowRgn。
  //    必须在窗口已具备最终尺寸后调用（回退路径按窗口宽高生成圆角区域）。
  ApplyRoundedCorners(hwnd);
}

// WM_GETMINMAXINFO：最小窗口尺寸一次性交给系统，替代 Dart 侧
// windowManager.setMinimumSize 的启动期往返。
// 返回 true 表示已接管该消息（调用方应返回 0）。
inline bool ApplyMinTrackSize(HWND hwnd, MINMAXINFO* info) {
  if (info == nullptr || hwnd == nullptr || !NativeSetupEnabled()) {
    return false;
  }
  const UINT dpi = DpiForWindowSafe(hwnd);
  const double scale = static_cast<double>(dpi) / 96.0;
  const LONG_PTR style = ::GetWindowLongPtr(hwnd, GWL_STYLE);
  const LONG_PTR ex_style = ::GetWindowLongPtr(hwnd, GWL_EXSTYLE);

  RECT rect = {};
  ClientToWindowRect(hwnd, style, static_cast<DWORD>(ex_style),
                     static_cast<int>(kMinWidthDip * scale + 0.5),
                     static_cast<int>(kMinHeightDip * scale + 0.5), &rect);

  // ptMinTrackSize 是含外框的窗口尺寸，这里按最小客户区反算。
  const int min_width = rect.right - rect.left;
  const int min_height = rect.bottom - rect.top;
  if (info->ptMinTrackSize.x < min_width) {
    info->ptMinTrackSize.x = min_width;
  }
  if (info->ptMinTrackSize.y < min_height) {
    info->ptMinTrackSize.y = min_height;
  }
  return true;
}

// 当前系统边框厚度（物理像素；进程已声明 Per-Monitor V2，多显示器/缩放由系统换算）。
inline int SystemFrameWidth() {
  int frame = ::GetSystemMetrics(SM_CXSIZEFRAME) +
              ::GetSystemMetrics(SM_CXPADDEDBORDER);
  if (frame <= 0) {
    frame = 4;
  }
  return frame;
}

// 去系统标题栏后，窗口四边的缩放热区厚度：比系统边框略厚一点，避免贴边难点。
inline int ResizeBorderWidth(HWND hwnd) {
  if (hwnd == nullptr) {
    return SystemFrameWidth();
  }
  int width = static_cast<int>(SystemFrameWidth() * 1.5);
  if (width < 6) {
    width = 6;
  }
  return width;
}

// WM_NCCALCSIZE —— 顶部 ~7px 深色横条的根因所在。
//
// 去掉 WS_CAPTION 后窗口仍保留 WS_THICKFRAME，如果该消息继续交给
// DefWindowProc，系统会把客户区从窗口外框里再内缩一圈非客户边框（顶部约
// SM_CYSIZEFRAME + SM_CXPADDEDBORDER 像素）。Flutter 视图是按客户区尺寸铺的
// 子窗口，那圈内缩区域既不绘制 Flutter 内容、窗口类又没设背景刷
// （hbrBackground = 0），于是露出未绘制的深色横条。
//
// 处理：wParam == TRUE 时直接返回 TRUE（调用方返回 0，不再调 DefWindowProc），
// 客户区 = 整窗，横条消失；最大化时窗口外框会超出工作区一圈边框，需要把客户区
// 收回对应厚度，否则顶边内容会被屏幕边缘吃掉。
// 返回 true 表示已接管（调用方应 return 0）。
inline bool HandleNcCalcSize(HWND hwnd, WPARAM wparam, LPARAM lparam) {
  // wParam == FALSE 时 lParam 是 RECT*，语义简单，交回系统即可。
  if (hwnd == nullptr || wparam != TRUE || !NativeSetupEnabled()) {
    return false;
  }
  auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
  if (params == nullptr) {
    return false;
  }
  if (::IsZoomed(hwnd)) {
    // 最大化：客户区直接取「该窗口所在显示器的工作区」，不再用
    // SM_CYSIZEFRAME + SM_CXPADDEDBORDER 去猜边框厚度。
    //
    // 旧写法按系统边框常量把外框内缩一圈，得到的客户区比工作区小 1~2px，
    // 于是最大化后顶边会留下一条始终存在的细带（未绘制 → 背景刷色），
    // 并且厚度随 DPI 缩放变化（125% 下 8px→10px），与「顶栏条带」肉眼观感一致。
    // 工作区即最大化应当铺满的区域，客户区与之严格相等后顶边零残留。
    MONITORINFO mi = {};
    mi.cbSize = sizeof(MONITORINFO);
    const HMONITOR monitor =
        ::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    if (monitor != nullptr && ::GetMonitorInfo(monitor, &mi)) {
      params->rgrc[0] = mi.rcWork;
      return true;
    }
    const int frame_x = SystemFrameWidth();
    const int frame_y = ::GetSystemMetrics(SM_CYSIZEFRAME) +
                        ::GetSystemMetrics(SM_CXPADDEDBORDER);
    params->rgrc[0].left += frame_x;
    params->rgrc[0].right -= frame_x;
    params->rgrc[0].top += frame_y > 0 ? frame_y : 4;
    params->rgrc[0].bottom -= frame_y > 0 ? frame_y : 4;
  }
  return true;
}

// 自绘标题栏高度（DIP）：与 Dart 侧 GlassTheme.hTitleBar = 42 保持一致。
constexpr int kTitleBarHeightDip = 42;
// 自绘窗口三键几何（DIP）：与 Dart 侧 _buildWindowButton 的 SizedBox(32×26) 一致。
constexpr int kWinBtnCount = 3;
constexpr int kWinBtnWidthDip = 32;
constexpr int kTitleBarRightPaddingDip = 16;

// 圆角半径（DIP）：Win10 回退路径使用；Win11 走 DWM 原生圆角，半径由系统决定（8）。
constexpr int kCornerRadiusDip = 8;

// 该点是否落在「自绘标题栏空白拖动带」内：
//   顶部 42 DIP 高的整条标题栏，扣除右侧窗口三键（最小化/最大化/关闭）交互区。
// 三键区必须留给 Flutter 处理点击，其余空白处交给系统 HTCAPTION 拖动。
inline bool IsPointInTitleBarDragBand(HWND hwnd, POINT screen_pt) {
  RECT window_rect = {};
  if (hwnd == nullptr || !::GetWindowRect(hwnd, &window_rect)) {
    return false;
  }
  const double scale = static_cast<double>(DpiForWindowSafe(hwnd)) / 96.0;
  const int band = static_cast<int>(kTitleBarHeightDip * scale + 0.5);
  const int y_from_top = screen_pt.y - window_rect.top;
  if (y_from_top < 0 || y_from_top >= band) {
    return false;
  }
  if (screen_pt.x < window_rect.left || screen_pt.x >= window_rect.right) {
    return false;
  }
  // 右侧三键交互区（右内边距 16 DIP + 3×32 DIP），再多留 2 DIP 容差。
  const int buttons_left =
      static_cast<int>((kTitleBarRightPaddingDip + kWinBtnCount * kWinBtnWidthDip) *
                           scale +
                       0.5) -
      2;
  const int x_from_right = window_rect.right - screen_pt.x;
  if (x_from_right >= 0 && x_from_right <= buttons_left) {
    return false;
  }
  return true;
}

// WM_NCHITTEST —— 客户区铺满整窗之后，四边/四角的缩放热区系统不再代劳，
// 由这里按窗口 rect 与鼠标屏幕坐标自行判定；其余位置返回 HTCLIENT 走正常逻辑。
// 返回非 HTCLIENT 表示命中缩放边框/标题栏（调用方应直接返回该值）。
//
// 关于「无法拖动窗口」的修复：
//   去掉 WS_CAPTION 之后窗口没有标题栏，系统不会自己给出 HTCAPTION，
//   而 Dart 侧 windowManager.startDragging() 走的是
//   SendMessage(WM_SYSCOMMAND, SC_MOVE | HTCAPTION) —— 这条路依赖 DefWindowProc
//   对「带标题栏窗口」的模态移动循环，且同样只在系统判定的标题栏矩形内生效，
//   自绘顶栏（客户区内）根本不在系统标题栏矩形里，于是拖动无效。
//   这里直接在命中测试里把「顶部 42 DIP 空白带」判成 HTCAPTION，拖动 / 双击
//   最大化还原全部回到系统标准非客户区流程，稳定可靠。
inline LRESULT HandleNcHitTest(HWND hwnd, LPARAM lparam) {
  if (hwnd == nullptr || !NativeSetupEnabled()) {
    return HTCLIENT;
  }
  // 最小化时不参与命中判定。
  if (::IsIconic(hwnd)) {
    return HTCLIENT;
  }
  RECT window_rect = {};
  if (!::GetWindowRect(hwnd, &window_rect)) {
    return HTCLIENT;
  }
  const POINT pt = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
  const bool zoomed = ::IsZoomed(hwnd) != FALSE;
  if (!zoomed) {
    const int border = ResizeBorderWidth(hwnd);
    const bool left = pt.x < window_rect.left + border;
    const bool right = pt.x >= window_rect.right - border;
    const bool top = pt.y < window_rect.top + border;
    const bool bottom = pt.y >= window_rect.bottom - border;
    if (top && left) return HTTOPLEFT;
    if (top && right) return HTTOPRIGHT;
    if (bottom && left) return HTBOTTOMLEFT;
    if (bottom && right) return HTBOTTOMRIGHT;
    if (left) return HTLEFT;
    if (right) return HTRIGHT;
    if (top) return HTTOP;
    if (bottom) return HTBOTTOM;
  }
  // 自绘标题栏空白带：HTCAPTION（拖动移动窗口；双击由系统最大化/还原）。
  // 最大化状态下同样返回 HTCAPTION —— 此时按住拖动会自动还原并跟随移动，
  // 双击也能还原，符合原生窗口习惯。
  if (IsPointInTitleBarDragBand(hwnd, pt)) {
    return HTCAPTION;
  }
  return HTCLIENT;
}

// ============================ 窗口圆角 ============================
//
// 现象：主窗口四角是直角。Win11 的 DWM 默认会给「标准帧窗口」加圆角，但本工程
// 为了自绘顶栏把 WS_CAPTION 去掉了，DWM 因此不再按普通窗口处理，圆角失效。
//
// 处理：
//   Win11（build 22000+）显式设置 DWMWA_WINDOW_CORNER_PREFERENCE = DWMWCP_ROUND，
//   由 DWM 自己裁剪圆角 —— 不改变窗口矩形，四边缩放热区、自绘顶栏完全不受
//   影响；最大化时系统自动恢复直角。
//   Win10 及更早系统该属性不存在（DwmSetWindowAttribute 返回失败），回退到
//   SetWindowRgn + CreateRoundRectRgn 的圆角区域裁剪；最大化时清空区域恢复直角
//   （否则最大化后四角会缺一块，贴屏留缝）。
constexpr DWORD kDwmwaWindowCornerPreference = 33;  // DWMWA_WINDOW_CORNER_PREFERENCE
constexpr int kDwmwcpDoNotRound = 1;
constexpr int kDwmwcpRound = 2;

inline bool SetDwmCornerPreference(HWND hwnd, int preference) {
  using DwmSetWindowAttributeFn = HRESULT(WINAPI*)(HWND, DWORD, LPCVOID, DWORD);
  static DwmSetWindowAttributeFn dwm_set = [] {
    HMODULE dwmapi = ::LoadLibraryW(L"dwmapi.dll");
    if (dwmapi == nullptr) {
      return static_cast<DwmSetWindowAttributeFn>(nullptr);
    }
    return reinterpret_cast<DwmSetWindowAttributeFn>(
        ::GetProcAddress(dwmapi, "DwmSetWindowAttribute"));
  }();
  if (dwm_set == nullptr || hwnd == nullptr) {
    return false;
  }
  const int pref = preference;
  const HRESULT hr = dwm_set(hwnd, kDwmwaWindowCornerPreference, &pref,
                             static_cast<DWORD>(sizeof(pref)));
  return SUCCEEDED(hr);
}

inline bool WindowHasRegion(HWND hwnd) {
  HRGN probe = ::CreateRectRgn(0, 0, 0, 0);
  if (probe == nullptr) {
    return false;
  }
  const int type = ::GetWindowRgn(hwnd, probe);
  ::DeleteObject(probe);
  return type != ERROR;
}

// 按当前「是否最大化」刷新圆角。幂等，可在 WM_SIZE / WM_DPICHANGED 后重复调用。
inline void ApplyRoundedCorners(HWND hwnd) {
  if (hwnd == nullptr || !NativeSetupEnabled()) {
    return;
  }
  // SetWindowRgn 会再次触发 WM_WINDOWPOSCHANGED/WM_SIZE，这里做重入保护。
  static bool updating = false;
  if (updating) {
    return;
  }
  updating = true;

  const bool zoomed = ::IsZoomed(hwnd) != FALSE;
  const UINT dpi = DpiForWindowSafe(hwnd);

  // Win11 的 DWM 原生圆角只取决于「最大化状态 + DPI」，与窗口宽高无关。
  // 但 ApplyRoundedCorners 会被每一个 WM_SIZE 调用，若每次都执行
  // DwmSetWindowAttribute，等于每帧都要求 DWM 重算非客户区（NC 重绘）：
  // 连续拖动缩放、最大化/还原动画期间，顶边就会周期性地闪出一条细带。
  // 这里把上一次生效的参数缓存起来，状态未变时直接跳过，DWM 只在真正
  // 需要切换圆角（最大化↔还原、跨 DPI 监视器）时才被调用一次。
  static HWND cached_hwnd = nullptr;
  static bool cached_zoomed = false;
  static UINT cached_dpi = 0;
  static bool cached_dwm_ok = false;
  if (cached_dwm_ok && cached_hwnd == hwnd && cached_zoomed == zoomed &&
      cached_dpi == dpi) {
    updating = false;
    return;
  }

  // ① Win11：DWM 原生圆角（最大化时显式取消圆角，与系统行为一致）。
  if (SetDwmCornerPreference(hwnd, zoomed ? kDwmwcpDoNotRound : kDwmwcpRound)) {
    if (WindowHasRegion(hwnd)) {
      ::SetWindowRgn(hwnd, nullptr, TRUE);  // 清掉可能残留的区域裁切
    }
    cached_hwnd = hwnd;
    cached_zoomed = zoomed;
    cached_dpi = dpi;
    cached_dwm_ok = true;
    updating = false;
    return;
  }
  cached_dwm_ok = false;

  // ② Win10 回退：GDI 圆角区域。
  if (zoomed || ::IsIconic(hwnd)) {
    if (WindowHasRegion(hwnd)) {
      ::SetWindowRgn(hwnd, nullptr, TRUE);
    }
    updating = false;
    return;
  }
  RECT window_rect = {};
  if (!::GetWindowRect(hwnd, &window_rect)) {
    updating = false;
    return;
  }
  const int width = window_rect.right - window_rect.left;
  const int height = window_rect.bottom - window_rect.top;
  if (width <= 0 || height <= 0) {
    updating = false;
    return;
  }
  const double scale = static_cast<double>(DpiForWindowSafe(hwnd)) / 96.0;
  int radius = static_cast<int>(kCornerRadiusDip * scale + 0.5);
  if (radius < 4) {
    radius = 4;
  }
  // CreateRoundRectRgn 的宽高是椭圆直径，所以传半径的 2 倍；右下角 +1 避免少一像素。
  HRGN rgn = ::CreateRoundRectRgn(0, 0, width + 1, height + 1, radius * 2,
                                  radius * 2);
  if (rgn != nullptr) {
    ::SetWindowRgn(hwnd, rgn, TRUE);  // 成功后 rgn 归系统所有，不再 DeleteObject
  }
  updating = false;
}

}  // namespace esw_window_setup

#endif  // RUNNER_WINDOW_SETUP_H_
