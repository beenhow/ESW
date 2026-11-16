# 生成安卓启动图标（现代 + 碑帖气质）：
# 渐变蓝底 + 两行中文「真题 / 课标词」，「题」「词」用方正魏碑 + 薄荷绿强调，
# 下方以手写笔触式强调线收尾。桌面已显示应用名 ESW，图标内不放英文。
# 输出自适应图标前景/背景、旧版圆角/圆形图标、Android 13 单色图标与预览图。
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $PSScriptRoot
$res = Join-Path $root 'android\app\src\main\res'
$release = Join-Path $root 'release'
New-Item -ItemType Directory -Force -Path $release | Out-Null

function New-RoundedPath([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $r * 2
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

$installed = (New-Object System.Drawing.Text.InstalledFontCollection).Families |
    ForEach-Object { $_.Name }
# 正文用 App 自带 Noto Sans SC，与界面同源
$cnFontName = 'Microsoft YaHei'
if ($installed -notcontains $cnFontName) {
    $cnFontName = if ($installed -contains 'SimHei') { 'SimHei' } else { 'Microsoft JhengHei' }
}
$stringFormat = [System.Drawing.StringFormat]::GenericTypographic

$pfc = New-Object System.Drawing.Text.PrivateFontCollection
$fontPathRegular = Join-Path $root 'assets\fonts\NotoSansSC-Regular.ttf'
$fontPathBold = Join-Path $root 'assets\fonts\NotoSansSC-Bold.ttf'
$iconFamily = $null
if ((Test-Path $fontPathRegular) -and (Test-Path $fontPathBold)) {
    $pfc.AddFontFile($fontPathRegular)
    $pfc.AddFontFile($fontPathBold)
    $iconFamily = $pfc.Families |
        Where-Object { $_.Name -like '*Noto Sans SC*' } |
        Select-Object -First 1
}
if ($null -eq $iconFamily) {
    $iconFamily = [System.Drawing.FontFamily]::new($cnFontName)
}

# 强调字：方正兰亭大黑（现代几何黑，重量足、造型干净），与正文同为无衬线，
# 突出但不违和。中文命名字体在本脚本进程里可能枚举不到，直接按文件加载。
$accentCandidates = @(
    'C:\ProgramData\Kingsoft\office6\muifont\GB2312\FZLTDHJW.TTF',
    'C:\ProgramData\Kingsoft\office6\muifont\GBK\FZLTDHK.TTF',
    'C:\Windows\Fonts\FZLTDHJW.TTF',
    'C:\Windows\Fonts\FZLTDHK.TTF'
)
$accentPfc = $null
$accentFamily = $null
foreach ($f in $accentCandidates) {
    if (-not (Test-Path $f)) { continue }
    try {
        $accentPfc = New-Object System.Drawing.Text.PrivateFontCollection
        $accentPfc.AddFontFile($f)
        $accentFamily = $accentPfc.Families[0]
        break
    } catch {
        $accentPfc = $null
    }
}
$accentName = 'fallback'
if ($null -ne $accentFamily) {
    $accentName = $accentFamily.Name
} else {
    $accentFamily = $iconFamily
    $accentName = $iconFamily.Name + ' (fallback)'
}

# 画一行中文：逐字绘制以控制字距并支持单字换字体/换色
function Draw-CnLine {
    param(
        [System.Drawing.Graphics]$g,
        [string]$text,
        [System.Drawing.Font]$font,
        [single]$tracking,
        [single]$y,
        [System.Drawing.Brush]$brush,
        [int]$size,
        [string]$accentChars = '',
        [System.Drawing.Brush]$accentBrush = $null,
        [System.Drawing.Font]$accentFont = $null
    )
    $widths = @()
    $fonts = @()
    foreach ($ch in $text.ToCharArray()) {
        $isAccent = ($accentBrush -ne $null -and $accentChars.Contains([string]$ch))
        $f = if ($isAccent -and $accentFont -ne $null) { $accentFont } else { $font }
        $fonts += $f
        $widths += $g.MeasureString(
            [string]$ch, $f, [System.Drawing.PointF]::new(0, 0), $stringFormat
        ).Width
    }
    $total = ($widths | Measure-Object -Sum).Sum + $tracking * ($text.Length - 1)
    $x = ($size - $total) / 2
    for ($i = 0; $i -lt $text.Length; $i++) {
        $ch = [string]$text[$i]
        $isAccent = ($accentBrush -ne $null -and $accentChars.Contains($ch))
        $useBrush = if ($isAccent) { $accentBrush } else { $brush }
        $useFont = $fonts[$i]
        # 混排不同字体时按字面高度差做垂直居中，避免基线跳动
        $dy = 0
        if ($isAccent -and $accentFont -ne $null) {
            $dy = ($font.GetHeight($g) - $accentFont.GetHeight($g)) * 0.45
        }
        $g.DrawString(
            $ch, $useFont, $useBrush,
            [single]$x, [single]($y + $dy), $stringFormat
        )
        $x += $widths[$i] + $tracking
    }
}

function Draw-Mark {
    param(
        [System.Drawing.Graphics]$g,
        [int]$size,
        [bool]$mono
    )
    $line1 = '真题'
    $line2 = '课标词'
    $fontSize1 = $size * 0.150
    $fontSize2 = $size * 0.132
    $accentSize1 = $fontSize1 * 1.16
    $accentSize2 = $fontSize2 * 1.14
    $tracking1 = $size * 0.045
    $tracking2 = $size * 0.016

    $f1 = [System.Drawing.Font]::new(
        $iconFamily, $fontSize1, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel
    )
    $f2 = [System.Drawing.Font]::new(
        $iconFamily, $fontSize2, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel
    )
    $a1 = [System.Drawing.Font]::new(
        $accentFamily, $accentSize1, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel
    )
    $a2 = [System.Drawing.Font]::new(
        $accentFamily, $accentSize2, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Pixel
    )
    $h1 = $f1.GetHeight($g)
    $h2 = $f2.GetHeight($g)
    $gap = $size * 0.030
    # 强调字字号更大，按行内较高的字体计算行高，保证整体居中
    $lineH1 = [Math]::Max($h1, $a1.GetHeight($g))
    $lineH2 = [Math]::Max($h2, $a2.GetHeight($g))

    # 整块垂直居中（无收尾横条）
    $blockH = $lineH1 + $gap + $lineH2
    $top = ($size - $blockH) / 2

    $whiteBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::White)
    $c2 = if ($mono) {
        [System.Drawing.Color]::White
    } else {
        [System.Drawing.Color]::FromArgb(236, 255, 255, 255)
    }
    $brush2 = [System.Drawing.SolidBrush]::new($c2)
    # 「题」「词」薄荷绿：呼应软件里的真题标注色
    $accentColor = if ($mono) {
        [System.Drawing.Color]::White
    } else {
        [System.Drawing.Color]::FromArgb(255, 122, 240, 191)
    }
    $accentBrush = [System.Drawing.SolidBrush]::new($accentColor)

    Draw-CnLine $g $line1 $f1 $tracking1 $top $whiteBrush $size '题' $accentBrush $a1
    Draw-CnLine $g $line2 $f2 $tracking2 ($top + $lineH1 + $gap) $brush2 $size '词' $accentBrush $a2

    $whiteBrush.Dispose()
    $brush2.Dispose()
    $accentBrush.Dispose()
    $f1.Dispose()
    $f2.Dispose()
    $a1.Dispose()
    $a2.Dispose()
}

function Draw-Background {
    param(
        [System.Drawing.Graphics]$g,
        [int]$size
    )
    $rect = [System.Drawing.Rectangle]::new(0, 0, $size, $size)
    $brush = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
        $rect,
        [System.Drawing.Color]::FromArgb(255, 108, 140, 255),
        [System.Drawing.Color]::FromArgb(255, 47, 70, 214),
        45
    )
    $g.FillRectangle($brush, $rect)
    $brush.Dispose()

    # 左上柔光
    $glowPath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $glowPath.AddEllipse(
        [single](-$size * 0.22), [single](-$size * 0.28),
        [single]($size * 0.95), [single]($size * 0.95)
    )
    $glow = [System.Drawing.Drawing2D.PathGradientBrush]::new($glowPath)
    $glow.CenterColor = [System.Drawing.Color]::FromArgb(64, 255, 255, 255)
    $glow.SurroundColors = [System.Drawing.Color[]]@([System.Drawing.Color]::FromArgb(0, 255, 255, 255))
    $g.FillEllipse($glow, -$size * 0.22, -$size * 0.28, $size * 0.95, $size * 0.95)
    $glow.Dispose()
    $glowPath.Dispose()
}

