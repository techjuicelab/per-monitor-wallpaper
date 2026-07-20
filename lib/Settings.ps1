<#
    공용 모듈 — 사용자 설정 저장. / Shared module — user settings.
    직접 실행하는 파일이 아닙니다. / Not meant to be run directly.

    설정은 저장소가 아니라 %LOCALAPPDATA%\MyWallpaper\settings.json 에 둔다.
    저장소를 새로 받아도 내 폴더 선택이 남아 있고, 남의 경로가 커밋에 섞이지도 않는다.
    Settings live outside the repo so a fresh clone keeps your choice and no personal
    path ever lands in a commit.
#>

$script:SettingsPath = Join-Path $env:LOCALAPPDATA 'MyWallpaper\settings.json'

function Get-AppSettings {
    if (Test-Path -LiteralPath $script:SettingsPath) {
        try {
            # PowerShell 5.1 은 -Encoding UTF8 을 줘야 한글 경로가 깨지지 않는다
            return (Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json)
        } catch { }
    }
    return [pscustomobject]@{ ImageFolder = $null; FitMode = $null }
}

function Save-AppSettings {
    param([Parameter(Mandatory)]$Settings)
    try {
        $dir = Split-Path $script:SettingsPath -Parent
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $json = $Settings | ConvertTo-Json -Depth 4
        # BOM 없는 UTF-8 로 쓴다 (ConvertFrom-Json 이 BOM 을 싫어하는 경우가 있다)
        [System.IO.File]::WriteAllText($script:SettingsPath, $json, [System.Text.UTF8Encoding]::new($false))
        return $true
    } catch { return $false }
}

function Get-ImageFolder {
    <#
        쓸 이미지 폴더를 정한다. 우선순위:
          1. 저장된 설정 (폴더가 아직 있으면)
          2. 저장소 안의 images\  (이미지가 들어 있으면)
          3. 내 사진 폴더
        Resolve the image folder: saved setting -> repo's images\ -> Pictures.
    #>
    param([Parameter(Mandatory)][string]$AppRoot)

    $s = Get-AppSettings
    if ($s.ImageFolder -and (Test-Path -LiteralPath $s.ImageFolder)) { return $s.ImageFolder }

    # 저장소 안의 images\ — 비어 있어도 여기를 쓴다. 첫 실행에서 사용자가
    # 어디에 이미지를 넣어야 하는지 분명해지기 때문이다(내 사진 폴더로 흘려보내지 않는다).
    $bundled = Join-Path $AppRoot 'images'
    if (Test-Path -LiteralPath $bundled) { return $bundled }

    return [Environment]::GetFolderPath('MyPictures')
}

function Set-ImageFolder {
    param([Parameter(Mandatory)][string]$Path)
    $s = Get-AppSettings
    $s | Add-Member -NotePropertyName ImageFolder -NotePropertyValue $Path -Force
    return (Save-AppSettings $s)
}

function Set-SavedFitMode {
    param([Parameter(Mandatory)][string]$Mode)
    $s = Get-AppSettings
    $s | Add-Member -NotePropertyName FitMode -NotePropertyValue $Mode -Force
    return (Save-AppSettings $s)
}

function Save-AppliedImages {
    <#
        모니터별로 '사용자가 고른 원본' 경로를 기억한다.

        왜 필요한가: 자동 맞춤으로 적용하면 Windows 에는 합성본 경로가 저장된다. 다음에 앱을
        열어 Windows 에 물어보면 composed\C58B1A00....jpg 같은 해시 이름이 돌아온다. 그걸
        그대로 보여주면 (1) 원본 파일명을 잃고 (2) 캐시를 비웠을 때 썸네일이 검게 뜬다.
        그래서 원본 경로를 따로 적어두고 화면에는 그것을 쓴다.
    #>
    param([Parameter(Mandatory)][hashtable]$Map)   # 라벨 -> 원본 경로
    $s = Get-AppSettings
    $obj = [pscustomobject]@{}
    foreach ($k in $Map.Keys) {
        if ($Map[$k]) { $obj | Add-Member -NotePropertyName $k -NotePropertyValue $Map[$k] -Force }
    }
    $s | Add-Member -NotePropertyName Applied -NotePropertyValue $obj -Force
    return (Save-AppSettings $s)
}

function Get-AppliedImage {
    <#
        해당 모니터에 마지막으로 고른 원본 경로. 파일이 사라졌으면 $null.
        호출 측은 이 값이 없을 때만 Windows 가 보고한 경로로 물러선다.
    #>
    param([Parameter(Mandatory)][string]$Label)
    $s = Get-AppSettings
    if (-not $s.Applied) { return $null }
    $p = $s.Applied.$Label
    if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    return $null
}

function Get-SavedFitMode {
    param([string[]]$Valid, [string]$Default = 'Auto')
    $s = Get-AppSettings
    if ($s.FitMode -and $Valid -contains $s.FitMode) { return $s.FitMode }
    return $Default
}
