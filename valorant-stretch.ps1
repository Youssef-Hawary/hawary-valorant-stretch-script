<#
.SYNOPSIS
    Valorant stretched resolution (you pick it, default 1280x960) for Windows - no black bars.

.DESCRIPTION
    What it does:
      1. Closes Valorant / Riot Client (they overwrite the config if left open).
      2. Patches every Valorant GameUserSettings.ini to 1280x960, Fullscreen,
         letterbox OFF, then marks the files read-only so Riot can't reset them.
      3. Sets Windows/GPU display scaling to "Stretch" (full screen) so the
         4:3 image fills a 16:9 monitor instead of showing black bars.
      4. (-Launch) Switches the desktop to 1280x960 at the highest refresh rate
         your monitor supports for it, launches Valorant, and puts your normal
         resolution back automatically when the game closes.

    Everything is backed up first. Run with -Revert to undo all of it.

.EXAMPLE
    .\valorant-stretch.ps1            # menu
    .\valorant-stretch.ps1 -Apply     # patch config + scaling
    .\valorant-stretch.ps1 -Launch    # patch + launch Valorant stretched
    .\valorant-stretch.ps1 -Revert    # undo everything
    .\valorant-stretch.ps1 -Apply -Width 1440 -Height 1080
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$Launch,
    [switch]$Revert,
    [switch]$SetupFill,           # one-time: set Aspect Ratio = Fill inside the game
    [switch]$KeepMonitorDriver,   # don't disable the monitor in Device Manager
    [int]$Width = 1280,
    [int]$Height = 960
)

$ErrorActionPreference = 'Stop'
$StateDir  = Join-Path $env:LOCALAPPDATA 'ValorantStretch'
$StateFile = Join-Path $StateDir 'scaling-backup.json'
$ValConfig = Join-Path $env:LOCALAPPDATA 'VALORANT\Saved\Config'
$GfxConfig = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers\Configuration'
$Section   = '[/Script/ShooterGame.ShooterGameUserSettings]'

function Write-Step($msg) { Write-Host "[*] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "[+] $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "[!] $msg" -ForegroundColor Yellow }
function Write-Bad($msg)  { Write-Host "[x] $msg" -ForegroundColor Red }

# ---------------------------------------------------------------- admin ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if (-not $PSCommandPath) {
        Write-Bad 'Run this from an Administrator PowerShell (right-click > Run as administrator).'
        return
    }
    Write-Step 'Asking for administrator rights...'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) { if ($v) { $argList += "-$k" } }
        else { $argList += "-$k"; $argList += "$v" }
    }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    return
}

