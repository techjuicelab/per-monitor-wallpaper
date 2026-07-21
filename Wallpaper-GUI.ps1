<#
    모니터별 배경화면 — GUI
    Per-Monitor Wallpaper — GUI

    실행 / Run:  Wallpaper.bat

    모니터 칸을 클릭해 이미지를 고르고 [적용] 을 누릅니다.
    썸네일은 실제 적용될 모습 그대로입니다.
#>

$ErrorActionPreference = 'Stop'

# 런처가 콘솔을 숨긴 채 띄우므로, 창이 뜨기 전에 죽으면 사용자는 아무것도 못 본다.
# 시작 단계의 오류를 대화상자로 보여준다 (모듈 로드 실패, COM 없음, 권한 문제 등).
trap {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [void][System.Windows.Forms.MessageBox]::Show(
            "$_`n`n$($_.ScriptStackTrace)", 'Per-Monitor Wallpaper', 'OK', 'Error')
    } catch { }
    exit 1
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

. (Join-Path $PSScriptRoot 'lib\Lang.ps1')          # T (UI 문구)
. (Join-Path $PSScriptRoot 'lib\Settings.ps1')      # 폴더/맞춤 기억
. (Join-Path $PSScriptRoot 'lib\WallpaperCom.ps1')  # 모니터 목록 + 적용
. (Join-Path $PSScriptRoot 'lib\ThumbCache.ps1')    # 썸네일 디스크 캐시
. (Join-Path $PSScriptRoot 'lib\ImageCompose.ps1')  # 자동 맞춤(흐린 배경 합성)
. (Join-Path $PSScriptRoot 'lib\ImagePicker.ps1')   # 이미지 고르기 창

# 고해상도 모니터에서 흐릿하게 나오지 않도록. 창을 만들기 전에 호출해야 한다.
try { [System.Windows.Forms.Application]::SetHighDpiMode([System.Windows.Forms.HighDpiMode]::SystemAware) | Out-Null } catch { }
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---- DPI 배율 -------------------------------------------------------------
# 폰트 크기는 pt(=DPI 비례) 단위라 150% 환경에서 글자가 1.5배로 커진다.
# 좌표를 96 DPI 기준으로 고정해두면 글자가 칸 밖으로 삐져나오므로,
# 모든 픽셀 값을 실제 DPI 배율로 함께 키운다.
$gfx   = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
$Scale = $gfx.DpiX / 96.0
$gfx.Dispose()

function Sc { param([double]$v) return [int][Math]::Round($v * $Scale) }

$ImageFolder = Get-ImageFolder -AppRoot $PSScriptRoot

$monitors = @(Get-WallpaperMonitor)
if ($monitors.Count -eq 0) {
    [void][System.Windows.Forms.MessageBox]::Show((T 'main.noMonitors'), (T 'main.errorTitle'), 'OK', 'Error')
    return
}

# 현재 적용된 배경화면으로 시작 상태를 채운다.
# 자동 맞춤으로 적용했으면 Windows 는 합성본(해시 이름) 경로를 돌려준다. 우리가 적어둔
# 원본이 있으면 그쪽을 쓴다 — 안 그러면 파일명이 C58B1A00....jpg 로 보이고, 캐시를
# 비웠을 때 썸네일이 검게 뜬다.
$state = @{}
foreach ($mon in $monitors) {
    $saved = Get-AppliedImage -Label $mon.Label
    $state[$mon.Label] = if ($saved) { $saved } else { $mon.Current }
}

# ---------------------------------------------------------------- 레이아웃
# 주의: PowerShell 변수명은 대소문자를 구분하지 않는다. 여백을 $M 으로 두면
# 아래 루프의 $m(모니터 객체) 이 덮어써서 좌표 계산이 조용히 깨진다. → $MARGIN
$MARGIN = Sc 20
$GAP    = Sc 16
$BTN_H  = Sc 28

