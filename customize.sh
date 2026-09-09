##########################################################################################
# Developer Options Persist — installer
##########################################################################################

SKIPUNZIP=0

print_modname() {
  ui_print " "
  ui_print "********************************"
  ui_print "  Developer Options Persist v4"
  ui_print "  Magisk / KernelSU / APatch"
  ui_print "********************************"
  ui_print " "
}

on_install() {
  DATA_DIR="/data/adb/dev-options-persist"
  CONFIG_FILE="$DATA_DIR/config"
  ORIGINAL_FILE="$DATA_DIR/original"
  LEGACY_CONFIG="/data/adb/modules/dev-options-persist/config"

  # ── Stop a daemon left over from the previous version ─────────────────────
  if [ -f "$DATA_DIR/daemon.pid" ]; then
    OLD_PID=$(cat "$DATA_DIR/daemon.pid" 2>/dev/null)
    case "$OLD_PID" in
      '' | *[!0-9]*) OLD_PID="" ;;
    esac
    if [ -n "$OLD_PID" ] && [ -d "/proc/$OLD_PID" ]; then
      ui_print "- Stopping the running daemon (pid $OLD_PID)"
      kill "$OLD_PID" 2>/dev/null
    fi
    rm -f "$DATA_DIR/daemon.pid"
  fi

  mkdir -p "$DATA_DIR" "$DATA_DIR/logs" "$DATA_DIR/locks"
  chmod 700 "$DATA_DIR"

  # ── Config lives outside the module directory now ─────────────────────────
  # A module update replaces /data/adb/modules/<id> wholesale, so v3 lost the
  # user's settings on every update.
  if [ -f "$LEGACY_CONFIG" ] && [ ! -f "$CONFIG_FILE" ]; then
    ui_print "- Migrating configuration out of the module directory"
    cp -f "$LEGACY_CONFIG" "$CONFIG_FILE"
  fi
  rm -f "$LEGACY_CONFIG" 2>/dev/null

  if [ -f "$CONFIG_FILE" ]; then
    ui_print "- Keeping existing configuration"
    grep -q '^profile=' "$CONFIG_FILE" || echo "profile=balanced" >>"$CONFIG_FILE"
    grep -q '^log_level=' "$CONFIG_FILE" || echo "log_level=1" >>"$CONFIG_FILE"
  else
    ui_print "- Writing default configuration"
    cat >"$CONFIG_FILE" <<'EOF'
# Developer Options Persist — configuration
# 1 = force on, 0 = force off, skip = leave this setting alone
adb_enabled=1
development_settings_enabled=0
extended_power_menu=1
adbinstall=1
adbinput=1

# profile: fast | balanced | battery  (poll interval / battery trade-off)
profile=balanced
# log_level: 0 = errors only, 1 = normal, 2 = verbose
log_level=1
EOF
  fi
  chmod 600 "$CONFIG_FILE"

  # ── Snapshot the values as they are BEFORE the module touches anything ────
  # This is what uninstall.sh restores. Without it, removing the module would
  # leave Developer Options hidden with no way to bring them back.
  if [ ! -f "$ORIGINAL_FILE" ]; then
    ui_print "- Capturing current values for a clean uninstall"
    {
      echo "adb_enabled=$(settings get global adb_enabled 2>/dev/null)"
      echo "development_settings_enabled=$(settings get global development_settings_enabled 2>/dev/null)"
      echo "extended_power_menu=$(settings get secure extended_power_menu 2>/dev/null)"
      echo "adbinstall=$(getprop persist.security.adbinstall 2>/dev/null)"
      echo "adbinput=$(getprop persist.security.adbinput 2>/dev/null)"
    } >"$ORIGINAL_FILE" 2>/dev/null

    if grep -q '=[0-9]' "$ORIGINAL_FILE" 2>/dev/null; then
      chmod 600 "$ORIGINAL_FILE"
    else
      # Settings provider not reachable from the installer — service.sh will
      # take the snapshot on the next boot instead.
      rm -f "$ORIGINAL_FILE"
      ui_print "- (will capture them on next boot instead)"
    fi
  fi

  # ── Permissions ───────────────────────────────────────────────────────────
  set_perm_recursive "$MODPATH" 0 0 0755 0644
  set_perm "$MODPATH/service.sh" 0 0 0755
  set_perm "$MODPATH/uninstall.sh" 0 0 0755
  set_perm "$MODPATH/sh/common.sh" 0 0 0755

  ui_print " "
  ui_print "- Installed. Reboot to start the daemon."
}

print_modname
on_install
