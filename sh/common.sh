#!/system/bin/sh
# shellcheck shell=ash disable=SC3043,SC2034
#
# common.sh — paths, tool resolution, logging, config/state and the key table.
# Sourced by service.sh and uninstall.sh.
#
# POSIX sh only. Written to keep process spawns in the daemon's idle path as
# close to zero as possible — see the notes in service.sh.

MODULE_ID="dev-options-persist"
MODDIR="${MODDIR:-/data/adb/modules/$MODULE_ID}"

# ── Paths ─────────────────────────────────────────────────────────────────────
# Everything mutable lives OUTSIDE the module directory: a module update wipes
# /data/adb/modules/<id> completely, which used to reset the user's settings.
DATA_DIR="/data/adb/$MODULE_ID"
CONFIG_FILE="$DATA_DIR/config"
ORIGINAL_FILE="$DATA_DIR/original"
STATE_FILE="$DATA_DIR/state"
PID_FILE="$DATA_DIR/daemon.pid"
LOCK_DIR="$DATA_DIR/locks"
CONFIG_LOCK="$LOCK_DIR/config.lock"
LOG_DIR="$DATA_DIR/logs"
LOG_FILE="$LOG_DIR/service.log"

LEGACY_CONFIG="$MODDIR/config"
MODULE_PROP="$MODDIR/module.prop"

SETTINGS_GLOBAL_XML="/data/system/users/0/settings_global.xml"
SETTINGS_SECURE_XML="/data/system/users/0/settings_secure.xml"

LOG_MAX_BYTES=131072
LOG_KEEP_LINES=250

# ── Managed keys ──────────────────────────────────────────────────────────────
# One table instead of the same five lines copy-pasted through the script.
KEYS="adb_enabled development_settings_enabled extended_power_menu adbinstall adbinput"
META_KEYS="profile log_level"

key_kind() {
  case "$1" in
    adb_enabled | development_settings_enabled) printf 'global' ;;
    extended_power_menu) printf 'secure' ;;
    adbinstall | adbinput) printf 'prop' ;;
    *) printf 'unknown' ;;
  esac
}

key_target() {
  case "$1" in
    adbinstall) printf 'persist.security.adbinstall' ;;
    adbinput) printf 'persist.security.adbinput' ;;
    *) printf '%s' "$1" ;;
  esac
}

key_label() {
  case "$1" in
    adb_enabled) printf 'USB Debugging' ;;
    development_settings_enabled) printf 'Developer Options' ;;
    extended_power_menu) printf 'Extended Power Menu' ;;
    adbinstall) printf 'Install via USB' ;;
    adbinput) printf 'USB Debugging (Security)' ;;
    *) printf '%s' "$1" ;;
  esac
}

# get_live / set_live are on the daemon's hot path, so they dispatch directly.
# Using $(key_kind ...) here would fork two extra subshells per key per check.
get_live() {
  case "$1" in
    adb_enabled | development_settings_enabled) settings get global "$1" 2>/dev/null ;;
    extended_power_menu) settings get secure "$1" 2>/dev/null ;;
    adbinstall) getprop persist.security.adbinstall 2>/dev/null ;;
    adbinput) getprop persist.security.adbinput 2>/dev/null ;;
  esac
}

set_live() {
  case "$1" in
    adb_enabled | development_settings_enabled) settings put global "$1" "$2" 2>/dev/null ;;
    extended_power_menu) settings put secure "$1" "$2" 2>/dev/null ;;
    adbinstall) setprop persist.security.adbinstall "$2" 2>/dev/null ;;
    adbinput) setprop persist.security.adbinput "$2" 2>/dev/null ;;
  esac
}

# ── Poll profiles ─────────────────────────────────────────────────────────────
# base = interval while something is changing, max = interval after the device
# has been idle for a while. The daemon backs off between the two.
profile_base() {
  case "$1" in
    fast) printf '5' ;;
    battery) printf '30' ;;
    *) printf '15' ;;
  esac
}

