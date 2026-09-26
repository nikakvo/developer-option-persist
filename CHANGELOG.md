# Changelog

All notable changes to Developer Options Persist are documented here.

## v7

### Added — mock location app

The mock location app ("Select mock location app" in Developer Options) can
now be chosen from the WebUI and is kept in place like the other settings.

- It is an AppOp, not a setting: the module does what Settings does — the
  chosen app gets `allow`, every other holder `deny`. Mocking works with
  Developer Options hidden.
- New config key `mock_location_app` (a package name or `skip`); **not managed
  by default**, so updating changes nothing until an app is picked.
- The picker lists every installed app that requests
  `ACCESS_MOCK_LOCATION`, whether or not it was ever selected, so a newly
  installed app shows up on its own. HyperOS 3 lists requested permissions
  only in single-package dumps (~60 ms each), so the scan is incremental and
  runs in the background: one `pm list packages -3 --show-versioncode` call,
  then only new or updated apps are dumped. The WebUI gets the cached list at
  once and fills in the rest when the scan is done.
- Detection: AppOps are saved to `/data/system/appops_accesses.xml` about ten
  seconds after a change, and `packages.xml` moves on every install, update or
  removal. The event engine watches both (the directory is otherwise quiet);
  the poll engine checks them too.
- Uninstalling the chosen app releases the choice: Android drops the app's
  permission, and the module switches the setting back to `skip` and logs it.
  This only happens when the package manager answers and confirms the package
  is gone, never during boot or shutdown.
- A package that is not installed cannot be set (`--config` refuses it) and
  never takes the permission away from the current app.
- Restore and uninstall put the previous mock location app back (or none).
  For values a newer version starts managing, the original is captured right
  before the module first changes them.

### Fixed

- **Errors in the log during a reboot.** Only a reboot through the framework
  (`sys.shutdown.requested`) was recognised. A root manager reboots with the
  `reboot` command, which only sets `sys.powerctl`; the stopping property
  service then made the Xiaomi properties read as unset, the correction failed
  and was logged as an ERROR. Shutdown is now also recognised by
  `sys.powerctl` and by `sys.boot_completed` no longer reading `1`; while it
  lasts nothing is corrected and nothing is logged.
- A value that cannot be read back right after a write is reported as "not
  answering" (one warning), not as a failed write.

### Changed

- README and help page state what the module was tested on (Poco F6 Pro,
  Xiaomi.eu ROM, HyperOS 3 / Android 16, SukiSU-Ultra) and what may differ
  on other devices and ROMs.
- Stopping the daemon polls in 0.2 s steps: about 0.2 s instead of just over
  a second.
- The WebUI shows the status first and fills the picker afterwards, and only
  rebuilds it when its contents change.
- Package names are shortened in the runtime table (full name on tap).

---

## v6

### Changed — event-driven enforcement

The daemon no longer polls. Android saves settings by writing
`settings_*.xml.new` and renaming it into place, and init does the same with
`/data/property/persistent_properties`. One busybox `inotifyd` watches those
directories plus the module's data directory, and the daemon reads its events
from a FIFO with the shell's built-in `read`. An idle daemon starts no
processes at all.

- Each event is checked only against the keys stored in the file that changed.
- `settings_secure.xml` is rewritten by HyperOS every few seconds, so its checks
  are rate-limited per profile (fast 2 s, balanced 10 s, battery 30 s). Global
  settings and properties are checked within 1–2 s. A cooldown delays a check,
  it never drops one.
- A full verification still runs on a timer (5 / 15 / 30 min).
- The watcher is restarted if it dies; if it keeps dying, the daemon switches
  to the poll engine by itself.
- New `engine` setting: `auto` (events) or `poll` (timed checks that `stat` the
  same files and check only what changed). Used automatically when `inotifyd`
  is not available.
- Profile and engine changes take effect immediately: `--config` signals the
  daemon instead of waiting for its next pass.

### Fixed

- **Status missing after an update.** The last status was cached in the state
  file, which survives updates, so a fresh `module.prop` never got
  "Working" back. The status is now compared with `module.prop` itself.
