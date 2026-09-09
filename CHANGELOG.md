# Changelog

All notable changes to Developer Options Persist are documented here.

## v4

### Fixed — battery

The v3 daemon ran a fixed 3-second loop. Each pass re-read all five config keys
with `grep | cut | tr` (15 processes), queried three settings and two
properties, then called `update_module_status`, which read every value a
**second** time and rewrote `module.prop` with `sed -i`.

Measured in a sandbox with counting wrappers on `PATH`, steady state, nothing
changing:

| | v3 | v4 (balanced, after backoff) |
|---|---|---|
| Process spawns | **430 in 35 s** (~737/min) | **4 per cycle**, 1 cycle/min |
| Per day | ~1,060,000 | ~5,800 |
| `module.prop` writes | ~1 every 3 s (~28,800/day) | only when the status string changes |

That is roughly **180× fewer process spawns**, and the CPU is no longer woken
every three seconds around the clock.

How:

- Config is parsed once into shell variables with a single `while read` loop and
  reloaded only when its mtime changes — no `grep`/`cut`/`tr` per key.
- The expensive checks are gated behind **one** `stat` of
  `settings_global.xml`, `settings_secure.xml` and the config file. If none of
  them changed, no `settings` query happens at all.
- Managed properties are still checked every pass, because `getprop` is cheap
  and properties are not covered by the settings databases.
- The interval **backs off** while the device is quiet (balanced: 15 s → 60 s)
  and snaps back the moment something changes.
- A full verification still runs at least every 5 minutes as a safety net, in
  case a ROM writes settings somewhere the mtime gate cannot see.
- `update_module_status` no longer re-reads everything; the status is derived
  from the values the apply pass already has.
- `module.prop` is rewritten only when the status string actually changes, and
  with a read loop instead of `sed -i`, so nothing in the text can be
  interpreted as a replacement pattern.
- A **poll profile** (fast / balanced / battery) is exposed in the WebUI.

### Fixed — data loss

- **Configuration is no longer stored inside the module directory.** Magisk and
  KernelSU replace `/data/adb/modules/<id>` wholesale on update, so every module
  update silently reset the user's toggles to defaults. It now lives in
  `/data/adb/dev-options-persist/config`, and the old file is migrated on
  install and on boot.

### Fixed — uninstall

- **`uninstall.sh` did nothing** and claimed "all values will be reset on next
  reboot". That was false: `settings put` writes to the settings database and
  `persist.*` properties live in `/data/property`, so both survive removal.
  Uninstalling used to leave Developer Options hidden **permanently**, with the
  module that hid them gone.
  The installer now snapshots every managed value before touching anything, and
  uninstall restores that snapshot. Developer Options are always restored as
  *visible*, since that is the one state a user cannot undo on their own. The
  restore also runs again after `sys.boot_completed`, because `uninstall.sh` can
  execute long before `system_server` exists.
- A **Restore Original** action was added to the WebUI for the same purpose.

### Fixed — WebUI

- **Most managers would have shown a dead interface.** The UI only used the
  legacy one-argument `ksu.exec(cmd)`; where a manager exposes only the callback
  form `ksu.exec(cmd, options, callbackName)`, every call failed silently. Both
  shapes are probed at startup, and a visible error box replaces the silent
  failure.
- **The daemon indicator was a lie.** It ran `test -f config && echo ok` and went
  green because a file existed. It now reads the daemon PID from `/proc`.
- **Cards could hang in the loading state forever.** `handleToggle` only cleared
  the spinner from inside `refreshAll`'s success path, and `refreshAll` swallows
  its own errors. Cleared in a `finally` block now.
- **No more immersive mode.** `ksu.fullScreen(true)` hid the status bar and the
  navigation buttons until the user swiped, which is unusable with 3-button
  navigation. The layout is edge-to-edge with `viewport-fit=cover` and
  `safe-area-inset` padding, so the system bars stay visible.
- **Config writes are atomic.** They were three separate `ksu.exec` calls sharing
  one `config.tmp` filename, so two quick toggles could interleave and lose a
  key. Writes go through `service.sh --config`, which validates the value and
  holds a lock.
- The external Google Fonts `<link>` was removed — it fails on a device with no
  network and the font stack falls back anyway.
- Duplicate `focus` + `visibilitychange` handlers collapsed into one.
- Added: a **runtime table** (config vs live vs state per key), a filterable
  service log with size and clear, poll profile and log level selectors, and
  Apply Now / Restart Daemon / Restore Original actions.

### Added

- **Logging** with timestamps and rotation at 128 KB. v3 had none at all, so a
  misbehaving module gave you nothing to look at.
- **Single-instance guard** with a PID file; the daemon can be stopped and
  started from the UI.
- **`skip` value** for any key, meaning "leave this setting alone" — useful for
  `extended_power_menu`, which is Xiaomi-specific and meaningless elsewhere.
- **`META-INF/com/google/android/update-binary`**, so the zip is flashable on
  Magisk. Without it only KernelSU and APatch could install the module.
- **Command interface** shared with the UI: `--status`, `--apply`, `--restore`,
  `--config KEY VALUE`, `--daemon-start`, `--daemon-stop`, `--log`,
  `--clear-log`.
- **Tool resolution with busybox fallback** for `stat`, `setsid`, `nohup`,
  `pgrep` and `base64`. Without `stat` the daemon falls back to a slow full poll
  rather than hammering the settings provider.
- Duplicated per-key logic replaced with one key table (`key_kind`,
  `key_target`, `key_label`, `get_live`, `set_live`).

### Notes

- `shellcheck -s sh -S warning` and `dash -n` are clean on every script; both run
  in CI on each push.

---

v3

- Add: USB Debugging (Security settings) toggle
  persist.security.adbinput (0/1) via setprop
- Add: adbinput=1 default in config

---

## v2

Re-Build

---

## v1

### Added
- Initial release
- Poll daemon (`service.sh`) that enforces 4 developer settings every 3 seconds
- Configurable via `/data/adb/modules/dev-options-persist/config`
- Auto-generated default config on first boot if missing
- Live `module.prop` description updates showing Working / Not Working status
- WebUI (`index.html`) with real-time toggle controls via KSU WebUI
- WebUI reads live system values alongside configured values for each setting
- Support for KernelSU, KernelSU-Next, SukiSU Ultra

### Controlled settings
- `global/adb_enabled` — USB Debugging
- `global/development_settings_enabled` — Developer Options visibility
- `secure/extended_power_menu` — Extended Power Menu
- `persist.security.adbinstall` — Install via USB
