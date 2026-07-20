<#
    모니터별 배경화면 — 명령줄 버전
    Per-Monitor Wallpaper — command line

    마우스로 고르고 미리보기까지 하려면 Wallpaper.bat 을 쓰세요.
    For a GUI with live previews, run Wallpaper.bat instead.

    사용법 / Usage
      Set-Wallpaper.bat                   설정대로 적용 / apply
      .\Set-Wallpaper.ps1 -List           현재 상태만 확인 / show current
      .\Set-Wallpaper.ps1 -WhatIf         적용될 내용 미리보기 / preview
#>
param(
    [switch]$List,
    [switch]$WhatIf
)

# ============================================================
#   여기만 수정하세요 / Edit here
# ============================================================

# 이미지 폴더. 비워두면 GUI 에서 고른 폴더, 없으면 images\, 그것도 없으면 내 사진 폴더.
# Image folder. Leave empty to use the folder picked in the GUI, else .\images, else Pictures.
$ImageFolder = ''

# 모니터별 이미지 — 파일 이름만 적습니다.
# 이름은 화면에 놓인 순서를 따릅니다. Windows 의 디스플레이 번호가 아닙니다.
#   1대        : ONLY
#   가로 2대   : LEFT / RIGHT            가로 3대 : LEFT / CENTER / RIGHT
#   세로 2대   : TOP / BOTTOM            세로 3대 : TOP / MIDDLE / BOTTOM
#   4대 이상   : MON1 / MON2 / ...       (읽는 순서)
#
# 비워두면 폴더의 이미지를 이름순으로 하나씩 배정합니다.
# Leave empty to auto-assign images from the folder, in name order.
$Assign = [ordered]@{
  # LEFT  = 'sunset.jpg'
  # RIGHT = 'forest.jpg'
}

# 맞춤 방식 / Fit mode
#   Auto     모니터에 딱 맞지 않는 이미지는 흐린 배경을 넣어 합성한다 (잘리지 않음)
#   Fill     채우기(잘림) / Fit 맞춤(여백) / Stretch 늘이기 / Center / Tile / Span
$Position = 'Auto'

# ============================================================
#   아래부터는 건드릴 필요 없습니다 / No need to edit below
# ============================================================

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing

. (Join-Path $PSScriptRoot 'lib\Lang.ps1')
. (Join-Path $PSScriptRoot 'lib\Settings.ps1')
. (Join-Path $PSScriptRoot 'lib\WallpaperCom.ps1')
. (Join-Path $PSScriptRoot 'lib\ThumbCache.ps1')
. (Join-Path $PSScriptRoot 'lib\ImageCompose.ps1')

if (-not $ImageFolder) { $ImageFolder = Get-ImageFolder -AppRoot $PSScriptRoot }

$monitors = @(Get-WallpaperMonitor)
if ($monitors.Count -eq 0) { throw (T 'cli.noMonitors') }

# --- 현재 상태만 보기 -------------------------------------------------------
if ($List) {
    Write-Host ''
    Write-Host (T 'cli.current' $monitors.Count ([Wallpaper]::GetPos())) -ForegroundColor Cyan
    Write-Host ''
    foreach ($m in $monitors) {
        # 합성본 해시 이름 대신 우리가 적어둔 원본 파일명을 보여준다
        $shown = Get-AppliedImage -Label $m.Label
        if (-not $shown) { $shown = $m.Current }
        '  {0,-8} {1,-11} {2,-18} {3}' -f $m.Label, "$($m.Width)x$($m.Height)", $m.Name,
            $(if ($shown) { Split-Path $shown -Leaf } else { T 'main.none' })
    }
    Write-Host ''
    return
}

# --- 설정 검증 --------------------------------------------------------------
if ($script:FitModes -notcontains $Position) {
    throw (T 'cli.badFit' $Position ($script:FitModes -join ', '))
}
if (-not (Test-Path -LiteralPath $ImageFolder)) {
    throw (T 'cli.noFolder' $ImageFolder)
}

$pool = @(Get-ChildItem -LiteralPath $ImageFolder -File -ErrorAction SilentlyContinue |
          Where-Object { $_.Extension -match '^\.(jpg|jpeg|png|bmp|gif|tif|tiff)$' } |
          Sort-Object Name)

# 새로 받은 저장소는 images\ 가 비어 있다. 첫 실행에서 가장 흔한 상황이므로
# '파일을 못 찾았다'가 아니라 무엇을 해야 하는지 알려준다.
if ($pool.Count -eq 0 -and $Assign.Count -eq 0) {
    throw (T 'cli.emptyFolder' $ImageFolder)
}

$plan = @()
for ($i = 0; $i -lt $monitors.Count; $i++) {
    $m = $monitors[$i]

    if ($Assign.Count -gt 0) {
        if (-not $Assign.Contains($m.Label)) {
            throw (T 'cli.noAssign' $m.Label (@($monitors.Label) -join ', '))
        }
        $path = Join-Path $ImageFolder $Assign[$m.Label]
        if (-not (Test-Path -LiteralPath $path)) {
            throw (T 'cli.noImage' $Assign[$m.Label] $ImageFolder (($pool.Name) -join "`n    "))
        }
    } else {
        # 비워뒀으면 폴더의 이미지를 순서대로 (모자라면 처음부터 다시)
        if ($pool.Count -eq 0) { throw (T 'cli.noImage' '*' $ImageFolder '') }
        $path = $pool[$i % $pool.Count].FullName
    }

    $plan += [pscustomobject]@{
        Label = $m.Label
        Id    = $m.Id
        W     = $m.Width
        H     = $m.Height
        Size  = "$($m.Width)x$($m.Height)"
        Name  = $m.Name
        Path  = (Resolve-Path -LiteralPath $path).Path
    }
}

Write-Host ''
Write-Host (T 'cli.plan' $Position) -ForegroundColor Cyan
Write-Host ''
foreach ($p in $plan) {
    '  {0,-8} {1,-11} {2,-18} <- {3}' -f $p.Label, $p.Size, $p.Name, (Split-Path $p.Path -Leaf)
}
Write-Host ''

if ($WhatIf) { Write-Host (T 'cli.preview') -ForegroundColor Yellow; return }

# --- 적용 -------------------------------------------------------------------
[Wallpaper]::SetPos((Get-WindowsPosition $Position))

$failed  = @()
$applied = @{}
foreach ($p in $plan) {
    $ok = Set-WallpaperFor -MonitorId $p.Id -Path $p.Path -Mode $Position -MonitorW $p.W -MonitorH $p.H
    if (-not $ok) { $failed += $p.Label } else { $applied[$p.Label] = $p.Path }
}
# 자동 맞춤이면 Windows 에는 합성본 경로가 남는다. 원본을 따로 기억해 둬야
# 다음에 열었을 때 해시 이름이 아니라 원래 파일명이 보인다.
[void](Save-AppliedImages $applied)

if ($failed.Count -eq 0) { Write-Host (T 'cli.done') -ForegroundColor Green }
else                     { Write-Host (T 'cli.failed' ($failed -join ', ')) -ForegroundColor Red }
Write-Host ''
