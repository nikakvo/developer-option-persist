# Developer Options Persist

<p align="center">
  <img src="https://img.shields.io/badge/platform-Android-green?style=flat-square&logo=android" />
  <img src="https://img.shields.io/badge/root-KernelSU%20%7C%20SukiSU-orange?style=flat-square" />
  <img src="https://img.shields.io/badge/version-v6-blue?style=flat-square" />
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

- **Event-driven enforcement.** Changes are undone within a second or two, and an idle daemon starts no processes at all. See [Battery](#battery).
- **Profiles** — fast, balanced or battery; **engine** — events or timed checks. Both switchable from the WebUI, effective immediately.
- **Web UI** — per-setting toggles with the live value next to each, a runtime table, a filterable service log, Apply / Restart / Restore actions and a built-in help page.
- **Clean uninstall** — the values present before installation are snapshotted and restored when the module is removed; Developer Options are always left visible.
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

1. Download `developer-option-persist-v6.zip` from [Releases](https://github.com/nikakvo/developer-option-persist/releases)
2. Install it from your root manager
3. Reboot
4. Open the module UI from the manager

<img width="300" alt="Developer Options Persist WebUI" src="https://raw.githubusercontent.com/nikakvo/developer-option-persist/main/DevOptionPersist.jpg" />

---

## Battery

v3 ran a fixed 3-second loop — about a million process spawns and 28,800 `module.prop` writes per day. v4 and v5 gated the checks on the settings files' modification time, but HyperOS rewrites `settings_secure.xml` every few seconds on its own, so in practice the gate kept opening.

v6 does not poll. Android saves settings by writing `settings_*.xml.new` and renaming it into place, and init does the same with `/data/property/persistent_properties`. One busybox `inotifyd` watches those directories; the daemon reads its events with the shell's built-in `read` and checks only the keys that live in the file that changed.

| | v3 | v5 | v6 (event engine) |
|---|---|---|---|
| Idle process spawns | ~737 / min | 4 per tick, plus a full check whenever `settings_secure.xml` moved | **0** |
| Reaction to a change | ≤ 3 s | 15 s – 5 min | ≤ 1–2 s (secure: profile cooldown) |
| `module.prop` writes | ~28,800 / day | on status change | on status change |

Because `settings_secure.xml` is noisy, checks of it are rate-limited per profile; the quiet sources are checked straight away. A full verification still runs on a long timer as a safety net.

| Profile | Global / props | Secure | Full check | Poll tick (poll engine) |
|---|---|---|---|---|
| fast | 1 s | 2 s | 5 min | 15 s |
| balanced *(default)* | 1 s | 10 s | 15 min | 60 s |
| battery | 2 s | 30 s | 30 min | 5 min |

Without `inotifyd` (every KernelSU / Magisk / APatch busybox has it) or with `engine=poll`, the daemon falls back to timed checks that `stat` the same files and check only what changed. It also falls back by itself if the watcher keeps dying.

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
engine=auto
```

Each managed key takes `1` (force on), `0` (force off) or `skip` (leave it alone). Everything is editable from the WebUI; edit the file directly if you prefer — the daemon picks the change up immediately. CRLF line endings, extra spaces and trailing `# comments` are tolerated; invalid values are ignored with a warning and the key is treated as `skip`.

---

## Command line

`service.sh` is the same interface the WebUI uses:

```sh
S=/data/adb/modules/dev-options-persist/service.sh

sh $S --status                  # key=value dump: config, live values, daemon state
sh $S --apply                   # enforce now
sh $S --restore                 # put back the values captured at install time, pause enforcement
sh $S --config adb_enabled 1    # 1 | 0 | skip
sh $S --config profile battery  # fast | balanced | battery
sh $S --config engine poll      # auto | poll
sh $S --config log_level 2      # 0 | 1 | 2
sh $S --daemon-start
sh $S --daemon-stop
sh $S --log 200
sh $S --clear-log
```

---

## Uninstalling

Removing the module restores the values captured when it was installed: settings that did not exist are deleted again and properties that were unset are cleared. Developer Options are always restored as **visible**, because that is the one state you cannot undo yourself once the module that hid them is gone.

`uninstall.sh` runs early in boot, before the settings service exists, so the settings part is repeated once the service answers.

To preview the result, use **Restore Original** in the WebUI. It pauses enforcement until Apply Now or the next reboot.

---

## Troubleshooting

**The header says "poll engine" although Engine is auto**
`inotifyd` is missing or kept exiting and the daemon fell back to timed checks. Enforcement still works; the log has the reason.

**The daemon shows as stopped**
Press Apply Now or Restart Daemon in the UI, or `sh service.sh --daemon-start`. Check the log for why it exited.

**Drift shown in the runtime table**
The live value does not match the config. Press Apply Now and check the log — if a value refuses to stick, it is logged as an error with the value that was actually read back.

**`extended_power_menu` always drifts**
That setting only exists on Xiaomi / HyperOS. Set it to `skip`.

**The log warns that `settings` is unavailable**
Nothing can be enforced without it. This should never happen on a booted device.

**"settings service not answering" in the log**
Logged once when the settings service does not respond, and cleared on its own. It is not logged during a reboot.

**The WebUI is blank or shows a red error box**
The root manager did not provide a working `ksu` JavaScript bridge. Open the module through KernelSU, SukiSU, APatch or MMRL.

---

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

---

## License

[MIT](LICENSE)