$form                 = New-Object System.Windows.Forms.Form
$form.Text            = T 'app.title'
$form.StartPosition   = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox     = $false
$form.Font            = Get-UIFont 9

# 창 제목 표시줄과 작업 표시줄에 프로젝트 아이콘을 사용한다.
$appIcon = $null
$iconPath = Join-Path $PSScriptRoot 'assets\icon.ico'
if (Test-Path -LiteralPath $iconPath) {
    try {
        $appIcon  = [System.Drawing.Icon]::new($iconPath)
        $form.Icon = $appIcon
    } catch {
        if ($appIcon) { $appIcon.Dispose(); $appIcon = $null }
    }
}

$LH = [System.Windows.Forms.TextRenderer]::MeasureText('Ag가', $form.Font).Height + (Sc 4)

function BtnW { param([string]$Text, [int]$MinPx = 0)
    $w = [System.Windows.Forms.TextRenderer]::MeasureText($Text, $form.Font).Width + (Sc 26)
    return [Math]::Max($w, $MinPx)
}

# 썸네일 크기: 모니터가 많으면 창이 화면 밖으로 나가므로, 들어갈 때까지 줄인다.
function Get-Strip { param([int]$ThumbH)
    $ws = @($monitors | ForEach-Object { [int][Math]::Round($ThumbH * $_.Width / $_.Height) })
    return @{ Widths = $ws; Total = (($ws | Measure-Object -Sum).Sum + $GAP * ($monitors.Count - 1)) }
}

