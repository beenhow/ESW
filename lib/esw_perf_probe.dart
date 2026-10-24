import 'dart:async';
import 'dart:io';
import 'dart:ui' show FramePhase, FrameTiming, Offset, Size;

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';

/// ESW 性能自测探针（仅在设置了环境变量 `ESW_PERF_PROBE` 时启用）。
///
/// 目的：为「运行提速」改造提供可复现的前后对比数据 —— 关键热路径的耗时
/// （微基准，单位毫秒）与真实交互期间的帧耗时（FrameTiming）。
///
/// 未设置环境变量时：所有入口立即 return，生产运行零开销、零副作用。
class EswPerf {
  EswPerf._();

  /// 是否启用探针。由进程环境变量决定，正常运行（双击 exe）永不开。
  static final bool enabled = Platform.environment['ESW_PERF_PROBE'] != null;

  static String get _logPath {
    final p = Platform.environment['ESW_PERF_LOG'];
    if (p != null && p.isNotEmpty) return p;
    return '${Directory.systemTemp.path}${Platform.pathSeparator}esw_perf_log.txt';
  }

  static final List<String> _lines = <String>[];

  /// 词库列表弹窗在探针模式下把「按输入重建列表」的回调登记于此，
  /// 便于脚本沿真实代码路径触发逐字重建并采集帧耗时。生产环境恒为 null。
  static void Function(String search)? bankSearchDriver;

  /// 微基准累加器：防止被测代码被编译器当作无副作用而优化掉。
  static int sink = 0;

  /// 逐帧明细开关（诊断用）：为 true 时每次采集到帧就把该帧的
  /// build / raster / total / vsync 耗时逐行打印，用于定位「一次性停顿」
  /// 究竟落在 UI 构建阶段还是光栅阶段。默认关闭。
  static bool logEachFrame = false;

  static void log(String s) {
    if (!enabled) return;
    _lines.add(s);
    stdout.writeln('[ESWPERF] $s');
  }

  /// 追加一行到探针日志文件（探针未启用时零开销）。
  /// 供导出等关键路径在进程被外部结束前也能留存耗时归因。
  static void logFile(String s) {
    if (!enabled) return;
    _lines.add(s);
    stdout.writeln('[ESWPERF] $s');
    try {
      File(_logPath).writeAsStringSync('$s\n', mode: FileMode.append);
    } catch (_) {}
  }

  /// 外部取证用打点：把 [tag] 与本地时间写入 [markerPath]（由环境变量给出），
  /// 供外部脚本按「打点时刻」同步抓取窗口画面，测量弹窗真正出现在屏幕上的时刻。
  static String? markerPath = Platform.environment['ESW_PERF_MARK'];

  static void mark(String tag) {
    if (!enabled) return;
    final p = markerPath;
    if (p == null) return;
    try {
      final now = DateTime.now();
      final ts = '${now.hour.toString().padLeft(2, '0')}:'
          '${now.minute.toString().padLeft(2, '0')}:'
          '${now.second.toString().padLeft(2, '0')}.'
          '${now.millisecond.toString().padLeft(3, '0')}';
      File(p).writeAsStringSync('$tag|$ts\n', mode: FileMode.append);
    } catch (_) {}
  }

  static Future<void> flush() async {
    if (!enabled) return;
    // boot()/log() already append every line to disk synchronously, so there is
    // nothing left to write here. Do NOT rewrite the whole file: the native
    // probe (windows/runner/perf_mark.h) appends 'cxx ' lines to the very same
    // log, and a full rewrite would truncate them.
  }

  // ==================== 启动阶段打点（boot phase） ====================
  // 目的：为「启动提速」给出可复现的阶段耗时归因 —— 以 dart main 入口为 0 点，
  // 记录每个启动阶段完成的墙钟时刻（毫秒）。与外部脚本的「进程启动→窗口出现」
  // 墙钟结合，即可定位启动耗时落在「引擎/依赖加载」还是「应用自建初始化」。
  //
  // 关键点：打点**立即追加**写入 ESW_PERF_LOG（而非攒在内存里最后统一 flush），
  // 因为启动测量常在进程被外部强制结束的情况下进行，内存缓冲会全部丢失。
  // 未启用探针（未设 ESW_PERF_PROBE）时：boot 立即 return，零开销、零副作用。
  static final Stopwatch _bootWatch = Stopwatch()..start();

