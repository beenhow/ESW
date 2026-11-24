# ESW Android 端 unslop 审查报告

审查对象：Android 端全部界面（查词页、检测页、词库页、检测结果页、语料栏、原文查看、各类弹窗、图标与启动页）。
审查方式：静态代码审查 + 现有设计令牌/主题比对（本轮未打包、未运行、未改动任何代码）。
审查标准：unslop（作者 Damir Sokolovsky，CC BY 4.0），对照 `references/signs.md` 全部条目。
对照基准：Windows 端刚完成的一轮整改（单一强调色 #4462F2、中性投影、字重 ≤600、圆角 12/10、表头常规字距、扁平 logo）。

---

## 0. 结论

Android 端三张主页面（查词 / 检测 / 词库）骨架已经比较干净：没有跨色相渐变、没有 emoji 图标、没有大写宽字距表头、字号基本走令牌。
**"AI 感"集中在两处**：

1. **同一套界面里跑着两套色板、三个蓝、两种弹窗、两种卡片** —— 这是最像"多人/AI 拼出来的"的地方；
2. **查词结果卡与检测结果页** 用彩色描边、彩色投影、红色大标题、四色彩卡、默认 Material 组件，把颜色和效果堆在"外观"上，而不是内容上。

Windows 已收敛的三个问题（彩色投影/光晕、字重 700+、色板漂移），Android 全部还在。

整体判定：**中等偏重 slop（light-to-heavy 之间）**。不需要重做布局，但色板、阴影、字重、组件形态四件事必须统一，否则改单点没有意义。

---

## 1. 建议方向（先定方向，再改单点）

- **产品**：给高中英语教师用的真题词汇检测与词库工具——按课标词/拓展词/超标词统计、查真题出处、导出标注版试卷。
- **性格**：严谨、安静、带一点纸面温度（exact, quiet, a little paper-warm）。
- **世界**：试卷、词汇表、教师批注笔。中性色偏纸白与墨黑，强调色取"批注笔"的靛蓝，而不是赛博蓝紫。
- **时刻**（每屏只留 1 个）：① 查词结果卡——单词、音标、词义、真题例句是主角，用排版和一条"年份·出处"信息轴承载；② 检测结果——四类词用一条堆叠占比条 + 一排数字，而不是四张彩色卡。
- **签名细节**：一条 2px 的"批注下划线"，只出现在被查词/当前选中项下方，全局仅此一处（呼应教师笔迹），其他地方一律不用圆点、光晕、胶囊来强调。

**需要用户拍板的两个口径**（二者互斥，决定后续全部改法）：

- 强调色统一到 **Windows 的 #4462F2**，还是保留 Android 现用 **#2F5DA8**？
- 四类词是否保留独立色相？建议：保留低饱和四色，但**只用于 6px 圆点/短横条**，卡片数字与标题一律走中性墨色。

---

## 2. 问题清单

严重度：P0 = 品牌级、整站可见，必须修；P1 = 单屏明显，应修；P2 = 打磨项。
优先级：P0 本轮必修，P1 本轮建议修，P2 可排后。

### A. 色板与阴影（全局）

**A1｜两套色板 + 三个蓝 + 字面色值并存** ｜ 严重 P0 ｜ 优先 P0
- 症状：`android_app.dart` 里 `AppTheme.*` 出现 55 次、`EswColors.*` 28 次；`EswColors.primary` = `#2F5DA8`，`AppTheme.primaryBlue` = `#2F6BDF`，扫描相机硬编码 `#2F80ED`；检测结果页还用 `Colors.blue.shade50/shade700`（像素级第四种蓝）。`AppTheme.primaryYellow/green/red/teal/purple/orange` 与 `EswColors.blue/green/orange/red/grey` 是两套语义色。
- 位置：`lib/theme/app_theme.dart:8-16`、`lib/theme/esw_tokens.dart:13-27`、`lib/android_app.dart:4554,4563`、`lib/shared/scan_camera_page.dart:494,583,662`。
- 为什么算问题：一个 App 三个品牌蓝、两套语义红绿，用户看到的是"每屏像不同产品"，也直接违反"一个中性 ramp + 一个强调色"。
- 建议：确定一个蓝（建议对齐 Windows `#4462F2`），删除 `AppTheme` 里的品牌/语义色，全部映射到 `EswColors`；扫描页的取景框蓝改为强调色常量；`Colors.blue.shade*` 改为令牌。改完加 lint/测试禁止 `Color(0xFF...)` 与 `Colors.*`（导出/PDF 代码除外）。
- 两端：Windows 已单强调色；Android 不一致。

