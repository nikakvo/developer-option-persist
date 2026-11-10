#!/system/bin/sh
# uninstall.sh - runs when the module is removed.
#
# Settings written with `settings put` and persist.* properties survive the
# module, so every setting it changed is put back to the value it had right
# before the module first changed it. Settings the module does not manage are
# left alone. If the module hid Developer Options, they are left visible, so
# they never stay hidden with no module left to show them.
#
# Self-contained on purpose - it must not depend on anything else in the
# module directory.

MODULE_ID="dev-options-persist"
DATA_DIR="/data/adb/$MODULE_ID"
ORIGINAL_FILE="$DATA_DIR/original"
TOUCHED_FILE="$DATA_DIR/managed"
CONFIG_FILE="$DATA_DIR/config"
CUSTOM_FILE="$DATA_DIR/custom"
LOG_FILE="$DATA_DIR/logs/uninstall.log"

mkdir -p "$DATA_DIR/logs" 2>/dev/null

ulog() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$*" >>"$LOG_FILE" 2>/dev/null
}

# stop_pid <pidfile> <needle> - only a process that really is ours.
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

# restore_mock <pkg[,pkg]|none> - the mock location app from before install.
restore_mock() {
  cur=$(appops query-op android:mock_location allow 2>&1)
  case "$cur" in *Failure* | *Exception* | *rror*) return 1 ;; esac
  for p in $cur; do
    case "$p" in *.*[A-Za-z0-9]) ;; *) continue ;; esac
    case ",$1," in
      *",$p,"*) ;;
      *) appops set "$p" android:mock_location deny >/dev/null 2>&1 ;;
    esac
  done
  if [ "$1" != none ]; then
    old_ifs=$IFS
    IFS=,
    for p in $1; do
      appops set "$p" android:mock_location allow >/dev/null 2>&1
    done
    IFS=$old_ifs
  fi
  ulog "restored mock location app: $1"
}

# restorable <key> - only keys the module changed are put back. Versions
# before v8.2 kept no list; then every key that is managed in the config
# counts (and without a config, every key, as before).
restorable() {
  if [ -f "$TOUCHED_FILE" ]; then
    grep -qx -- "$1" "$TOUCHED_FILE" 2>/dev/null
    return
  fi
  [ -f "$CONFIG_FILE" ] || return 0
  _rv=$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\([^#[:space:]]*\).*/\1/p" "$CONFIG_FILE" 2>/dev/null | tail -n 1)
  [ "$_rv" != skip ]
}

# custom_where <id> - sets ns and t from CUSTOM_FILE ("<id> <kind> <target>
# <value>"); returns 1 if the id is not there or looks wrong.
custom_where() {
  [ -f "$CUSTOM_FILE" ] || return 1
  while read -r _cw_id _cw_kind _cw_t _cw_rest; do
    [ "$_cw_id" = "$1" ] || continue
    case "$_cw_t" in '' | .* | *[!A-Za-z0-9_.-]*) return 1 ;; esac
    case "$_cw_kind:$_cw_t" in
      global:* | secure:* | system:* | prop:persist.?*) ns=$_cw_kind t=$_cw_t; return 0 ;;
    esac
    return 1
  done <"$CUSTOM_FILE"
  return 1
}

restore() {
  if [ ! -f "$ORIGINAL_FILE" ]; then
    restorable development_settings_enabled || return 0
    settings put global development_settings_enabled 1 >/dev/null 2>&1 &&
      ulog "no snapshot - made Developer Options visible again"
    return 0
  fi
  while IFS='=' read -r k v; do
    v=${v%"$(printf '\r')"}
    # Where each key lives (same table as key_info in sh/common.sh).
    case "$k" in
      adb_enabled | development_settings_enabled | verifier_verify_adb_installs | \
        window_animation_scale | transition_animation_scale | animator_duration_scale | \
        stay_on_while_plugged_in)
        ns=global t=$k ;;
      extended_power_menu) ns=secure t=$k ;;
      adbinstall | adbinput) ns=prop t=persist.security.$k ;;
      phantom_process_killer) ns=prop t=persist.sys.fflag.override.settings_enable_monitor_phantom_procs ;;
      mock_location_app) ns=appop t="" ;;
      c[0-9] | c[0-9][0-9] | c[0-9][0-9][0-9])
        custom_where "$k" || continue
        # Custom values: the same characters the module itself writes.
        case "$v" in
          '' | null) ;;
          *[!A-Za-z0-9._,:+-]*) continue ;;
        esac
        restorable "$k" || continue
        case "$ns" in
          prop) setprop "$t" "$v" 2>/dev/null && ulog "restored $t=${v:-<unset>}" ;;
          *)
            if [ "$v" = null ]; then
              settings delete "$ns" "$t" >/dev/null 2>&1 && ulog "restored $ns/$t (deleted)"
            elif [ -n "$v" ]; then
              settings put "$ns" "$t" "$v" >/dev/null 2>&1 && ulog "restored $ns/$t=$v"
            fi ;;
        esac
        continue ;;
      *) continue ;;
    esac
    case "$ns:$v" in
      prop:*)
        case "$v" in *[!A-Za-z0-9._]*) continue ;; esac ;;
      appop:none) ;;
      appop:*)
        case "$v" in '' | *[!A-Za-z0-9._,]*) continue ;; esac ;;
      *:null) ;;
      *:'' | *:*[!0-9.]*) continue ;;
    esac
    restorable "$k" || continue
    if [ "$k" = development_settings_enabled ]; then
      case "$v" in 0 | null) v=1 ;; esac
    fi
    case "$ns" in
      global | secure)
        if [ "$v" = null ]; then
          settings delete "$ns" "$t" >/dev/null 2>&1 && ulog "restored $ns/$t (deleted)"
        else
          settings put "$ns" "$t" "$v" >/dev/null 2>&1 && ulog "restored $ns/$t=$v"
        fi ;;
      prop)
        setprop "$t" "$v" 2>/dev/null && ulog "restored $t=${v:-<unset>}" ;;
      appop)
        restore_mock "$v" ;;
    esac
  done <"$ORIGINAL_FILE"
}

# Properties can be restored right away. uninstall.sh usually runs early in
# boot, before the settings service exists, so the settings part is done
# again once it answers, and only then is the data directory removed.
ulog "uninstall started"
restore

# The first boot after an OTA can take several minutes (apps are optimized),
# so the wait is long. If the settings service still never answers, the
# snapshot is kept: the values can then be put back by hand from it.
(
  i=0
  while [ "$i" -lt 900 ]; do
    [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ] && settings_ready && break
    sleep 2
    i=$((i + 2))
  done
  if settings_ready; then
    restore
    ulog "uninstall cleanup finished"
    rm -rf "$DATA_DIR" 2>/dev/null
  else
    ulog "settings service never answered - settings not restored; snapshot kept in $ORIGINAL_FILE"
  fi
) </dev/null >/dev/null 2>&1 &

exit 0
