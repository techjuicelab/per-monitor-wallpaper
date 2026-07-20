<#
    공용 모듈 — 모니터 해상도에 정확히 맞는 배경화면 이미지를 합성한다.
    직접 실행하는 파일이 아닙니다.

    왜 필요한가
      Windows 의 '채우기'는 비율이 다르면 잘라낸다. 정사각형 이미지를 16:9 모니터에 넣으면
      위아래 44%가 사라지고, 모니터보다 작은 이미지는 늘려서 흐려진다.

      대신 모니터 해상도와 똑같은 크기의 이미지를 직접 만들어 그것을 배경화면으로 지정한다.
        · 뒤: 같은 이미지를 화면 가득 덮게 확대 → 강하게 흐리게 → 어둡게
        · 앞: 원본 전체가 잘리지 않게 축소해서 가운데
      결과적으로 어떤 비율/크기의 이미지든 손실 없이 화면을 채운다.

    성능 요령
      뒷배경은 어차피 흐려지므로 원본을 다시 디코딩하지 않고 ThumbCache 의 720px 축소본을 쓴다.
      전체 디코딩은 앞쪽 이미지 한 번뿐이다.

    흐리게 처리
      GDI+ 에는 가우시안 블러가 없다. 아주 작게 줄였다가 다시 크게 늘리면(bicubic) 같은 효과가
      난다 — 훨씬 빠르고 결과도 부드럽다.
#>

# 의존 모듈을 스스로 챙긴다 — 이 파일만 dot-source 해도 동작하게.
# (이미 불러와 있으면 다시 읽지 않는다)
if (-not (Get-Command Get-CachedThumbPath -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'ThumbCache.ps1')
}

$script:ComposeDir       = Join-Path $env:LOCALAPPDATA 'MyWallpaper\composed'
$script:ComposeQuality   = 92     # 배경화면으로 쓸 최종 이미지라 캐시본보다 높게
$script:BlurSeed         = 36     # 배경을 이 정도 폭까지 줄였다가 되늘린다 (작을수록 더 흐림)
$script:BlurDim          = 88     # 배경 위에 덮을 검정 알파 (0~255)
$script:AutoCropLimit    = 0.25   # 잘림이 이 비율을 넘으면 합성으로 전환
$script:AutoUpscaleLimit = 1.05   # 이만큼 넘게 늘려야 하면 합성으로 전환

function Initialize-ComposeDir {
    if (-not (Test-Path -LiteralPath $script:ComposeDir)) {
        New-Item -ItemType Directory -Force -Path $script:ComposeDir | Out-Null
    }
}

function Get-CropLoss {
    <#
        '채우기'로 넣었을 때 잘려나가는 면적 비율(0~1).

        주의: 여기서 [Math]::Max(0, $실수) 를 쓰면 안 된다. 첫 인자가 정수라 PowerShell 이
        Max(int,int) 오버로드를 골라 0.4375 를 0 으로 잘라버린다(실제로 겪은 버그 — 정사각형
        이미지의 44% 잘림이 0% 로 보고돼 자동 합성이 통째로 동작하지 않았다).
    #>
    param([int]$SrcW, [int]$SrcH, [int]$DstW, [int]$DstH)

    if ($SrcW -le 0 -or $SrcH -le 0) { return 0.0 }
    $k = [Math]::Max($DstW / $SrcW, $DstH / $SrcH)      # 둘 다 실수라 여기는 안전
    $scaledArea = ($SrcW * $k) * ($SrcH * $k)
    if ($scaledArea -le 0) { return 0.0 }

    $loss = 1.0 - (($DstW * $DstH) / $scaledArea)
    if ($loss -lt 0) { return 0.0 }
    return $loss
}

function Test-NeedsCompose {
    <#
        '자동' 모드에서 합성이 필요한지 판단한다.
        · 늘려야 하는 경우      → 합성 (원본 크기를 지켜 흐려지지 않게)
        · 너무 많이 잘리는 경우 → 합성 (정사각형 등)
        · 그 외                 → 원본 그대로 '채우기' (재인코딩하지 않는다)
    #>
    param([int]$SrcW, [int]$SrcH, [int]$DstW, [int]$DstH)

    if ($SrcW -le 0 -or $SrcH -le 0) { return $false }
    $cover = [Math]::Max($DstW / $SrcW, $DstH / $SrcH)
    if ($cover -gt $script:AutoUpscaleLimit) { return $true }
    return ((Get-CropLoss -SrcW $SrcW -SrcH $SrcH -DstW $DstW -DstH $DstH) -gt $script:AutoCropLimit)
}

function Get-ComposeKey {
    param([System.IO.FileInfo]$File, [int]$W, [int]$H)
    $raw = '{0}|{1}|{2}|{3}x{4}|b{5}d{6}' -f $File.FullName.ToLowerInvariant(),
           $File.LastWriteTimeUtc.Ticks, $File.Length, $W, $H, $script:BlurSeed, $script:BlurDim
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try   { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw)) }
    finally { $sha.Dispose() }
    return (([System.BitConverter]::ToString($hash) -replace '-', '').Substring(0, 16) + '.jpg')
}