**A2｜彩色投影与彩色聚焦光晕** ｜ 严重 P0 ｜ 优先 P0
- 症状：`EswShadow.button` = `0x332F5DA8`（主色投影，blur 16 / offset 6）；`EswShadow.glow` = 主色 + spread 2；主按钮悬空、搜索框聚焦时泛蓝光。
- 位置：`lib/theme/esw_tokens.dart:110-135`、`lib/widgets/esw_widgets.dart:140-152,685-691`。
- 为什么算问题：彩色投影/光晕是 unslop 明列的第一梯队 slop，且 Android 只有浅色主题，投影应靠 surface step + 发丝线。
- 建议：删除 `glow`；主按钮改为无投影或中性 `0x14181B` 小投影；聚焦态只保留 1.5px 强调色描边 + `accentSoft` 底。
- 两端：Windows 已全部改中性投影（`glass_theme.dart:410-411`）；Android 落后。

**A3｜统计卡四色大数字 + 16% 光晕 + 2×2 等宽** ｜ 严重 P1 ｜ 优先 P1
- 症状：四张等宽卡，右上角各压一个 56px、16% 不透明度的同色圆斑当作"光晕"；数字 26px / w700 / 同色；卡内再放一个同色 8px 圆点。
- 位置：`lib/widgets/esw_widgets.dart:497-585`（光晕 `518-530`）、`lib/pages/word_bank_page.dart:547-606`。
- 为什么算问题：光晕是纯装饰；四色大数字让"没有主角"；四等卡同构是模板特征；数字 w700 超界。
- 建议：删光晕；数字改中性 `textPrimary`、w500；类目色只保留 6px 圆点；四卡改为"一行总览数字 + 下方 2×2 紧凑计数"，或三窄一宽打破等分。
- 两端：Windows 无此类彩卡；Android 独有。

**A4｜AppBar 实心主色 + 白字** ｜ 严重 P1 ｜ 优先 P1
- 症状：`_SourcePopupViewer` 把 `backgroundColor` 设为 `AppTheme.primaryBlue`、标题/图标全白；`_ExamPaperViewer` 标题居中加粗 16。
- 位置：`lib/android_app.dart:6875-6882`、`3186-3194`。
- 为什么算问题：全站最响的一块颜色给了"位置"这个次要页面，chrome 抢了内容；同时 `centerTitle` 与三主页面的左对齐标题自相矛盾。
- 建议：AppBar 回 `EswColors.page`/白底、标题 `EswText.titleSmall`、`centerTitle: false`；强调色只留在被查词高亮上。
- 两端：Windows 标题栏为浅底墨字；建议统一。

**A5｜提示条按类型整条染色** ｜ 严重 P2 ｜ 优先 P2
- 症状：info 类型 SnackBar 是整条主色底白字；success/error 整条绿/红。
- 位置：`lib/shared/app_snack_bar.dart:15-31`。
- 为什么算问题：被动通知不该是整屏最亮的东西；一眼看去每两秒弹一块品牌色。
- 建议：底色统一为 `textPrimary`（深墨）或 `card` + 发丝线，只有图标用语义色；错误保留红图标 + 红字。
- 两端：Android 独有（Windows 用行内提示）。

### B. 查词结果卡（问题最集中）

**B1｜红色 28px 粗体单词 + 浅蓝灰卡片 + 14 圆角** ｜ 严重 P0 ｜ 优先 P0
- 症状：结果卡 `Card(color: AppTheme.surfaceLight)`（#EBF0F6 蓝灰）、圆角 14；单词 28px `FontWeight.bold` 且用 `AppTheme.red`；音标 `monospace` 蓝色。
- 位置：`lib/android_app.dart:2321-2387`、`2360-2368`。
- 为什么算问题：红色是语义色，却拿来当"好看的大字"，读起来像报错；蓝灰卡与全站白卡 + 20 圆角不是一套；字号/颜色/字重全是字面量，绕过令牌。
- 建议：卡改 `EswCard`（白底 20→统一后 12/16）；单词 `textPrimary`、`EswText.display` 但 w500；音标用次级文字色 + `tabular` 等宽数字字体，不用蓝色；删除红/蓝/青三处着色。
- 两端：Windows 查词结果以墨色排版；Android 独有。

