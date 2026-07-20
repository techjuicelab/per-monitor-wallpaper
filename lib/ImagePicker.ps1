<#
    공용 모듈 — 이미지 고르기 창(모달 갤러리).
    Shared module — modal image gallery. Not meant to be run directly.

    Show-ImagePicker 는 고른 이미지 경로(문자열)를, 취소하면 $null 을 돌려줍니다.

    설계 메모
      · 타일의 가로세로비 = 대상 모니터의 실제 비율, 그림은 현재 맞춤 방식대로 그린다.
        즉 격자에 보이는 그대로가 실제 적용될 모습이다. 파일 탐색 대화상자로는 불가능한 부분.
      · 썸네일은 lib\ThumbCache.ps1 의 디스크 캐시를 쓴다. 캐시가 없으면 장당 약 210ms 라
        타이머로 한 장씩 채운다 — 창은 그 동안에도 계속 반응한다.
      · 원본 해상도는 Get-ImageSize(헤더만 읽음, 약 2ms)로 얻는다. 전체 디코딩(약 207ms)을
        쓰면 타일을 만들거나 클릭할 때마다 눈에 띄게 멈춘다.
      · 이벤트 핸들러가 건드리는 상태는 전부 $script:Pk* 로 둔다. 함수 지역 변수를 잡으면
        모달이 떠 있는 동안은 우연히 동작하다가 나중에 조용히 깨진다.
#>

