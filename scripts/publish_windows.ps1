# ESW Windows 一键发布脚本
# 用途：flutter build windows --release 后，直接从构建产物目录打出发布 zip：
#       自带 VC 运行库三件套、插件 DLL、data/flutter_assets、tesseract OCR 组件，
#       并按黑名单剔除本机专属配置/日志/缓存/链接器中间产物；
#       打包前后各做一次依赖完整性校验，确保换机器解压即用。
# 用法：
#   powershell -ExecutionPolicy Bypass -File scripts\publish_windows.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\publish_windows.ps1 -SkipBuild
#   powershell -ExecutionPolicy Bypass -File scripts\publish_windows.ps1 -SkipBuild -OutDir "D:\UserData\Desktop\esw"
param(
    [switch]$SkipBuild,   # 跳过 flutter build，直接用现有 build 产物
    [string]$OutDir = ''  # zip 额外复制到的目录（默认工程根目录）
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = $root }

$buildDir = Join-Path $root 'build\windows\x64\runner\Release'

Write-Host '== ESW Windows Publish =='

# ---------- 1. 构建 ----------
if (-not $SkipBuild) {
    Write-Host '[1/4] flutter build windows --release ...'
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'flutter build windows failed' }
} else {
    Write-Host '[1/4] SkipBuild: use existing build output'
}
if (-not (Test-Path $buildDir)) { throw "Build output not found: $buildDir" }

# ---------- 2. 依赖清单定义 ----------
# 不分发的文件（本机专属 / 中间产物 / 缓存）：
#   esw_config.json、eva_config.json —— 本机配置快照（含开发机绝对路径、词库历史、最近导入路径）
#   *.exp / *.lib / *.ilk / *.pdb    —— 链接器与调试中间产物
#   *.log / debug_log.txt / esw_sync_debug.log / *.dmp —— 运行日志与崩溃转储
#   *.tmp                            —— 缓存
#   tesseract 安装器残留 / 开发工具  —— 见下方 tesseractJunk（无需分发，卸载器尤其危险）
$excludePatterns = @(
    'esw_config.json', 'eva_config.json',
    '*.exp', '*.lib', '*.ilk', '*.pdb',
    'debug_log.txt', 'esw_sync_debug.log', '*.log', '*.dmp', '*.tmp'
)
# tesseract 组件只需 OCR 运行所需部分：tesseract.exe + DLL 依赖链 + tessdata(chi_sim/eng)。
# 以下为安装器残留（含卸载器 tesseract-uninstall.exe，误点会删掉 OCR 文件）与训练/开发工具，
# 一律不进包；这些文件与 tesseract.exe 运行无关，删除不影响 OCR。
$tesseractJunk = @(
    '$PLUGINSDIR', 'tesseract-uninstall.exe',
    '*.html', 'doc',
    'ambiguous_words.exe', 'classifier_tester.exe', 'cntraining.exe',
    'combine_lang_model.exe', 'combine_tessdata.exe', 'dawg2wordlist.exe',
    'lstmeval.exe', 'lstmtraining.exe', 'merge_unicharsets.exe', 'mftraining.exe',
    'set_unicharset_properties.exe', 'shapeclustering.exe', 'text2image.exe',
    'unicharset_extractor.exe', 'winpath.exe', 'wordlist2dawg.exe'
)
$excludePatterns += $tesseractJunk

$requiredFiles = @(
    # VC 运行库三件套（缺一即 0xc0000135 / 0xc000007b 无法启动）
    'vcruntime140.dll',
    'vcruntime140_1.dll',
    'msvcp140.dll',
    # Flutter 引擎与插件 DLL
    'flutter_windows.dll',
    'charset_converter_plugin.dll',
    'file_selector_windows_plugin.dll',
    'pdfium.dll',
    'pdfrx.dll',
    'sqlite3.dll',
    'sqlite3_flutter_libs_plugin.dll',
    'screen_retriever_windows_plugin.dll',
    'url_launcher_windows_plugin.dll',
    'window_manager_plugin.dll'
)
$requiredPaths = @(
    'data\flutter_assets',
    'data\icudtl.dat',
    'data\app.so',
    'data\flutter_assets\assets\ecdict.db',
    'data\flutter_assets\assets\standard_words.json',
    'tesseract\tesseract.exe',
    'tesseract\libtesseract-5.dll',
    'tesseract\libleptonica-6.dll',
    'tesseract\tessdata\chi_sim.traineddata',
    'tesseract\tessdata\eng.traineddata'
)