profile_max() {
  case "$1" in
    fast) printf '15' ;;
    battery) printf '300' ;;
    *) printf '60' ;;
  esac
}

# How often to run a full verification even when nothing looks changed.
profile_full() {
  case "$1" in
    fast) printf '60' ;;
    battery) printf '900' ;;
    *) printf '300' ;;
  esac
}

# ── External tools ────────────────────────────────────────────────────────────
BUSYBOX=""
for _bb_cand in \
  /data/adb/magisk/busybox \
  /data/adb/ksu/bin/busybox \
  /data/adb/ap/bin/busybox \
  /system/bin/busybox \
  /system/xbin/busybox; do
  [ -x "$_bb_cand" ] || continue
  "$_bb_cand" echo >/dev/null 2>&1 || continue
  BUSYBOX="$_bb_cand"
  break
done
unset _bb_cand

_BB_APPLETS=""
[ -n "$BUSYBOX" ] && _BB_APPLETS=$("$BUSYBOX" --list 2>/dev/null)

has_applet() {
  [ -n "$_BB_APPLETS" ] || return 1
  printf '%s\n' "$_BB_APPLETS" | grep -qx "$1"
}

resolve_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    printf '%s' "$1"
    return 0
  fi
  if [ -n "$BUSYBOX" ] && has_applet "$1"; then
    printf '%s %s' "$BUSYBOX" "$1"
    return 0
  fi
  return 1
}

CMD_STAT=$(resolve_cmd stat)
CMD_SETSID=$(resolve_cmd setsid)
CMD_NOHUP=$(resolve_cmd nohup)
CMD_PGREP=$(resolve_cmd pgrep)
CMD_BASE64=$(resolve_cmd base64)

# The mtime gate is what keeps the daemon cheap. Without stat we still work,
# just with a full check every cycle on a longer interval.
MTIME_GATE=1
[ -n "$CMD_STAT" ] || MTIME_GATE=0
[ -f "$SETTINGS_GLOBAL_XML" ] || MTIME_GATE=0

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_LEVEL_VAL=1

_ts() { date '+%Y-%m-%d %H:%M:%S' 2>/dev/null; }

_log() {
  mkdir -p "$LOG_DIR" 2>/dev/null
  printf '[%s] %s %s\n' "$1" "$(_ts)" "$2" >>"$LOG_FILE" 2>/dev/null
}

log_error() { _log ERROR "$*"; return 0; }
log_warn() { [ "$LOG_LEVEL_VAL" -ge 1 ] && _log WARN "$*"; return 0; }
log_info() { [ "$LOG_LEVEL_VAL" -ge 1 ] && _log INFO "$*"; return 0; }
log_debug() { [ "$LOG_LEVEL_VAL" -ge 2 ] && _log DEBUG "$*"; return 0; }

log_sep() {
  mkdir -p "$LOG_DIR" 2>/dev/null
  printf '=== %s %s ===\n' "$(_ts)" "$*" >>"$LOG_FILE" 2>/dev/null
  return 0
}

file_size() {
  [ -f "$1" ] || {
    printf '0'
    return 0
  }
  _fs=""
  [ -n "$CMD_STAT" ] && _fs=$($CMD_STAT -c %s "$1" 2>/dev/null)
  case "$_fs" in
    '' | *[!0-9]*) _fs=$(wc -c <"$1" 2>/dev/null | tr -d ' \t') ;;
  esac
  case "$_fs" in
    '' | *[!0-9]*) _fs=0 ;;
  esac
  printf '%s' "$_fs"
  unset _fs
}

log_rotate() {
  [ -f "$LOG_FILE" ] || return 0
  _lr=$(file_size "$LOG_FILE")
  if [ "$_lr" -gt "$LOG_MAX_BYTES" ]; then
    if tail -n "$LOG_KEEP_LINES" "$LOG_FILE" >"$LOG_FILE.rot" 2>/dev/null; then
      mv -f "$LOG_FILE.rot" "$LOG_FILE" 2>/dev/null
      _log INFO "log rotated (was $_lr bytes)"
    else
      rm -f "$LOG_FILE.rot" 2>/dev/null
    fi
  fi
  unset _lr
  return 0
}