function New-BlurredBackdrop {
    <#
        $W x $H 를 가득 덮는 흐릿하고 어두운 배경을 그린다.
        원본이 아니라 ThumbCache 의 축소본을 재료로 쓴다 (어차피 흐려지므로 화질 차이가 없다).
    #>
    param([System.Drawing.Graphics]$Graphics, [string]$SourcePath, [int]$W, [int]$H)

    $small = Get-CachedThumbPath -Path $SourcePath
    if (-not $small) { $small = $SourcePath }

    $seedW = [Math]::Max($script:BlurSeed, 8)
    $seedH = [Math]::Max([int][Math]::Round($seedW * $H / $W), 8)

    $ms = $null; $src = $null; $tiny = $null; $tg = $null
    try {
        $ms  = New-Object System.IO.MemoryStream (, [System.IO.File]::ReadAllBytes($small))
        $src = [System.Drawing.Image]::FromStream($ms)

        # 1) 아주 작게 — 이 축소가 곧 블러다
        $tiny = New-Object System.Drawing.Bitmap $seedW, $seedH
        $tg   = [System.Drawing.Graphics]::FromImage($tiny)
        $tg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $k  = [Math]::Max($seedW / $src.Width, $seedH / $src.Height)     # 덮도록(cover)
        $dw = [int][Math]::Round($src.Width * $k); $dh = [int][Math]::Round($src.Height * $k)
        $tg.DrawImage($src, [int](($seedW - $dw) / 2), [int](($seedH - $dh) / 2), $dw, $dh)
        $tg.Dispose(); $tg = $null

        # 2) 다시 화면 크기로 — 가장자리 색이 번지지 않도록 타일링을 끈다
        $Graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $attr = New-Object System.Drawing.Imaging.ImageAttributes
        $attr.SetWrapMode([System.Drawing.Drawing2D.WrapMode]::TileFlipXY)
        $Graphics.DrawImage($tiny, (New-Object System.Drawing.Rectangle 0, 0, $W, $H),
                            0, 0, $seedW, $seedH, [System.Drawing.GraphicsUnit]::Pixel, $attr)
        $attr.Dispose()

        # 3) 어둡게 — 앞쪽 이미지가 배경에 묻히지 않게
        $dim = New-Object System.Drawing.SolidBrush (
                   [System.Drawing.Color]::FromArgb($script:BlurDim, 0, 0, 0))
        $Graphics.FillRectangle($dim, 0, 0, $W, $H)
        $dim.Dispose()
        return $true
    } catch {
        return $false
    } finally {
        if ($tg)   { $tg.Dispose() }
        if ($tiny) { $tiny.Dispose() }
        if ($src)  { $src.Dispose() }
        if ($ms)   { $ms.Dispose() }
    }
}

function New-ComposedWallpaper {
    <#
        $Path 이미지를 $W x $H 에 맞춘 이미지 파일로 합성하고 그 경로를 돌려준다.
        이미 만들어 둔 것이 있으면 그대로 재사용한다. 실패하면 $null.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$W,
        [Parameter(Mandatory)][int]$H
    )

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    Initialize-ComposeDir

    $file = Get-Item -LiteralPath $Path
    $dest = Join-Path $script:ComposeDir (Get-ComposeKey -File $file -W $W -H $H)
    if (Test-Path -LiteralPath $dest) { return $dest }

    $canvas = $null; $gr = $null; $ms = $null; $src = $null
    try {
        $canvas = New-Object System.Drawing.Bitmap $W, $H
        $gr     = [System.Drawing.Graphics]::FromImage($canvas)
        $gr.Clear([System.Drawing.Color]::Black)

        [void](New-BlurredBackdrop -Graphics $gr -SourcePath $Path -W $W -H $H)

        # 앞쪽 이미지 — 여기만 원본을 쓴다
        $ms  = New-Object System.IO.MemoryStream (, [System.IO.File]::ReadAllBytes($file.FullName))
        $src = [System.Drawing.Image]::FromStream($ms)

        $fit = [Math]::Min($W / $src.Width, $H / $src.Height)      # 잘리지 않게(contain)
        $dw  = [Math]::Max([int][Math]::Round($src.Width  * $fit), 1)
        $dh  = [Math]::Max([int][Math]::Round($src.Height * $fit), 1)

        $gr.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $gr.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $gr.DrawImage($src, [int](($W - $dw) / 2), [int](($H - $dh) / 2), $dw, $dh)

        $gr.Dispose(); $gr = $null
        $src.Dispose(); $src = $null
        $ms.Dispose();  $ms = $null

        $enc = Get-JpegEncoder
        if ($enc) {
            $ps = New-Object System.Drawing.Imaging.EncoderParameters 1
            $ps.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
                              [System.Drawing.Imaging.Encoder]::Quality, [int]$script:ComposeQuality)
            $canvas.Save($dest, $enc, $ps)
            $ps.Dispose()
        } else {
            $canvas.Save($dest, [System.Drawing.Imaging.ImageFormat]::Jpeg)
        }
        return $dest
    } catch {
        return $null
    } finally {
        if ($gr)     { $gr.Dispose() }
        if ($src)    { $src.Dispose() }
        if ($ms)     { $ms.Dispose() }
        if ($canvas) { $canvas.Dispose() }
    }
}