# ------------------------------------------------------- display (Win32) ----
if (-not ('VSDisplay4' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class VSDisplay4 {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra;
        public int dmFields;
        public int dmPositionX; public int dmPositionY; public int dmDisplayOrientation; public int dmDisplayFixedOutput;
        public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight;
        public int dmDisplayFlags; public int dmDisplayFrequency;
        public int dmICMMethod; public int dmICMIntent; public int dmMediaType; public int dmDitherType;
        public int dmReserved1; public int dmReserved2; public int dmPanningWidth; public int dmPanningHeight;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFOEX {
        public int cbSize; public RECT rcMonitor; public RECT rcWork; public int dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string dev, uint i, ref DISPLAY_DEVICE dd, uint f);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE dm, IntPtr hwnd, int flags, IntPtr lp);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ChangeDisplaySettingsEx(string dev, IntPtr dm, IntPtr hwnd, int flags, IntPtr lp);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFOEX mi);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);

    [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] public struct PATH_SOURCE { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }
    [StructLayout(LayoutKind.Sequential)] public struct PATH_TARGET {
        public LUID adapterId; public uint id; public uint modeInfoIdx; public uint outputTechnology; public uint rotation;
        public uint scaling; public uint refreshNum; public uint refreshDen; public uint scanLineOrdering; public int targetAvailable; public uint statusFlags;
    }
    [StructLayout(LayoutKind.Sequential)] public struct PATH_INFO { public PATH_SOURCE sourceInfo; public PATH_TARGET targetInfo; public uint flags; }
    [StructLayout(LayoutKind.Sequential)] public struct MODE_INFO { public uint infoType; public uint id; public LUID adapterId; public ulong u0, u1, u2, u3, u4, u5; }
    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint np, out uint nm);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint np, [Out] PATH_INFO[] p, ref uint nm, [Out] MODE_INFO[] m, IntPtr topo);
    [DllImport("user32.dll")] static extern int SetDisplayConfig(uint np, [In] PATH_INFO[] p, uint nm, [In] MODE_INFO[] m, uint flags);

    // Tell Windows/the GPU to scale every active screen as STRETCHED (fill, no bars) right now.
    // Not saved, so your normal setup comes back when the resolution is restored.
    // Returns 0 = already stretched or applied, otherwise a Win32 error code.
    public static int ForceStretchScaling() {
        uint np, nm;
        int r = GetDisplayConfigBufferSizes(2, out np, out nm); // QDC_ONLY_ACTIVE_PATHS
        if (r != 0) return r;
        PATH_INFO[] p = new PATH_INFO[np]; MODE_INFO[] m = new MODE_INFO[nm];
        r = QueryDisplayConfig(2, ref np, p, ref nm, m, IntPtr.Zero);
        if (r != 0) return r;
        bool need = false;
        for (int i = 0; i < np; i++) if (p[i].targetInfo.scaling != 3) { p[i].targetInfo.scaling = 3; need = true; }
        if (!need) return 0;
        return SetDisplayConfig(np, p, nm, m, 0x80 | 0x20 | 0x400); // APPLY | USE_SUPPLIED | ALLOW_CHANGES
    }

    static DEVMODE New() { DEVMODE d = new DEVMODE(); d.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE)); return d; }

    // Real pixel coordinates even with Windows display scaling (125%, 150%...).
    public static void DpiAware() { try { SetProcessDPIAware(); } catch { } }

    // Every monitor that is part of the desktop, e.g. \\.\DISPLAY1. Primary first.
    public static string[] Displays() {
        List<string> list = new List<string>();
        DISPLAY_DEVICE dd = new DISPLAY_DEVICE(); dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
        for (uint i = 0; EnumDisplayDevices(null, i, ref dd, 0); i++) {
            if ((dd.StateFlags & 1) == 0) continue;                 // ATTACHED_TO_DESKTOP
            if ((dd.StateFlags & 4) != 0) list.Insert(0, dd.DeviceName); // PRIMARY_DEVICE
            else list.Add(dd.DeviceName);
            dd.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
        }
        return list.ToArray();
    }

    // x, y, width, height, Hz of a monitor right now.
    public static int[] Current(string dev) {
        DEVMODE d = New();
        EnumDisplaySettings(dev, -1, ref d);
        return new int[] { d.dmPositionX, d.dmPositionY, d.dmPelsWidth, d.dmPelsHeight, d.dmDisplayFrequency };
    }

    // Highest refresh rate this monitor offers at WxH (0 = mode doesn't exist).
    public static int MaxHz(string dev, int w, int h) {
        int best = 0; DEVMODE d = New();
        for (int i = 0; EnumDisplaySettings(dev, i, ref d); i++)
            if (d.dmPelsWidth == w && d.dmPelsHeight == h && d.dmBitsPerPel == 32 && d.dmDisplayFrequency > best)
                best = d.dmDisplayFrequency;
        return best;
    }

    // Temporary mode change (not saved) with DMDFO_STRETCH so the image fills the panel.
    public static int SetStretched(string dev, int w, int h, int hz) {
        DEVMODE d = New();
        EnumDisplaySettings(dev, -1, ref d);
        d.dmPelsWidth = w; d.dmPelsHeight = h; d.dmBitsPerPel = 32;
        d.dmDisplayFixedOutput = 1;
        d.dmFields = 0x80000 | 0x100000 | 0x40000 | 0x20000000;
        if (hz > 0) { d.dmDisplayFrequency = hz; d.dmFields |= 0x400000; }
        return ChangeDisplaySettingsEx(dev, ref d, IntPtr.Zero, 0, IntPtr.Zero);
    }

    // Put a monitor back to the resolution saved in Windows settings.
    public static int Restore(string dev) { return ChangeDisplaySettingsEx(dev, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero); }

    public static IntPtr GameWindow() { return FindWindow("VALORANTUnrealWindow", null); }

    // Which monitor a window is (mostly) on.
    public static string WindowDisplay(IntPtr h) {
        if (h == IntPtr.Zero) return null;
        IntPtr m = MonitorFromWindow(h, 2); // NEAREST
        MONITORINFOEX mi = new MONITORINFOEX(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFOEX));
        return GetMonitorInfo(m, ref mi) ? mi.szDevice : null;
    }

    public static bool WindowAt(IntPtr h, int x, int y, int w, int hh) {
        RECT r; if (h == IntPtr.Zero || !GetWindowRect(h, out r)) return false;
        return r.L == x && r.T == y && r.R == x + w && r.B == y + hh;
    }

    // Make the window borderless and exactly cover x,y,w,h.
    // Returns -1 = no usable window, 0 = already correct, 1 = fixed it.
    public static int FitWindow(IntPtr h, int x, int y, int w, int hh) {
        if (h == IntPtr.Zero || !IsWindowVisible(h) || IsIconic(h)) return -1;
        int s  = GetWindowLong(h, -16);
        int ns = s & ~(0x00C00000 | 0x00040000 | 0x00080000 | 0x00020000 | 0x00010000);
        int ex  = GetWindowLong(h, -20);
        int nex = ex & ~(0x1 | 0x100 | 0x200 | 0x20000);
        if (ns == s && nex == ex && WindowAt(h, x, y, w, hh)) return 0;
        if (ns != s) SetWindowLong(h, -16, ns);
        if (nex != ex) SetWindowLong(h, -20, nex);
        SetWindowPos(h, IntPtr.Zero, x, y, w, hh, 0x0020 | 0x0040 | 0x0200);
        return 1;
    }
}
'@
}
[VSDisplay4]::DpiAware()

