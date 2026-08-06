<#
    Per-Monitor Wallpaper — 설치 (선택 사항)
    Per-Monitor Wallpaper — optional installer

    실행 / Run (저장소 루트에서 / from the repo root):
        pwsh -ExecutionPolicy Bypass -File .\Install.ps1

    하는 일 / What it does:
      1. 앱 파일을 %LOCALAPPDATA%\Programs\PerMonitorWallpaper 로 복사
      2. 시작 메뉴에 "Wallpaper-GUI" 바로가기 생성
      3. 사용자 예약 작업 등록 (매일 + 로그온) → Update.ps1 이 자동 업데이트
    관리자 권한이 필요 없고, 몇 번을 다시 실행해도 안전합니다(멱등).
    설치하지 않아도 기존처럼 clone 폴더에서 Wallpaper.bat 으로 그대로 쓸 수 있습니다.

    No admin rights needed; safe to re-run any number of times. Installing is
    optional — running straight from the clone keeps working as before.
#>

$ErrorActionPreference = 'Stop'

# --- 환경 확인 --------------------------------------------------------------
# $IsWindows 는 PS 5.1 에 없으므로($null → false) 버전 검사를 먼저 한다.
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host ''
    Write-Host 'PowerShell 7 이 필요합니다 / PowerShell 7 is required:'
    Write-Host '    winget install Microsoft.PowerShell'
    Write-Host '그 다음 / then:  pwsh -ExecutionPolicy Bypass -File .\Install.ps1'
    Write-Host ''
    exit 1
}
if (-not $IsWindows) {
    Write-Host 'Windows 전용입니다 / This installer is Windows-only.'
    exit 1
}

$SourceDir  = $PSScriptRoot
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\PerMonitorWallpaper'
$TaskName   = 'PerMonitorWallpaper Update'

if (-not (Test-Path -LiteralPath (Join-Path $SourceDir 'Wallpaper-GUI.ps1'))) {
    Write-Host "여기는 Per-Monitor Wallpaper 저장소가 아닙니다 / Not the repo root: $SourceDir"
    exit 1
}

# 예약 작업과 바로가기에 기록할 pwsh 절대 경로 (PATH 가 없어도 동작하도록).
$pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwshPath) { $pwshPath = [Environment]::ProcessPath }

# --- 1. 파일 복사 -----------------------------------------------------------
# site\ 와 docs\ 는 웹/문서 전용이라 설치하지 않는다. .git 도 복사하지 않는다
# (아래는 지정 목록만 복사하므로 자연히 제외된다).
$AppFiles = @('Wallpaper-GUI.ps1', 'Set-Wallpaper.ps1', 'Wallpaper.bat', 'Set-Wallpaper.bat',
              'Install.ps1', 'Update.ps1', 'VERSION', 'LICENSE', 'README.md')
$AppDirs  = @('lib', 'assets', 'images')

# 설치본 안에서 다시 실행한 경우: 자기 자신 위로 복사하지 않고 바로가기/작업만 갱신한다.
$sameDir = [System.IO.Path]::GetFullPath($SourceDir).TrimEnd('\') -ieq
           [System.IO.Path]::GetFullPath($InstallDir).TrimEnd('\')

if ($sameDir) {
    Write-Host "이미 설치 폴더 안입니다 — 복사는 건너뜁니다 / Already in the install dir, skipping copy."
} else {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    foreach ($f in $AppFiles) {
        $src = Join-Path $SourceDir $f
        if (Test-Path -LiteralPath $src) {
            Copy-Item -LiteralPath $src -Destination $InstallDir -Force
        }
    }
    foreach ($d in $AppDirs) {
        $src = Join-Path $SourceDir $d
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dst = Join-Path $InstallDir $d
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        # 덮어쓰기 병합 — 설치 폴더 images\ 에 사용자가 넣어둔 이미지는 지우지 않는다
        if (@(Get-ChildItem -LiteralPath $src -Force).Count -gt 0) {
            Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
        }
    }
    Write-Host "복사 완료 / Copied to:  $InstallDir"
}

# --- 2. 시작 메뉴 바로가기 --------------------------------------------------
# Wallpaper.bat 을 거치면 콘솔 창이 깜빡인다. pwsh 를 숨김 창으로 직접 겨눈다.
# -STA: WinForms 와 OpenFileDialog 는 단일 스레드 아파트가 필요하다.
$startMenu = [Environment]::GetFolderPath('Programs')   # 사용자 시작 메뉴\Programs
$lnkPath   = Join-Path $startMenu 'Wallpaper-GUI.lnk'

$wsh = New-Object -ComObject WScript.Shell
try {
    $lnk = $wsh.CreateShortcut($lnkPath)
    $lnk.TargetPath       = $pwshPath
    $lnk.Arguments        = '-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f
                            (Join-Path $InstallDir 'Wallpaper-GUI.ps1')
    $lnk.WorkingDirectory = $InstallDir
    $lnk.IconLocation     = (Join-Path $InstallDir 'assets\icon.ico') + ',0'
    $lnk.WindowStyle      = 7      # 최소화로 시작 — 혹시 콘솔이 떠도 눈에 안 띄게
    $lnk.Description      = 'Per-Monitor Wallpaper'
    $lnk.Save()
} finally {
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wsh)
}
Write-Host "바로가기 / Shortcut:  $lnkPath"

# --- 3. 자동 업데이트 예약 작업 ---------------------------------------------
# 사용자 수준 작업이라 관리자 권한이 필요 없다. -Force 로 있으면 갱신(멱등).
# Update.ps1 은 실패해도 조용히 exit 0 하므로 작업 이력이 오류로 물들지 않는다.
$action   = New-ScheduledTaskAction -Execute $pwshPath -Argument (
                '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f
                (Join-Path $InstallDir 'Update.ps1'))
$triggers = @(
    New-ScheduledTaskTrigger -Daily -At '12:30'
    New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable `
                -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -Hidden

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
    -Settings $settings -Force | Out-Null
Write-Host "예약 작업 / Scheduled task:  $TaskName  (매일 12:30 + 로그온 / daily 12:30 + logon)"

Write-Host ''
Write-Host '설치가 끝났습니다. 시작 메뉴에서 Wallpaper-GUI 를 실행하세요.'
Write-Host 'Done. Launch "Wallpaper-GUI" from the Start Menu.'
Write-Host ''