**B2｜一张卡里 5 种强调手段** ｜ 严重 P0 ｜ 优先 P0
- 症状：分类标签彩色 1.5px 描边（`2336-2355`）；词性蓝色 + 斜体 + 粗体三重（`2400-2406`）；词形说明青绿 `#12B886`（`2437`）；三个 `+ 拓展词/+ 超标词/+ 专有词` 按钮分别绿/红/灰描边（`2445-2466`）；Collins 五星金色（`2496-2506`）。
- 位置：同上。
- 为什么算问题：斜体、彩框、彩字、金星同时出现，没有一个"主角"；斜体强调是 unslop 明列禁止项；彩色描边是"霓虹边框"。
- 建议：词性改 `textSecondary` 正常体；分类标签改中性 `accentSoft` 底 + 强调色字（去描边）；词形说明并入正文次级色；三个分类按钮改为一组等宽次级按钮（统一 `border` 描边），选中态用 `accentSoft`；星级改中性色实心/空心，不填黄。
- 两端：Windows 分类用单一强调色的文字标签。

**B3｜词频区胶囊 + 默认 ExpansionTile + 黄底红字高亮** ｜ 严重 P1 ｜ 优先 P1
- 症状：`共 N 次` 用 14 圆角主色胶囊；年份列表用 Material 默认 `ExpansionTile`（展开箭头、分隔线都是系统默认）；例句里被查词是 `yellow@40%` 底 + `red.shade700` + bold。
- 位置：`lib/android_app.dart:2632-2666`、`2744-2751`。
- 为什么算问题：胶囊计数是 signs 里"glowing pills for counts"的浅版本；黄底红字三重重音，和导出方案一"只用颜色区分"的口径也冲突。
- 建议：`共 N 次` 改等宽数字 + 次级色文本；`ExpansionTile` 换成自绘行（与语料栏行同高）；高亮只保留一条 `accentSoft` 底或一条批注下划线，不加粗、不变红。
- 两端：Windows 用中性高亮。

### C. 检测结果页（`_AnalysisPage`）

**C1｜默认 Material FilterChip 胶囊 + 默认状态色** ｜ 严重 P1 ｜ 优先 P1
- 症状：5 个 `FilterChip` 直接用，圆角为 Material 3 的胶囊形，选中态是系统 secondaryContainer，和全站 10/12 圆角控件不是一套；计数塞在 label 里（`课标词 12`）。
- 位置：`lib/android_app.dart:4387-4416`、`7190-7214`。
- 为什么算问题：默认组件 = 没人做决定；胶囊化正是 Windows 刚修过的"全圆角"问题。
- 建议：自绘分段筛选条（`EswRadius.control` 以内的矩形，选中 `accentSoft` + 强调色字，计数用等宽小字置右）。
- 两端：Windows 筛选胶囊为玻璃底 + r10；Android 是 M3 默认胶囊，观感不同。

**C2｜列表行三处同时着色 + 页面外第四种蓝** ｜ 严重 P1 ｜ 优先 P1
- 症状：每行 = 彩色 7px 圆点 + 彩色分类小签 + 右侧 `Colors.blue.shade50` 底 / `shade700` 字频次块；单词 15px w600；行用默认 `ListTile`。
- 位置：`lib/android_app.dart:4474-4569`。
- 为什么算问题：一行里三个色块竞争；`Colors.blue` 不在任何色板；默认 ListTile 行高与 EswListTile、语料行都不一致。
- 建议：去掉圆点（类别已有文字签）；小签改中性底 + 语义色字；频次改成 `tabular` 数字 + 次级色，不套色底；统一行高与内边距。
- 两端：Windows 列表为发丝线 + 墨字。

**C3｜批量条与"连续筛选"弹窗用了第三套样式** ｜ 严重 P1 ｜ 优先 P1
- 症状：底部批量条 4 个等宽 `TextButton`，上方一条 `Colors.black12` 投影；"连续筛选"是裸 `AlertDialog` + `ElevatedButton`，按钮直接 `Colors.grey[700]` / `AppTheme.orange` 实心，高 36。
- 位置：`lib/android_app.dart:4624-4680`、`4949-5101`（按钮 `5053-5094`）。
- 为什么算问题：同一个"归类"动作，主结果页、批量条、弹窗三种按钮体系；橙/灰实心按钮把颜色当分类编码，正是 slop 的定义。
- 建议：全部并入 `EswDialogFrame` + 统一次级按钮；分类按钮用文字标签，不用色块；批量条改一行"已选 N 个 · 归类" + 一个主按钮 + 菜单。
- 两端：Windows 全程同一套 dialog_kit。