# -------------------------------------------------------------- helpers ----
function Stop-Riot {
    $names = 'VALORANT-Win64-Shipping','VALORANT','RiotClientServices','RiotClientUx','RiotClientUxRender','Riot Client'
    $procs = Get-Process -Name $names -ErrorAction SilentlyContinue
    if ($procs) {
        Write-Step 'Closing Valorant / Riot Client so they do not overwrite the config...'
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
}

function Get-ValorantInis {
    if (-not (Test-Path $ValConfig)) { return @() }
    @(Get-ChildItem -Path $ValConfig -Recurse -Filter 'GameUserSettings.ini' -File -ErrorAction SilentlyContinue)
}

function Read-Ini($path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $enc = New-Object Text.UnicodeEncoding($false, $true) }
    elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $enc = New-Object Text.UTF8Encoding($true) }
    else { $enc = New-Object Text.UTF8Encoding($false) }
    $text = [IO.File]::ReadAllText($path, $enc)
    @{ Encoding = $enc; Lines = [Collections.Generic.List[string]]($text -split "`r?`n") }
}

function Set-IniStretch($file) {
    $path = $file.FullName
    if ($file.IsReadOnly) { $file.IsReadOnly = $false }

    $bak = "$path.stretch-backup"
    if (-not (Test-Path $bak)) { Copy-Item $path $bak -Force }

    $ini = Read-Ini $path
    $lines = $ini.Lines
    $values = [ordered]@{
        'ResolutionSizeX'                      = $Width
        'ResolutionSizeY'                      = $Height
        'LastUserConfirmedResolutionSizeX'     = $Width
        'LastUserConfirmedResolutionSizeY'     = $Height
        'DesiredScreenWidth'                   = $Width
        'DesiredScreenHeight'                  = $Height
        'LastUserConfirmedDesiredScreenWidth'  = $Width
        'LastUserConfirmedDesiredScreenHeight' = $Height
        # 1 = Windowed Fullscreen. Valorant's exclusive Fullscreen snaps back to native res;
        # Windowed Fullscreen follows the desktop resolution and keeps Fill selectable.
        'FullscreenMode'                       = 1
        'LastConfirmedFullscreenMode'          = 1
        'PreferredFullscreenMode'              = 1
        # Aspect Ratio Method = Fill (False = Fill, True = Letterbox) - the keys stretch tools like VALORez set.
        'bShouldLetterbox'                     = 'False'
        'bLastConfirmedShouldLetterbox'        = 'False'
        'bUseDesiredScreenHeight'              = 'False'
        'LastRecommendedScreenWidth'           = '-1.000000'
        'LastRecommendedScreenHeight'          = '-1.000000'
        'WindowPosX'                           = 0
        'WindowPosY'                           = 0
    }

    # Drop any existing copies of these keys, wherever they are.
    $keyPattern = '^\s*(' + (($values.Keys | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\s*='
    for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -match $keyPattern) { $lines.RemoveAt($i) } }

    $newLines = @($values.Keys | ForEach-Object { "$_=$($values[$_])" })
    $idx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -eq $Section) { $idx = $i; break } }
    if ($idx -ge 0) {
        $lines.InsertRange($idx + 1, [string[]]$newLines)
    } else {
        while ($lines.Count -gt 0 -and $lines[$lines.Count - 1].Trim() -eq '') { $lines.RemoveAt($lines.Count - 1) }
        if ($lines.Count -gt 0) { $lines.Add('') }
        $lines.Add($Section)
        $lines.AddRange([string[]]$newLines)
        $lines.Add('')
    }

    [IO.File]::WriteAllText($path, ($lines -join "`r`n"), $ini.Encoding)
    (Get-Item $path).IsReadOnly = $true
}

function Get-ScalingKeys {
    if (-not (Test-Path $GfxConfig)) { return @() }
    @(Get-ChildItem -Path $GfxConfig -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.GetValueNames() -contains 'Scaling' })
}

function Set-GpuStretch {
    $keys = Get-ScalingKeys
    if ($keys.Count -eq 0) { Write-Warn2 'No display scaling entries found in the registry (set it in your GPU panel - see README).'; return }

    if (-not (Test-Path $StateFile)) {
        New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
        $backup = @{}
        foreach ($k in $keys) { $backup[$k.Name] = [int]$k.GetValue('Scaling') }
        $backup | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
    }
    foreach ($k in $keys) {
        Set-ItemProperty -Path $k.PSPath -Name 'Scaling' -Value 3 -Type DWord   # 3 = Stretched (full screen)
    }
    Write-Ok "Display scaling set to Full-screen stretch on $($keys.Count) display config(s)."
}

