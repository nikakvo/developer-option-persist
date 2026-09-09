# Developer Options Persist

<p align="center">
  <img src="https://img.shields.io/badge/platform-Android-green?style=flat-square&logo=android" />
  <img src="https://img.shields.io/badge/root-KernelSU%20%7C%20SukiSU-orange?style=flat-square" />
  <img src="https://img.shields.io/badge/version-v4-blue?style=flat-square" />
  <img src="https://img.shields.io/badge/arch-ARM64-lightgrey?style=flat-square" />
</p>

A Magisk / KernelSU / APatch module that keeps USB debugging, Install via USB and the extended power menu enabled **while Developer Options stay hidden** in Settings.

---

## What it does

Turning Developer Options off in Android's Settings also turns off everything inside it — USB debugging goes with it. This module keeps the switches you care about in the state you chose and puts Developer Options back out of sight, so the menu is hidden but ADB keeps working.

It enforces five values:

| Setting | Where it lives |
|---|---|
| USB Debugging | `global / adb_enabled` |
| Developer Options | `global / development_settings_enabled` |
| Extended Power Menu | `secure / extended_power_menu` |
| Install via USB | `persist.security.adbinstall` |
| USB Debugging (Security) | `persist.security.adbinput` |

The last three are Xiaomi / HyperOS specific. On other devices set them to `skip` in the config or leave them — they simply have no effect.

---

## Features

- **Cheap enforcement.** An idle check costs four process spawns and no query to the settings provider at all. See [Battery](#battery).
- **Poll profiles** — fast, balanced or battery, switchable from the WebUI.
- **Web UI** — per-setting toggles, a runtime table showing config vs. live values, a filterable service log, and Apply / Restart / Restore actions.
- **Clean uninstall** — the values present before installation are snapshotted and restored when the module is removed.
- **Per-key `skip`** — leave any setting unmanaged.
- **Configuration survives module updates.**
- **Logging** with timestamps and rotation.

---

## Requirements

- Magisk, KernelSU, SukiSU-Ultra or APatch
- Android 8+ (anything with `cmd settings`)
- **The WebUI needs a root manager that provides the `ksu` JavaScript bridge** — KernelSU, SukiSU, APatch or MMRL. Plain Magisk has no built-in WebUI; the module works there, but the interface is only reachable through MMRL.

---

## Installation

1. Download `developer-option-persist-v4.zip`
2. Install it from your root manager
3. Reboot
4. Open the module UI from the manager

<img width="300" alt="Trust-User-Certs" src="https://raw.githubusercontent.com/nikakvo/developer-option-persist/main/DevOprion.jpg" />

---

## Battery

This is what v4 is mostly about. v3 ran a fixed 3-second loop that re-read every config key with `grep | cut | tr`, queried the settings provider twice per pass, and rewrote `module.prop` with `sed -i` every time.

Measured in a sandbox with counting wrappers on `PATH`, steady state, nothing changing:

| | v3 | v4 (balanced, after backoff) |
|---|---|---|
| Process spawns | 430 in 35 s (~737/min) | 4 per cycle, 1 cycle/min |
| Per day | ~1,060,000 | ~5,800 |
| `module.prop` writes | ~28,800/day | only when the status changes |

The trick is that a change to any Android setting rewrites `/data/system/users/0/settings_global.xml` (or `settings_secure.xml`). One `stat` of those two files plus the config file tells the daemon whether anything could have changed. If the fingerprint is unchanged, it does not query the settings provider at all. The interval also backs off while the device is quiet and snaps back the moment something moves, and a full verification still runs every few minutes as a safety net.

Profiles:

| Profile | Interval | Full check |
|---|---|---|
| fast | 5 → 15 s | 60 s |
| balanced *(default)* | 15 → 60 s | 5 min |
| battery | 30 → 300 s | 15 min |

---

## Configuration

`/data/adb/dev-options-persist/config` — outside the module directory, so it survives updates.

```
adb_enabled=1
development_settings_enabled=0
extended_power_menu=1
adbinstall=1
adbinput=1

profile=balanced
log_level=1
```

Each managed key takes `1` (force on), `0` (force off) or `skip` (leave it alone). Everything is editable from the WebUI; edit the file directly if you prefer — the daemon notices the change on its next pass.

---

## Command line

`service.sh` is the same interface the WebUI uses:

```sh
S=/data/adb/modules/dev-options-persist/service.sh

sh $S --status                  # key=value dump: config, live values, daemon state
sh $S --apply                   # enforce now
sh $S --restore                 # put back the values captured at install time
sh $S --config adb_enabled 1    # 1 | 0 | skip
sh $S --config profile battery  # fast | balanced | battery
sh $S --config log_level 2      # 0 | 1 | 2
sh $S --daemon-start
sh $S --daemon-stop
sh $S --log 200
sh $S --clear-log
```

---

## Uninstalling

Removing the module restores the values captured when it was installed. Developer Options are always restored as **visible**, because that is the one state you cannot undo yourself once the module that hid them is gone.

If you want to check the result first, use **Restore Original** in the WebUI before uninstalling.

Uninstall cleanup is also retried after `sys.boot_completed`, because `uninstall.sh` can run long before `system_server` exists.

---

## Troubleshooting

**The daemon shows as stopped**
Press Restart Daemon in the UI, or `sh service.sh --daemon-start`. Check the log for why it exited.

**Drift shown in the runtime table**
The live value does not match the config. Press Apply Now and check the log — if a value refuses to stick, it is logged as an error with the value that was actually read back.

**`extended_power_menu` always drifts**
That setting only exists on Xiaomi / HyperOS. Set it to `skip`.

**The log warns that `settings` is unavailable**
Nothing can be enforced without it. This should never happen on a booted device.

**The WebUI is blank or shows a red error box**
The root manager did not provide a working `ksu` JavaScript bridge. Open the module through KernelSU, SukiSU, APatch or MMRL.

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

---

## License

MIT

