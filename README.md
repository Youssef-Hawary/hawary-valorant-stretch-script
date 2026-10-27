# Valorant Stretched Resolution

One script that puts Valorant on **any stretched resolution you type** (1280x960 by default) (full screen, no black bars) on Windows 10/11, and can undo it all.

## Quick start

**Option A - download and double-click**

1. Download this repo (green **Code** button > **Download ZIP**) and unzip it.
2. Double-click **`ValorantStretch.bat`** and accept the admin prompt.
3. Pick **1**, then type the resolution you want (e.g. `1440x1080`, or a number from the list - Enter reuses your last one). Every time you play, start Valorant with **`Play-Stretched.bat`** (or option 1) instead of the normal shortcut.

**Option B - one line in PowerShell (run as Administrator)**

```powershell
irm https://raw.githubusercontent.com/Youssef-Hawary/hawary-valorant-stretch-script/main/valorant-stretch.ps1 -OutFile "$env:TEMP\valorant-stretch.ps1"; powershell -ExecutionPolicy Bypass -File "$env:TEMP\valorant-stretch.ps1"
```

> Run Valorant at least once (log in, reach the main menu) before using the script, so its config files exist.

## Modes

| Command | What it does |
|---|---|
| `valorant-stretch.ps1` | Menu |
| `valorant-stretch.ps1 -Apply` | Patches Valorant's config + sets GPU scaling to stretch |
| `valorant-stretch.ps1 -Launch` | Applies the config, starts Valorant, then keeps the screen at 1280x960 stretched (max Hz) and the game window borderless full screen. If Valorant snaps back to native, it's switched back within ~2 seconds. Your normal resolution returns when the game closes. `Play-Stretched.bat` does this in one click. |
| `valorant-stretch.ps1 -Revert` | Restores the original config files and scaling |
| `-Width 1440 -Height 1080` | Skip the resolution prompt and use this one |

## What it changes

- **Valorant config** - every `GameUserSettings.ini` under `%LOCALAPPDATA%\VALORANT\Saved\Config` gets 1280x960, Windowed mode, letterbox off (Valorant's own Fullscreen mode always resets to native, so the launcher runs it windowed and makes the window borderless full screen - same as the WinEXP method). The files are set **read-only** so Riot can't reset them. A `.stretch-backup` copy is kept next to each.
  - Because the files are read-only, other video settings you change in-game won't save. Run `-Revert`, change them, then apply again.
- **Display scaling** - the Windows display configuration (`HKLM\...\GraphicsDrivers\Configuration\...\Scaling`) is set to *Stretched*. Original values are saved in `%LOCALAPPDATA%\ValorantStretch` for revert.
- **Launch mode** only changes the resolution temporarily; nothing about your desktop is saved.

## Still seeing black bars?

1. Make sure you started the game with **Play-Stretched.bat** and left its window open.
2. Restart your PC once after the first run (loads the new display scaling).
3. **NVIDIA:** Control Panel > *Adjust desktop size and position* > Scaling mode **Full-screen**, Perform scaling on **GPU**, tick **Override the scaling mode set by games and programs** > Apply.
   **AMD:** Adrenalin > Settings > Display > **GPU Scaling: On**, **Scaling Mode: Full panel**.
4. If the script says 1280x960 isn't in your mode list, add it as a custom resolution (NVIDIA: *Change resolution > Customize > Create Custom Resolution*, use your max refresh rate).

## Notes

- Needs administrator rights (registry + display changes); the script asks for them itself.
- Only touches Valorant config files and display settings. It does not touch game files or Vanguard, so it's the same as changing settings by hand.