### D. 语料栏与原文查看

**D1｜"返回段落分析"巨型主色满宽按钮，且出现两次** ｜ 严重 P1 ｜ 优先 P1
- 症状：语料面板顶部一个 54 高、满宽、16px w700 的实心主色按钮；`_ExamPaperViewer` 底部又来一个同样按钮。
- 位置：`lib/android_app.dart:3646-3660`、`3229-3245`。
- 为什么算问题：一个"返回"动作占据首屏最强位置，主次颠倒；一屏两个主按钮。
- 建议：改用 AppBar 返回箭头（带文字"段落分析"）；面板内不再放返回按钮；若必须保留，降为次级描边按钮。
- 两端：Windows 返回在标题区。

**D2｜语料面板标题层级与行距脱离刻度** ｜ 严重 P2 ｜ 优先 P2
- 症状：标题 `17 * f` + w700；副标题 `11.5 * f`；行内上下 11，图标间距 6；读者区背景 `Color(0xFFFBFBFD)`；高亮行同时叠 `primarySoft` 底 + 主色 w700 字 + 5% 选中底。
- 位置：`lib/android_app.dart:3623-3645`、`3769-3796`、`3836-3837`。
- 为什么算问题：三个离格值 + 五个近似白底 + 选中态三重叠加，读不出"哪个是选中"。
- 建议：标题回 `EswText.titleSmall`（16/w600）；副标题 `bodySmall`；行距上下 12、图标间距 8；读者区改 `EswColors.page` 或纯白二选一；选中态只保留一层。
- 两端：Windows 面板圆角 12、行高统一。

### E. 弹窗体系

**E1｜两套弹窗并存** ｜ 严重 P0 ｜ 优先 P0
- 症状：`esw_app_dialog.dart` 是自绘圆角面板 + 图标徽标 + 等宽按钮；但至少 8 处仍是裸 `AlertDialog`（M3 默认 28 圆角、默认按钮、默认内容边距）：去重合并、词库未同步后、关联课标词 ×2、连续筛选、编辑此词、编辑检测词、真题编辑。
- 位置：`lib/android_app.dart:536,746,2171,3113,4701,4801,4949,6470`；对照 `lib/widgets/esw_app_dialog.dart:223-363`。
- 为什么算问题：用户点同一个"取消/确定"，有时是 20 圆角白卡、有时是 28 圆角 M3 灰卡；这是最典型的"拼装感"。
- 建议：全部改为 `showEswCustom` / `showEswConfirm`；`AlertDialog` 只允许出现在导出/系统能力代码里；加一条测试或 lint 禁止页面内 `AlertDialog(`。
- 两端：Windows 只有一套 dialog_kit。

**E2｜弹窗内字号与徽标偏大偏"模板"** ｜ 严重 P2 ｜ 优先 P2
- 症状：标题 `17 * f` + w700；正文 `13 * f`；按钮 `14.5 * f`；顶部 52px 圆形彩色图标徽标；所有内容居中。
- 位置：`lib/widgets/esw_app_dialog.dart:292-327,388-396`。
- 为什么算问题：字号偏离刻度（17/14.5），徽标 + 居中标题 + 居中正文是"每个弹窗都长一样"的模板；标题 w700 超界。
- 建议：标题 16/w600，正文 13/常规，按钮 14/w500；徽标缩到 40 或去掉，标题左对齐（正文可左对齐）。
- 两端：Windows 弹窗标题 w600（`dialog_kit.dart:103-104`）。

### F. 字重、字号与排版

