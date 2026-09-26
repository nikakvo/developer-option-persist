#!/system/bin/sh
# uninstall.sh — runs when the module is removed.
#
# Settings written with `settings put` and persist.* properties survive the
# module, so everything it changed is put back from the snapshot taken at
# install time. Developer Options are always left visible: hidden is the one
# state the user could not undo without the module.
#
# Self-contained on purpose — it must not depend on anything else in the
# module directory.

MODULE_ID="dev-options-persist"
DATA_DIR="/data/adb/$MODULE_ID"
ORIGINAL_FILE="$DATA_DIR/original"
LOG_FILE="$DATA_DIR/logs/uninstall.log"

mkdir -p "$DATA_DIR/logs" 2>/dev/null

ulog() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$*" >>"$LOG_FILE" 2>/dev/null
}

# stop_pid <pidfile> <needle> — only a process that really is ours.
stop_pid() {
  _p=""
  [ -f "$1" ] && read -r _p <"$1" 2>/dev/null
  case "$_p" in '' | *[!0-9]*) return 0 ;; esac
  [ -d "/proc/$_p" ] || return 0
  grep -qF -- "$2" "/proc/$_p/cmdline" 2>/dev/null || return 0
  kill "$_p" 2>/dev/null
  sleep 1
  [ -d "/proc/$_p" ] && kill -9 "$_p" 2>/dev/null
  ulog "stopped pid $_p"
}

stop_pid "$DATA_DIR/run/daemon.pid" "$MODULE_ID/service.sh"
stop_pid "$DATA_DIR/run/watcher.pid" "inotifyd"
stop_pid "$DATA_DIR/daemon.pid" "$MODULE_ID/service.sh" # v4-v5 layout

settings_ready() {
  case "$(settings get global adb_enabled 2>/dev/null)" in
    null | [0-9] | [0-9][0-9]) return 0 ;;
  esac
  return 1
}

restore() {
  if [ ! -f "$ORIGINAL_FILE" ]; then
    settings put global development_settings_enabled 1 >/dev/null 2>&1 &&
      ulog "no snapshot — made Developer Options visible again"
    return 0
  fi
  while IFS='=' read -r k v; do
    v=${v%"$(printf '\r')"}
    case "$k" in
      adbinstall | adbinput)
        case "$v" in '' | [0-9] | [0-9][0-9]) ;; *) continue ;; esac ;;
      adb_enabled | development_settings_enabled | extended_power_menu)
        case "$v" in null) ;; '' | *[!0-9]*) continue ;; esac ;;
      *) continue ;;
    esac
    if [ "$k" = development_settings_enabled ]; then
      case "$v" in 0 | null) v=1 ;; esac
    fi
    case "$k" in
      adb_enabled | development_settings_enabled)
        if [ "$v" = null ]; then
          settings delete global "$k" >/dev/null 2>&1 && ulog "restored global/$k (deleted)"
        else
          settings put global "$k" "$v" >/dev/null 2>&1 && ulog "restored global/$k=$v"
        fi ;;
      extended_power_menu)
        if [ "$v" = null ]; then
          settings delete secure "$k" >/dev/null 2>&1 && ulog "restored secure/$k (deleted)"
        else
          settings put secure "$k" "$v" >/dev/null 2>&1 && ulog "restored secure/$k=$v"
        fi ;;
      adbinstall | adbinput)
        setprop "persist.security.$k" "$v" 2>/dev/null &&
          ulog "restored persist.security.$k=${v:-<unset>}" ;;
    esac
  done <"$ORIGINAL_FILE"
}

# Properties can be restored right away. uninstall.sh usually runs early in
# boot, before the settings service exists, so the settings part is done
# again once it answers, and only then is the data directory removed.
ulog "uninstall started"
restore

(
  i=0
  while [ "$i" -lt 240 ]; do
    [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && settings_ready && break
    sleep 2
    i=$((i + 2))
  done
  if settings_ready; then
    restore
    ulog "uninstall cleanup finished"
  else
    ulog "settings service never answered — settings may not be restored"
  fi
  rm -rf "$DATA_DIR" 2>/dev/null
) </dev/null >/dev/null 2>&1 &

exit 0
