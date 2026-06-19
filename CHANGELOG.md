# Changelog

All notable changes to Developer Options Persist are documented here.

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