# --------------------------------------------------------------- actions ----
# ------------------------------------------ fullscreen optimizations off ----
# When the game window has focus, Windows' "fullscreen optimizations" /
# "optimizations for windowed games" take over presenting the frame and the
# stretch is lost (black bars come back until you alt-tab). Turning both off
# for VALORANT-Win64-Shipping.exe is the standard fix (same as ticking
# "Disable fullscreen optimizations" in the exe's Compatibility tab).
$CompatStateFile = Join-Path $StateDir 'compat-exes.txt'
$LayersKey  = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
$GpuPrefKey = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'

function Find-ValorantExe {
    $tail = 'ShooterGame\Binaries\Win64\VALORANT-Win64-Shipping.exe'
    $yaml = Join-Path $env:ProgramData 'Riot Games\Metadata\valorant.live\valorant.live.product_settings.yaml'
    if (Test-Path $yaml) {
        $line = Select-String -Path $yaml -Pattern 'product_install_full_path:\s*"?([^"]+)"?' | Select-Object -First 1
        if ($line) {
            $p = Join-Path ($line.Matches[0].Groups[1].Value -replace '/', '\') $tail
            if (Test-Path $p) { return $p }
        }
    }
    if (Test-Path $CompatStateFile) {
        foreach ($p in Get-Content $CompatStateFile) { if ($p -and (Test-Path $p)) { return $p } }
    }
    foreach ($root in 'C:\Riot Games\VALORANT\live', 'D:\Riot Games\VALORANT\live', "${env:ProgramFiles}\Riot Games\VALORANT\live") {
        $p = Join-Path $root $tail
        if (Test-Path $p) { return $p }
    }
    return $null
}

function Get-RegString($key, $name) {
    try { return [string](Get-ItemProperty -Path $key -Name $name -ErrorAction Stop).$name } catch { return '' }
}

# Returns $true if anything had to be changed (the game must be restarted to pick it up).
function Set-GameCompatFlags($exe) {
    if (-not $exe) { return $false }
    $changed = $false
    foreach ($k in $LayersKey, $GpuPrefKey) { if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null } }

    $layers = Get-RegString $LayersKey $exe
    if ($layers -notmatch 'DISABLEDXMAXIMIZEDWINDOWEDMODE') {
        $flags = @(($layers -replace '^~\s*', '') -split '\s+' | Where-Object { $_ }) + 'DISABLEDXMAXIMIZEDWINDOWEDMODE'
        Set-ItemProperty -Path $LayersKey -Name $exe -Value ('~ ' + ($flags -join ' ')) -Type String
        $changed = $true
    }
    $pref = Get-RegString $GpuPrefKey $exe
    if ($pref -notmatch 'SwapEffectUpgradeEnable=0;') {
        $pref = ($pref -replace 'SwapEffectUpgradeEnable=\d;', '') + 'SwapEffectUpgradeEnable=0;'
        Set-ItemProperty -Path $GpuPrefKey -Name $exe -Value $pref -Type String
        $changed = $true
    }
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    if (-not ((Test-Path $CompatStateFile) -and (Get-Content $CompatStateFile) -contains $exe)) { Add-Content -Path $CompatStateFile -Value $exe }
    if ($changed) { Write-Ok 'Turned off fullscreen optimizations for Valorant (stops the black bars when the game is focused).' }
    return $changed
}

function Remove-GameCompatFlags {
    if (-not (Test-Path $CompatStateFile)) { return }
    foreach ($exe in Get-Content $CompatStateFile) {
        if (-not $exe) { continue }
        $layers = Get-RegString $LayersKey $exe
        if ($layers) {
            $rest = @(($layers -replace '^~\s*', '') -split '\s+' | Where-Object { $_ -and $_ -ne 'DISABLEDXMAXIMIZEDWINDOWEDMODE' })
            if ($rest.Count -gt 0) { Set-ItemProperty -Path $LayersKey -Name $exe -Value ('~ ' + ($rest -join ' ')) }
            else { Remove-ItemProperty -Path $LayersKey -Name $exe -ErrorAction SilentlyContinue }
        }
        $pref = Get-RegString $GpuPrefKey $exe
        if ($pref) {
            $pref = $pref -replace 'SwapEffectUpgradeEnable=0;', ''
            if ($pref) { Set-ItemProperty -Path $GpuPrefKey -Name $exe -Value $pref }
            else { Remove-ItemProperty -Path $GpuPrefKey -Name $exe -ErrorAction SilentlyContinue }
        }
    }
    Remove-Item $CompatStateFile -Force
    Write-Ok 'Fullscreen optimizations for Valorant restored.'
}

