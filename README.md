
# ESW — 真题课标词

**Exam-tested Syllabus Words**

一款面向高中英语命题研究的 Windows和Android应用程序，帮助命题者在真题语料中快速检测课标词汇的覆盖情况。

---

## 功能特性

- **词汇检索**：内置最新版3100课标词汇+初中专有名词+不规则变化词，合计3325词。
- **词汇分类**：按「真题词」「课标词」「拓展词」「超纲词」「专有词」五级分类，支持实时搜索和过滤。
- **语料分析**：支持导入 TXT / PDF / DOCX 格式的真题语料，自动扫描并标记其中出现的词汇。
- **拖拽导入**：通过 Windows 原生 WM_DROPFILES 机制将文件直接拖入窗口即可导入。
- **OCR 识别**：集成 Tesseract OCR，可将扫描版 PDF 转为可检索文本。
- **词库扩展**：支持自定义拓展词库和词根映射，数据持久化存储。
- **词频统计**：对已导入语料中的词汇进行出现频次统计，功能对标Antconc，在检索速度上完胜。
- **系统支持**：目前电脑版仅支持win10和win11，安卓版支持7.0（API 24）及以上，后续可能拓展版本和系统支持。

---

## 技术栈

| 层面 | 技术 |
|------|------|
| UI 框架 | Flutter (Windows) |
| 语言 | Dart + C (FFI) |
| 构建 | CMake + MSVC (Visual Studio) |
| PDF 解析 | pdfrx |
| OCR | Tesseract CLI |
| 文档解析 | archive (EPUB), xml (DOCX) |
| 打包格式 | 独立 EXE，附 data/、tesseract/、esw_config.json 及 DLL 依赖 |

---

## 安卓版本

ESW 同时提供 Android APK，支持手机端查词。

<<<<<<< HEAD
**Windows**
- 修复超纲词导出 Word 文档黄色高亮背景不生效
- 代码清理：删除约 325 行无效代码，13 处性能优化
- 修复 Dart 空安全编译错误
=======
- **最新版本**：[ESW](https://github.com/beenhow/ESW/releases/latest)
- 词典：本地离线词典（340万词条），含音标、释义、柯林斯星级、词频、变形词反查
- 功能：真题检测、词频统计、词库积累、离线查词
- UI：全局浅黄背景 #FFF8E1，词类标签置于音标上方加边框加粗
>>>>>>> 709b3684810134ba693011e39da06ce06c3e267c

> 安卓版与桌面版共享词库数据，通过数据备份功能可跨平台同步。

---

## 构建与运行

### 前置要求

- Flutter SDK ≥ 3.9.2
- Visual Studio 2022（含「使用 C++ 的桌面开发」工作负载）
- Windows 10 / 11

### 构建步骤

```powershell
# 1. 克隆仓库
git clone https://github.com/beenhow/ESW.git
cd ESW

# 2. 获取依赖
flutter pub get

# 3. Release 构建
flutter build windows --release

# 4. 产物位于 build/windows/x64/runner/Release/
```

### 运行

```powershell
flutter run -d windows
```

---

## 项目结构

```
ESW/
├── lib/                    # Dart 源码
│   ├── main.dart           # 主入口（窗口、词库、语料分析）
│   └── theme/              # 主题配置
├── windows/                # Windows 平台代码（CMake + C）
├── assets/                 # 内置资源
│   └── standard_words.json # 课标词库
├── esw_config.json         # 用户数据（拓展词、词根映射、历史记录）
├── data/                  # Tesseract 语言数据
├── tesseract/             # Tesseract CLI
├── pubspec.yaml           # Flutter 依赖配置
└── CMakeLists.txt         # CMake 构建入口
```

---

## 版本命名

版本号格式：`主版本.次版本.修订号`（如 `1.3.0`），窗口标题显示为 `真题课标词 v1.x.xx`。

<<<<<<< HEAD
```powershell
flutter pub get
flutter build windows --release
# 产物：build/windows/x64/runner/Release/ESW1.3.1.exe（需同目录 DLL 和 data/）
```

### Android

```powershell
flutter pub get
flutter build apk --release
# 产物：build/app/outputs/flutter-apk/app-release.apk
```
=======
>>>>>>> 709b3684810134ba693011e39da06ce06c3e267c

---

## 许可证

MIT
