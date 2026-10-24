#ifndef RUNNER_PERF_MARK_H_
#define RUNNER_PERF_MARK_H_

#include <windows.h>
#include <cstdio>
#include <string>

// 启动阶段原生探针（仅在设置环境变量 ESW_PERF_PROBE 时生效）。
//
// 目的：把「进程启动 -> Dart main 入口」这一段（Flutter 引擎与各插件 DLL 的
// 加载、原生窗口/视图创建）也纳入可复现的耗时归因 —— Dart 侧探针只能从
// main() 开始计时，看不到这段。输出追加到 ESW_PERF_LOG（默认 %TEMP%\esw_perf_log.txt），
// 与 Dart 侧探针共用同一份日志，按 'cxx ' / 'boot ' 前缀区分来源。
//
// 未设置 ESW_PERF_PROBE 时：一次环境变量查询后立即返回，生产运行无落盘、无副作用。
inline double EswCxxMsSinceProcessStart() {
  FILETIME create{}, exit{}, kernel{}, user{};
  if (!::GetProcessTimes(::GetCurrentProcess(), &create, &exit, &kernel, &user)) {
    return 0.0;
  }
  FILETIME now{};
  ::GetSystemTimeAsFileTime(&now);
  ULARGE_INTEGER c, n;
  c.LowPart = create.dwLowDateTime;
  c.HighPart = create.dwHighDateTime;
  n.LowPart = now.dwLowDateTime;
  n.HighPart = now.dwHighDateTime;
  return static_cast<double>(n.QuadPart - c.QuadPart) / 10000.0;  // 100ns -> ms
}

inline void EswCxxPerfMark(const char* tag) {
  if (::GetEnvironmentVariableA("ESW_PERF_PROBE", nullptr, 0) == 0) return;

  char buf[MAX_PATH] = {};
  std::string path;
  const DWORD len = ::GetEnvironmentVariableA("ESW_PERF_LOG", buf, MAX_PATH);
  if (len > 0 && len < MAX_PATH) {
    path = buf;
  } else {
    char tmp[MAX_PATH] = {};
    if (::GetTempPathA(MAX_PATH, tmp) == 0) return;
    path = std::string(tmp) + "esw_perf_log.txt";
  }

  // 同时写入本地墙钟时间，便于与 Dart 侧探针（进程内相对时间起点不同）
  // 归并到同一条时间轴上做交叉核对。
  SYSTEMTIME st{};
  ::GetLocalTime(&st);

  FILE* f = nullptr;
  if (fopen_s(&f, path.c_str(), "a") == 0 && f != nullptr) {
    fprintf(f, "cxx %s  t=%.1fms w=%02d:%02d:%02d.%03d\n", tag,
            EswCxxMsSinceProcessStart(), st.wHour, st.wMinute, st.wSecond,
            st.wMilliseconds);
    fclose(f);
  }
}

#endif  // RUNNER_PERF_MARK_H_