**F1｜设计令牌本身就把标题定在 w700** ｜ 严重 P1 ｜ 优先 P1
- 症状：`EswText.display`（26/w700）、`EswText.title`（20/w700）被三页页头、统计数字、弹窗标题直接使用；另有 13 处 UI 侧 `w700`/`bold`（结果页、语料栏、导出方案卡等）。
- 位置：`lib/theme/esw_tokens.dart:58-71`；使用点 `android_app.dart:2350,2384,2404,2749,3034,3191,3240,3627,3656,3792,5170`、`word_bank_page.dart:1045`、`esw_app_dialog.dart:311`。
- 为什么算问题：unslop 要求 400/500，最多 600；Windows 已全量收敛到 ≤600，Android 令牌层就超界，改单点没意义。
- 建议：`display` → 26/500，`title` → 20/600，`titleSmall` 16/600 保持；`chip` 12/500；逐处把 w700 降一级，层级交给字号 + 颜色。
- 两端：不一致（Windows ≤600），必须统一到 600。

**F2｜69 处字号字面量，且出现 17 / 15 / 14.5 / 13.5 / 11.5 / 10.5** ｜ 严重 P1 ｜ 优先 P1
- 症状：`android_app.dart` 内 `fontSize:` 字面量 69 处；另有 `esw_app_dialog.dart` 3 处、`scan_photo_page` 2 处等；多数还乘了 `f`。
- 位置：`lib/android_app.dart` 全文（如 `3626,3635,3655,3745,3813,3870`）。
- 为什么算问题：字号刻度失控，半像素字号在小屏上渲染模糊；也是"每人各写一套"的直接证据。
- 建议：只允许 `EswText` 的 8 个字号；确需展示型大字号时新增一个 `EswText.figure`（28/500）并全局复用；用 grep 作为验收。
- 两端：Windows 有固定字号表。

**F3｜结果页/查看器不走响应式，字号写死** ｜ 严重 P2 ｜ 优先 P2
- 症状：三张主页面包了 `EswResponsive.wrap`，但检测结果页、语料面板、两个查看器都是独立路由，既没 wrap，也没有乘 `f`（或只乘了一部分），平板上字仍是 360dp 设计值。
- 位置：`lib/android_app.dart:4330-4382`、`6875-6913`；对照 `lib/theme/responsive.dart:127-151`。
- 为什么算问题：同一台平板上，主页文字放大、结果页缩小，视觉断裂。
- 建议：结果页与查看器统一包 `EswResponsive.wrap`，去掉手工 `* f` 混用。
- 两端：Windows 无此问题（桌面固定窗口）。

### G. 间距、圆角与组件形态

**G1｜圆角整体膨胀：卡 20 / 控件 14 / 小签 10 / 筛选胶囊** ｜ 严重 P1 ｜ 优先 P1
- 症状：`EswRadius.card=20`、`control=14`；统计小签 10；`共 N 次` 用 14（高度约 22，接近胶囊）；FilterChip 为胶囊。
- 位置：`lib/theme/esw_tokens.dart:30-37`。
- 为什么算问题：unslop 建议控件 8-10、卡片 12-16、面板 14-20；Windows 已用面板 12 / 控件 10；20+14 让所有东西都显得"软"。
- 建议：`card` 20→16（或对齐 Windows 12），`control` 14→10，`small` 10→8；小签用 6；禁止 `StadiumBorder`。
- 两端：Windows 12/10，需统一。

**G2｜离格间距与魔法固定高度** ｜ 严重 P1 ｜ 优先 P1
- 症状：行内边距 11（`3772`）、图标间距 6（`3783,3799`）、结果卡 18/16（`2328`）、标题下 2/3/6、语料面板 2/6/4；固定高度：粘贴卡 `168 * f`、历史区 `176 * f`、统计格 `92 * f`。
- 位置：`lib/android_app.dart:2328,3603-3606,3769-3772,3783,3799`、`lib/pages/detect_page.dart:248-254,272`、`lib/pages/word_bank_page.dart:555`。
- 为什么算问题：11/6 这类值破坏 4px 节奏；固定高度在多机型/大字号下只能靠 FittedBox 兜底，说明结构没按内容设计。
- 建议：全部归到 4/8/12/16/20/24；高度改为最小高度 + 内边距，让内容决定；统计卡高度交给内容，去掉 `FittedBox` 缩放。
- 两端：Windows 用 4/8 栅格。

**G3｜列表行高与行内构成三种并存** ｜ 严重 P2 ｜ 优先 P2
- 症状：`EswListTile` 上下 12；`WordListPage` 用 `ListTile(dense)`；检测结果用默认 `ListTile`（约 72 高）；语料行上下 11。
- 位置：`lib/widgets/esw_widgets.dart:344-350`、`word_bank_page.dart:1031-1070`、`android_app.dart:4474`、`3770`。
- 为什么算问题：同类型列表在三个页面节奏不同，扫读时会"跳"。
- 建议：统一成一个 44/56 两档行高标准，全部复用 `EswListTile`。
- 两端：Windows 行高统一。