function Invoke-Apply {
    Stop-Riot

    $inis = Get-ValorantInis
    if ($inis.Count -eq 0) {
        Write-Bad "No Valorant config found in $ValConfig"
        Write-Bad 'Open Valorant once, log in, go to the main menu, close it, then run this again.'
        return $false
    }
    foreach ($f in $inis) {
        try { Set-IniStretch $f; Write-Ok "Patched $($f.FullName.Replace($ValConfig, 'Config'))" }
        catch { Write-Bad "Failed on $($f.FullName): $($_.Exception.Message)" }
    }

    Set-GpuStretch
    [void](Set-GameCompatFlags (Find-ValorantExe))

    foreach ($d in [VSDisplay4]::Displays()) {
        $hz = [VSDisplay4]::MaxHz($d, $Width, $Height)
        if ($hz -gt 0) { Write-Ok "$($d.TrimStart('\.')): ${Width}x${Height} available up to ${hz}Hz." }
    }
    return $true
}

function Find-RiotClient {
    $json = Join-Path $env:ProgramData 'Riot Games\RiotClientInstalls.json'
    if (Test-Path $json) {
        try {
            $data = Get-Content $json -Raw | ConvertFrom-Json
            foreach ($p in @($data.rc_default, $data.rc_live)) { if ($p -and (Test-Path $p)) { return $p } }
        } catch { }
    }
    foreach ($p in @('C:\Riot Games\Riot Client\RiotClientServices.exe',
                     "${env:ProgramFiles}\Riot Games\Riot Client\RiotClientServices.exe",
                     'D:\Riot Games\Riot Client\RiotClientServices.exe')) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

# ------------------------------------------------- monitor driver toggle ----
# Disabling the monitor in Device Manager stops Windows from forcing the
# monitor's real aspect ratio, so a 4:3 resolution actually fills the screen.
$MonStateFile = Join-Path $StateDir 'disabled-monitors.txt'

function Disable-MonitorDrivers {
    $mons = @(Get-PnpDevice -Class Monitor -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'OK' })
    if ($mons.Count -eq 0) { Write-Warn2 'No active monitor devices found in Device Manager.'; return }
    Write-Step ("Disabling monitor driver in Device Manager: " + (($mons | ForEach-Object { $_.FriendlyName }) -join ', '))
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    $n = 0
    foreach ($m in $mons) {
        try {
            Disable-PnpDevice -InstanceId $m.InstanceId -Confirm:$false -ErrorAction Stop
            Add-Content -Path $MonStateFile -Value $m.InstanceId
            $n++
        } catch { Write-Warn2 "Could not disable $($m.FriendlyName): $($_.Exception.Message)" }
    }
    if ($n -gt 0) {
        Start-Sleep -Seconds 4   # let Windows re-detect the screens
        Write-Ok "Disabled $n monitor driver(s). Screens stay on - they come back to normal when you quit."
    }
}

function Enable-MonitorDrivers {
    $ids = @()
    if (Test-Path $MonStateFile) { $ids += @(Get-Content $MonStateFile | Where-Object { $_.Trim() }) }
    # Also catch any monitor left disabled (code 22) if the window was closed mid-game.
    $ids += @(Get-PnpDevice -Class Monitor -PresentOnly -ErrorAction SilentlyContinue |
              Where-Object { $_.ConfigManagerErrorCode -eq 22 } | ForEach-Object { $_.InstanceId })
    $ids = @($ids | Select-Object -Unique)
    if ($ids.Count -eq 0) { return }
    foreach ($id in $ids) {
        try { Enable-PnpDevice -InstanceId $id -Confirm:$false -ErrorAction Stop } catch { }
    }
    Remove-Item $MonStateFile -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    foreach ($d in [VSDisplay4]::Displays()) { [void][VSDisplay4]::Restore($d) }
    Write-Ok "Monitor driver(s) re-enabled in Device Manager."
}