  /// 启动阶段打点：tag 为阶段名，可自带 `dt=xxms` 形式的分段耗时。
  static void boot(String tag) {
    if (!enabled) return;
    final ms = _bootWatch.elapsedMicroseconds / 1000.0;
    final now = DateTime.now();
    final wall = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
    final line = 'boot $tag  t=${ms.toStringAsFixed(1)}ms w=$wall';
    _lines.add(line);
    stdout.writeln('[ESWPERF] $line');
    try {
      File(_logPath).writeAsStringSync('$line\n', mode: FileMode.append);
    } catch (_) {}
  }

  /// 一次性耗时打点：配合 `Stopwatch` 记录某段同步代码的净耗时。
  /// 例：`EswPerf.bootDt('loadStandardWords', sw)`。
  static void bootDt(String tag, Stopwatch sw) =>
      boot('$tag  dt=${(sw.elapsedMicroseconds / 1000.0).toStringAsFixed(1)}ms');

  /// 事件循环停顿看门狗（仅探针模式）：用一个 16ms 周期的 Timer 观察实际
  /// 触发间隔，若某次间隔 >= [thresholdMs] 说明 UI 线程被同步计算占用（期间
  /// Flutter 无法出帧，正是顶栏条带/割裂的成因），立即把停顿长度写进日志。
  /// 生产运行（未设 ESW_PERF_PROBE）调用即 return，零开销。
  static void startStallWatch({int thresholdMs = 60}) {
    if (!enabled) return;
    var last = DateTime.now();
    Timer.periodic(const Duration(milliseconds: 16), (t) {
      final now = DateTime.now();
      final gap = now.difference(last).inMilliseconds;
      last = now;
      if (gap >= thresholdMs) {
        logFile('[stall] gap=${gap}ms at ${now.hour}:${now.minute}:'
            '${now.second}.${now.millisecond}');
      }
    });
  }

  /// 自动退出钩子（仅测量用）：设 `ESW_PERF_EXIT_MS=8000` 时，进程启动 8 秒后
  /// 自行退出，便于脚本无人值守地采集「启动阶段打点」而无需强制结束进程。
  /// 未设环境变量时不注册任何定时器。
  static void scheduleAutoExit() {
    if (!enabled) return;
    final v = Platform.environment['ESW_PERF_EXIT_MS'];
    if (v == null) return;
    final ms = int.tryParse(v);
    if (ms == null || ms <= 0) return;
    Timer(Duration(milliseconds: ms), () {
      boot('autoExit(${ms}ms)');
      flush().whenComplete(() => exit(0));
    });
  }

  /// 微基准：重复 [times] 次执行 [body]（body 返回一个用于累加的值，
  /// 避免被测逻辑被优化掉），输出 平均 / 最小 / 最大 耗时（毫秒）。
  static void bench(String key, int times, int Function() body) {
    if (!enabled) return;
    // 预热一次，避免首次 JIT/缓存冷启动污染样本
    sink += body();
    final sw = Stopwatch();
    var min = double.infinity;
    var max = 0.0;
    var sum = 0.0;
    for (var i = 0; i < times; i++) {
      sw.reset();
      sw.start();
      sink += body();
      sw.stop();
      final ms = sw.elapsedMicroseconds / 1000.0;
      sum += ms;
      if (ms < min) min = ms;
      if (ms > max) max = ms;
    }
    final avg = sum / times;
    log('bench $key  n=$times  avg=${avg.toStringAsFixed(3)}ms'
        '  min=${min.toStringAsFixed(3)}ms  max=${max.toStringAsFixed(3)}ms');
  }

  static final List<FrameTiming> _frames = <FrameTiming>[];

  static void _onTimings(List<FrameTiming> timings) {
    _frames.addAll(timings);
    if (!logEachFrame) return;
    for (final f in timings) {
      log('frame  build=${_ms(f.buildDuration)}ms  '
          'raster=${_ms(f.rasterDuration)}ms  '
          'total=${_ms(f.totalSpan)}ms  '
          'vsync=${_ms(f.vsyncOverhead)}ms');
    }
  }

  static String _ms(Duration d) => (d.inMicroseconds / 1000.0).toStringAsFixed(2);