### H. 图标与启动页

**H1｜启动图标是"跨色相渐变 + 文字 logo + 撞色"** ｜ 严重 P0 ｜ 优先 P0
- 症状：图标底为紫蓝（violet→blue）对角渐变，压两行中文字"真题/课标词"，其中"题""词"为薄荷绿；自适应前景也是这行文字；`ic_launcher_monochrome.png` 只存在于 xxxhdpi，其它密度缺失。
- 位置：`android/app/src/main/res/mipmap-*/ic_launcher*.png`、`mipmap-anydpi-v26/ic_launcher.xml:1-5`。
- 为什么算问题：跨色相渐变 + 渐变砖 + 文字做 logo，是 signs 里三条同时命中；紫蓝与品牌蓝、与 Windows 靛蓝都不是一个色相；绿字与蓝底撞色。
- 建议：改为平底单色（强调色或墨色）+ 一个单色几何标记（如"课"字骨架/一条批注下划线），文字不进图标；自适应安全区内 66%；补齐各密度 monochrome，做 Android 12 主题图标。
- 两端：Windows logo 已是"单色块 + 白字"（`glass_theme.dart:1041-1066`）；建议图标也统一为单色标记。

**H2｜启动页纯白无标记，夜间模式仍白底** ｜ 严重 P1 ｜ 优先 P1
- 症状：`launch_background.xml` 只有 `@android:color/white`；`values-night/styles.xml` 的 LaunchTheme 用 `Theme.Black.NoTitleBar` 但背景仍是同一张白色 drawable；没有 `values-v31` 启动屏配置。
- 位置：`android/app/src/main/res/drawable/launch_background.xml:1-12`、`values/styles.xml:4-7`、`values-night/styles.xml:4-7`。
- 为什么算问题：冷启动先闪一块纯白，深色系统下再跳回浅色 App；Android 12+ 只能看到系统默认启动图，品牌感为零。
- 建议：启动底改 `EswColors.page`（#F6F7F9）并放一个 96dp 单色标记居中；夜间接同一底色（App 本身只有浅色主题，就不要用 Black 父主题）；加 `values-v31/styles.xml` 设置 `windowSplashScreenBackground` 与 `windowSplashScreenAnimatedIcon`。
- 两端：Windows 有自绘标题栏与品牌标识。

### I. 文案

**I1｜感叹号与重复兜底文案** ｜ 严重 P2 ｜ 优先 P2
- 症状：删除保护警告"…请确认网络正常后再操作！"带感叹号；历史词副标题在无数据时一律"点击查看词义与真题出处"；版本页脚硬编码 `V1.6.1 · github.com/...`，与 `kAndroidAppVersion` 双源。
- 位置：`lib/android_app.dart:676`、`lib/pages/word_bank_page.dart:909,679`、`lib/pages/search_page.dart:162,2070`。
- 为什么算问题：unslop 明确禁止界面文案用感叹号；"点击查看…"是没信息量的占位；版本号双源迟早不一致（项目规则也要求单源）。
- 建议：去掉感叹号；空副标题留空或显示类别；版本页脚读 `kAndroidAppVersion`（并同步 build 号）。
- 两端：Windows 同为"云端备份失败…！"，可一并处理。

---

## 3. 两端对照表

| 项目 | Windows（已整改） | Android（现状） | 是否一致 | 建议统一到 |
|---|---|---|---|---|
| 强调色 | 单一 `#4462F2`，violet 仅留常量不用 | 双色板 + 3 个蓝 + 4 种语义色 | 否 | 单一强调色，语义色仅状态点 |
| 彩色投影/光晕 | 仅中性 `0x0F18181B` / `0x0A18181B` | 主色投影 + 聚焦光晕 + 卡角光斑 | 否 | 中性投影 + 发丝线 |
| 字重 | ≤600（标题 600、按钮 500） | 令牌标题 700 + 13 处 700/bold | 否 | ≤600 |
| 圆角 | 面板 12 / 控件 10 / 小件 4-8 | 卡 20 / 控件 14 / 小签 10 + 胶囊 | 否 | 面板 12 / 控件 10 |
| 表头字距 | 常规（仅 logo 上 0.4） | 无大写宽字距（本来就合规） | 是 | 保持 |
| Logo | 单色块 + 白字 | 跨色相渐变 + 中文文字 + 绿字 | 否 | 单色标记 |
| 弹窗 | 单一 dialog_kit | Esw 框架 + 8 处 M3 AlertDialog | 否 | 单一弹窗套件 |
| 四类词配色语义 | 课标蓝/拓展绿/超标红/专有灰/未筛选紫 | 同上，但未筛选用橙 | 否 | 未筛选改中性灰，紫/橙都去掉 |
| 版本号 | 单源 | 页脚硬编码 | 否 | 单源 |