function Invoke-SetupFill {
    if (Test-Path $LastResFile) {
        $saved = (Get-Content $LastResFile -Raw).Trim()
        if ($saved -match '^(\d+)x(\d+)$') { $script:Width = [int]$Matches[1]; $script:Height = [int]$Matches[2] }
    }
    # Valorant syncs Aspect Ratio Method with your Riot account, which can override
    # the config file (bars on top + bottom = Letterbox is still on). Setting Fill
    # once inside the game saves it to the account for good.
    Stop-Riot
    Enable-MonitorDrivers   # Valorant needs the real monitor driver to list resolutions
    foreach ($d in [VSDisplay4]::Displays()) { [void][VSDisplay4]::Restore($d) }
    foreach ($f in Get-ValorantInis) { $f.IsReadOnly = $false }

    $riot = Find-RiotClient
    if (-not $riot) { Write-Bad 'Could not find RiotClientServices.exe - is Valorant installed?'; return }
    Write-Step 'Launching Valorant normally for the one-time Fill setup...'
    Start-Process -FilePath $riot -ArgumentList '--launch-product=valorant', '--launch-patchline=live'

    Write-Host ''
    Write-Host '  In Valorant: Settings > Video > General' -ForegroundColor White
    Write-Host '    1. Display Mode = Fullscreen'
    Write-Host "    2. Resolution   = ${Width}x${Height} (any 4:3 one works)   -> Apply"
    Write-Host '    3. Click Letterbox -> Apply, then Fill -> Apply   (Fill sticks this way)'
    Write-Host '    4. Display Mode = Windowed Fullscreen                     -> Apply'
    Write-Host '    5. Close the game.'
    Write-Host ''
    Write-Step 'Waiting for you to finish and close Valorant...'

    $deadline = (Get-Date).AddMinutes(10); $game = $null
    while (-not $game -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $game = Get-Process -Name 'VALORANT-Win64-Shipping' -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $game) { Write-Warn2 'Valorant did not start in time.'; return }
    $game.WaitForExit()
    Start-Sleep -Seconds 3

    if (Invoke-Apply) {
        Write-Host ''
        Write-Ok 'Fill is now saved to your account. From now on just use Play-Stretched.bat.'
    }
}

function Invoke-Launch {
    $changedDevs = New-Object System.Collections.Generic.List[string]
    try {
        if (-not $KeepMonitorDriver) { Stop-Riot; Disable-MonitorDrivers }
        if (-not (Invoke-Apply)) { return }

        $riot = Find-RiotClient
        if (-not $riot) { Write-Bad 'Could not find RiotClientServices.exe - is Valorant installed?'; return }

        # Launch at native resolution first (Valorant resets the screen while it starts up).
        Write-Step 'Launching Valorant...'
        Start-Process -FilePath $riot -ArgumentList '--launch-product=valorant', '--launch-patchline=live'

        Write-Step 'Waiting for the game window (up to 10 minutes)...'
        $deadline = (Get-Date).AddMinutes(10)
        $game = $null
        while ((Get-Date) -lt $deadline) {
            $game = Get-Process -Name 'VALORANT-Win64-Shipping' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($game -and [VSDisplay4]::GameWindow() -ne [IntPtr]::Zero) { break }
            Start-Sleep -Seconds 2
        }
        if (-not $game) { Write-Warn2 'Valorant did not start in time.'; return }
        Start-Sleep -Seconds 5   # let it finish creating its window

        # First run on a new install path: the flags only apply from the next game start.
        try { $exePath = $game.Path } catch { $exePath = $null }
        if ($exePath -and (Set-GameCompatFlags $exePath)) {
            Write-Warn2 'Valorant needs one restart for the black-bar fix: close the game, then run Play-Stretched again.'
        }

        Write-Ok 'Valorant is up - leave this window open while you play.'
        Write-Host '    (Your normal resolution comes back automatically when you close the game.)' -ForegroundColor Gray

        # Watchdog: follow whichever monitor the game is on, keep that monitor at
        # WxH stretched at its highest refresh rate, and keep the window covering it.
        $activeDev = $null; $hz = 0; $scWarned = $false; $needScale = $true
        $resets = New-Object System.Collections.Generic.Queue[datetime]
        $forceDesktop = $true
        while (-not $game.HasExited) {
            $win = [VSDisplay4]::GameWindow()
            $dev = [VSDisplay4]::WindowDisplay($win)
            if (-not $dev) { $dev = ([VSDisplay4]::Displays())[0] }

            # Switch monitors only if the game really moved (not just mid-resize).
            if ($dev -ne $activeDev) {
                $stay = $false
                if ($activeDev) {
                    $a = [VSDisplay4]::Current($activeDev)
                    $stay = [VSDisplay4]::WindowAt($win, $a[0], $a[1], $a[2], $a[3])
                }
                if (-not $stay) {
                    if ($activeDev -and $changedDevs.Contains($activeDev)) {
                        [void][VSDisplay4]::Restore($activeDev); [void]$changedDevs.Remove($activeDev)
                    }
                    $activeDev = $dev
                    $hz = [VSDisplay4]::MaxHz($dev, $Width, $Height)
                    $resets.Clear(); $forceDesktop = $true
                    $hzText = if ($hz -gt 0) { "${hz}Hz (max for this monitor)" } else { 'default Hz (mode not listed)' }
                    Write-Ok "Game is on $($dev.TrimStart('\.')) -> ${Width}x${Height} @ $hzText"
                }
            }

            $cur = [VSDisplay4]::Current($activeDev)
            if ($forceDesktop -and ($cur[2] -ne $Width -or $cur[3] -ne $Height -or ($hz -gt 0 -and $cur[4] -ne $hz))) {
                $r = [VSDisplay4]::SetStretched($activeDev, $Width, $Height, $hz)
                if ($r -eq 0) {
                    if (-not $changedDevs.Contains($activeDev)) { $changedDevs.Add($activeDev) }
                    $needScale = $true
                    $now = Get-Date
                    $resets.Enqueue($now)
                    while ($resets.Count -gt 0 -and ($now - $resets.Peek()).TotalSeconds -gt 60) { [void]$resets.Dequeue() }
                    if ($resets.Count -ge 6) {
                        $forceDesktop = $false
                        Write-Bad 'Valorant keeps switching back to native - it is probably in Fullscreen mode.'
                        Write-Bad 'Close the game, run Revert, set Display Mode = Windowed Fullscreen in Valorant, then run this again.'
                    }
                } else {
                    $forceDesktop = $false
                    Write-Bad "Windows refused ${Width}x${Height} on this monitor (code $r). Add it as a custom resolution in your GPU panel (see README)."
                }
                $cur = [VSDisplay4]::Current($activeDev)
            }
            # Force GPU stretch scaling once after each resolution change (not every loop - avoids flicker).
            if ($needScale) {
                $needScale = $false
                $sc = [VSDisplay4]::ForceStretchScaling()
            } else { $sc = 0 }
            if ($sc -ne 0 -and -not $scWarned) { Write-Warn2 "Windows didn't accept stretch scaling (code $sc) - set Full-screen + Override in NVIDIA Control Panel."; $scWarned = $true }
            [void][VSDisplay4]::FitWindow($win, $cur[0], $cur[1], $cur[2], $cur[3])
            Start-Sleep -Milliseconds 1500
        }
        Write-Step 'Valorant closed.'
    }
    finally {
        foreach ($d in $changedDevs) { [void][VSDisplay4]::Restore($d) }
        if ($changedDevs.Count -gt 0) { Write-Ok 'Monitor resolution restored.' }
        if (-not $KeepMonitorDriver) { Enable-MonitorDrivers }
    }
}