  /// 记录 [action] 执行期间产生的帧耗时统计（build / raster / 总耗时，
  /// 含 p90 与掉帧数；60fps 预算 16.7ms）。
  static Future<void> recordFrames(
    String key,
    Future<void> Function() action,
  ) async {
    if (!enabled) {
      await action();
      return;
    }
    final from = _frames.length;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    final sw = Stopwatch()..start();
    await action();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    sw.stop();
    final fs = _frames.sublist(from);
    if (fs.isEmpty) {
      log('frames $key  (无帧产生)  动作耗时=${sw.elapsedMilliseconds}ms');
      return;
    }
    final builds = <double>[];
    final rasters = <double>[];
    final totals = <double>[];
    for (final f in fs) {
      builds.add(f.buildDuration.inMicroseconds / 1000.0);
      rasters.add(f.rasterDuration.inMicroseconds / 1000.0);
      totals.add(f.totalSpan.inMicroseconds / 1000.0);
    }
    double avg(List<double> v) => v.reduce((a, b) => a + b) / v.length;
    double p90(List<double> v) {
      final s = List<double>.from(v)..sort();
      final i = ((s.length - 1) * 0.9).round();
      return s[i];
    }

    double maxOf(List<double> v) => v.reduce((a, b) => a > b ? a : b);

    final jank = totals.where((t) => t > 16.7).length;
    log('frames $key  n=${fs.length}  动作耗时=${sw.elapsedMilliseconds}ms'
        '  build avg=${avg(builds).toStringAsFixed(2)}/p90=${p90(builds).toStringAsFixed(2)}/max=${maxOf(builds).toStringAsFixed(2)}ms'
        '  raster avg=${avg(rasters).toStringAsFixed(2)}/p90=${p90(rasters).toStringAsFixed(2)}/max=${maxOf(rasters).toStringAsFixed(2)}ms'
        '  total avg=${avg(totals).toStringAsFixed(2)}/p90=${p90(totals).toStringAsFixed(2)}/max=${maxOf(totals).toStringAsFixed(2)}ms'
        '  jank(>16.7ms)=$jank/${fs.length}');
  }

  /// 测量「发起动作 → 首帧开始构建」的墙钟时长（毫秒），即用户可感知的
  /// 「点了之后多久画面才开始出来」；探针未启用时返回 -1。
  ///
  /// 同时输出三项诊断数据，用于区分停顿时落在哪一层：
  /// · `frameBegin @Xms`：每帧「开始构建」的墙钟偏移（帧是否按时产出）；
  /// · `latency#n @Yms`：每帧被引擎上报的时刻（若 Y 远大于 X，说明只是上报延迟）；
  /// · `UI事件循环最长空档`：8ms 心跳定时器的最大间隔，直接反映 UI 线程同步阻塞。
  /// · `首帧墙钟 / 动画跨度`：由 frameBegin 序列直接得出（**与上报无关，可信**）——
  ///   即「点了之后多久画面开始出来」「动画多久收敛」两个用户可感知的量化值；
  /// · `| 诊断:` 之后的两个批次级数值：引擎 FrameTiming 批量延迟投递，批次常夹带
  ///   本次测量之前的旧帧，其跨度与投递时刻**均不代表用户可见耗时**。
  static Future<double> openLatency(
    String key,
    Future<void> Function() action, {
    int frames = 2,
  }) async {
    if (!enabled) {
      unawaited(action());
      return -1;
    }
    final sw = Stopwatch()..start();
    final done = Completer<double>();
    final ticks = <int>[];
    final frameStamps = <int>[];
    var seen = 0;
    var logFrames = true;
    var baseTs = -1;
    var vsSpanMs = -1.0;
    // 本次测量首个「开始构建」帧的引擎时间戳（微秒）。引擎会批量延迟投递
    // FrameTiming，投递批次可能夹带本次测量之前的旧帧，故以该锚点过滤，
    // 保证统计到的都是本次动作触发的帧。
    var anchorUs = -1;
    void onBeginFrame(Duration _) {
      if (!logFrames) return;
      if (anchorUs < 0) {
        anchorUs = SchedulerBinding.instance.currentFrameTimeStamp.inMicroseconds;
      }
      frameStamps.add(sw.elapsedMilliseconds);
      log('  frameBegin @${sw.elapsedMilliseconds}ms');
    }

    void onTimings(List<FrameTiming> timings) {
      if (anchorUs < 0) return; // 本次测量的首帧还没开始构建 → 批次必为旧帧
      for (final f in timings) {
        seen += 1;
        final vs = f.timestampInMicroseconds(FramePhase.vsyncStart);
        final rf = f.timestampInMicroseconds(FramePhase.rasterFinish);
        if (vs < anchorUs) {
          seen -= 1; // 旧帧，不计入本次测量
          continue;
        }
        if (baseTs < 0) baseTs = vs;
        vsSpanMs = (rf - baseTs) / 1000.0;
        log('  latency#$seen @${sw.elapsedMilliseconds}ms  '
            'build=${(f.buildDuration.inMicroseconds / 1000.0).toStringAsFixed(1)}ms  '
            'raster=${(f.rasterDuration.inMicroseconds / 1000.0).toStringAsFixed(1)}ms  '
            '| 引擎时间线 vsyncStart=+${((vs - baseTs) / 1000.0).toStringAsFixed(1)}ms  '
            'rasterFinish=+${((rf - baseTs) / 1000.0).toStringAsFixed(1)}ms');
        if (seen >= frames && !done.isCompleted) {
          done.complete(sw.elapsedMicroseconds / 1000.0);
        }
      }
    }

    SchedulerBinding.instance.addPersistentFrameCallback(onBeginFrame);
    SchedulerBinding.instance.addTimingsCallback(onTimings);
    final watch = Timer.periodic(
      const Duration(milliseconds: 8),
      (_) => ticks.add(sw.elapsedMilliseconds),
    );
    unawaited(action());
    // 等前 [frames] 帧「上报」完成（延迟投递，仅作参考值）
    final batchMs = await done.future.timeout(
      const Duration(milliseconds: 1500),
      onTimeout: () => -1.0,
    );
    // 再等到动画回稳：连续约 140ms 无新帧，或最多再等 1200ms
    var quiet = 0;
    var lastSeen = frameStamps.length;
    final tailLimit = sw.elapsedMilliseconds + 1200;
    while (quiet < 7 && sw.elapsedMilliseconds < tailLimit) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      if (frameStamps.length == lastSeen) {
        if (frameStamps.isNotEmpty) quiet += 1;
      } else {
        lastSeen = frameStamps.length;
        quiet = 0;
      }
    }
    watch.cancel();
    SchedulerBinding.instance.removeTimingsCallback(onTimings);
    logFrames = false;

