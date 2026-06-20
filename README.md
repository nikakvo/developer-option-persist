# Developer Options Persist

<p align="center">
  <img src="https://img.shields.io/badge/platform-Android-green?style=flat-square&logo=android" />
  <img src="https://img.shields.io/badge/root-KernelSU%20%7C%20SukiSU-orange?style=flat-square" />
  <img src="https://img.shields.io/badge/version-v1-blue?style=flat-square" />
  <img src="https://img.shields.io/badge/arch-ARM64-lightgrey?style=flat-square" />
</p>

A KernelSU / SukiSU Ultra module that keeps your developer settings permanently enforced — even after Android resets them — while keeping Developer Options itself **hidden** from the Settings menu.

---

## What it does

Android tends to silently reset developer settings (USB debugging, install via USB, etc.) after reboots, OTA updates, or certain app actions. This module runs a lightweight poll daemon in the background that watches those settings and restores them to your configured values the moment they drift.

| Setting | Key | Default |
|---|---|---|
| USB Debugging | `global/adb_enabled` | `1` (enabled) |
| Developer Options visibility | `global/development_settings_enabled` | `0` (hidden) |
| Extended Power Menu | `secure/extended_power_menu` | `1` (enabled) |
| Install via USB | `persist.security.adbinstall` | `1` (enabled) |

> Developer Options is intentionally kept **hidden** (`development_settings_enabled=0`) so the full developer menu doesn't appear in Settings, while ADB and related functions still work normally.

---

## Requirements

- KernelSU, KernelSU-Next, or SukiSU Ultra
- Android 12+ (uses `settings` command + `setprop`)
- For the WebUI: KSU WebUI support (SukiSU Ultra recommended)

---

## Installation

1. Download the latest `.zip` from [Releases](../../releases/latest)
2. Open KernelSU / SukiSU manager
3. Tap **Install from storage** and select the zip
4. Reboot

---

## Configuration

After installation, a config file is created at:

```
/data/adb/modules/dev-options-persist/config
```

Default contents:

```ini
adb_enabled=1
development_settings_enabled=0
extended_power_menu=1
adbinstall=1
```

You can edit this file manually with a root-capable file manager or via ADB shell. The daemon picks up changes within ~3 seconds — no reboot required.

### WebUI

If your manager supports WebUI (SukiSU Ultra), tap the module's web icon to open the built-in control panel. It shows live vs configured values for each setting and lets you toggle them with a switch.

<img width="300" alt="dnscrypt" src="https://raw.githubusercontent.com/nikakvo/developer-option-persist/main/Dev-Oprion.jpg" />

---

## How it works

- `service.sh` starts after boot and launches a background daemon
- The daemon polls every 3 seconds, comparing live system values against `config`
- Any drift is immediately corrected with `settings put` / `setprop`
- `module.prop` description updates live to reflect whether settings are being enforced correctly

---

## Uninstall

Disable or remove the module through your KernelSU manager. On next reboot all settings revert to Android defaults (no cleanup script needed — values are not baked in).

---

## Author

**Tears Burn** — [@nikakvo](https://github.com/nikakvo)

---

## License

MIT