function Invoke-Revert {
    Stop-Riot
    foreach ($f in Get-ValorantInis) {
        $bak = "$($f.FullName).stretch-backup"
        $f.IsReadOnly = $false
        if (Test-Path $bak) {
            Copy-Item $bak $f.FullName -Force
            (Get-Item $f.FullName).IsReadOnly = $false
            Remove-Item $bak -Force
            Write-Ok "Restored $($f.FullName.Replace($ValConfig, 'Config'))"
        } else {
            Write-Ok "Unlocked $($f.FullName.Replace($ValConfig, 'Config')) (no backup, left as is)"
        }
    }

    if (Test-Path $StateFile) {
        $backup = Get-Content $StateFile -Raw | ConvertFrom-Json
        foreach ($p in $backup.PSObject.Properties) {
            $regPath = 'Registry::' + $p.Name
            if (Test-Path $regPath) { Set-ItemProperty -Path $regPath -Name 'Scaling' -Value ([int]$p.Value) -Type DWord }
        }
        Remove-Item $StateFile -Force
        Write-Ok 'Display scaling restored to what it was before.'
    } else {
        Write-Warn2 'No scaling backup found - display scaling left unchanged.'
    }
    Remove-GameCompatFlags
    Enable-MonitorDrivers
    foreach ($d in [VSDisplay4]::Displays()) { [void][VSDisplay4]::Restore($d) }
    Write-Ok 'Done. Restart your PC to be 100% back to normal.'
}

# ------------------------------------------------------------------ main ----
$LastResFile = Join-Path $StateDir 'last-resolution.txt'