    var maxGap = 0;
    for (var i = 1; i < ticks.length; i++) {
      final gap = ticks[i] - ticks[i - 1];
      if (gap > maxGap) maxGap = gap;
    }
    final firstWall =
        frameStamps.isEmpty ? -1.0 : frameStamps.first.toDouble();
    final span = frameStamps.length < 2
        ? -1.0
        : (frameStamps.last - frameStamps.first).toDouble();
    log('latency $key  首帧墙钟=${firstWall < 0 ? "超时" : "${firstWall.toStringAsFixed(1)}ms"}'
        '  动画跨度=${span < 0 ? "n/a" : "${span.toStringAsFixed(1)}ms"}/${frameStamps.length}帧'
        '  UI事件循环最长空档=${maxGap}ms(心跳${ticks.length}次)'
        '  | 诊断: 本批次引擎跨度=${vsSpanMs < 0 ? "n/a" : "${vsSpanMs.toStringAsFixed(1)}ms"}'
        ' 本批次投递=${batchMs < 0 ? "超时" : "${batchMs.toStringAsFixed(1)}ms"}');
    return firstWall;
  }

  /// 鼠标横扫主界面：沿若干横行逐点派发 hover 事件，触发真实的
  /// hover 高亮 / 渐变 / 玻璃模糊层重绘，用于测量交互帧耗时。
  static Future<void> hoverSweep(
    Size windowSize, {
    int stepsPerRow = 12,
    List<double>? rows,
  }) async {
    if (!enabled) return;
    const device = 42;
    const pointer = 43;
    GestureBinding.instance.handlePointerEvent(
      const PointerAddedEvent(
        device: device,
        pointer: pointer,
        kind: PointerDeviceKind.mouse,
        position: Offset(10, 10),
      ),
    );
    final ys = rows ??
        <double>[
          14,
          32,
          64,
          120,
          168,
          300,
          430,
          windowSize.height - 60,
        ];
    final steps = stepsPerRow < 2 ? 2 : stepsPerRow;
    for (final y in ys) {
      if (y > windowSize.height - 4) continue;
      for (var i = 0; i < steps; i++) {
        final x = 60 + (windowSize.width - 120) * i / (steps - 1);
        GestureBinding.instance.handlePointerEvent(
          PointerHoverEvent(
            device: device,
            pointer: pointer,
            kind: PointerDeviceKind.mouse,
            position: Offset(x, y),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    }
    GestureBinding.instance.handlePointerEvent(
      const PointerRemovedEvent(
        device: device,
        pointer: pointer,
        kind: PointerDeviceKind.mouse,
        position: Offset(10, 10),
      ),
    );
  }
}