**Android 独有、Windows 无对应的问题**（单列）：
1. B1/B2/B3：查词结果卡的红字大标题、五重强调、黄底红字高亮。
2. C1/C2/C3：M3 默认 FilterChip、`Colors.blue.shade*`、裸 AlertDialog 的连续筛选。
3. D1/D2：语料面板的巨型返回按钮、17/11.5px 离格字号、`#FBFBFD` 第五种白。
4. H1/H2：渐变文字图标与纯白启动页（Windows 侧为 exe 图标 + 自绘标题栏）。
5. G3/F3：结果页不参与 `EswResponsive`，平板字号断裂。

**Windows 侧顺手发现（不在本次 Android 范围，供参考）**：`windows_app.dart:314,8497` 仍把"未筛选"映射为 `AppTheme.purple`，与"紫色已移除"的整改口径冲突；`dialog_kit.dart:424-430` 仍有同色相渐变按钮（红→浅红、蓝→深蓝），且 `#2F6BFF` 与强调色 `#4462F2` 不是同一个蓝。

---

## 4. 建议修复顺序（未执行，等确认）

1. **批 0｜口径确认**：强调色取值、四类词是否保留色相、圆角是否对齐 Windows。
2. **批 1｜令牌层**（改 3 个文件即可全局生效）：`esw_tokens.dart` 圆角/字重/阴影；`app_theme.dart` 收敛为别名；新增 `figure` 字号。
3. **批 2｜色板迁移**：`android_app.dart` 55 处 `AppTheme` → `EswColors`；清掉 `Colors.blue/yellow/red.shade*` 与 `Color(0xFFFBFBFD)`；扫描页 `#2F80ED` → 强调色。
4. **批 3｜查词结果卡重排**（B1-B3）：去红标题、去斜体、去彩框、去金星；高亮改批注下划线。
5. **批 4｜弹窗统一**（E1）：8 处 AlertDialog 迁到 `showEswCustom`；连续筛选弹窗重做。
6. **批 5｜检测结果页**（C1-C3）：筛选条自绘、列表去色块、频次等宽数字、批量条降噪。
7. **批 6｜语料栏/查看器**（D1-D2、F3）：返回入口改 AppBar、行距归格、包 wrap。
8. **批 7｜图标与启动页**（H1-H2）：新单色标记、v31 启动屏、补齐 monochrome。
9. **批 8｜验收**：grep 验收 0 处 `AlertDialog(`（页面内）、0 处 `Colors.`（UI 层）、0 处 `fontSize:` 字面量、0 处 `w700`；三张主页面 + 结果页 + 语料栏 + 6 个弹窗逐屏截图对照。

---

## 5. 附：审查覆盖清单

- 页面：`search_page.dart`、`detect_page.dart`、`word_bank_page.dart`（含 `WordListPage`、`HelpPage`）、`android_app.dart` 的 `_AnalysisPage`、`CorpusSheet`、`_ExamPaperViewer`、`_SourcePopupViewer`、`ScanPhotoPage`、`ScanCameraPage`、`PageCropPage`、`ExportProgressOverlay`。
- 组件：`esw_widgets.dart` 全部、`esw_app_dialog.dart` 全部、`app_snack_bar.dart`。
- 主题：`esw_tokens.dart`、`esw_theme.dart`、`app_theme.dart`、`responsive.dart`；对照 `glass_theme.dart`、`dialog_kit.dart`。
- 原生：`AndroidManifest` 相关资源、`launch_background.xml`、`styles.xml`、`values-night/styles.xml`、`mipmap-*` 图标（含 monochrome）。
- 未审查：导出 docx/pdf 内部排版（不属于界面）、OCR/相机的图像算法、Windows 端界面（仅作对照）。
