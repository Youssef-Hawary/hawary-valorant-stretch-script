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
if (-not ('VSDisplay' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class VSDisplay {
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

    static DEVMODE New() { DEVMODE d = new DEVMODE(); d.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE)); return d; }

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
        d.dmPelsWidth = w; d.dmPelsHeight = h; d.dmDisplayFrequency = hz; d.dmBitsPerPel = 32;
        d.dmDisplayFixedOutput = 1; // DMDFO_STRETCH
        d.dmFields = 0x80000 | 0x100000 | 0x400000 | 0x40000 | 0x20000000;
        return ChangeDisplaySettingsEx(null, ref d, IntPtr.Zero, 0, IntPtr.Zero);
    }
    // Go back to the resolution saved in Windows settings.
    public static int Restore() { return ChangeDisplaySettingsEx(null, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero); }
}
'@
}

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
        'FullscreenMode'                       = 0      # 0 = Fullscreen (needed for stretch)
        'LastConfirmedFullscreenMode'          = 0
        'PreferredFullscreenMode'              = 0
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

    $hz = [VSDisplay]::MaxHz($Width, $Height)
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
    if (-not $riot) { Write-Bad 'Could not find RiotClientServices.exe. Start Valorant yourself - the config is already stretched.'; return }

    $hz = [VSDisplay]::MaxHz($Width, $Height)
    $orig = [VSDisplay]::Current()
    $changed = $false
    try {
        if ($hz -gt 0) {
            $r = [VSDisplay]::SetStretched($Width, $Height, $hz)
            if ($r -eq 0) { $changed = $true; Write-Ok "Desktop switched to ${Width}x${Height} @ ${hz}Hz (stretched)." }
            else { Write-Warn2 "Could not switch desktop resolution (code $r). Launching anyway." }
        }

        Write-Step 'Launching Valorant...'
        Start-Process -FilePath $riot -ArgumentList '--launch-product=valorant', '--launch-patchline=live'

        Write-Step 'Waiting for the game to start (up to 10 minutes)...'
        $deadline = (Get-Date).AddMinutes(10)
        $game = $null
        while (-not $game -and (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3
            $game = Get-Process -Name 'VALORANT-Win64-Shipping' -ErrorAction SilentlyContinue | Select-Object -First 1
        }
        if (-not $game) { Write-Warn2 'Valorant did not start in time.'; return }

        Write-Ok 'Valorant is running. Leave this window open - your normal resolution comes back when the game closes.'
        $game.WaitForExit()
    }
    finally {
        if ($changed) {
            [void][VSDisplay]::Restore()
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
    [void][VSDisplay]::Restore()
    Write-Ok 'Done. Restart your PC to be 100% back to normal.'
}

# ------------------------------------------------------------------ main ----
Write-Host ''
Write-Host "  VALORANT STRETCHED  ${Width}x${Height}" -ForegroundColor Magenta
Write-Host '  ----------------------------------' -ForegroundColor DarkGray

if (-not ($Apply -or $Launch -or $Revert)) {
    Write-Host '  1) Apply stretch (config + GPU scaling)'
    Write-Host '  2) Apply + launch Valorant stretched (best - auto restores your resolution)'
    Write-Host '  3) Revert everything'
    Write-Host ''
    switch (Read-Host '  Choose 1, 2 or 3') {
        '1' { $Apply = $true }
        '2' { $Launch = $true }
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
            Write-Ok 'Done. Restart your PC once (so the new scaling loads), then open Valorant.'
            Write-Host '    In-game: Video > Display Mode must stay on Fullscreen.' -ForegroundColor Gray
        }
    }
}
catch {
    Write-Bad $_.Exception.Message
}

if ($Host.Name -eq 'ConsoleHost') { Write-Host ''; Read-Host 'Press Enter to close' | Out-Null }