function Read-Resolution {
    # Default = last resolution you used, otherwise 1280x960.
    $def = '1280x882'
    if (Test-Path $LastResFile) {
        $saved = (Get-Content $LastResFile -Raw).Trim()
        if ($saved -match '^\d+x\d+$') { $def = $saved }
    }
    $presets = @('1280x882', '1440x993', '1568x1080', '1280x960', '1440x1080', '1024x768')
    $mons    = [VSDisplay4]::Displays()
    $sizes   = @($mons | ForEach-Object { $c = [VSDisplay4]::Current($_); "$($c[2])x$($c[3])@$($c[4])Hz" })
    $maxW    = ($mons | ForEach-Object { ([VSDisplay4]::Current($_))[2] } | Measure-Object -Maximum).Maximum
    $maxH    = ($mons | ForEach-Object { ([VSDisplay4]::Current($_))[3] } | Measure-Object -Maximum).Maximum

    Write-Host ''
    Write-Host '  Resolution:' -ForegroundColor White
    for ($i = 0; $i -lt $presets.Count; $i++) {
        $w, $h = $presets[$i] -split 'x'
        $hzs = @($mons | ForEach-Object { $x = [VSDisplay4]::MaxHz($_, [int]$w, [int]$h); if ($x -gt 0) { "${x}Hz" } else { '-' } })
        $tag = if ($hzs -ne '-') { $hzs -join ' / ' } else { 'needs custom res' }
        Write-Host ("   {0}) {1,-10} {2}" -f ($i + 1), $presets[$i], $tag) -ForegroundColor Gray
    }
    Write-Host "   Or type any resolution, e.g. 1350x1080" -ForegroundColor DarkGray
    Write-Host "   Monitors: $($sizes -join ', ')  - Hz is picked automatically for the one the game is on" -ForegroundColor DarkGray

    while ($true) {
        $in = (Read-Host "  Resolution [Enter = $def]").Trim().ToLower()
        if ($in -eq '') { $in = $def }
        if ($in -match '^\d$' -and [int]$in -ge 1 -and [int]$in -le $presets.Count) { $in = $presets[[int]$in - 1] }
        if ($in -match '^\s*(\d{3,4})\s*[x\*, ]\s*(\d{3,4})\s*$') {
            $w = [int]$Matches[1]; $h = [int]$Matches[2]
            if ($w -lt 640 -or $h -lt 480) { Write-Bad 'Too small - minimum is 640x480.'; continue }
            if ($w -gt $maxW -or $h -gt $maxH) { Write-Bad "Bigger than your monitor (${maxW}x${maxH}) - nothing to stretch."; continue }
            # Valorant adds its own bars top + bottom when width/height is under ~1.45
            # (4:3 is 1.33). The "true stretched" resolutions everyone uses now sit at 1.45.
            if (($w / $h) -lt 1.44) {
                $h2 = [math]::Floor($w / 1.45)
                Write-Warn2 "Valorant puts black bars top + bottom on ${w}x${h} (ratio under 1.45)."
                Write-Warn2 "The no-bars version of it is ${w}x${h2}."
                $ans = (Read-Host "  Use ${w}x${h2} instead? [Y/n]").Trim().ToLower()
                if ($ans -ne 'n') { $h = $h2 }
            }
            New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
            Set-Content -Path $LastResFile -Value "${w}x${h}"
            return @($w, $h)
        }
        Write-Bad 'Type it like 1280x960, or a number from the list.'
    }
}

Write-Host ''
Write-Host '  VALORANT STRETCHED' -ForegroundColor Magenta
Write-Host '  ----------------------------------' -ForegroundColor DarkGray

if (-not ($Apply -or $Launch -or $Revert -or $SetupFill)) {
    Write-Host '  1) Play Valorant stretched  (use this every time you play)'
    Write-Host '  2) Only patch the config + GPU scaling'
    Write-Host '  3) Revert everything'
    Write-Host '  4) One-time Fill setup  (black bars on top + bottom? do this once)'
    Write-Host ''
    switch (Read-Host '  Choose 1-4') {
        '1' { $Launch = $true }
        '2' { $Apply = $true }
        '3' { $Revert = $true }
        '4' { $SetupFill = $true }
        default { Write-Bad 'Nothing selected.'; return }
    }
}

# Ask for the resolution unless it was given on the command line (-Width / -Height).
if (-not $Revert -and -not $SetupFill -and -not ($PSBoundParameters.ContainsKey('Width') -or $PSBoundParameters.ContainsKey('Height'))) {
    $Width, $Height = Read-Resolution
}
if (-not $Revert -and -not $SetupFill) {
    Write-Host ''
    Write-Host "  Using ${Width}x${Height}" -ForegroundColor Magenta
    if (-not (@([VSDisplay4]::Displays() | Where-Object { [VSDisplay4]::MaxHz($_, $Width, $Height) -gt 0 }))) {
        Write-Warn2 "${Width}x${Height} isn't in your monitor's list - add it as a custom resolution first:"
        Write-Warn2 '  NVIDIA Control Panel > Change resolution > Customize > tick "Enable resolutions not exposed by the display"'
        Write-Warn2 "  > Create Custom Resolution > ${Width} x ${Height} at your max Hz > Test > Apply" 
        Write-Warn2 '  AMD Software > Gaming/Display > Custom Resolutions'
    }
}

try {
    if ((Test-Path $MonStateFile) -and -not $Revert) {
        Write-Warn2 'Monitor driver was left disabled last time - turning it back on first.'
        Enable-MonitorDrivers
    }
    if ($Revert)     { Invoke-Revert }
    elseif ($SetupFill) { Invoke-SetupFill }
    elseif ($Launch) { Invoke-Launch }
    else {
        if (Invoke-Apply) {
            Write-Host ''
            Write-Ok 'Config patched. To actually play stretched, start the game with Play-Stretched.bat'
            Write-Host '    (or option 1) - Valorant resets the screen to native if you open it normally.' -ForegroundColor Gray
        }
    }
}
catch {
    Write-Bad $_.Exception.Message
}

if ($Host.Name -eq 'ConsoleHost') { Write-Host ''; Read-Host 'Press Enter to close' | Out-Null }