# ── Locking ───────────────────────────────────────────────────────────────────
lock_acquire() {
  _lk="$1"
  _lk_t="${2:-10}"
  _lk_i=0
  mkdir -p "$LOCK_DIR" 2>/dev/null
  while ! mkdir "$_lk" 2>/dev/null; do
    _lk_i=$((_lk_i + 1))
    if [ "$_lk_i" -gt "$_lk_t" ]; then
      unset _lk _lk_t _lk_i
      return 1
    fi
    _lk_o=$(cat "$_lk/pid" 2>/dev/null)
    if [ -n "$_lk_o" ] && [ ! -d "/proc/$_lk_o" ]; then
      rm -rf "$_lk" 2>/dev/null
      continue
    fi
    sleep 1
  done
  echo "$$" >"$_lk/pid" 2>/dev/null
  unset _lk _lk_t _lk_i _lk_o
  return 0
}

lock_release() { rm -rf "$1" 2>/dev/null; return 0; }

# ── Config ────────────────────────────────────────────────────────────────────
# Loaded into CFG_<key> shell variables with a single `while read` — no grep,
# cut or tr subprocesses. The old code spawned three processes per key per read
# and read every key twice per cycle.
CFG_MTIME=""

file_mtime() {
  [ -n "$CMD_STAT" ] || {
    printf '0'
    return 0
  }
  $CMD_STAT -c %Y "$1" 2>/dev/null || printf '0'
}

load_config() {
  for _lc_k in $KEYS $META_KEYS; do
    eval "CFG_$_lc_k=''"
  done

  if [ -f "$CONFIG_FILE" ]; then
    while IFS='=' read -r _lc_k _lc_v; do
      case "$_lc_k" in
        '' | '#'*) continue ;;
      esac
      case " $KEYS $META_KEYS " in
        *" $_lc_k "*) eval "CFG_$_lc_k=\"\$_lc_v\"" ;;
      esac
    done <"$CONFIG_FILE"
  fi

  [ -n "$CFG_profile" ] || CFG_profile="balanced"
  case "$CFG_log_level" in
    0 | 1 | 2) ;;
    *) CFG_log_level=1 ;;
  esac
  LOG_LEVEL_VAL="$CFG_log_level"

  CFG_MTIME=$(file_mtime "$CONFIG_FILE")
  unset _lc_k _lc_v
  return 0
}

write_default_config() {
  mkdir -p "$DATA_DIR" 2>/dev/null
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
  chmod 600 "$CONFIG_FILE" 2>/dev/null
  return 0
}

write_cfg() {
  lock_acquire "$CONFIG_LOCK" 5 || {
    log_warn "config lock busy, $1 not written"
    return 1
  }
  _wc_tmp="$CONFIG_FILE.tmp.$$"
  grep -v "^$1=" "$CONFIG_FILE" 2>/dev/null >"$_wc_tmp"
  printf '%s=%s\n' "$1" "$2" >>"$_wc_tmp"
  mv -f "$_wc_tmp" "$CONFIG_FILE" 2>/dev/null
  chmod 600 "$CONFIG_FILE" 2>/dev/null
  lock_release "$CONFIG_LOCK"
  unset _wc_tmp
  return 0
}

# ── State (runtime counters shown in the UI) ─────────────────────────────────
read_state() {
  [ -f "$STATE_FILE" ] || return 0
  sed -n "s/^$1=//p" "$STATE_FILE" 2>/dev/null | tail -n 1
}

