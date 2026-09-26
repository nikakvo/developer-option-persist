#!/system/bin/sh
# shellcheck shell=ash disable=SC1091,SC2034,SC2154
##########################################################################################
# Developer Options Persist — installer (Magisk / KernelSU / APatch)
##########################################################################################

SKIPUNZIP=0

MODDIR="$MODPATH"
. "$MODPATH/sh/common.sh"

command -v grep_prop >/dev/null 2>&1 || grep_prop() {
  sed -n "s/^$1=//p" "$2" 2>/dev/null | head -n 1
}

VER=$(grep_prop version "$MODPATH/module.prop")

ui_print " "
ui_print "********************************"
ui_print "  Developer Options Persist $VER"
ui_print "  Magisk / KernelSU / APatch"
ui_print "********************************"
ui_print " "

ensure_dirs

# ── Configuration ─────────────────────────────────────────────────────────────
# Lives outside the module directory, so an update keeps it.
if [ -f "$LEGACY_CONFIG" ] && [ ! -f "$CONFIG_FILE" ]; then
  ui_print "- Migrating configuration out of the module directory"
fi
migrate_legacy_config

if [ -f "$CONFIG_FILE" ]; then
  ui_print "- Keeping existing configuration"
else
  ui_print "- Writing default configuration"
fi
ensure_config

# ── Snapshot for a clean uninstall ────────────────────────────────────────────
# Taken once, before the module ever writes anything. A running daemon from
# the previous version is left alone: it keeps enforcing until the reboot
# switches over to this version.
if [ ! -f "$ORIGINAL_FILE" ]; then
  if capture_originals; then
    ui_print "- Captured current values for a clean uninstall"
  else
    ui_print "- Current values will be captured on the next boot"
  fi
fi

if [ -n "$CMD_INOTIFYD" ]; then
  ui_print "- Change detection: inotify (busybox)"
else
  ui_print "- Change detection: timed checks (inotifyd not found)"
fi

# ── Permissions ───────────────────────────────────────────────────────────────
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/sh/common.sh" 0 0 0755

ui_print " "
ui_print "- Installed. Reboot to activate."