function Resolve-WallpaperPath {
    <#
        실제로 배경화면에 지정할 파일 경로를 정한다.
        Mode 가 'Auto' 이고 합성이 필요하면 합성본 경로를, 아니면 원본 경로를 돌려준다.
        합성에 실패하면 조용히 원본으로 되돌아간다 — 합성 실패가 적용 실패가 되면 안 된다.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$W,
        [Parameter(Mandatory)][int]$H,
        [string]$Mode = 'Auto'
    )

    if ($Mode -ne 'Auto') { return $Path }

    $sz = Get-ImageSize -Path $Path
    if (-not $sz) { return $Path }
    if (-not (Test-NeedsCompose -SrcW $sz.Width -SrcH $sz.Height -DstW $W -DstH $H)) { return $Path }

    $made = New-ComposedWallpaper -Path $Path -W $W -H $H
    if ($made) { return $made }
    return $Path
}

function New-PreviewBitmap {
    <#
        미리보기(모니터 칸 / 갤러리 타일)용 비트맵.

        Mode 가 'Auto' 이고 합성이 필요한 이미지면 합성 결과와 똑같은 모습을 축소해서 그린다.
        합성본 파일을 만들어 다시 읽지 않고 같은 순서로 직접 그린다 — 미리보기는 자주 다시
        그려지므로 3840x2160 파일을 만드는 비용을 치를 이유가 없다.

        그 외 Mode 는 ThumbCache 의 New-FittedBitmap 이 그대로 처리한다.
        반환한 Bitmap 은 호출 측이 Dispose 해야 한다.
    #>
    param(
        [string]$Path,
        [Parameter(Mandatory)][int]$W,
        [Parameter(Mandatory)][int]$H,
        [string]$Mode = 'Auto',
        [int]$MonitorW = 0,
        [int]$MonitorH = 0
    )

    if ($Mode -ne 'Auto') { return (New-FittedBitmap -Path $Path -W $W -H $H -Mode $Mode) }

    # 합성 여부는 미리보기 크기가 아니라 '실제 모니터' 크기로 판단해야 한다.
    if ($MonitorW -le 0 -or $MonitorH -le 0) { $MonitorW = $W; $MonitorH = $H }

    $sz = if ($Path) { Get-ImageSize -Path $Path } else { $null }
    if (-not $sz -or -not (Test-NeedsCompose -SrcW $sz.Width -SrcH $sz.Height -DstW $MonitorW -DstH $MonitorH)) {
        return (New-FittedBitmap -Path $Path -W $W -H $H -Mode 'Fill')
    }

    $bmp = New-Object System.Drawing.Bitmap $W, $H
    $gr  = [System.Drawing.Graphics]::FromImage($bmp)
    $gr.Clear([System.Drawing.Color]::Black)

    $ms = $null; $src = $null
    try {
        [void](New-BlurredBackdrop -Graphics $gr -SourcePath $Path -W $W -H $H)

        $small = Get-CachedThumbPath -Path $Path       # 미리보기는 축소본으로 충분하다
        if (-not $small) { $small = $Path }
        $ms  = New-Object System.IO.MemoryStream (, [System.IO.File]::ReadAllBytes($small))
        $src = [System.Drawing.Image]::FromStream($ms)

        $fit = [Math]::Min($W / $src.Width, $H / $src.Height)
        $dw  = [Math]::Max([int][Math]::Round($src.Width  * $fit), 1)
        $dh  = [Math]::Max([int][Math]::Round($src.Height * $fit), 1)

        $gr.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $gr.DrawImage($src, [int](($W - $dw) / 2), [int](($H - $dh) / 2), $dw, $dh)
    } catch {
        # 손상된 이미지 — 배경만 남는다
    } finally {
        if ($src) { $src.Dispose() }
        if ($ms)  { $ms.Dispose() }
        $gr.Dispose()
    }
    return $bmp
}

function Get-ComposeCacheInfo {
    Initialize-ComposeDir
    $items = @(Get-ChildItem -LiteralPath $script:ComposeDir -File -ErrorAction SilentlyContinue)
    return [pscustomobject]@{
        Path  = $script:ComposeDir
        Count = $items.Count
        MB    = [math]::Round((($items | Measure-Object Length -Sum).Sum / 1MB), 2)
    }
}

function Clear-ComposeCache {
    Initialize-ComposeDir
    $n = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $script:ComposeDir -File -Filter *.jpg -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        $n++
    }
    return $n
}
