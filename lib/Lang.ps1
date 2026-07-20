<#
    공용 모듈 — UI 문구 (한국어 / English).
    Shared module — UI strings. Not meant to be run directly.

    Windows 표시 언어가 한국어면 한국어, 아니면 영어로 나옵니다.
    강제로 바꾸려면 실행 전에 환경변수를 지정하세요:  $env:MYWALLPAPER_LANG = 'en'

    언어를 추가하려면 $Strings 에 키를 하나 더 넣고 Resolve-Lang 에 조건만 더하면 됩니다.
    To add a language: add a key to $Strings and a branch to Resolve-Lang.
#>

function Resolve-Lang {
    if ($env:MYWALLPAPER_LANG) {
        $forced = $env:MYWALLPAPER_LANG.Trim().ToLowerInvariant()
        if ($script:Strings.Contains($forced)) { return $forced }
    }
    try { $ui = (Get-UICulture).Name } catch { $ui = 'en-US' }
    if ($ui -like 'ko*') { return 'ko' }
    return 'en'
}

$script:Strings = [ordered]@{

  ko = @{
    # --- 위치 / 모니터 ---
    'pos.left'        = '왼쪽';       'pos.center'   = '가운데';   'pos.right'  = '오른쪽'
    'pos.top'         = '위';         'pos.middle'   = '중간';     'pos.bottom' = '아래'
    'pos.only'        = '모니터';     'pos.nth'      = '{0}번 모니터'
    'mon.unknown'     = '알 수 없는 모니터'
    'mon.primary'     = ', 주 모니터'

    # --- 맞춤 방식 ---
    'fit.Auto'  = '자동 (안 맞으면 흐린 배경)';  'fit.Fill'   = '채우기 (잘림)'
    'fit.Fit'   = '맞춤 (여백)';                 'fit.Stretch'= '늘이기'
    'fit.Center'= '가운데';                      'fit.Tile'   = '바둑판'
    'fit.Span'  = '여러 대에 걸치기'

    # --- 메인 창 ---
    'app.title'       = '모니터별 배경화면'
    'main.hint'       = '모니터 칸을 클릭하면 폴더의 이미지를 격자로 보며 고를 수 있습니다. 썸네일은 실제 적용될 모습 그대로입니다.'
    'main.fit'        = '맞춤'
    'main.random'     = '무작위'
    'main.folder'     = '폴더...'
    'main.apply'      = '적용'
    'main.close'      = '닫기'
    'main.applying'   = '적용하는 중...'
    'main.applied'    = '적용되었습니다'
    'main.applyFail'  = '적용 실패: {0}'
    'main.pending'    = '[적용] 을 누르면 반영됩니다'
    'main.noImage'    = '이미지를 고르지 않은 모니터가 있습니다'
    'main.noFolderImg'= '폴더에 이미지가 없습니다'
    'main.error'      = '오류: {0}'
    'main.none'       = '(없음)'
    'main.noMonitors' = '연결된 모니터를 찾지 못했습니다.'
    'main.errorTitle' = '오류'
    'main.pickFolder' = '배경화면 이미지가 들어있는 폴더를 고르세요'

    # --- 이미지 고르기 창 ---
    'pick.title'      = '이미지 고르기'
    'pick.header'     = '{0} ({1}x{2})   ·   맞춤: {3}'
    'pick.search'     = '검색'
    'pick.sortNew'    = '최신순';  'pick.sortName' = '이름순';  'pick.sortSize' = '크기순'
    'pick.reload'     = '새로고침'
    'pick.count'      = '{0}장'
    'pick.countFind'  = '{0}장 (검색: {1})'
    'pick.browse'     = '파일 찾아보기...'
    'pick.ok'         = '확인'
    'pick.cancel'     = '취소'
    'pick.chooseIt'   = '이미지를 먼저 고르세요'
    'pick.noResults'  = '검색 결과가 없습니다'
    'pick.noImages'   = '폴더에 이미지가 없습니다: {0}'
    'pick.dlgTitle'   = '{0} 모니터에 사용할 이미지'
    'pick.filterImg'  = '이미지'
    'pick.filterAll'  = '모든 파일'
    'pick.autoFit'    = '자동 맞춤'
    'pick.upscaled'   = '확대됨'
    'pick.autoNote'   = '모니터에 맞지 않아 흐린 배경을 넣어 합성합니다 (잘리지 않음)'
    'pick.upNote'     = '모니터({0}x{1})보다 작아 확대됩니다'

    # --- 명령줄 ---
    'cli.current'     = '현재 배경화면 (모니터 {0}대, 맞춤={1})'
    'cli.plan'        = '적용할 내용 (맞춤={0})'
    'cli.preview'     = '미리보기만 했습니다. 적용하려면 -WhatIf 없이 실행하세요.'
    'cli.done'        = '완료되었습니다.'
    'cli.failed'      = '적용 실패: {0}'
    'cli.badFit'      = "`$Position 값이 잘못됐습니다: '{0}'. 가능한 값: {1}"
    'cli.noFolder'    = '이미지 폴더가 없습니다: {0}'
    'cli.noAssign'    = "`$Assign 에 '{0}' 항목이 없습니다. 지금 연결된 모니터는 {1} 입니다."
    'cli.noImage'     = "이미지를 찾을 수 없습니다: {0}`n  폴더: {1}`n  사용 가능한 파일:`n    {2}"
    'cli.noMonitors'  = '연결된 모니터를 찾지 못했습니다.'
    'cli.emptyFolder' = "이미지 폴더가 비어 있습니다: {0}`n`n  이 폴더에 이미지(jpg/png 등)를 넣거나,`n  Wallpaper.bat 을 실행해 [폴더...] 버튼으로 다른 폴더를 지정하세요."
  }

  en = @{
    # --- position / display ---
    'pos.left'        = 'Left';       'pos.center'   = 'Center';   'pos.right'  = 'Right'
    'pos.top'         = 'Top';        'pos.middle'   = 'Middle';   'pos.bottom' = 'Bottom'
    'pos.only'        = 'Display';    'pos.nth'      = 'Display {0}'
    'mon.unknown'     = 'Unknown display'
    'mon.primary'     = ', primary'

    # --- fit modes ---
    'fit.Auto'  = 'Auto (blurred fill)';   'fit.Fill'   = 'Fill (crops)'
    'fit.Fit'   = 'Fit (letterbox)';       'fit.Stretch'= 'Stretch'
    'fit.Center'= 'Center';                'fit.Tile'   = 'Tile'
    'fit.Span'  = 'Span displays'

    # --- main window ---
    'app.title'       = 'Per-Monitor Wallpaper'
    'main.hint'       = 'Click a display to pick an image from your folder. Thumbnails show exactly how it will look.'
    'main.fit'        = 'Fit'
    'main.random'     = 'Shuffle'
    'main.folder'     = 'Folder...'
    'main.apply'      = 'Apply'
    'main.close'      = 'Close'
    'main.applying'   = 'Applying...'
    'main.applied'    = 'Applied'
    'main.applyFail'  = 'Failed: {0}'
    'main.pending'    = 'Press [Apply] to set'
    'main.noImage'    = 'Some displays have no image selected'
    'main.noFolderImg'= 'No images in the folder'
    'main.error'      = 'Error: {0}'
    'main.none'       = '(none)'
    'main.noMonitors' = 'No displays found.'
    'main.errorTitle' = 'Error'
    'main.pickFolder' = 'Choose the folder holding your wallpaper images'

    # --- picker ---
    'pick.title'      = 'Choose Image'
    'pick.header'     = '{0} ({1}x{2})   ·   Fit: {3}'
    'pick.search'     = 'Search'
    'pick.sortNew'    = 'Newest';  'pick.sortName' = 'Name';  'pick.sortSize' = 'Size'
    'pick.reload'     = 'Refresh'
    'pick.count'      = '{0} images'
    'pick.countFind'  = '{0} images (search: {1})'
    'pick.browse'     = 'Browse...'
    'pick.ok'         = 'OK'
    'pick.cancel'     = 'Cancel'
    'pick.chooseIt'   = 'Select an image first'
    'pick.noResults'  = 'No matches'
    'pick.noImages'   = 'No images in: {0}'
    'pick.dlgTitle'   = 'Image for the {0} display'
    'pick.filterImg'  = 'Images'
    'pick.filterAll'  = 'All files'
    'pick.autoFit'    = 'auto-fit'
    'pick.upscaled'   = 'upscaled'
    'pick.autoNote'   = "Doesn't fit this display - will be composed with a blurred backdrop (nothing cropped)"
    'pick.upNote'     = 'Smaller than the display ({0}x{1}) - will be upscaled'

    # --- command line ---
    'cli.current'     = 'Current wallpapers ({0} displays, fit={1})'
    'cli.plan'        = 'Will apply (fit={0})'
    'cli.preview'     = 'Preview only. Run without -WhatIf to apply.'
    'cli.done'        = 'Done.'
    'cli.failed'      = 'Failed: {0}'
    'cli.badFit'      = "Invalid `$Position: '{0}'. Valid values: {1}"
    'cli.noFolder'    = 'Image folder not found: {0}'
    'cli.noAssign'    = "`$Assign has no entry for '{0}'. Currently attached: {1}."
    'cli.noImage'     = "Image not found: {0}`n  Folder: {1}`n  Available files:`n    {2}"
    'cli.noMonitors'  = 'No displays found.'
    'cli.emptyFolder' = "The image folder is empty: {0}`n`n  Put some images (jpg/png/...) in it,`n  or run Wallpaper.bat and use the [Folder...] button to point somewhere else."
  }
}

