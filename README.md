---
AIGC:
    Label: "1"
    ContentProducer: 001191440300708461136T1XGW3
    ProduceID: 58517953bc17ebd4c00e5d39198d03e4_505711ab7f2311f18ce5525400826444
    ReservedCode1: qdhgJ6vQu90WRDqSgLFAWX0OHfFxXznhFqeoQQZcW+e1xZ6Fqc/3N9OdGBxZGOGvksR/BxEZaoyzpA5MLO0Quj5+ERthoBXP2C1OuPyvwChPfqTTyG/c/zme+xrSonAOeU0HRVS+OxMtpoALMKFfk+1Y3d453fOK2CJtN+ijWrHEOMduvJRrSAYz0Jk=
    ContentPropagator: 001191440300708461136T1XGW3
    PropagateID: 58517953bc17ebd4c00e5d39198d03e4_505711ab7f2311f18ce5525400826444
    ReservedCode2: qdhgJ6vQu90WRDqSgLFAWX0OHfFxXznhFqeoQQZcW+e1xZ6Fqc/3N9OdGBxZGOGvksR/BxEZaoyzpA5MLO0Quj5+ERthoBXP2C1OuPyvwChPfqTTyG/c/zme+xrSonAOeU0HRVS+OxMtpoALMKFfk+1Y3d453fOK2CJtN+ijWrHEOMduvJRrSAYz0Jk=
---

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

- **最新版本**：[ESW v1.0](https://github.com/beenhow/ESW/releases/download/v1.0/ESW.apk)
- 功能：离线中文翻译（ML Kit）、词频查询、真题检测、词库积累
- 部分功能需要联网（联网释义等）

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

版本号格式：`主版本.次版本.修订号`（如 `1.2.79`），窗口标题显示为 `真题课标词 v1.2.xx`。

每个正式版本部署到 `D:\UserData\Desktop\ESW\`，同时备份到 `E:\ESW{版本号}\`。

---

## 许可证

MIT
