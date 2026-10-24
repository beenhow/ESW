import 'dart:async';
import 'dart:ffi';
import 'dart:io' show Platform;

import 'package:flutter/scheduler.dart';

/// Windows 窗口「整窗强制重绘」工具。
///
/// 背景：本应用自绘标题栏（约 33px），导出时弹出的系统保存对话框是独立的
/// 原生顶层窗口。对话框关闭后，Windows 只对暴露出来的区域做增量重绘，
/// 若 Flutter 侧没有产生新帧，顶栏下沿会残留对话框投影/旧像素，表现为
/// 一条与上下不一致的横向条带（界面割裂）。仅靠 Dart 侧 setState 不足：
/// 需要显式让系统窗口（含子 HWND）整窗失效并立即重绘。
///
/// 做法：调用 user32 的 RedrawWindow，标志位
/// RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN | RDW_UPDATENOW | RDW_FRAME，
/// 并配合 SchedulerBinding.ensureVisualUpdate 让 Flutter 也立刻出一帧。
class WinWindowRepaint {
  WinWindowRepaint._();

  static DynamicLibrary? _user32;
  static int Function()? _getActiveWindow;
  static int Function(int, Pointer<Void>, Pointer<Void>, int)? _redrawWindow;
  static bool _inited = false;

  static bool get _supported => Platform.isWindows;

  static void _init() {
    if (_inited || !_supported) return;
    _inited = true;
    try {
      _user32 = DynamicLibrary.open('user32.dll');
      _getActiveWindow = _user32!
          .lookupFunction<IntPtr Function(), int Function()>(
        'GetActiveWindow',
      );
      _redrawWindow = _user32!.lookupFunction<
          Int32 Function(IntPtr, Pointer<Void>, Pointer<Void>, Uint32),
          int Function(int, Pointer<Void>, Pointer<Void>, int)>('RedrawWindow');
    } catch (_) {
      _user32 = null;
    }
  }

  /// 立即让当前活动窗口整窗失效并同步重绘一次。
  static void now() {
    if (!_supported) return;
    try {
      SchedulerBinding.instance.ensureVisualUpdate();
    } catch (_) {}
    _init();
    final getActive = _getActiveWindow;
    final redraw = _redrawWindow;
    if (getActive == null || redraw == null) return;
    try {
      final hwnd = getActive();
      if (hwnd == 0) return;
      const int flags =
          0x0001 | // RDW_INVALIDATE
          0x0004 | // RDW_ERASE
          0x0080 | // RDW_ALLCHILDREN
          0x0100 | // RDW_UPDATENOW
          0x0400; // RDW_FRAME
      redraw(hwnd, Pointer<Void>.fromAddress(0),
          Pointer<Void>.fromAddress(0), flags);
    } catch (_) {}
  }

  /// 重绘脉冲：对话框关闭瞬间系统可能仍在处理投影/非客户区，单次重绘
  /// 有可能被紧随其后的系统绘制覆盖，因此在若干毫秒点上重复触发。
  static void burst({List<int> atMs = const [0, 16, 48, 120, 240, 480]}) {
    if (!_supported) return;
    now();
    for (final ms in atMs) {
      if (ms <= 0) continue;
      Timer(Duration(milliseconds: ms), now);
    }
  }
}
