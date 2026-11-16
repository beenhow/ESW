# 安卓 release 出包：APK 文件名始终使用版本号（pubspec version 的主版本段），
# 产物同时复制到 release/<version>.apk，避免每次手动重命名。
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

$m = Select-String -Path 'pubspec.yaml' -Pattern '^version:\s*([0-9]+\.[0-9]+\.[0-9]+)' |
    Select-Object -First 1
if (-not $m) { throw '未在 pubspec.yaml 中解析到 version' }
$version = $m.Matches[0].Groups[1].Value

$apkDir = Join-Path $root 'build\app\outputs\apk\release'
$src = Join-Path $apkDir 'app-release.apk'
# 清掉旧包，构建后用产物是否存在判断成功，避免 $LASTEXITCODE 在部分环境为空
Remove-Item -Force $src -ErrorAction SilentlyContinue

# 直接用 Gradle assembleRelease 构建（含 Dart AOT / 资源合并 / 打包），
# 并显式给足堆内存：压缩大体积 .so 时默认 512m 会 OOM。
Push-Location (Join-Path $root 'android')
# 不要在这里 --stop：daemon 异步退出时会占着 build/.cxx 的文件锁，
# 紧接着构建会让 :pdfrx:configureCMakeRelWithDebInfo 报“拒绝访问”。
# 也不要覆盖 -Dorg.gradle.jvmargs：会额外拉起新 daemon 并再次抢锁，
# 堆大小由 gradle.properties（-Xmx6G）提供。
# --no-daemon：常驻 daemon 会残留陈旧的文件句柄，导致
# :pdfrx:configureCMakeRelWithDebInfo 在写 configure 日志时“拒绝访问”。
# --max-workers=1：串行执行，避免多个 CMake configure 争用 build 目录。
# 打包阶段偶发 Java 堆 OOM（同一 JVM 里先跑完 AOT/R8 后堆紧张）：
# 失败时单独再跑一次 packageRelease，新 JVM 内存干净，通常即可通过。
$buildExit = 1
.\gradlew.bat :app:assembleRelease --no-daemon --max-workers=1 --no-watch-fs --console=plain
$buildExit = $LASTEXITCODE
if (-not (Test-Path $src)) {
    Write-Output "首次构建未产出 APK（退出码 $buildExit），单独重试打包…"
    .\gradlew.bat :app:packageRelease --no-daemon --no-watch-fs --console=plain
    $buildExit = $LASTEXITCODE
}
Pop-Location
if (-not (Test-Path $src)) { throw "APK 构建失败（退出码 $buildExit）" }

$releaseDir = Join-Path $root 'release'
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
$dest = Join-Path $releaseDir "$version.apk"
Copy-Item -Force $src $dest

$mb = [math]::Round((Get-Item $dest).Length / 1MB, 2)
Write-Output "APK_VERSION=$version"
Write-Output "APK_SOURCE=$src"
Write-Output "APK_PATH=$dest"
Write-Output "APK_MB=$mb"
if ($mb -ge 100) {
    Write-Warning "APK 体积 ${mb}MB 超过 100MB 目标"
}