write_state() { # write_state KEY=VALUE ...
  mkdir -p "$DATA_DIR" 2>/dev/null
  _ws_tmp="$STATE_FILE.tmp.$$"
  if [ -f "$STATE_FILE" ]; then
    cp -f "$STATE_FILE" "$_ws_tmp" 2>/dev/null || : >"$_ws_tmp"
  else
    : >"$_ws_tmp"
  fi
  for _ws_p in "$@"; do
    grep -v "^${_ws_p%%=*}=" "$_ws_tmp" >"$_ws_tmp.n" 2>/dev/null
    mv -f "$_ws_tmp.n" "$_ws_tmp" 2>/dev/null
    printf '%s\n' "$_ws_p" >>"$_ws_tmp"
  done
  mv -f "$_ws_tmp" "$STATE_FILE" 2>/dev/null
  unset _ws_tmp _ws_p
  return 0
}

# ── Original values (captured before we ever wrote anything) ─────────────────
capture_originals() {
  [ -f "$ORIGINAL_FILE" ] && return 0
  mkdir -p "$DATA_DIR" 2>/dev/null
  _co_tmp="$ORIGINAL_FILE.tmp.$$"
  : >"$_co_tmp"
  for _co_k in $KEYS; do
    printf '%s=%s\n' "$_co_k" "$(get_live "$_co_k")" >>"$_co_tmp"
  done
  # Only keep the snapshot if the settings provider actually answered.
  if grep -q '=[0-9]' "$_co_tmp" 2>/dev/null; then
    mv -f "$_co_tmp" "$ORIGINAL_FILE"
    chmod 600 "$ORIGINAL_FILE" 2>/dev/null
    log_info "Captured original values"
  else
    rm -f "$_co_tmp"
    log_warn "Could not capture original values yet — settings provider not ready"
  fi
  unset _co_tmp _co_k
  return 0
}

read_original() {
  [ -f "$ORIGINAL_FILE" ] || return 0
  sed -n "s/^$1=//p" "$ORIGINAL_FILE" 2>/dev/null | tail -n 1
}

# ── Misc ──────────────────────────────────────────────────────────────────────
# daemon_detach — leave the caller's cgroups and opt out of the low-memory
# killer. A daemon started from the WebUI is a child of the manager app's root
# shell, so it inherits the app's cgroup: when Android freezes or kills the
# manager, the daemon dies with it. Moving to the root cgroup and pinning
# oom_score_adj makes it behave like a boot-started service instead.
daemon_detach() {
  for _dd in /dev/cpuctl /dev/cpuset /dev/stune /dev/blkio /dev/memcg /sys/fs/cgroup; do
    [ -d "$_dd" ] || continue
    if [ -w "$_dd/cgroup.procs" ]; then
      echo "$$" >"$_dd/cgroup.procs" 2>/dev/null
    elif [ -w "$_dd/tasks" ]; then
      echo "$$" >"$_dd/tasks" 2>/dev/null
    fi
  done
  echo -1000 >"/proc/$$/oom_score_adj" 2>/dev/null
  unset _dd
  return 0
}

spawn_detached() {
  if [ -n "$CMD_SETSID" ]; then
    $CMD_SETSID "$@" </dev/null >/dev/null 2>&1 &
    return 0
  fi
  if [ -n "$CMD_NOHUP" ]; then
    $CMD_NOHUP "$@" </dev/null >/dev/null 2>&1 &
    return 0
  fi
  "$@" </dev/null >/dev/null 2>&1 &
  return 0
}

wait_for_prop() { # wait_for_prop <prop> <value> <timeout>
  _wp=0
  while [ "$_wp" -lt "$3" ]; do
    [ "$(getprop "$1" 2>/dev/null)" = "$2" ] && {
      unset _wp
      return 0
    }
    sleep 2
    _wp=$((_wp + 2))
  done
  unset _wp
  return 1
}

migrate_legacy_config() {
  [ -f "$LEGACY_CONFIG" ] || return 0
  mkdir -p "$DATA_DIR" 2>/dev/null
  if [ ! -f "$CONFIG_FILE" ]; then
    cp -f "$LEGACY_CONFIG" "$CONFIG_FILE" 2>/dev/null
    chmod 600 "$CONFIG_FILE" 2>/dev/null
    log_warn "Migrated config from the module directory to $CONFIG_FILE"
  fi
  rm -f "$LEGACY_CONFIG" 2>/dev/null
  return 0
}