# 의존 모듈을 스스로 챙긴다 — 빠뜨리면 타일 렌더가 try/catch 안에서 조용히 실패해
# "썸네일이 안 뜨는" 원인 모를 증상이 된다. (이미 불러와 있으면 다시 읽지 않는다)
if (-not (Get-Command New-PreviewBitmap -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'ImageCompose.ps1')
}
if (-not (Get-Command T -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Lang.ps1')
}

function Show-ImagePicker {
    param(
        [Parameter(Mandatory)]$Monitor,             # Get-WallpaperMonitor 가 준 객체
        [Parameter(Mandatory)][string]$Folder,
        [string]$FitMode = 'Auto',
        [string]$Current,                           # 지금 이 모니터에 걸린 이미지
        [hashtable]$InUse = @{},                    # 라벨 -> 경로 (다른 모니터에서 쓰는 중 표시)
        [double]$Scale = 1.0
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    function PkSc { param([double]$v) return [int][Math]::Round($v * $Scale) }
    function PkFiles {
        if (-not (Test-Path -LiteralPath $Folder)) { return @() }
        return @(Get-ChildItem -LiteralPath $Folder -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.Extension -match '^\.(jpg|jpeg|png|bmp|gif|tif|tiff)$' })
    }

    # ---- 상태 (이벤트 핸들러가 보는 값은 전부 $script:) -------------------
    $script:PkResult   = $null
    $script:PkSelected = $Current
    $script:PkTiles    = @()                       # @{ Panel; Pic; Name; Info; Path }
    $script:PkQueue    = New-Object System.Collections.Queue
    $script:PkClosing  = $false

    $posName = $Monitor.Display
    $fitName = T "fit.$FitMode"

    # ---- 창 ----------------------------------------------------------------
    # 폼을 먼저 만든다 — 글자 높이를 재야 타일/행 수를 화면에 맞춰 계산할 수 있다.
    $dlg                 = New-Object System.Windows.Forms.Form
    $dlg.Text            = T 'pick.title'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.StartPosition   = 'CenterParent'
    $dlg.KeyPreview      = $true
    $dlg.Font            = Get-UIFont 9

    $LH   = [System.Windows.Forms.TextRenderer]::MeasureText('Ag가', $dlg.Font).Height + (PkSc 4)
    $BTNH = PkSc 28

    function PkBtnW { param([string]$Text, [int]$MinPx = 0)
        $w = [System.Windows.Forms.TextRenderer]::MeasureText($Text, $dlg.Font).Width + (PkSc 26)
        return [Math]::Max($w, $MinPx)
    }

    # ---- 치수 --------------------------------------------------------------
    $MG      = PkSc 16
    $TILE_W  = PkSc 190
    $CELLPAD = PkSc 3
    $COLS    = 4
    $MAXROWS = 3

    $smallFont = Get-UIFont 8.5
    $LABH      = [System.Windows.Forms.TextRenderer]::MeasureText('Ag가', $smallFont).Height + (PkSc 2)

    # 타일은 대상 모니터의 실제 비율을 따른다. 다만 세로(피벗) 모니터는 비율이 1:1.78 이라
    # 타일이 세로로 길어져 창이 화면 밖으로 나간다 — 높이에 상한을 두고, 넘으면 가로도 같이
    # 줄여 비율을 지킨다. (메인 창이 가로를 제한하는 것과 같은 이유)
    $TILE_H = [int][Math]::Round($TILE_W * $Monitor.Height / $Monitor.Width)
    $MAX_TH = PkSc 240
    if ($TILE_H -gt $MAX_TH) {
        $TILE_W = [Math]::Max([int][Math]::Round($TILE_W * $MAX_TH / $TILE_H), (PkSc 90))
        $TILE_H = $MAX_TH
    }

    $CELL_W = $TILE_W + $CELLPAD * 2
    $CELL_H = $TILE_H + $CELLPAD * 2 + $LABH * 2
    $flowW  = $COLS * ($CELL_W + (PkSc 8)) + (PkSc 26)     # 세로 스크롤바 여유

    # 창 높이를 실제 장수에 맞춘다 (8장인데 3행 높이로 열면 아래가 텅 빈다).
    # 검색으로 줄어들 때 창이 들썩이지 않도록 처음 장수로 한 번만 정한다.
    # 동시에 화면 작업 영역을 넘지 않도록 행 수를 제한한다 — 안 그러면 확인/취소 버튼이
    # 화면 밖으로 밀린다. 대화상자는 부모 창이 있는 화면에 뜨므로 그 화면 기준으로 잰다.
    $work    = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
    $chrome  = $MG * 3 + $LH * 2 + $BTNH * 2 + (PkSc 60)   # 제목줄 + 헤더 + 검색줄 + 버튼줄 여유
    $fitRows = [Math]::Floor(($work.Height - $chrome) / ($CELL_H + (PkSc 8)))

    $n0    = (PkFiles).Count
    $rows  = [Math]::Max(1, [Math]::Min([Math]::Min([Math]::Ceiling($n0 / $COLS), $MAXROWS), $fitRows))
    $flowH = $rows * ($CELL_H + (PkSc 8)) + (PkSc 10)

    $hdr          = New-Object System.Windows.Forms.Label
    $hdr.Text     = T 'pick.header' $posName $Monitor.Width $Monitor.Height $fitName
    $hdr.Location = New-Object System.Drawing.Point $MG, $MG
    $hdr.Size     = New-Object System.Drawing.Size ($flowW - (PkSc 4)), $LH
    $hdr.Font     = Get-UIFont 9 ([System.Drawing.FontStyle]::Bold)
    $dlg.Controls.Add($hdr)

    $barY = $MG + $LH + (PkSc 6)

    $lblFind          = New-Object System.Windows.Forms.Label
    $lblFind.Text     = T 'pick.search'
    $lblFind.Location = New-Object System.Drawing.Point $MG, ($barY + (PkSc 5))
    $lblFind.AutoSize = $true
    $dlg.Controls.Add($lblFind)

    $barX = $MG + [System.Windows.Forms.TextRenderer]::MeasureText((T 'pick.search'), $dlg.Font).Width + (PkSc 10)

    $txtFind          = New-Object System.Windows.Forms.TextBox
    $txtFind.Location = New-Object System.Drawing.Point $barX, $barY
    $txtFind.Width    = PkSc 190
    $dlg.Controls.Add($txtFind)
    $barX += $txtFind.Width + (PkSc 10)

    $sortLabels = @((T 'pick.sortNew'), (T 'pick.sortName'), (T 'pick.sortSize'))
    $cboSort               = New-Object System.Windows.Forms.ComboBox
    $cboSort.Location      = New-Object System.Drawing.Point $barX, $barY
    $cboSort.DropDownStyle = 'DropDownList'
    [void]$cboSort.Items.AddRange($sortLabels)
    $cboSort.Width = ($sortLabels | ForEach-Object {
                        [System.Windows.Forms.TextRenderer]::MeasureText($_, $dlg.Font).Width } |
                      Measure-Object -Maximum).Maximum + (PkSc 34)
    $cboSort.SelectedIndex = 0                      # 새로 넣은 이미지를 먼저 보여준다
    $dlg.Controls.Add($cboSort)
    $barX += $cboSort.Width + (PkSc 10)

    $btnReload          = New-Object System.Windows.Forms.Button
    $btnReload.Text     = T 'pick.reload'
    $btnReload.Size     = New-Object System.Drawing.Size (PkBtnW (T 'pick.reload') (PkSc 72)), $BTNH
    $btnReload.Location = New-Object System.Drawing.Point $barX, ($barY - (PkSc 1))
    $dlg.Controls.Add($btnReload)
    $barX += $btnReload.Width + (PkSc 12)

    $lblCount           = New-Object System.Windows.Forms.Label
    $lblCount.Location  = New-Object System.Drawing.Point $barX, ($barY + (PkSc 5))
    $lblCount.Size      = New-Object System.Drawing.Size ([int][Math]::Max(($flowW - $barX), (PkSc 60))), $LH
    $lblCount.ForeColor = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($lblCount)

    $flowY = $barY + $BTNH + (PkSc 8)

    $flow              = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.Location     = New-Object System.Drawing.Point $MG, $flowY
    $flow.Size         = New-Object System.Drawing.Size $flowW, $flowH
    $flow.AutoScroll   = $true
    $flow.WrapContents = $true
    $flow.BorderStyle  = 'FixedSingle'
    $flow.BackColor    = [System.Drawing.Color]::FromArgb(250, 250, 250)
    $dlg.Controls.Add($flow)

    $rowY = $flowY + $flowH + (PkSc 10)

    $browseW = PkBtnW (T 'pick.browse') (PkSc 110)
    $okW     = PkBtnW (T 'pick.ok')     (PkSc 88)
    $cancelW = PkBtnW (T 'pick.cancel') (PkSc 88)

    $btnCancel          = New-Object System.Windows.Forms.Button
    $btnCancel.Text     = T 'pick.cancel'
    $btnCancel.Size     = New-Object System.Drawing.Size $cancelW, $BTNH
    $btnCancel.Location = New-Object System.Drawing.Point ($MG + $flowW - $cancelW), $rowY
    $dlg.Controls.Add($btnCancel)

    $btnOK          = New-Object System.Windows.Forms.Button
    $btnOK.Text     = T 'pick.ok'
    $btnOK.Size     = New-Object System.Drawing.Size $okW, $BTNH
    $btnOK.Location = New-Object System.Drawing.Point ($btnCancel.Left - $okW - (PkSc 8)), $rowY
    $dlg.Controls.Add($btnOK)

    $btnBrowse          = New-Object System.Windows.Forms.Button
    $btnBrowse.Text     = T 'pick.browse'
    $btnBrowse.Size     = New-Object System.Drawing.Size $browseW, $BTNH
    $btnBrowse.Location = New-Object System.Drawing.Point ($btnOK.Left - $browseW - (PkSc 12)), $rowY
    $dlg.Controls.Add($btnBrowse)

    $status              = New-Object System.Windows.Forms.Label
    $status.Location     = New-Object System.Drawing.Point $MG, ($rowY + (PkSc 5))
    $status.Size         = New-Object System.Drawing.Size (
                               [int][Math]::Max(($btnBrowse.Left - $MG - (PkSc 10)), (PkSc 60))), $LH
    $status.AutoEllipsis = $true
    $status.ForeColor    = [System.Drawing.Color]::DimGray
    $dlg.Controls.Add($status)

    $dlg.ClientSize   = New-Object System.Drawing.Size ($flowW + $MG * 2), ($rowY + $BTNH + $MG)
    $dlg.CancelButton = $btnCancel

    $script:PkTimer          = New-Object System.Windows.Forms.Timer
    $script:PkTimer.Interval = 15

    # ---- 도우미 -------------------------------------------------------------
    function PkClearTiles {
        $script:PkQueue.Clear()
        foreach ($t in $script:PkTiles) {
            if ($t.Pic.Image) { $t.Pic.Image.Dispose(); $t.Pic.Image = $null }
        }
        $flow.Controls.Clear()                 # 컨트롤 Dispose 는 폼이 담당
        $script:PkTiles = @()
    }

    function PkRing { param($Tile)
        $Tile.Panel.BackColor = if ($Tile.Path -eq $script:PkSelected) {
            [System.Drawing.Color]::FromArgb(0, 120, 215)
        } else { $flow.BackColor }
    }

    function PkUsedBy { param([string]$Path)
        $u = @()
        foreach ($k in $InUse.Keys) {
            if ($InUse[$k] -eq $Path) { $u += (Get-MonitorDisplayName $k) }
        }
        return $u
    }

    function PkSelect { param([string]$Path)
        $script:PkSelected = $Path
        foreach ($t in $script:PkTiles) { PkRing $t }

        $name = Split-Path $Path -Leaf
        $sz   = Get-ImageSize -Path $Path
        if (-not $sz) { $status.ForeColor = [System.Drawing.Color]::DimGray; $status.Text = $name; return }

        $needs = Test-NeedsCompose -SrcW $sz.Width -SrcH $sz.Height -DstW $Monitor.Width -DstH $Monitor.Height
        $small = ($sz.Width -lt $Monitor.Width -or $sz.Height -lt $Monitor.Height)

        $tail = ''
        if ($FitMode -eq 'Auto') {
            if ($needs) { $tail = '    ' + (T 'pick.autoNote'); $status.ForeColor = [System.Drawing.Color]::SeaGreen }
            else        { $status.ForeColor = [System.Drawing.Color]::DimGray }
        } elseif ($small) {
            $tail = '    ' + (T 'pick.upNote' $Monitor.Width $Monitor.Height)
            $status.ForeColor = [System.Drawing.Color]::Firebrick
        } else { $status.ForeColor = [System.Drawing.Color]::DimGray }

        $status.Text = "$name    $($sz.Width)x$($sz.Height)$tail"
    }

    function PkBuild {
        PkClearTiles

        $all = PkFiles
        $q   = $txtFind.Text.Trim()
        if ($q) { $all = @($all | Where-Object { $_.Name -like "*$q*" }) }
        $all = switch ($cboSort.SelectedIndex) {
            1       { @($all | Sort-Object Name) }
            2       { @($all | Sort-Object Length -Descending) }
            default { @($all | Sort-Object LastWriteTime -Descending) }
        }
        $lblCount.Text = if ($q) { T 'pick.countFind' $all.Count $q } else { T 'pick.count' $all.Count }

        $onClick  = { PkSelect $this.Tag }
        $onDouble = { PkSelect $this.Tag; $script:PkResult = $this.Tag; $dlg.Close() }

        $flow.SuspendLayout()
        $slot = 0
        foreach ($file in $all) {
            $cell           = New-Object System.Windows.Forms.Panel
            $cell.Size      = New-Object System.Drawing.Size $CELL_W, $CELL_H
            $cell.Margin    = New-Object System.Windows.Forms.Padding (PkSc 4)
            $cell.BackColor = $flow.BackColor
            $cell.Cursor    = [System.Windows.Forms.Cursors]::Hand
            $cell.Tag       = $file.FullName

            $box           = New-Object System.Windows.Forms.PictureBox
            $box.Location  = New-Object System.Drawing.Point $CELLPAD, $CELLPAD
            $box.Size      = New-Object System.Drawing.Size $TILE_W, $TILE_H
            $box.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 32)
            $box.Cursor    = [System.Windows.Forms.Cursors]::Hand
            $box.Tag       = $file.FullName
            $cell.Controls.Add($box)

            # 라벨 배경을 불투명하게 둔다. 투명이면 선택했을 때 파란 링 색이 뒤로 비쳐
            # 글자가 묻히고, 해상도/경고 색 구분도 안 보인다. 링은 썸네일 테두리로만 보이면 된다.
            $labName              = New-Object System.Windows.Forms.Label
            $labName.Location     = New-Object System.Drawing.Point $CELLPAD, ($CELLPAD + $TILE_H + (PkSc 1))
            $labName.Size         = New-Object System.Drawing.Size $TILE_W, $LABH
            $labName.Font         = $smallFont
            $labName.AutoEllipsis = $true
            $labName.Cursor       = [System.Windows.Forms.Cursors]::Hand
            $labName.Tag          = $file.FullName
            $labName.Text         = $file.Name
            $labName.ForeColor    = [System.Drawing.Color]::Black   # 밝은 배경 고정이므로 명시
            $labName.BackColor    = $flow.BackColor
            $cell.Controls.Add($labName)

            $labInfo              = New-Object System.Windows.Forms.Label
            $labInfo.Location     = New-Object System.Drawing.Point $CELLPAD, ($CELLPAD + $TILE_H + (PkSc 1) + $LABH)
            $labInfo.Size         = New-Object System.Drawing.Size $TILE_W, $LABH
            $labInfo.Font         = $smallFont
            $labInfo.AutoEllipsis = $true
            $labInfo.Cursor       = [System.Windows.Forms.Cursors]::Hand
            $labInfo.Tag          = $file.FullName
            $labInfo.ForeColor    = [System.Drawing.Color]::DimGray
            $labInfo.BackColor    = $flow.BackColor
            $cell.Controls.Add($labInfo)

            foreach ($c in @($cell, $box, $labName, $labInfo)) {
                $c.Add_Click($onClick)
                $c.Add_DoubleClick($onDouble)
            }

            $flow.Controls.Add($cell)
            $tile = @{ Panel = $cell; Pic = $box; Name = $labName; Info = $labInfo; Path = $file.FullName }
            $script:PkTiles += $tile
            PkRing $tile
            $script:PkQueue.Enqueue($slot)
            $slot++
        }
        $flow.ResumeLayout()

        if ($script:PkQueue.Count -gt 0) { $script:PkTimer.Start() }
        if ($all.Count -eq 0) {
            $status.ForeColor = [System.Drawing.Color]::Firebrick
            $status.Text = if ($q) { T 'pick.noResults' } else { T 'pick.noImages' $Folder }
        }
    }

    # ---- 이벤트 -------------------------------------------------------------
    # 썸네일과 해상도를 한 칸씩 채운다. 캐시가 없으면 장당 약 210ms 이므로
    # 한꺼번에 하면 창이 통째로 멈춘다.
    $script:PkTimer.Add_Tick({
        if ($script:PkClosing -or $script:PkQueue.Count -eq 0) { $this.Stop(); return }
        $i = $script:PkQueue.Dequeue()
        if ($i -lt $script:PkTiles.Count) {
            $t = $script:PkTiles[$i]
            try {
                $t.Pic.Image = New-PreviewBitmap -Path $t.Path -W $TILE_W -H $TILE_H -Mode $FitMode `
                                                 -MonitorW $Monitor.Width -MonitorH $Monitor.Height

                $sz   = Get-ImageSize -Path $t.Path
                $used = PkUsedBy $t.Path

                # 자동 모드에서는 합성이 처리하므로 '확대됨' 경고 대신 '자동 맞춤'을 표시한다.
                $note = ''; $warn = $false
                if ($sz) {
                    $needs = Test-NeedsCompose -SrcW $sz.Width -SrcH $sz.Height `
                                               -DstW $Monitor.Width -DstH $Monitor.Height
                    if ($FitMode -eq 'Auto') {
                        if ($needs) { $note = '  ' + (T 'pick.autoFit') }
                    } elseif ($sz.Width -lt $Monitor.Width -or $sz.Height -lt $Monitor.Height) {
                        $note = '  ' + (T 'pick.upscaled'); $warn = $true
                    }
                }

                $txt = if ($sz) { "$($sz.Width)x$($sz.Height)" } else { '' }
                $txt += $note
                if ($used.Count) { $txt += "  ● $($used -join ', ')" }

                $t.Info.Text      = $txt
                $t.Info.ForeColor = if ($warn)           { [System.Drawing.Color]::Firebrick }
                                    elseif ($note)       { [System.Drawing.Color]::SeaGreen }
                                    elseif ($used.Count) { [System.Drawing.Color]::FromArgb(0, 120, 215) }
                                    else                 { [System.Drawing.Color]::DimGray }
            } catch { }
        }
        if ($script:PkQueue.Count -eq 0) { $this.Stop() }
    })

    # 검색은 타이핑할 때마다 다시 그리지 않도록 잠깐 묶어둔다
    $script:PkDebounce          = New-Object System.Windows.Forms.Timer
    $script:PkDebounce.Interval = 300
    $script:PkDebounce.Add_Tick({ $this.Stop(); PkBuild })
    $txtFind.Add_TextChanged({ $script:PkDebounce.Stop(); $script:PkDebounce.Start() })

    $cboSort.Add_SelectedIndexChanged({ PkBuild })
    $btnReload.Add_Click({ PkBuild })

    $btnBrowse.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.InitialDirectory = $Folder
        $ofd.Filter = "$(T 'pick.filterImg')|*.jpg;*.jpeg;*.png;*.bmp;*.gif;*.tif;*.tiff|$(T 'pick.filterAll')|*.*"
        $ofd.Title  = T 'pick.dlgTitle' $posName
        if ($ofd.ShowDialog() -eq 'OK') { $script:PkResult = $ofd.FileName; $dlg.Close() }
        $ofd.Dispose()
    })

    $btnOK.Add_Click({
        if (-not $script:PkSelected) {
            $status.ForeColor = [System.Drawing.Color]::Firebrick
            $status.Text = T 'pick.chooseIt'
            return
        }
        $script:PkResult = $script:PkSelected
        $dlg.Close()
    })
    $btnCancel.Add_Click({ $script:PkResult = $null; $dlg.Close() })

    $dlg.Add_KeyDown({
        if ($_.KeyCode -eq 'Return' -and $script:PkSelected) {
            $script:PkResult = $script:PkSelected; $dlg.Close()
        }
    })

    # 타이머를 먼저 멈춘 뒤 비트맵을 놓아야 한다.
    # 순서가 바뀌면 폼이 닫힌 뒤 Tick 이 Dispose 된 컨트롤을 건드려 예외가 난다.
    $dlg.Add_FormClosing({ $script:PkClosing = $true })
    $dlg.Add_FormClosed({
        $script:PkTimer.Stop();    $script:PkTimer.Dispose()
        $script:PkDebounce.Stop(); $script:PkDebounce.Dispose()
        foreach ($t in $script:PkTiles) { if ($t.Pic.Image) { $t.Pic.Image.Dispose() } }
        $script:PkTiles = @()
    })

    $dlg.Add_Shown({
        PkBuild
        if ($script:PkSelected) { PkSelect $script:PkSelected }
    })

    [void]$dlg.ShowDialog()
    $dlg.Dispose()
    $smallFont.Dispose()
    return $script:PkResult
}