function New-Icon {
    param(
        [int]$size,
        [string]$outPath,
        [ValidateSet('full', 'round', 'plain', 'foreground', 'mono')]
        [string]$shape = 'plain',
        [bool]$background = $true,
        [bool]$mono = $false
    )
    $bmp = [System.Drawing.Bitmap]::new($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias

    $clip = $null
    if ($shape -eq 'full') {
        $clip = New-RoundedPath 0 0 $size $size ($size * 0.225)
    } elseif ($shape -eq 'round') {
        $clip = New-Object System.Drawing.Drawing2D.GraphicsPath
        $clip.AddEllipse(0, 0, $size, $size)
    }
    if ($clip -ne $null) {
        $g.SetClip($clip)
    }
    if ($background) {
        Draw-Background $g $size
    }
    Draw-Mark $g $size $mono

    $g.Dispose()
    $dir = Split-Path -Parent $outPath
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    if ($clip -ne $null) { $clip.Dispose() }
}

$densities = @(
    @{ dir = 'mipmap-mdpi'; legacy = 48; adaptive = 108 },
    @{ dir = 'mipmap-hdpi'; legacy = 72; adaptive = 162 },
    @{ dir = 'mipmap-xhdpi'; legacy = 96; adaptive = 216 },
    @{ dir = 'mipmap-xxhdpi'; legacy = 144; adaptive = 324 },
    @{ dir = 'mipmap-xxxhdpi'; legacy = 192; adaptive = 432 }
)

foreach ($d in $densities) {
    $dir = Join-Path $res $d.dir
    New-Icon $d.legacy (Join-Path $dir 'ic_launcher.png') 'full' $true $false
    New-Icon $d.legacy (Join-Path $dir 'ic_launcher_round.png') 'round' $true $false
    New-Icon $d.adaptive (Join-Path $dir 'ic_launcher_foreground.png') 'plain' $false $false
    New-Icon $d.adaptive (Join-Path $dir 'ic_launcher_background.png') 'plain' $true $false
}

# Android 13 主题图标：白色单色标记
New-Icon 432 (Join-Path $res 'mipmap-xxxhdpi\ic_launcher_monochrome.png') 'plain' $false $true

# 预览图
New-Icon 1024 (Join-Path $release 'icon-preview.png') 'full' $true $false
New-Icon 1024 (Join-Path $release 'icon-preview-round.png') 'round' $true $false

$anydpi26 = Join-Path $res 'mipmap-anydpi-v26'
$anydpi33 = Join-Path $res 'mipmap-anydpi-v33'
New-Item -ItemType Directory -Force -Path $anydpi26, $anydpi33 | Out-Null

$adaptiveBase = @'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
'@
$adaptiveMono = @'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@mipmap/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
    <monochrome android:drawable="@mipmap/ic_launcher_monochrome" />
</adaptive-icon>
'@

Set-Content -Path (Join-Path $anydpi26 'ic_launcher.xml') -Value $adaptiveBase -Encoding UTF8
Set-Content -Path (Join-Path $anydpi26 'ic_launcher_round.xml') -Value $adaptiveBase -Encoding UTF8
Set-Content -Path (Join-Path $anydpi33 'ic_launcher.xml') -Value $adaptiveMono -Encoding UTF8
Set-Content -Path (Join-Path $anydpi33 'ic_launcher_round.xml') -Value $adaptiveMono -Encoding UTF8

Write-Output "ICON_FONT=$($iconFamily.Name)"
Write-Output "ACCENT_FONT=$accentName"
Write-Output 'ICONS_GENERATED'
