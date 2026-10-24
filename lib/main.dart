import 'package:flutter/material.dart';
import 'dart:async' show unawaited;
import 'dart:io' show Platform, Directory, File, FileMode;
import 'dart:ffi' as ffi;
import 'dart:ui' show PlatformDispatcher;
import 'package:sqlite3/open.dart' as sqlite3_open;
import 'package:window_manager/window_manager.dart';
import 'theme/esw_theme.dart';
import 'theme/glass_theme.dart' show FrostFilter;
import 'esw_perf_probe.dart';
import 'android_app.dart';
import 'windows_app.dart';

/// P5：全局异常日志落盘目录（%LOCALAPPDATA%\ESW 用户可写目录，异步初始化；
/// 极端早期未就绪时回退系统临时目录）。
/// 不再使用「文档目录」：跨机器时 Documents 可能被重定向/不可写。
String? _crashLogDir;

Future<void> _initCrashLogDir() async {
  try {
    final dir = eswUserDataDir;
    await Directory(dir).create(recursive: true);
    _crashLogDir = dir;
  } catch (_) {
    try {
      _crashLogDir = Directory.systemTemp.path;
    } catch (_) {}
  }
}

/// P5：全局异常兜底日志。统一记录到文档目录 esw_crash.log（追加模式），
/// 供后续诊断定位闪退/异常根因；写盘失败静默忽略，绝不影响主流程。
void _logGlobalError(String phase, Object error, StackTrace? stack) {
  final dir = _crashLogDir;
  if (dir == null) return;
  try {
    final lines = <String>[
      '===== [$phase] ${DateTime.now().toIso8601String()} =====',
      'ERROR: $error',
      if (stack != null) 'STACK:\n$stack',
      '',
    ];
    File('$dir/esw_crash.log')
        .writeAsStringSync(lines.join('\n'), mode: FileMode.append);
  } catch (_) {}
}

void main() async {
  // 启动阶段打点（仅 ESW_PERF_PROBE 时生效，生产运行零开销）
  EswPerf.boot('main.enter');
  WidgetsFlutterBinding.ensureInitialized();
  EswPerf.boot('binding.ready');

  // P5：全局异常兜底——注册 Flutter 错误与平台错误处理，未捕获异常一律
  // 记录日志（release 写文档目录），避免异常冒泡直接闪退且无任何诊断痕迹。
  unawaited(_initCrashLogDir());
  FlutterError.onError = (details) {
    _logGlobalError('FlutterError', details.exception, details.stack);
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    _logGlobalError('PlatformDispatcher', error, stack);
    return true;
  };

  // Android 必须显式初始化 sqlite3 FFI，否则 DictionaryService.lookup() 静默失败
  // 导致所有非课标词查不到词义（课标词有 VocabService JSON 兜底不受影响）
  if (Platform.isAndroid) {
    sqlite3_open.open.overrideFor(
      sqlite3_open.OperatingSystem.android,
      () => ffi.DynamicLibrary.open('libsqlite3.so'),
    );
  }

  if (Platform.isWindows) {
    // 任务④（运行速度）：全局背景模糊开关。本应用背景是近白柔光渐变、面板底色
    // 又是高不透明度白，模糊与否肉眼几乎不可分辨，却要付出成倍光栅耗时。
    // 默认开启（观感优先）；ESW_NO_BLUR=1 时整体关闭，仅用于性能对比/低配应急。
    FrostFilter.blurOn = Platform.environment['ESW_NO_BLUR'] != '1';
    // 自绘浅色标题栏：窗口客户区 1200×680、最小尺寸 900×600、屏幕居中、去系统
    // 标题栏，全部改由原生层在 CreateWindow 阶段一次性完成（windows/runner/
    // window_setup.h）——Dart 侧不再发起任何窗口设置平台调用，Flutter 视图按
    // 最终尺寸创建，连同「创建后再改尺寸」引发的重排版一起省掉。
    // 这里只保留 windowManager 初始化与「首帧后显示窗口」。
    await windowManager.ensureInitialized();
    EswPerf.boot('windowManager.ready');
    EswPerf.scheduleAutoExit();
    EswPerf.startStallWatch();
    const winSize = Size(1200, 680);
    const winMinSize = Size(900, 600);
    const winTitle = '真题课标词 v1.5.8';
    final swWin = Stopwatch()..start();
    // 5 个窗口设置互不依赖：并行发起，省掉串行平台往返（每个 ~5ms，冷启动更久）。
    // 逐项打点用于确认「谁来承担启动期平台往返成本」。
    Future<void> timed(String tag, Future<void> f) async {
      final sw = Stopwatch()..start();
      await f;
      EswPerf.bootDt('window.$tag', sw);
    }

    // 默认：窗口设定已在原生完成，Dart 侧零平台调用。
    // A/B 对照（复现 1.5.7 旧路径）：ESW_NATIVE_WIN_SETUP=0 且 ESW_WIN_SETUP=1，
    // 此时逐项打点，用于量化「平台往返 + 重排版」占用的启动时间。
    final winSetup = Platform.environment['ESW_WIN_SETUP'] != '1'
        ? Future<void>.value()
        : Future.wait<void>([
            timed('titleBarStyle',
                windowManager.setTitleBarStyle(TitleBarStyle.hidden)),
            timed('title', windowManager.setTitle(winTitle)),
            timed('size', windowManager.setSize(winSize)),
            timed('alignment', windowManager.setAlignment(Alignment.center)),
            timed('minSize', windowManager.setMinimumSize(winMinSize)),
          ]);
    if (Platform.environment['ESW_WIN_READY_CB'] == '1') {
      // 旧行为（A/B 对照用）：等待引擎 ready-to-show 信号后再显示窗口。
      // 实测该信号在本机约 550ms 才到达，而首帧 127ms 就已画完，
      // 等于白白多等 ~420ms 才让用户看到窗口。
      windowManager.waitUntilReadyToShow(null, () async {
        EswPerf.boot('readyToShow 回调进入');
        await winSetup;
        EswPerf.bootDt('window.setup', swWin);
        await windowManager.show();
        EswPerf.bootDt('window.show', swWin);
        await windowManager.focus();
        EswPerf.bootDt('window.focus', swWin);
        EswPerf.boot('window.shown');
      });
    } else {
      // 默认（启动提速）：不再等 ready-to-show 信号，改为「首帧渲染完成即显示」。
      // 窗口出现时间由 ~560ms 提前到首帧附近，内容已画好所以不会闪空白。
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        EswPerf.boot('first.frame 回调（触发显示窗口）');
        await winSetup;
        EswPerf.bootDt('window.setup', swWin);
        await windowManager.show();
        EswPerf.bootDt('window.show', swWin);
        await windowManager.focus();
        EswPerf.bootDt('window.focus', swWin);
        EswPerf.boot('window.shown');
      });
    }
    EswPerf.boot('runApp 前');
    runApp(const WinEswApp());
  } else {
    runApp(const EswApp());
  }
}

class EswApp extends StatelessWidget {
  const EswApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ESW',
      debugShowCheckedModeBanner: false,
      theme: EswTheme.light,
      home: const AndroidEswApp(),
    );
  }
}
