# PotPlayer Auto Skip (potplayer-auto-skip)

Per-series automatic intro/outro skipping for PotPlayer, with optional cold-open and post-credits preservation. Zero dependencies — uses only the Windows built-in PowerShell, no plugins. Runs as a tray daemon; calibrate with global hotkeys, no manual typing.

[中文说明](README.md)

## Why

PotPlayer's built-in "skip playback" only supports one global fixed duration, must be re-entered for every show, and always cuts from 0:00 — destroying the cold open. This project talks to PotPlayer's official SDK window messages and remembers settings **per series (per folder)**:

- **A show needs exactly two times**: the intro time (`op_end`) and the outro time (`ed_start`), captured live with global hotkeys — no manual typing
- Advanced options: keep the cold open (skip only the OP), keep previews/end cards, per-episode overrides
- Manual seeking and resume-from-middle never trigger a skip; a resume position past the intro is never rewound

## Requirements

- Windows 10 / 11
- Windows PowerShell 5.1 (built in)
- PotPlayer (32/64-bit)

## Install

```powershell
git clone https://github.com/anaconda110/potplayer-auto-skip.git
cd potplayer-auto-skip\src
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

Installs to `%LOCALAPPDATA%\PotSkip` by default and registers autostart (Startup-folder shortcut). Options: `-Dir <path>`, `-NoAutostart`, `-NoStart`. Uninstall with `uninstall.ps1` (add `-DeleteFiles` to remove files).

## Usage

A show needs exactly two times: the intro time and the outro time.

Play episode 1 of a new show (episodes before `apply_from` are never auto-skipped) and tap the global hotkeys:

| Moment | Key | Writes |
|---|---|---|
| OP just ended | `Ctrl+Alt+1` | `op_end` (intro time) |
| ED just started | `Ctrl+Alt+2` | `ed_start` (outro time) |

A tray balloon confirms each capture; values are written to `skip.ini` under the show's section automatically. From episode 2 on: every open lands right on the feature presentation, and the outro is skipped to the next episode. `Ctrl+Alt+0` pauses/resumes; the tray icon menu can quit the daemon; config edits apply instantly.

## Configuration

A show needs only two lines:

```ini
[My Show]
op_end = 2:15      ; intro time: every open jumps here (feature start)
ed_start = 22:10   ; outro time: from here, skip to the end
```

Times accept seconds or `h:mm:ss`. Edits apply instantly.

### Advanced options (all optional)

- **Keep the cold open** (skip only the OP): add `op_start` — the cold open plays normally, and once playback crosses it the daemon jumps to `op_end`
- **Keep the preview / end card**: add `ed_end` (hotkey `Ctrl+Alt+3`); after `ed_start` the daemon lands there instead of the file end
- **Per-episode overrides**: `[My Show\12]` matches files whose name contains `12`
- **`apply_from`**: first episode to auto-skip (default `2`); **`paths.root`**: used to name sections captured by hotkeys

See [config/skip.example.ini](config/skip.example.ini) for the fully annotated template.

## How it works

The daemon polls PotPlayer's official SDK window messages at 400 ms: `POT_GET_TOTAL_TIME` (0x5002), `POT_GET_CURRENT_TIME` (0x5004), `POT_SET_CURRENT_TIME` (0x5005) and `POT_GET_PLAYFILE_NAME` (0x6020, full path via WM_COPYDATA — used to match the show folder). Skips trigger only when playback *naturally crosses* a boundary between two adjacent samples, so manual seeks and resumes never misfire. Seeks land on the keyframe preceding the target (standard DirectShow behavior).

## Tests

```powershell
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

## License

[MIT](LICENSE)
