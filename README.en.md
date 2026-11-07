# PotPlayer Auto Skip (potplayer-auto-skip)

Per-series automatic intro/outro skipping for PotPlayer, with optional cold-open and post-credits preservation. Zero dependencies — uses only the Windows built-in PowerShell, no plugins. Runs as a tray daemon; calibrate with global hotkeys, no manual typing.

[中文说明](README.md)

## Why

PotPlayer's built-in "skip playback" only supports one global fixed duration, must be re-entered for every show, and always cuts from 0:00 — destroying the cold open. This project talks to PotPlayer's official SDK window messages and remembers settings **per series (per folder)**:

- **Two intro modes**
  - `op_end` only: on episode open, jump straight to it (cold open + OP together)
  - `op_start` + `op_end`: the cold open plays normally; once playback naturally crosses `op_start`, jump to `op_end` (skips only the OP song)
- **Outro**: when playback naturally crosses `ed_start`, jump to `ed_end`. Point `ed_end` at the preview to keep next-episode previews and end cards; leave it empty to advance straight to the next episode
- Episodes with different structure? `[Show\05]` sections override per episode
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

Play episode 1 of a new show (episodes before `apply_from` are never auto-skipped) and tap the global hotkeys:

| Moment | Key | Writes |
|---|---|---|
| OP just ended | `Ctrl+Alt+1` | `op_end` |
| ED just started | `Ctrl+Alt+2` | `ed_start` |
| ED just ended (only if you want to keep the preview) | `Ctrl+Alt+3` | `ed_end` |

A tray balloon confirms each capture; values are written to `skip.ini` under the show's section automatically. From episode 2 on, everything is automatic. `Ctrl+Alt+0` pauses/resumes; the tray icon menu can quit the daemon; config edits apply instantly.

## Configuration

See [config/skip.example.ini](config/skip.example.ini) for the full annotated template. Keys: `enabled`, `apply_from`, `paths.root`, `op_start`, `op_end`, `ed_start`, `ed_end`, plus `[Show\NN]` per-episode overrides. Times accept seconds or `h:mm:ss`.

## How it works

The daemon polls PotPlayer's official SDK window messages at 400 ms: `POT_GET_TOTAL_TIME` (0x5002), `POT_GET_CURRENT_TIME` (0x5004), `POT_SET_CURRENT_TIME` (0x5005) and `POT_GET_PLAYFILE_NAME` (0x6020, full path via WM_COPYDATA — used to match the show folder). Skips trigger only when playback *naturally crosses* a boundary between two adjacent samples, so manual seeks and resumes never misfire. Seeks land on the keyframe preceding the target (standard DirectShow behavior).

## Tests

```powershell
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

## License

[MIT](LICENSE)
