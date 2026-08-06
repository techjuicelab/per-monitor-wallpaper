<#
    Per-Monitor Wallpaper — 무인 자동 업데이트
    Per-Monitor Wallpaper — unattended updater

    Install.ps1 이 등록한 예약 작업(매일 + 로그온)이 숨김 창으로 실행합니다.
    직접 실행해도 됩니다:  pwsh -ExecutionPolicy Bypass -File .\Update.ps1

    동작:
      설치 폴더의 VERSION 과 main 브랜치의 VERSION 을 비교해서, 다르면 main 의 zip 을
      받아 설치 폴더 위에 덮어씁니다. 어떤 실패든(오프라인, 404, 부분 다운로드,
      실행 중인 GUI 가 파일을 잡고 있음) update.log 에 한 줄 남기고 조용히 exit 0 —
      다음 주기에 다시 시도하면 됩니다.

    안전 장치:
      · git clone(.git 존재)에서는 아무것도 하지 않는다 — clone 은 git pull 이 관리
      · 교체는 삭제 없는 '덮어쓰기 병합' — 설치 폴더 images\ 의 사용자 이미지는 남는다
      · VERSION 은 맨 마지막에 쓴다 — 중간 실패 시 다음 주기에 처음부터 재시도
      · 사용자 설정·캐시는 %LOCALAPPDATA%\MyWallpaper\ (설치 폴더 밖)라 건드리지 않는다
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # 숨김 창 + 다운로드 속도(진행바 비용 제거)

# 신뢰 경로: HTTPS + github.com (techjuicelab) 만 사용한다.
$VersionUrl = 'https://raw.githubusercontent.com/techjuicelab/per-monitor-wallpaper/main/VERSION'
$ZipUrl     = 'https://codeload.github.com/techjuicelab/per-monitor-wallpaper/zip/refs/heads/main'
$ZipRoot    = 'per-monitor-wallpaper-main'    # zip 안의 최상위 폴더 이름

$InstallDir  = $PSScriptRoot
$LogPath     = Join-Path $InstallDir 'update.log'
$MaxLogLines = 200

function Write-UpdateLog {
    # 로그는 update.log 하나. 마지막 200줄만 유지한다. 로그 실패로 죽지는 않는다.
    param([string]$Message)
    try {
        $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
        Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8
        $lines = @(Get-Content -LiteralPath $LogPath -Encoding utf8)
        if ($lines.Count -gt $MaxLogLines) {
            [System.IO.File]::WriteAllLines($LogPath,
                [string[]]($lines | Select-Object -Last $MaxLogLines),
                [System.Text.UTF8Encoding]::new($false))
        }
    } catch { }
}

# --- 안전 장치: git clone 은 건드리지 않는다 --------------------------------
if (Test-Path -LiteralPath (Join-Path $InstallDir '.git')) {
    Write-UpdateLog 'skip: this is a git clone - update with git pull'
    exit 0
}

# --- 버전 비교 --------------------------------------------------------------
$localVersion = '0'
$verPath = Join-Path $InstallDir 'VERSION'
if (Test-Path -LiteralPath $verPath) {
    try { $localVersion = (Get-Content -LiteralPath $verPath -Raw -Encoding utf8).Trim() } catch { }
}

try {
    $remoteVersion = ([string](Invoke-RestMethod -Uri $VersionUrl -TimeoutSec 30)).Trim()
} catch {
    Write-UpdateLog "check failed: $($_.Exception.Message)"
    exit 0
}

# 버전 문자열답지 않으면(프록시 오류 페이지, 캡티브 포털 등) 건드리지 않는다
if ($remoteVersion -notmatch '^\d+(\.\d+)*([\-+][0-9A-Za-z\.\-]+)?$') {
    Write-UpdateLog 'check failed: VERSION content does not look like a version'
    exit 0
}

if ($remoteVersion -eq $localVersion) {
    Write-UpdateLog "up to date (v$localVersion)"
    exit 0
}

Write-UpdateLog "update available: v$localVersion -> v$remoteVersion"

# --- 다운로드 → 풀기 → 교체 -------------------------------------------------
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) `
                 ('PerMonitorWallpaper-update-' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $zipPath = Join-Path $tmp 'repo.zip'

    try {
        Invoke-WebRequest -Uri $ZipUrl -OutFile $zipPath -TimeoutSec 120
    } catch {
        Write-UpdateLog "download failed: $($_.Exception.Message)"
        exit 0
    }

    # 부분 다운로드·손상 zip 이면 여기서 던진다 → 조용히 포기, 다음 주기에 재시도
    try {
        Expand-Archive -LiteralPath $zipPath -DestinationPath $tmp -Force
    } catch {
        Write-UpdateLog 'extract failed: corrupt or partial download'
        exit 0
    }

    $src = Join-Path $tmp $ZipRoot
    if (-not (Test-Path -LiteralPath (Join-Path $src 'VERSION')) -or
        -not (Test-Path -LiteralPath (Join-Path $src 'Wallpaper-GUI.ps1'))) {
        Write-UpdateLog 'extract failed: unexpected archive layout'
        exit 0
    }

    # 교체는 '덮어쓰기 병합' — 설치 폴더를 지우지 않으므로 사용자가 설치 폴더의
    # images\ 를 이미지 폴더로 쓰고 있어도 파일이 사라지지 않는다.
    # VERSION 은 맨 마지막: 도중에 실패하면 버전이 그대로라 다음 주기에 전부 재시도된다.
    $AppFiles = @('Wallpaper-GUI.ps1', 'Set-Wallpaper.ps1', 'Wallpaper.bat', 'Set-Wallpaper.bat',
                  'Install.ps1', 'Update.ps1', 'LICENSE', 'README.md')
    $AppDirs  = @('lib', 'assets', 'images')

    try {
        foreach ($d in $AppDirs) {
            $s = Join-Path $src $d
            if (-not (Test-Path -LiteralPath $s)) { continue }
            $dst = Join-Path $InstallDir $d
            New-Item -ItemType Directory -Force -Path $dst | Out-Null
            if (@(Get-ChildItem -LiteralPath $s -Force).Count -gt 0) {
                Copy-Item -Path (Join-Path $s '*') -Destination $dst -Recurse -Force
            }
        }
        foreach ($f in $AppFiles) {
            $s = Join-Path $src $f
            if (Test-Path -LiteralPath $s) {
                Copy-Item -LiteralPath $s -Destination $InstallDir -Force
            }
        }
        Copy-Item -LiteralPath (Join-Path $src 'VERSION') -Destination $InstallDir -Force
    } catch {
        # 실행 중인 GUI 가 파일을 잡고 있는 경우 등 — 조용히 물러나고 다음 주기에 재시도
        Write-UpdateLog "replace failed (will retry next run): $($_.Exception.Message)"
        exit 0
    }

    Write-UpdateLog "updated to v$remoteVersion"
} finally {
    if (Test-Path -LiteralPath $tmp) {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
exit 0