- **Stale PID file.** A PID was trusted if its command line contained
  `service.sh` — true for every module. Early-boot PIDs repeat from boot to
  boot, so a stale file could point at another module's daemon: this one then
  refused to start, and Daemon Stop, update and uninstall could kill the wrong
  process. PIDs are now matched against this module's own path, zombies do not
  count, and runtime files are cleared on boot.
- **Error text taken as a value.** When the settings service fails, `cmd`
  prints its error on stdout. It is now recognised as "unreadable" instead of
  being compared with, and logged as, the setting's value.
- **Slow and unclean stop.** A TERM arriving during `sleep` was held until the
  sleep ended (up to 5 minutes), so every stop ended in `kill -9` and left an
  orphaned `sleep`. Stopping is now immediate and takes the watcher with it.
- **Restore Original was undone at once.** The running daemon reapplied the
  config on its next pass. Restore now pauses enforcement until Apply Now,
  Restart Daemon or the next reboot, and the WebUI shows "paused".
- **Uninstall could leave settings unrestored.** The settings part was only
  retried after boot if Developer Options were still hidden. It is now always
  repeated once the settings service answers. Settings that did not exist
  before installation are deleted again and unset properties are cleared,
  instead of being left at the module's values.
- **Updating stopped enforcement until the reboot.** The installer killed the
  running daemon; it is now left alone and replaced by the reboot.
- **Hand-edited config.** CRLF line endings, surrounding spaces and trailing
  `# comments` are handled. Invalid values are ignored with one warning and the
  key falls back to `skip`. Writes from the WebUI keep the file's order and
  comments.
- **Log noise.** A failure is logged once per streak instead of on every pass,
  and the settings service disappearing during a reboot is not logged at all.
- **Stale lock.** A lock whose holder died before recording its PID blocked
  config writes forever; it is now taken over.

### WebUI

- Header shows the version from `module.prop` and the engine actually running.
- Status line shows the watcher's PID and a **paused** state.
- The badge on each card shows the live value (VISIBLE / HIDDEN, ON / OFF /
  UNSET) and turns amber when it does not match the switch.
- "reaction" chip and profile hint describe the current profile; new Engine
  card; `n/a` in the runtime table when the settings service does not answer.
- Hints no longer break in the middle of a word.
- Help page rewritten for the event engine, profiles, restore and uninstall.

### Other

- All versions come from `module.prop`; the installer and WebUI no longer carry
  their own.
- Default configuration defined in one place; the installer uses `common.sh`.
- `update-binary` reduced to the standard installer.
- Runtime files moved to `/data/adb/dev-options-persist/run/`; old ones are
  cleaned up on boot.
- LICENSE file added.

---

## v5

### Added — built-in help page

`webroot/help.html`, reachable from a **HELP** button in the top right of the
interface. The other modules in this family ship documentation; this one had
five toggles with names like `persist.security.adbinput` and nowhere explaining
what they mean.

It covers what the module does, all five managed settings (including which are
Xiaomi-specific and why the Developer Options toggle is inverted), how the mtime
gate and backoff keep the daemon cheap, the poll profiles, the config file
format and the `skip` value, the full `service.sh` command reference, what
happens on restore and uninstall, troubleshooting, and the file layout.

The back button uses `history.back()` with a fallback to `index.html`, so it
works whether the manager navigated there from the main page or opened the file
directly.

---

## v4.1

### Fixed — the daemon could die after a change from the WebUI

`--config profile` restarted the daemon so it would pick up the new intervals.
That restart was spawned from the manager app's root shell, so the new daemon
inherited the app's cgroup: when Android froze or killed the manager, it took
the daemon with it. A healthy boot-started daemon was being replaced by a
fragile one.

- A profile change no longer restarts anything. The config file is part of the
  daemon's mtime fingerprint, so it reloads the new intervals on its own next
  pass.
- Any daemon that *is* started from the WebUI now calls `daemon_detach()` first:
  it moves itself into the root cgroup (`cpuctl`, `cpuset`, `stune`, `blkio`,
  `memcg`, unified `cgroup.procs`) and sets `oom_score_adj` to -1000, so it
  behaves like a boot-started service instead of an app child.
- **Apply Now** restarts the daemon if it is not running, and says so.
- The status line tells you what to press when the daemon is stopped.

The "daemon stopped" indicator itself was correct — that is v4's honest PID
check working. v3 would have shown green because a config file existed.

---

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
