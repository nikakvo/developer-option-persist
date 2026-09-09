#!/system/bin/sh
# uninstall.sh — runs when the module is removed.
#
# v3 did nothing here and claimed "all values will be reset on next reboot".
# That was not true: `settings put` writes to the settings database and
# persist.* properties live in /data/property, so both survive uninstallation.
# Removing the module used to leave Developer Options hidden forever, with no
# way left to unhide them.
#
# Deliberately self-contained: sh/common.sh may already be gone by the time
# this runs.

DATA_DIR="/data/adb/dev-options-persist"
ORIGINAL_FILE="$DATA_DIR/original"
LOG_FILE="$DATA_DIR/logs/uninstall.log"

mkdir -p "$DATA_DIR/logs" 2>/dev/null

ulog() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$*" >>"$LOG_FILE" 2>/dev/null
}

# Stop the daemon.
PID=$(cat "$DATA_DIR/daemon.pid" 2>/dev/null)
case "$PID" in
  '' | *[!0-9]*) PID="" ;;
esac
if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
  kill "$PID" 2>/dev/null
  sleep 1
  [ -d "/proc/$PID" ] && kill -9 "$PID" 2>/dev/null
fi

restore() {
  # Put back what was there before the module ever ran. Falls back to making
  # Developer Options visible again, which is the one value the user cannot
  # recover on their own once it is hidden.
  if [ -f "$ORIGINAL_FILE" ]; then
    while IFS='=' read -r k v; do
      case "$k" in
        '' | '#'*) continue ;;
      esac
      case "$v" in
        '' | null) continue ;;
      esac
      # Never restore "Developer Options hidden": that is the one state the
      # user cannot undo once the module is gone.
      if [ "$k" = "development_settings_enabled" ] && [ "$v" = "0" ]; then
        v=1
      fi
      case "$k" in
        adb_enabled | development_settings_enabled)
          settings put global "$k" "$v" 2>/dev/null && ulog "restored global/$k=$v"
          ;;
        extended_power_menu)
          settings put secure "$k" "$v" 2>/dev/null && ulog "restored secure/$k=$v"
          ;;
        adbinstall)
          setprop persist.security.adbinstall "$v" 2>/dev/null && ulog "restored persist.security.adbinstall=$v"
          ;;
        adbinput)
          setprop persist.security.adbinput "$v" 2>/dev/null && ulog "restored persist.security.adbinput=$v"
          ;;
      esac
    done <"$ORIGINAL_FILE"
  else
    settings put global development_settings_enabled 1 2>/dev/null &&
      ulog "no snapshot — made Developer Options visible again"
  fi
}

# uninstall.sh can run during post-fs-data, long before system_server exists,
# so a direct attempt may silently do nothing. Try now, then verify after boot
# and retry in the background if needed.
restore

(
  i=0
  while [ "$i" -lt 180 ]; do
    [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && break
    sleep 2
    i=$((i + 2))
  done
  sleep 5
  if [ "$(settings get global development_settings_enabled 2>/dev/null)" != "1" ]; then
    restore
  fi
  ulog "uninstall cleanup finished"
  rm -rf "$DATA_DIR" 2>/dev/null
) </dev/null >/dev/null 2>&1 &

exit 0
