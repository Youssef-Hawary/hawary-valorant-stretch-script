<#
.SYNOPSIS
    Valorant stretched resolution (default 1280x960) for Windows - no black bars.

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
if (-not ('VSDisplay2' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class VSDisplay2 {
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
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE dm, IntPtr hwnd, int flags, IntPtr lp);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int ChangeDisplaySettingsEx(string dev, IntPtr dm, IntPtr hwnd, int flags, IntPtr lp);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);

    static DEVMODE New() { DEVMODE d = new DEVMODE(); d.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE)); return d; }

    // Real pixel coordinates even with Windows display scaling (125%, 150%...).
    public static void DpiAware() { try { SetProcessDPIAware(); } catch { } }

    public static IntPtr GameWindow() { return FindWindow("VALORANTUnrealWindow", null); }

    // Make the Valorant window borderless and exactly cover (0,0)-(w,h).
    // Returns -1 = no usable window, 0 = already correct, 1 = fixed it.
    public static int FitWindow(IntPtr h, int w, int hh) {
        if (h == IntPtr.Zero || !IsWindowVisible(h) || IsIconic(h)) return -1;
        int s  = GetWindowLong(h, -16);
        int ns = s & ~(0x00C00000 | 0x00040000 | 0x00080000 | 0x00020000 | 0x00010000); // caption, sizing frame, sysmenu, min/max
        int ex  = GetWindowLong(h, -20);
        int nex = ex & ~(0x1 | 0x100 | 0x200 | 0x20000);                                // dialog/window/client/static edges
        RECT r; GetWindowRect(h, out r);
        if (ns == s && nex == ex && r.L == 0 && r.T == 0 && r.R == w && r.B == hh) return 0;
        if (ns != s) SetWindowLong(h, -16, ns);
        if (nex != ex) SetWindowLong(h, -20, nex);
        SetWindowPos(h, IntPtr.Zero, 0, 0, w, hh, 0x0020 | 0x0040 | 0x0200); // FRAMECHANGED | SHOWWINDOW | NOOWNERZORDER
        return 1;
    }

    public static int[] Current() {
        DEVMODE d = New();
        EnumDisplaySettings(null, -1, ref d);
        return new int[] { d.dmPelsWidth, d.dmPelsHeight, d.dmDisplayFrequency };
    }
    // Highest refresh rate available for WxH on the primary monitor, 0 if the mode doesn't exist.
    public static int MaxHz(int w, int h) {
        int best = 0; DEVMODE d = New();
        for (int i = 0; EnumDisplaySettings(null, i, ref d); i++)
            if (d.dmPelsWidth == w && d.dmPelsHeight == h && d.dmBitsPerPel == 32 && d.dmDisplayFrequency > best)
                best = d.dmDisplayFrequency;
        return best;
    }
    // Temporary mode change (not saved), with DMDFO_STRETCH so the driver fills the screen.
    public static int SetStretched(int w, int h, int hz) {
        DEVMODE d = New();
        EnumDisplaySettings(null, -1, ref d);
        d.dmPelsWidth = w; d.dmPelsHeight = h; d.dmBitsPerPel = 32;
        d.dmDisplayFixedOutput = 1; // DMDFO_STRETCH
        d.dmFields = 0x80000 | 0x100000 | 0x40000 | 0x20000000;
        if (hz > 0) { d.dmDisplayFrequency = hz; d.dmFields |= 0x400000; }
        return ChangeDisplaySettingsEx(null, ref d, IntPtr.Zero, 0, IntPtr.Zero);
    }
    // Go back to the resolution saved in Windows settings.
    public static int Restore() { return ChangeDisplaySettingsEx(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero); }
}
'@
}
[VSDisplay2]::DpiAware()

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
        # 2 = Windowed. Valorant's Fullscreen always snaps back to native res, so the
        # launcher runs the game windowed and makes that window borderless + full screen.
        'FullscreenMode'                       = 2
        'LastConfirmedFullscreenMode'          = 2
        'bShouldLetterbox'                     = 'False'
        'bLastConfirmedShouldLetterbox'        = 'False'
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

    $hz = [VSDisplay2]::MaxHz($Width, $Height)
    if ($hz -gt 0) {
        Write-Ok "Your monitor supports ${Width}x${Height} up to ${hz}Hz."
    } else {
        Write-Warn2 "${Width}x${Height} is not in your monitor's mode list yet."
        Write-Warn2 'Create it once: NVIDIA Control Panel > Change resolution > Customize > Create Custom Resolution'
        Write-Warn2 "  (${Width} x ${Height}, your max refresh rate), or AMD Software > Display > Custom Resolutions."
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

function Invoke-Launch {
    if (-not (Invoke-Apply)) { return }

    $riot = Find-RiotClient
    if (-not $riot) { Write-Bad 'Could not find RiotClientServices.exe - is Valorant installed?'; return }

    $hz   = [VSDisplay2]::MaxHz($Width, $Height)
    $orig = [VSDisplay2]::Current()
    $hzText = if ($hz -gt 0) { "${hz}Hz" } else { 'default Hz' }
    $changed = $false
    try {
        # Launch at native resolution first (Valorant resets the screen while it starts up).
        Write-Step 'Launching Valorant...'
        Start-Process -FilePath $riot -ArgumentList '--launch-product=valorant', '--launch-patchline=live'

        Write-Step 'Waiting for the game window (up to 10 minutes)...'
        $deadline = (Get-Date).AddMinutes(10)
        $game = $null
        while ((Get-Date) -lt $deadline) {
            $game = Get-Process -Name 'VALORANT-Win64-Shipping' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($game -and [VSDisplay2]::GameWindow() -ne [IntPtr]::Zero) { break }
            Start-Sleep -Seconds 2
        }
        if (-not $game) { Write-Warn2 'Valorant did not start in time.'; return }
        Start-Sleep -Seconds 5   # let it finish creating its window

        Write-Ok "Valorant is up. Keeping it at ${Width}x${Height} stretched - leave this window open."
        Write-Host '    (Your normal resolution comes back automatically when you close the game.)' -ForegroundColor Gray

        # Watchdog: whenever Valorant (or anything) puts the screen back to native,
        # switch it to WxH again and refit the game window to cover the whole screen.
        $resets = New-Object System.Collections.Generic.Queue[datetime]
        $forceDesktop = $true
        $announced = $false
        while (-not $game.HasExited) {
            $cur = [VSDisplay2]::Current()
            if ($forceDesktop -and ($cur[0] -ne $Width -or $cur[1] -ne $Height)) {
                $r = [VSDisplay2]::SetStretched($Width, $Height, $hz)
                if ($r -eq 0) {
                    $changed = $true
                    $now = Get-Date
                    $resets.Enqueue($now)
                    while ($resets.Count -gt 0 -and ($now - $resets.Peek()).TotalSeconds -gt 60) { [void]$resets.Dequeue() }
                    if (-not $announced) { Write-Ok "Screen set to ${Width}x${Height} @ $hzText (stretched)."; $announced = $true }
                    if ($resets.Count -ge 6) {
                        $forceDesktop = $false
                        Write-Bad 'Valorant keeps switching back to native - it is probably in Fullscreen mode.'
                        Write-Bad 'Close the game, run Revert, set Display Mode = Windowed in Valorant, then run this again.'
                    }
                } else {
                    $forceDesktop = $false
                    Write-Bad "Windows refused ${Width}x${Height} (code $r). Add it as a custom resolution in your GPU panel (see README)."
                }
            }
            [void][VSDisplay2]::FitWindow([VSDisplay2]::GameWindow(), $Width, $Height)
            Start-Sleep -Milliseconds 1500
        }
        Write-Step 'Valorant closed.'
    }
    finally {
        if ($changed) {
            [void][VSDisplay2]::Restore()
            Write-Ok "Desktop restored to $($orig[0])x$($orig[1]) @ $($orig[2])Hz."
        }
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
    [void][VSDisplay2]::Restore()
    Write-Ok 'Done. Restart your PC to be 100% back to normal.'
}

# ------------------------------------------------------------------ main ----
Write-Host ''
Write-Host "  VALORANT STRETCHED  ${Width}x${Height}" -ForegroundColor Magenta
Write-Host '  ----------------------------------' -ForegroundColor DarkGray

if (-not ($Apply -or $Launch -or $Revert)) {
    Write-Host '  1) Play Valorant stretched  (use this every time you play)'
    Write-Host '  2) Only patch the config + GPU scaling'
    Write-Host '  3) Revert everything'
    Write-Host ''
    switch (Read-Host '  Choose 1, 2 or 3') {
        '1' { $Launch = $true }
        '2' { $Apply = $true }
        '3' { $Revert = $true }
        default { Write-Bad 'Nothing selected.'; return }
    }
}

try {
    if ($Revert)     { Invoke-Revert }
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
