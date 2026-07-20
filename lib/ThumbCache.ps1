<#
    공용 모듈 — 썸네일 디스크 캐시.
    직접 실행하는 파일이 아닙니다.

    왜 필요한가 (실측, 2026-07-20 이 PC):
      6000x4000 JPEG 한 장 디코딩에 ~290ms 가 걸린다. Unsplash 이미지에는 내장 EXIF
      썸네일이 없어서 GetThumbnailImage 도, WIC 축소 디코드도 전체 디코딩을 피하지 못한다
      (각각 1.2배 / 1.3배 빨라지는 데 그침). 100장이면 29초.

      그래서 원본을 한 번만 디코딩해 가로세로 720px 이내로 줄여 JPEG 로 저장해두고,
      이후에는 그 작은 파일만 읽는다. 캐시 적중 시 장당 6~14ms — 20~48배 빠르다.

    캐시 키는 (전체경로 + 수정시각 + 파일크기) 해시라 원본이 바뀌면 자동으로 무효화된다.
#>

$script:ThumbCacheDir = Join-Path $env:LOCALAPPDATA 'MyWallpaper\thumbcache'
$script:ThumbMaxEdge  = 720    # 250% DPI 패널(약 600px)까지 커버
$script:ThumbQuality  = 85

function Initialize-ThumbCache {
    if (-not (Test-Path -LiteralPath $script:ThumbCacheDir)) {
        New-Item -ItemType Directory -Force -Path $script:ThumbCacheDir | Out-Null
    }
}

function Get-ThumbCacheKey {
    param([Parameter(Mandatory)][System.IO.FileInfo]$File)
    $raw   = '{0}|{1}|{2}' -f $File.FullName.ToLowerInvariant(), $File.LastWriteTimeUtc.Ticks, $File.Length
    $sha   = [System.Security.Cryptography.SHA1]::Create()
    try   { $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($raw)) }
    finally { $sha.Dispose() }
    return (([System.BitConverter]::ToString($hash) -replace '-', '').Substring(0, 16) + '.jpg')
}

function Get-JpegEncoder {
    if (-not $script:JpegCodec) {
        $script:JpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                            Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
    }
    return $script:JpegCodec
}

function Test-ThumbCached {
    <# 캐시가 이미 있는지만 확인한다. UI 가 "먼저 있는 것부터 그리고 나머지는 나중에" 할 때 쓴다. #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $key = Get-ThumbCacheKey (Get-Item -LiteralPath $Path)
    return (Test-Path -LiteralPath (Join-Path $script:ThumbCacheDir $key))
}

function Get-CachedThumbPath {
    <#
        원본 이미지에 대응하는 캐시 파일 경로를 돌려준다. 없으면 만들어서 저장한다.
        실패하면 $null (호출 측에서 원본으로 폴백).
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    Initialize-ThumbCache

    $file  = Get-Item -LiteralPath $Path
    $dest  = Join-Path $script:ThumbCacheDir (Get-ThumbCacheKey $file)
    if (Test-Path -LiteralPath $dest) { return $dest }

    $src = $null; $bmp = $null; $gr = $null
    try {
        $src = [System.Drawing.Image]::FromFile($file.FullName)

        # 이미 충분히 작으면 그대로 복사만 한다 (재인코딩으로 화질 깎지 않도록)
        if ($src.Width -le $script:ThumbMaxEdge -and $src.Height -le $script:ThumbMaxEdge) {
            $src.Dispose(); $src = $null
            Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
            return $dest
        }

        $ratio = [Math]::Min($script:ThumbMaxEdge / $src.Width, $script:ThumbMaxEdge / $src.Height)
        $w = [Math]::Max([int][Math]::Round($src.Width  * $ratio), 1)
        $h = [Math]::Max([int][Math]::Round($src.Height * $ratio), 1)

        $bmp = New-Object System.Drawing.Bitmap $w, $h
        $gr  = [System.Drawing.Graphics]::FromImage($bmp)
        $gr.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $gr.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $gr.DrawImage($src, 0, 0, $w, $h)

        $enc = Get-JpegEncoder
        if ($enc) {
            $ps = New-Object System.Drawing.Imaging.EncoderParameters 1
            $ps.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
                              [System.Drawing.Imaging.Encoder]::Quality, [int]$script:ThumbQuality)
            $bmp.Save($dest, $enc, $ps)
            $ps.Dispose()
        } else {
            $bmp.Save($dest, [System.Drawing.Imaging.ImageFormat]::Jpeg)
        }
        return $dest
    } catch {
        return $null                      # 손상된 이미지 등 — 호출 측에서 처리
    } finally {
        if ($gr)  { $gr.Dispose() }
        if ($bmp) { $bmp.Dispose() }
        if ($src) { $src.Dispose() }      # Dispose 해야 원본 파일 잠금이 풀린다
    }
}