$THUMB_H = Sc 168
$MIN_TH  = Sc 84
$availW  = [int]([System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Width * 0.92) - $MARGIN * 2
$strip   = Get-Strip $THUMB_H
for ($pass = 0; $pass -lt 3 -and $strip.Total -gt $availW -and $THUMB_H -gt $MIN_TH; $pass++) {
    $THUMB_H = [Math]::Max([int]($THUMB_H * $availW / $strip.Total), $MIN_TH)
    $strip   = Get-Strip $THUMB_H
}
$widths = $strip.Widths
$stripW = $strip.Total

# 아래 컨트롤 폭을 미리 재서 창 최소 폭을 정한다.
# 상수(예: Sc 660)로 두면 언어에 따라 왼쪽 묶음이 폭을 다 먹는다 — 특히 한국어
# '자동 (안 맞으면 흐린 배경)' 항목 때문에 맞춤 콤보가 넓어져 상태 메시지 자리가
# 26px 만 남고, 적용 실패·오류 안내가 잘려서 사실상 안 보이게 된다.
$fitKeys    = @($script:FitModes)
$fitLabels  = @($fitKeys | ForEach-Object { T "fit.$_" })
$cboFitW    = ($fitLabels | ForEach-Object {
                  [System.Windows.Forms.TextRenderer]::MeasureText($_, $form.Font).Width } |
               Measure-Object -Maximum).Maximum + (Sc 34)
$fitLblW    = [System.Windows.Forms.TextRenderer]::MeasureText((T 'main.fit'), $form.Font).Width + (Sc 10)
$randomW    = BtnW (T 'main.random') (Sc 76)
$folderW    = BtnW (T 'main.folder') (Sc 76)
$applyW     = BtnW (T 'main.apply')  (Sc 88)
$closeW     = BtnW (T 'main.close')  (Sc 88)
$STATUS_MIN = Sc 190      # 가장 긴 안내 문구가 읽히는 최소 폭

$rowW = $MARGIN + $fitLblW + $cboFitW + (Sc 10) + $randomW + (Sc 8) + $folderW + (Sc 12) +
        $STATUS_MIN + (Sc 10) + $applyW + (Sc 8) + $closeW + $MARGIN

$clientW = [int][Math]::Max(($stripW + $MARGIN * 2), $rowW)

# 힌트는 창 폭에 맞춰 줄바꿈시킨다 (언어에 따라 길이가 달라진다).
# 측정할 때는 라벨 실제 폭보다 좁게 잡는다 — 딱 맞게 재면 반올림 한두 픽셀 때문에
# "한 줄에 들어간다"고 판정해 놓고 그릴 때 마지막 글자가 잘린다.
$hintText = T 'main.hint'
$hintW    = $clientW - $MARGIN * 2
$hintH    = [System.Windows.Forms.TextRenderer]::MeasureText(
                $hintText, $form.Font,
                (New-Object System.Drawing.Size(($hintW - (Sc 14)), 0)),
                [System.Windows.Forms.TextFormatFlags]::WordBreak).Height
$hintH    = [Math]::Max($hintH, $LH)

$hint           = New-Object System.Windows.Forms.Label
$hint.Text      = $hintText
$hint.Location  = New-Object System.Drawing.Point($MARGIN, $MARGIN)
$hint.Size      = New-Object System.Drawing.Size($hintW, $hintH)
$hint.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($hint)

$thumbY = $MARGIN + $hintH + (Sc 10)
$headY  = $thumbY + $THUMB_H + (Sc 8)
$subY   = $headY + $LH
$capY   = $subY  + $LH
$rowY   = $capY  + $LH + (Sc 14)

$form.ClientSize = New-Object System.Drawing.Size $clientW, ($rowY + $BTN_H + $MARGIN)

$pics = @{}
$capt = @{}
$x = [int](($clientW - $stripW) / 2)

for ($i = 0; $i -lt $monitors.Count; $i++) {
    $mon = $monitors[$i]
    $w   = $widths[$i]

    $pic             = New-Object System.Windows.Forms.PictureBox
    $pic.Location    = New-Object System.Drawing.Point($x, $thumbY)
    $pic.Size        = New-Object System.Drawing.Size($w, $THUMB_H)
    $pic.BorderStyle = 'FixedSingle'
    $pic.Cursor      = [System.Windows.Forms.Cursors]::Hand
    $pic.Tag         = $mon.Label
    $form.Controls.Add($pic)
    $pics[$mon.Label] = $pic

    $primary = if ($mon.Left -eq 0 -and $mon.Top -eq 0) { T 'mon.primary' } else { '' }

    $head              = New-Object System.Windows.Forms.Label
    $head.Text         = "$($mon.Display)  —  $($mon.Name)"
    $head.Location     = New-Object System.Drawing.Point($x, $headY)
    $head.Size         = New-Object System.Drawing.Size($w, $LH)
    $head.Font         = Get-UIFont 9 ([System.Drawing.FontStyle]::Bold)
    $head.AutoEllipsis = $true
    $form.Controls.Add($head)

    $sub           = New-Object System.Windows.Forms.Label
    $sub.Text      = "$($mon.Width)x$($mon.Height)$primary"
    $sub.Location  = New-Object System.Drawing.Point($x, $subY)
    $sub.Size      = New-Object System.Drawing.Size($w, $LH)
    $sub.ForeColor = [System.Drawing.Color]::DimGray
    $form.Controls.Add($sub)

    $cap              = New-Object System.Windows.Forms.Label
    $cap.Location     = New-Object System.Drawing.Point($x, $capY)
    $cap.Size         = New-Object System.Drawing.Size($w, $LH)
    $cap.AutoEllipsis = $true
    $cap.ForeColor    = [System.Drawing.Color]::FromArgb(0, 90, 158)
    $form.Controls.Add($cap)
    $capt[$mon.Label] = $cap

    $x += $w + $GAP
}

# ---------------------------------------------------------------- 아래 컨트롤
$lblFit          = New-Object System.Windows.Forms.Label
$lblFit.Text     = T 'main.fit'
$lblFit.Location = New-Object System.Drawing.Point($MARGIN, ($rowY + (Sc 5)))
$lblFit.AutoSize = $true
$form.Controls.Add($lblFit)

$cursorX = $MARGIN + $fitLblW

$cboFit               = New-Object System.Windows.Forms.ComboBox
$cboFit.Location      = New-Object System.Drawing.Point($cursorX, $rowY)
$cboFit.DropDownStyle = 'DropDownList'
$cboFit.Width         = $cboFitW
foreach ($lbl in $fitLabels) { [void]$cboFit.Items.Add($lbl) }
$savedFit = Get-SavedFitMode -Valid $fitKeys -Default 'Auto'
$cboFit.SelectedIndex = [Math]::Max([Array]::IndexOf($fitKeys, $savedFit), 0)
$form.Controls.Add($cboFit)
$cursorX += $cboFitW + (Sc 10)

$btnRandom          = New-Object System.Windows.Forms.Button
$btnRandom.Text     = T 'main.random'
$btnRandom.Size     = New-Object System.Drawing.Size($randomW, $BTN_H)
$btnRandom.Location = New-Object System.Drawing.Point($cursorX, ($rowY - (Sc 1)))
$form.Controls.Add($btnRandom)
$cursorX += $randomW + (Sc 8)

$btnFolder          = New-Object System.Windows.Forms.Button
$btnFolder.Text     = T 'main.folder'
$btnFolder.Size     = New-Object System.Drawing.Size($folderW, $BTN_H)
$btnFolder.Location = New-Object System.Drawing.Point($cursorX, ($rowY - (Sc 1)))
$form.Controls.Add($btnFolder)
$cursorX += $folderW + (Sc 12)

$btnClose          = New-Object System.Windows.Forms.Button
$btnClose.Text     = T 'main.close'
$btnClose.Size     = New-Object System.Drawing.Size($closeW, $BTN_H)
$btnClose.Location = New-Object System.Drawing.Point(($clientW - $MARGIN - $closeW), ($rowY - (Sc 1)))
$form.Controls.Add($btnClose)

$btnApply          = New-Object System.Windows.Forms.Button
$btnApply.Text     = T 'main.apply'
$btnApply.Size     = New-Object System.Drawing.Size($applyW, $BTN_H)
$btnApply.Location = New-Object System.Drawing.Point(($btnClose.Left - $applyW - (Sc 8)), ($rowY - (Sc 1)))
$form.Controls.Add($btnApply)

$status              = New-Object System.Windows.Forms.Label
$status.Location     = New-Object System.Drawing.Point($cursorX, ($rowY + (Sc 5)))
$status.Size         = New-Object System.Drawing.Size(
                           [int][Math]::Max(($btnApply.Left - $cursorX - (Sc 10)), (Sc 40))), $LH
$status.AutoEllipsis = $true
$form.Controls.Add($status)

# ---------------------------------------------------------------- 동작
function Get-Mon { param([string]$Label)
    return ($monitors | Where-Object { $_.Label -eq $Label } | Select-Object -First 1)
}
function Set-Status { param([string]$Text, [string]$Color = 'DimGray')
    $status.ForeColor = [System.Drawing.Color]::FromName($Color)
    $status.Text      = $Text
}
function Update-Panel {
    param([string]$Label)
    $pic = $pics[$Label]
    $mon = Get-Mon $Label
    $old = $pic.Image
    # 자동 모드 판정은 미리보기 크기가 아니라 실제 모니터 해상도로 해야 한다
    $pic.Image = New-PreviewBitmap -Path $state[$Label] -W $pic.Width -H $pic.Height `
                                   -Mode $fitKeys[$cboFit.SelectedIndex] `
                                   -MonitorW $mon.Width -MonitorH $mon.Height
    if ($old) { $old.Dispose() }
    $capt[$Label].Text = if ($state[$Label]) { Split-Path $state[$Label] -Leaf } else { T 'main.none' }
}

foreach ($mon in $monitors) { Update-Panel -Label $mon.Label }

$onPick = {
    $label  = $this.Tag
    $mon    = Get-Mon $label
    $picked = Show-ImagePicker -Monitor $mon -Folder $script:ImageFolder `
                               -FitMode $fitKeys[$cboFit.SelectedIndex] `
                               -Current $state[$label] -InUse $state -Scale $Scale `
                               -Icon $appIcon
    if ($picked) {
        $state[$label] = $picked
        Update-Panel -Label $label
        Set-Status (T 'main.pending')
    }
}
foreach ($p in $pics.Values) { $p.Add_Click($onPick) }

$cboFit.Add_SelectedIndexChanged({
    foreach ($mon in $monitors) { Update-Panel -Label $mon.Label }   # 미리보기 갱신
})

$btnFolder.Add_Click({
    $fbd = New-Object System.Windows.Forms.FolderBrowserDialog
    $fbd.Description = T 'main.pickFolder'
    if (Test-Path -LiteralPath $script:ImageFolder) { $fbd.SelectedPath = $script:ImageFolder }
    if ($fbd.ShowDialog() -eq 'OK') {
        $script:ImageFolder = $fbd.SelectedPath
        [void](Set-ImageFolder $fbd.SelectedPath)
        Set-Status (Split-Path $fbd.SelectedPath -Leaf)
    }
    $fbd.Dispose()
})

$btnRandom.Add_Click({
    $files = @(Get-ChildItem -LiteralPath $script:ImageFolder -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -match '^\.(jpg|jpeg|png|bmp|gif|tif|tiff)$' })
    if ($files.Count -eq 0) { Set-Status (T 'main.noFolderImg') 'Firebrick'; return }

    # 이미지가 충분하면 겹치지 않게, 모자라면 중복 허용
    $pick = if ($files.Count -ge $monitors.Count) {
        @($files | Get-Random -Count $monitors.Count)
    } else {
        @(1..$monitors.Count | ForEach-Object { $files | Get-Random })
    }
    for ($i = 0; $i -lt $monitors.Count; $i++) {
        $state[$monitors[$i].Label] = $pick[$i].FullName
        Update-Panel -Label $monitors[$i].Label
    }
    Set-Status (T 'main.pending')
})

$btnApply.Add_Click({
    if (@($monitors | Where-Object { -not $state[$_.Label] }).Count -gt 0) {
        Set-Status (T 'main.noImage') 'Firebrick'; return
    }
    $mode = $fitKeys[$cboFit.SelectedIndex]
    try {
        # 자동 모드는 이미지를 합성해야 해서 장당 최대 0.6초가 걸린다 (한 번 만들면 캐시된다)
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        Set-Status (T 'main.applying')
        [System.Windows.Forms.Application]::DoEvents()

        [Wallpaper]::SetPos((Get-WindowsPosition $mode))
        $failed = @()
        foreach ($mon in $monitors) {
            $ok = Set-WallpaperFor -MonitorId $mon.Id -Path $state[$mon.Label] `
                                   -Mode $mode -MonitorW $mon.Width -MonitorH $mon.Height
            if (-not $ok) { $failed += $mon.Display }
        }
        [void](Set-SavedFitMode $mode)

        # 원본 경로를 기억해 둔다 (합성본 해시 이름이 아니라 원래 파일명이 보이도록)
        $applied = @{}
        foreach ($mon in $monitors) { $applied[$mon.Label] = $state[$mon.Label] }
        [void](Save-AppliedImages $applied)

        if ($failed.Count -eq 0) { Set-Status (T 'main.applied') 'ForestGreen' }
        else                     { Set-Status (T 'main.applyFail' ($failed -join ', ')) 'Firebrick' }
    } catch {
        Set-Status (T 'main.error' $_.Exception.Message) 'Firebrick'
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

$btnClose.Add_Click({ $form.Close() })
$form.Add_FormClosed({
    foreach ($p in $pics.Values) { if ($p.Image) { $p.Image.Dispose() } }
    if ($appIcon) { $appIcon.Dispose() }
})

[void]$form.ShowDialog()