# ---------- 3. 打 zip（直接从构建产物目录，带 --exclude，无需中转目录） ----------
$exe = Get-ChildItem $buildDir -Filter '*.exe' | Where-Object { $_.DirectoryName -eq $buildDir } | Select-Object -First 1
if (-not $exe) { throw "No exe found in $buildDir (root level)" }
$exeName = $exe.Name
$zipName = "$([IO.Path]::GetFileNameWithoutExtension($exeName))-Windows.zip"
$zipPath = Join-Path $root "release\$zipName"

Write-Host "[2/4] Compress -> $zipPath ..."
if (-not (Test-Path (Split-Path -Parent $zipPath))) { New-Item -ItemType Directory -Path (Split-Path -Parent $zipPath) | Out-Null }
if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
$tarArgs = @('-a', '-c', '-f', $zipPath, '-C', $buildDir)
foreach ($p in $excludePatterns) { $tarArgs += "--exclude=$p" }
$tarArgs += '.'
tar @tarArgs
if ($LASTEXITCODE -ne 0) { throw 'tar zip failed' }

# ---------- 4. 校验 ----------
Write-Host '[3/4] Verify package ...'
$entries = @(tar -tf $zipPath)
$entryNames = $entries | ForEach-Object { ($_ -replace '^\./', '') } | Where-Object { $_ -ne '' -and $_ -ne '.' }
Write-Host "  zip entries : $($entryNames.Count)"

# 4.1 依赖是否齐全（源目录 + zip 条目双重核对）
$missing = @()
foreach ($f in $requiredFiles) {
    if (-not (Test-Path (Join-Path $buildDir $f))) { $missing += "build:$f" }
    if ($entryNames -notcontains $f) { $missing += "zip:$f" }
}
foreach ($p in $requiredPaths) {
    if (-not (Test-Path (Join-Path $buildDir $p))) { $missing += "build:$p" }
    $norm = $p -replace '\\', '/'
    if (-not ($entryNames | Where-Object { ($_ -replace '\\', '/') -eq $norm -or ($_ -replace '\\', '/') -like "$norm/*" })) {
        $missing += "zip:$p"
    }
}
if ($missing.Count -gt 0) {
    Write-Host '[ERROR] Missing dependencies:' -ForegroundColor Red
    $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    throw 'Dependency check FAILED'
}

# 4.2 本机专属文件 / 日志 / 缓存不得进包
$forbiddenHits = @()
foreach ($n in @('esw_config.json', 'eva_config.json')) {
    if ($entryNames -contains $n) { $forbiddenHits += $n }
}
$forbiddenHits += ($entryNames | Where-Object { $_ -match '\.(log|dmp|tmp|exp|lib|ilk|pdb)$' })
if ($forbiddenHits.Count -gt 0) {
    throw "Local-only files present in zip: $($forbiddenHits -join ', ')"
}

$zipMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
$rawMB = [math]::Round((Get-ChildItem $buildDir -Recurse -File | Measure-Object Length -Sum).Sum / 1MB, 1)
Write-Host "  exe         : $exeName"
Write-Host "  VC runtime  : OK (vcruntime140 / vcruntime140_1 / msvcp140)"
Write-Host "  plugin dll  : OK ($($requiredFiles.Count) files)"
Write-Host "  data assets : OK (app.so / icudtl.dat / ecdict.db / standard_words.json)"
Write-Host "  tesseract   : OK (tesseract.exe + chi_sim / eng traineddata)"
Write-Host "  no local config / log / cache in zip"
Write-Host "  zip size    : $zipMB MB (raw build dir: $rawMB MB)"
Write-Host '  Dependency check PASSED'

# ---------- 5. 复制到交付目录 ----------
Write-Host '[4/4] Deliver ...'
$targetDir = if ([string]::IsNullOrWhiteSpace($OutDir)) { $root } else { $OutDir }
if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir | Out-Null }
Copy-Item $zipPath (Join-Path $targetDir $zipName) -Force
Write-Host "  copied -> $(Join-Path $targetDir $zipName)"

Write-Host '== Publish completed =='