$script:Lang = Resolve-Lang

function T {
    <#
        문구를 가져온다. 자리표시자가 있으면 뒤에 값을 넘긴다.
        Get a string; pass values for {0}, {1}... placeholders.
            T 'main.applyFail' ($failed -join ', ')

        키가 없으면 영어 표를 보고, 그것도 없으면 키 자체를 돌려준다 —
        문구 하나 빠졌다고 앱이 죽지는 않게.

        주의: 남은 인자는 반드시 ValueFromRemainingArguments 로 받아야 한다.
        [Parameter()] 를 붙이는 순간 이 함수는 '고급 함수'가 되어 $args 가 없어지고,
        값을 하나라도 넘기면 "positional parameter cannot be found" 로 터진다.
    #>
    param(
        [Parameter(Mandatory, Position = 0)][string]$Key,
        [Parameter(ValueFromRemainingArguments = $true)][object[]]$Values
    )

    $tbl = $script:Strings[$script:Lang]
    $s = if ($tbl -and $tbl.ContainsKey($Key)) { $tbl[$Key] }
         elseif ($script:Strings['en'].ContainsKey($Key)) { $script:Strings['en'][$Key] }
         else { $Key }

    if ($Values -and $Values.Count -gt 0) { return ($s -f $Values) }
    return $s
}

function Get-LangCode { return $script:Lang }

function Get-UIFont {
    <#
        한국어 UI 는 맑은 고딕이 가장 잘 맞고, 그 외에는 Segoe UI 가 표준이다.
        폰트가 없으면 GDI+ 가 알아서 대체하므로 실패하지 않는다.
    #>
    param([single]$Size = 9, [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular)
    $family = if ($script:Lang -eq 'ko') { 'Malgun Gothic' } else { 'Segoe UI' }
    return (New-Object System.Drawing.Font($family, $Size, $Style))
}
