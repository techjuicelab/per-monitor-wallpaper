<#
    공용 모듈 — IDesktopWallpaper COM 래퍼 + 모니터 목록.
    Shared module — IDesktopWallpaper COM wrapper and display enumeration.
    직접 실행하는 파일이 아닙니다. / Not meant to be run directly.
#>

if (-not (Get-Command T -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Lang.ps1')
}

# Windows 가 이해하는 맞춤 값 / Values Windows itself understands
$script:PositionMap = [ordered]@{
    Fill    = 4
    Fit     = 3
    Stretch = 2
    Center  = 0
    Tile    = 1
    Span    = 5
}

# UI 에 보여줄 순서. 'Auto' 는 Windows 값이 아니라 이 도구가 직접 이미지를 합성하는 모드다.
# 모니터 해상도에 정확히 맞는 이미지를 만들어 넣으므로 Windows 쪽에는 '채우기'로 지정한다.
$script:FitModes = @('Auto', 'Fill', 'Fit', 'Stretch', 'Center', 'Tile', 'Span')

function Get-WindowsPosition {
    param([string]$Mode)
    if ($Mode -eq 'Auto') { return $script:PositionMap['Fill'] }
    if ($script:PositionMap.Contains($Mode)) { return $script:PositionMap[$Mode] }
    return $script:PositionMap['Fill']
}

$code = @'
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
public struct DwRect { public int Left, Top, Right, Bottom; }

[ComImport, Guid("B92B56A9-8B55-4E14-9A89-0199BBB6F93B"),
 InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IDesktopWallpaper
{
    void SetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID,
                      [MarshalAs(UnmanagedType.LPWStr)] string wallpaper);
    [return: MarshalAs(UnmanagedType.LPWStr)]
    string GetWallpaper([MarshalAs(UnmanagedType.LPWStr)] string monitorID);
    [return: MarshalAs(UnmanagedType.LPWStr)]
    string GetMonitorDevicePathAt(uint monitorIndex);
    uint GetMonitorDevicePathCount();
    DwRect GetMonitorRECT([MarshalAs(UnmanagedType.LPWStr)] string monitorID);
    void SetBackgroundColor(uint color);
    uint GetBackgroundColor();
    void SetPosition(int position);
    int GetPosition();
}

// IDesktopWallpaper has no IDispatch, so PowerShell can neither cast __ComObject to
// the ComImport interface nor call its methods. Everything goes through this compiled
// static shim instead - the QueryInterface and every call happen in C#.
public static class Wallpaper
{
    private static IDesktopWallpaper _dw;
    private static IDesktopWallpaper DW
    {
        get
        {
            if (_dw == null)
            {
                Type t = Type.GetTypeFromCLSID(new Guid("C2CF3110-460E-4FC1-B9D0-8A1C0C9CC4BD"));
                _dw = (IDesktopWallpaper)Activator.CreateInstance(t);
            }
            return _dw;
        }
    }

    public static int    Count()                     { return (int)DW.GetMonitorDevicePathCount(); }
    public static string IdAt(int i)                 { return DW.GetMonitorDevicePathAt((uint)i); }
    public static int[]  RectOf(string id)           { DwRect r = DW.GetMonitorRECT(id);
                                                       return new int[] { r.Left, r.Top, r.Right, r.Bottom }; }
    public static string Get(string id)              { return DW.GetWallpaper(id); }
    public static void   Set(string id, string path) { DW.SetWallpaper(id, path); }
    public static int    GetPos()                    { return DW.GetPosition(); }
    public static void   SetPos(int p)               { DW.SetPosition(p); }
}
'@

if (-not ('Wallpaper' -as [type])) { Add-Type -TypeDefinition $code }


function Get-MonitorLabelSet {
    <#
        모니터 개수와 배치에 맞는 라벨 목록을 만든다.
        Build stable labels for the given count and arrangement.

        가로 한 줄   : LEFT / CENTER / RIGHT
        세로 한 줄   : TOP / MIDDLE / BOTTOM
        그 외, 4대+  : MON1 .. MONn   (읽는 순서)
    #>
    param([int]$Count, [string]$Arrangement)

    if ($Count -le 0) { return @() }
    if ($Count -eq 1) { return @('ONLY') }

    if ($Arrangement -eq 'h' -and $Count -eq 2) { return @('LEFT', 'RIGHT') }
    if ($Arrangement -eq 'h' -and $Count -eq 3) { return @('LEFT', 'CENTER', 'RIGHT') }
    if ($Arrangement -eq 'v' -and $Count -eq 2) { return @('TOP', 'BOTTOM') }
    if ($Arrangement -eq 'v' -and $Count -eq 3) { return @('TOP', 'MIDDLE', 'BOTTOM') }

    return @(1..$Count | ForEach-Object { "MON$_" })
}

function Get-MonitorDisplayName {
    <# 라벨을 사람이 읽는 이름으로. / Label -> localized human name. #>
    param([string]$Label)
    switch ($Label) {
        'ONLY'   { return (T 'pos.only') }
        'LEFT'   { return (T 'pos.left') }
        'CENTER' { return (T 'pos.center') }
        'RIGHT'  { return (T 'pos.right') }
        'TOP'    { return (T 'pos.top') }
        'MIDDLE' { return (T 'pos.middle') }
        'BOTTOM' { return (T 'pos.bottom') }
        default  {
            if ($Label -match '^MON(\d+)$') { return (T 'pos.nth' $Matches[1]) }
            return $Label
        }
    }
}

function Get-WallpaperMonitor {
<#
    연결된 모니터를 화면에 놓인 순서대로 반환한다.
    Return attached displays in physical layout order.

    왜 좌표로 정렬하는가:
      Windows 의 디스플레이 번호(1, 2, 3)는 물리적 배치 순서가 아니다. 가운데 모니터가
      1번이고 왼쪽이 3번인 경우도 흔하다. 그래서 항상 가상 데스크톱 좌표로 정렬한다 —
      모니터를 다른 포트에 옮겨 꽂아도 이름이 계속 맞는다.

    배치 판정:
      모든 모니터가 세로 구간을 공유하면 가로 한 줄, 가로 구간을 공유하면 세로 한 줄,
      둘 다 아니면 격자로 본다. 겹침으로 판정하므로 높이가 다른 모니터를 나란히 둬서
      위아래가 조금 어긋나도 여전히 '가로 한 줄'로 잡힌다.
      2~3대 한 줄이면 왼쪽/가운데/오른쪽(또는 위/중간/아래), 그 외에는 MON1..MONn.
      격자는 읽는 순서(위 줄부터 왼쪽에서 오른쪽)로 번호를 매긴다.

    주의:
      GetMonitorRECT 는 실제 물리 픽셀을 돌려준다. System.Windows.Forms.Screen 은
      per-monitor DPI 를 인식하지 못해 4K@150% 를 2560x1440 으로 잘못 보고한다.
      또 COM 슬롯 수 != 연결된 모니터 수다 — 분리된 슬롯은 빈 id 를 주거나 예외를 던진다.
#>
    $mons = @()
    for ($i = 0; $i -lt [Wallpaper]::Count(); $i++) {
        $id = [Wallpaper]::IdAt($i)
        if ([string]::IsNullOrEmpty($id)) { continue }      # 분리된 슬롯 / detached slot
        try { $r = [Wallpaper]::RectOf($id) } catch { continue }
        $mons += [pscustomobject]@{
            Id      = $id
            Left    = $r[0]
            Top     = $r[1]
            Width   = $r[2] - $r[0]
            Height  = $r[3] - $r[1]
            Index   = 0
            Label   = $null
            Display = $null
            Name    = $null
            Current = $null
        }
    }
    if ($mons.Count -eq 0) { return @() }

    # 배치 판정: 좌표가 정확히 같은지가 아니라 '범위가 겹치는지'로 본다.
    # 좌표 비교로 하면 높이가 다른 모니터를 나란히 둔 흔한 경우(위아래로 조금 어긋남)가
    # 격자로 잘못 잡혀 왼쪽/오른쪽 이름을 잃는다.
    $maxTop    = ($mons | Measure-Object Top  -Maximum).Maximum
    $minBottom = ($mons | ForEach-Object { $_.Top  + $_.Height } | Measure-Object -Minimum).Minimum
    $maxLeft   = ($mons | Measure-Object Left -Maximum).Maximum
    $minRight  = ($mons | ForEach-Object { $_.Left + $_.Width  } | Measure-Object -Minimum).Minimum

    $rowLike = ($maxTop  -lt $minBottom)   # 모두 세로 구간이 겹친다 = 가로 한 줄
    $colLike = ($maxLeft -lt $minRight)    # 모두 가로 구간이 겹친다 = 세로 한 줄

    $spanX = (($mons | Measure-Object Left -Maximum).Maximum) - (($mons | Measure-Object Left -Minimum).Minimum)
    $spanY = (($mons | Measure-Object Top  -Maximum).Maximum) - (($mons | Measure-Object Top  -Minimum).Minimum)

    $arrangement =
        if ($mons.Count -eq 1)                                        { 'h' }
        elseif ($rowLike -and (-not $colLike -or $spanX -ge $spanY))   { 'h' }
        elseif ($colLike)                                             { 'v' }
        else                                                          { 'grid' }

    # 가로 줄은 왼쪽부터, 세로 줄은 위부터, 격자는 읽는 순서(위 줄 → 아래 줄)
    $mons = if ($arrangement -eq 'h') { @($mons | Sort-Object Left, Top) }
            else                      { @($mons | Sort-Object Top, Left) }

    $labels = Get-MonitorLabelSet -Count $mons.Count -Arrangement $arrangement

    # COM 의 모니터 ID 를 WMI 의 모니터 이름과 연결한다 / map COM id -> friendly name
    #   COM:  \\?\DISPLAY#XXX0000#5&abcdef&0&UID4353#{guid}
    #   WMI:  DISPLAY\XXX0000\5&abcdef&0&UID4353_0
    $names = @{}
    try {
        foreach ($w in Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop) {
            $friendly = -join ($w.UserFriendlyName | Where-Object { $_ -gt 0 } | ForEach-Object { [char]$_ })
            if ($friendly) { $names[($w.InstanceName -replace '_\d+$', '')] = $friendly }
        }
    } catch { }

    for ($i = 0; $i -lt $mons.Count; $i++) {
        $mons[$i].Index   = $i + 1
        $mons[$i].Label   = $labels[$i]
        $mons[$i].Display = Get-MonitorDisplayName $labels[$i]
        try { $mons[$i].Current = [Wallpaper]::Get($mons[$i].Id) } catch { }

        $key = ($mons[$i].Id -replace '^\\\\\?\\', '' -replace '#\{.*$', '') -replace '#', '\'
        $mons[$i].Name = if ($names.ContainsKey($key)) { $names[$key] } else { (T 'mon.unknown') }
    }
    return $mons
}


function Set-WallpaperFor {
    <#
        한 모니터에 배경화면을 지정한다. / Set one display's wallpaper.

        Mode 가 'Auto' 이고 이미지가 그 모니터에 딱 맞지 않으면(비율이 다르거나 해상도가 작으면)
        Resolve-WallpaperPath 가 모니터 해상도에 정확히 맞는 이미지를 합성해 그 경로를 돌려준다.
        ImageCompose.ps1 을 불러오지 않았거나 합성에 실패하면 조용히 원본을 그대로 쓴다.
    #>
    param(
        [Parameter(Mandatory)][string]$MonitorId,
        [Parameter(Mandatory)][string]$Path,
        [string]$Mode  = 'Fill',
        [int]$MonitorW = 0,
        [int]$MonitorH = 0
    )

    $full = (Resolve-Path -LiteralPath $Path).Path

    if ($Mode -eq 'Auto' -and $MonitorW -gt 0 -and $MonitorH -gt 0 -and
        (Get-Command Resolve-WallpaperPath -ErrorAction SilentlyContinue)) {
        try {
            $resolved = Resolve-WallpaperPath -Path $full -W $MonitorW -H $MonitorH -Mode 'Auto'
            if ($resolved) { $full = $resolved }
        } catch { }      # 합성 실패가 적용 실패가 되면 안 된다 / never let compose failure block apply
    }

    [Wallpaper]::Set($MonitorId, $full)
    return ([Wallpaper]::Get($MonitorId) -eq $full)   # 실제로 적용됐는지 확인 / verify
}