function New-FittedBitmap {
    <#
        캐시본(또는 원본)에서 지정 크기의 비트맵을 만든다. Mode 는 실제 배경화면 맞춤 방식과 동일:
          Fill    가운데 기준으로 잘라 꽉 채움 (기본)
          Fit     비율 유지, 남는 곳은 배경색
          Stretch 비율 무시하고 늘임
          Center  원본 크기 그대로 가운데
        반환한 Bitmap 은 호출 측이 Dispose 해야 한다.
    #>
    param(
        [string]$Path,
        [Parameter(Mandatory)][int]$W,
        [Parameter(Mandatory)][int]$H,
        [string]$Mode = 'Fill',
        [switch]$NoCache
    )

    $bmp = New-Object System.Drawing.Bitmap $W, $H
    $gr  = [System.Drawing.Graphics]::FromImage($bmp)
    $gr.Clear([System.Drawing.Color]::FromArgb(32, 32, 32))

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { $gr.Dispose(); return $bmp }

    $use = if ($NoCache) { $Path } else { (Get-CachedThumbPath -Path $Path) }
    if (-not $use) { $use = $Path }

    $src = $null; $ms = $null
    try {
        # Image::FromFile 은 Image 를 Dispose 할 때까지 파일을 잠근다. 캐시 파일이 잠기면
        # 캐시 재생성/삭제가 IOException 으로 실패하므로, 바이트로 읽어 메모리에서 연다.
        # (Image.FromStream 은 스트림이 살아있어야 하므로 둘의 수명을 함께 묶는다.)
        $ms  = New-Object System.IO.MemoryStream (, [System.IO.File]::ReadAllBytes($use))
        $src = [System.Drawing.Image]::FromStream($ms)
        $gr.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic

        if ($Mode -eq 'Stretch') {
            $gr.DrawImage($src, 0, 0, $W, $H)
        } else {
            $ratio = switch ($Mode) {
                'Fit'    { [Math]::Min($W / $src.Width, $H / $src.Height) }
                'Center' { 1.0 }
                default  { [Math]::Max($W / $src.Width, $H / $src.Height) }   # Fill / Tile / Span
            }
            $dw = [int][Math]::Round($src.Width  * $ratio)
            $dh = [int][Math]::Round($src.Height * $ratio)
            $gr.DrawImage($src, [int](($W - $dw) / 2), [int](($H - $dh) / 2), $dw, $dh)
        }
    } catch {
        # 손상된 이미지 — 회색 칸으로 둔다
    } finally {
        if ($src) { $src.Dispose() }      # 스트림보다 먼저 닫아야 한다
        if ($ms)  { $ms.Dispose() }
        $gr.Dispose()
    }
    return $bmp
}

function Get-ImageSize {
    <#
        원본 해상도만 빠르게 읽는다. 실패하면 $null.

        Image::FromFile 로 읽으면 픽셀을 전부 디코딩해서 6000x4000 한 장에 약 207ms 가 든다
        (실측). validateImageData=$false 로 스트림에서 열면 헤더만 보므로 약 2ms — 92배 빠르다.
        갤러리에서 타일마다/클릭마다 부르는 값이라 이 차이가 그대로 멈춤으로 나타난다.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $null }
    $fs = $null; $im = $null
    try {
        $fs = [System.IO.File]::OpenRead($Path)
        $im = [System.Drawing.Image]::FromStream($fs, $false, $false)   # 색보정 무시 + 픽셀 검증 생략
        return [pscustomobject]@{ Width = $im.Width; Height = $im.Height }
    } catch {
        return $null
    } finally {
        if ($im) { $im.Dispose() }      # 스트림보다 먼저
        if ($fs) { $fs.Dispose() }
    }
}

function Get-ThumbCacheInfo {
    Initialize-ThumbCache
    $items = @(Get-ChildItem -LiteralPath $script:ThumbCacheDir -File -ErrorAction SilentlyContinue)
    return [pscustomobject]@{
        Path  = $script:ThumbCacheDir
        Count = $items.Count
        MB    = [math]::Round((($items | Measure-Object Length -Sum).Sum / 1MB), 2)
    }
}

function Clear-ThumbCache {
    <# 캐시 폴더 안의 .jpg 만 지운다. 폴더 자체나 다른 파일은 건드리지 않는다. #>
    Initialize-ThumbCache
    $n = 0
    foreach ($f in @(Get-ChildItem -LiteralPath $script:ThumbCacheDir -File -Filter *.jpg -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        $n++
    }
    return $n
}
