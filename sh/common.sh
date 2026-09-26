#!/system/bin/sh
# shellcheck shell=ash disable=SC3043,SC2034
#
# common.sh — paths, the key table, tool resolution, logging, locking, config,
# state and original-value handling. Sourced by service.sh and customize.sh.
#
# POSIX sh only; runs under busybox ash (boot, daemon) and mksh (WebUI calls).
# Anything on the daemon's idle path is written with shell builtins so an idle
# daemon spawns no processes at all.

MODULE_ID="dev-options-persist"
MODDIR="${MODDIR:-/data/adb/modules/$MODULE_ID}"

# ── Paths ─────────────────────────────────────────────────────────────────────
# Everything mutable lives outside the module directory, which a module update
# replaces wholesale.
DATA_DIR="/data/adb/$MODULE_ID"
CONFIG_FILE="$DATA_DIR/config"
ORIGINAL_FILE="$DATA_DIR/original"
LOG_DIR="$DATA_DIR/logs"
LOG_FILE="$LOG_DIR/service.log"

# Runtime files get their own directory so the daemon's watch on DATA_DIR only
# ever sees the config file change.
RUN_DIR="$DATA_DIR/run"
STATE_FILE="$RUN_DIR/state"
PID_FILE="$RUN_DIR/daemon.pid"
WATCHER_PID_FILE="$RUN_DIR/watcher.pid"
FIFO="$RUN_DIR/events"
LOCK_DIR="$RUN_DIR/locks"
CONFIG_LOCK="$LOCK_DIR/config"
APPLY_LOCK="$LOCK_DIR/apply"

# Older layouts, cleaned up or migrated on install and boot.
LEGACY_CONFIG="/data/adb/modules/$MODULE_ID/config" # v3
LEGACY_RUNTIME="$DATA_DIR/state $DATA_DIR/daemon.pid $DATA_DIR/locks" # v4-v5

MODULE_PROP="$MODDIR/module.prop"

SYSTEM_DIR="/data/system"
APPOPS_FILES="appops_accesses.xml appops.xml" # Android 15+ / older
PACKAGES_XML="$SYSTEM_DIR/packages.xml"
SETTINGS_DIR="/data/system/users/0"
SETTINGS_GLOBAL_XML="$SETTINGS_DIR/settings_global.xml"
SETTINGS_SECURE_XML="$SETTINGS_DIR/settings_secure.xml"
PROP_DIR="/data/property"
PROP_FILE="$PROP_DIR/persistent_properties"

LOG_MAX_BYTES=131072
LOG_KEEP_LINES=400

CR=$(printf '\r')

# ── Managed keys ──────────────────────────────────────────────────────────────
KEYS="adb_enabled development_settings_enabled extended_power_menu adbinstall adbinput mock_location_app"
KEYS_GLOBAL="adb_enabled development_settings_enabled"
KEYS_SECURE="extended_power_menu"
KEYS_PROP="adbinstall adbinput"
KEYS_APPOP="mock_location_app"
META_KEYS="profile log_level engine"

key_kind() {
  case "$1" in
    adb_enabled | development_settings_enabled) printf 'global' ;;
    extended_power_menu) printf 'secure' ;;
    adbinstall | adbinput) printf 'prop' ;;
    mock_location_app) printf 'appop' ;;
    *) printf 'unknown' ;;
  esac
}

key_target() {
  case "$1" in
    adbinstall) printf 'persist.security.adbinstall' ;;
    adbinput) printf 'persist.security.adbinput' ;;
    mock_location_app) printf 'android:mock_location' ;;
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
    mock_location_app) printf 'Mock Location App' ;;
    *) printf '%s' "$1" ;;
  esac
}

# valid_pkg <name> — an Android package name (a.b, letters, digits, _ and .).
valid_pkg() {
  case "$1" in
    '' | .* | *. | *..* | *[!A-Za-z0-9._]*) return 1 ;;
    *.*) return 0 ;;
  esac
  return 1
}

# valid_value <key> <value> — what the config accepts for a managed key.
valid_value() {
  case "$1:$2" in
    *:skip) return 0 ;;
    mock_location_app:*) valid_pkg "$2" ;;
    *:0 | *:1) return 0 ;;
    *) return 1 ;;
  esac
}

# mock_holders — packages whose mock_location AppOp is "allow", comma
# separated, "none" if there are none. Settings grants it to exactly one app.
# Returns 1 if the AppOps service did not answer.
mock_holders() {
  _mh_out=$(appops query-op android:mock_location allow 2>&1)
  case "$_mh_out" in
    *Failure* | *Exception* | *rror*)
      unset _mh_out
      return 1 ;;
  esac
  MOCK=""
  for _mh_p in $_mh_out; do
    valid_pkg "$_mh_p" && MOCK="${MOCK:+$MOCK,}$_mh_p"
  done
  [ -n "$MOCK" ] || MOCK=none
  unset _mh_out _mh_p
  return 0
}

# set_mock <pkg[,pkg]|none> — what Settings does when a mock location app is
# picked: every other holder is set to deny, the chosen one to allow.
set_mock() {
  # Never take the permission away from the current app for a package that
  # cannot receive it (not installed, typo in a hand-edited config).
  if [ "$1" != none ]; then
    _sm_ifs=$IFS
    IFS=,
    for _sm_p in $1; do
      case "$(appops get "$_sm_p" MOCK_LOCATION 2>&1)" in
        *rror* | *Failure* | *Exception*)
          IFS=$_sm_ifs
          unset _sm_p _sm_ifs
          return 1 ;;
      esac
    done
    IFS=$_sm_ifs
  fi
  mock_holders || return 1
  _sm_ifs=$IFS
  IFS=,
  for _sm_p in $MOCK; do
    [ "$_sm_p" = none ] && continue
    case ",$1," in
      *",$_sm_p,"*) ;;
      *) appops set "$_sm_p" android:mock_location deny >/dev/null 2>&1 ;;
    esac
  done
  if [ "$1" != none ]; then
    for _sm_p in $1; do
      appops set "$_sm_p" android:mock_location allow >/dev/null 2>&1
    done
  fi
  IFS=$_sm_ifs
  unset _sm_p _sm_ifs
  return 0
}

# system_down — the system is shutting down or not fully up: a reboot through
# the framework (sys.shutdown.requested), a `reboot` command (sys.powerctl),
# or property reads that no longer answer (sys.boot_completed not 1). Checked
# only when a value is unreadable or wrong, so it costs nothing normally.
system_down() {
  [ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ] || return 0
  [ -n "$(getprop sys.powerctl 2>/dev/null)" ] && return 0
  [ -n "$(getprop sys.shutdown.requested 2>/dev/null)" ] && return 0
  return 1
}

# pkg_state <pkg> — prints "installed", "missing", or "unknown" when the
# package manager itself did not answer (early boot, shutdown). Only
# "missing" is ever acted on.
pkg_state() {
  if [ -n "$(pm path "$1" 2>/dev/null)" ]; then
    printf 'installed'
  elif [ -n "$(pm path android 2>/dev/null)" ]; then
    printf 'missing'
  else
    printf 'unknown'
  fi
}

# read_live <key> — sets LIVE. Returns 1 when the value could not be read.
#
# A healthy read is digits, "null" for an absent setting, or empty for an unset
# property. Anything else is an error: when the settings service is down, `cmd`
# prints its failure message on stdout ("cmd: Failure calling service settings:
# Failed transaction"), and v5 took that text for the setting's value.
read_live() {
  case "$1" in
    adb_enabled | development_settings_enabled)
      LIVE=$(settings get global "$1" 2>/dev/null) ;;
    extended_power_menu)
      LIVE=$(settings get secure "$1" 2>/dev/null) ;;
    adbinstall)
      LIVE=$(getprop persist.security.adbinstall 2>/dev/null) ;;
    adbinput)
      LIVE=$(getprop persist.security.adbinput 2>/dev/null) ;;
    mock_location_app)
      if mock_holders; then
        LIVE=$MOCK
        return 0
      fi
      LIVE=""
      return 1 ;;
    *)
      LIVE=""
      return 1 ;;
  esac
  case "$1" in
    adbinstall | adbinput)
      case "$LIVE" in
        '' | [0-9] | [0-9][0-9]) return 0 ;;
      esac ;;
    *)
      case "$LIVE" in
        null) return 0 ;;
        '' | *[!0-9]*) ;;
        *) return 0 ;;
      esac ;;
  esac
  LIVE=""
  return 1
}

# set_live <key> <value>. "null" deletes a setting, "" clears a property.
set_live() {
  case "$1" in
    adb_enabled | development_settings_enabled)
      if [ "$2" = null ]; then
        settings delete global "$1" >/dev/null 2>&1
      else
        settings put global "$1" "$2" >/dev/null 2>&1
      fi ;;
    extended_power_menu)
      if [ "$2" = null ]; then
        settings delete secure "$1" >/dev/null 2>&1
      else
        settings put secure "$1" "$2" >/dev/null 2>&1
      fi ;;
    adbinstall) setprop persist.security.adbinstall "$2" 2>/dev/null ;;
    adbinput) setprop persist.security.adbinput "$2" 2>/dev/null ;;
    mock_location_app) set_mock "$2" ;;
  esac
}

# ── Profiles ──────────────────────────────────────────────────────────────────
# CD_FAST     cooldown for the quiet sources (global settings, properties)
# CD_SECURE   cooldown for settings_secure.xml, which HyperOS rewrites every
#             few seconds for unrelated reasons
# FULL        safety-net verification of every key
# POLL        tick of the fallback engine when inotify is unavailable
set_profile_vars() {
  case "$1" in
    fast) CD_FAST=1 CD_SECURE=2 FULL=300 POLL=15 ;;
    battery) CD_FAST=2 CD_SECURE=30 FULL=1800 POLL=300 ;;
    *) CD_FAST=1 CD_SECURE=10 FULL=900 POLL=60 ;;
  esac
}

# ── External tools ────────────────────────────────────────────────────────────
BUSYBOX=""
for _bb in \
  /data/adb/ksu/bin/busybox \
  /data/adb/magisk/busybox \
  /data/adb/ap/bin/busybox \
  /system/bin/busybox \
  /system/xbin/busybox; do
  [ -x "$_bb" ] || continue
  "$_bb" true >/dev/null 2>&1 || continue
  BUSYBOX="$_bb"
  break
done
unset _bb

_BB_APPLETS=""
[ -n "$BUSYBOX" ] && _BB_APPLETS=" $("$BUSYBOX" --list 2>/dev/null | tr '\n' ' ') "

has_applet() {
  case "$_BB_APPLETS" in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

resolve_cmd() {
  if command -v "$1" >/dev/null 2>&1; then
    printf '%s' "$1"
    return 0
  fi
  if has_applet "$1"; then
    printf '%s %s' "$BUSYBOX" "$1"
    return 0
  fi
  return 1
}

CMD_STAT=$(resolve_cmd stat)
CMD_SETSID=$(resolve_cmd setsid)
CMD_NOHUP=$(resolve_cmd nohup)
CMD_BASE64=$(resolve_cmd base64)
CMD_MKFIFO=$(resolve_cmd mkfifo)

# Only busybox's inotifyd is used: it flushes every event line, which the
# daemon's reader depends on.
CMD_INOTIFYD=""
has_applet inotifyd && CMD_INOTIFYD="$BUSYBOX inotifyd"

# The shell the daemon runs under. Boot scripts already run in busybox ash;
# a daemon started from the WebUI is given the same shell.
DAEMON_SH="sh"
[ -n "$BUSYBOX" ] && DAEMON_SH="$BUSYBOX sh"

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_LEVEL_VAL=1

_ts() { date '+%Y-%m-%d %H:%M:%S' 2>/dev/null; }

_log() {
  [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2>/dev/null
  printf '[%s] %s %s\n' "$1" "$(_ts)" "$2" >>"$LOG_FILE" 2>/dev/null
}

log_error() { _log ERROR "$*"; return 0; }
log_warn() { [ "$LOG_LEVEL_VAL" -ge 1 ] && _log WARN "$*"; return 0; }
log_info() { [ "$LOG_LEVEL_VAL" -ge 1 ] && _log INFO "$*"; return 0; }
log_debug() { [ "$LOG_LEVEL_VAL" -ge 2 ] && _log DEBUG "$*"; return 0; }

log_sep() {
  [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2>/dev/null
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

# ── Small helpers ─────────────────────────────────────────────────────────────
ensure_dirs() {
  mkdir -p "$DATA_DIR" "$LOG_DIR" "$RUN_DIR" "$LOCK_DIR" 2>/dev/null
  chmod 700 "$DATA_DIR" 2>/dev/null
}

# now_up — seconds since boot into NOW, without spawning `date`.
now_up() {
  read -r NOW _ </proc/uptime 2>/dev/null || NOW=0
  NOW=${NOW%%.*}
}

# read_pidfile <file> — prints the PID, or 0.
read_pidfile() {
  _rp=0
  [ -f "$1" ] && read -r _rp <"$1" 2>/dev/null
  case "$_rp" in
    '' | *[!0-9]*) _rp=0 ;;
  esac
  printf '%s' "$_rp"
  unset _rp
}

# pid_alive <pid> — running and not a zombie.
pid_alive() {
  case "$1" in
    '' | 0 | *[!0-9]*) return 1 ;;
  esac
  [ -r "/proc/$1/stat" ] || return 1
  _pa_s=""
  read -r _ _ _pa_s _ <"/proc/$1/stat" 2>/dev/null
  [ "$_pa_s" = "Z" ] && return 1
  [ -n "$_pa_s" ]
}

# pid_is <pid> <needle> — alive and its command line contains needle. A bare
# PID is not proof of identity: PIDs are reused, and early-boot PIDs are
# assigned in much the same order every boot, so a stale PID file can easily
# point at another module's service.sh.
pid_is() {
  pid_alive "$1" || return 1
  grep -qF -- "$2" "/proc/$1/cmdline" 2>/dev/null
}

DAEMON_NEEDLE="$MODULE_ID/service.sh"

daemon_pid() { read_pidfile "$PID_FILE"; }

daemon_is_running() {
  pid_is "$(daemon_pid)" "$DAEMON_NEEDLE"
}

# kill_verified <pid> <needle> <grace seconds>
kill_verified() {
  pid_is "$1" "$2" || return 1
  kill "$1" 2>/dev/null
  _kv=0
  while pid_alive "$1" && [ "$_kv" -lt $(($3 * 5)) ]; do
    sleep 0.2
    _kv=$((_kv + 1))
  done
  pid_alive "$1" && kill -9 "$1" 2>/dev/null
  unset _kv
  return 0
}

# ── Locking ───────────────────────────────────────────────────────────────────
# mkdir is atomic. A lock whose owner is gone, or that never got an owner
# written (the holder died between mkdir and echo), is taken over.
lock_acquire() { # lock_acquire <dir> <seconds>
  _lk_t="${2:-5}"
  _lk_empty=0
  [ -d "$LOCK_DIR" ] || mkdir -p "$LOCK_DIR" 2>/dev/null
  while ! mkdir "$1" 2>/dev/null; do
    _lk_o=""
    [ -f "$1/pid" ] && read -r _lk_o <"$1/pid" 2>/dev/null
    if [ -n "$_lk_o" ]; then
      if ! pid_alive "$_lk_o"; then
        rm -rf "$1" 2>/dev/null
        continue
      fi
    else
      _lk_empty=$((_lk_empty + 1))
      if [ "$_lk_empty" -ge 3 ]; then
        rm -rf "$1" 2>/dev/null
        continue
      fi
    fi
    [ "$_lk_t" -le 0 ] && {
      unset _lk_t _lk_o _lk_empty
      return 1
    }
    _lk_t=$((_lk_t - 1))
    sleep 1
  done
  echo "$$" >"$1/pid" 2>/dev/null
  unset _lk_t _lk_o _lk_empty
  return 0
}

lock_release() { rm -rf "$1" 2>/dev/null; return 0; }

# ── Config ────────────────────────────────────────────────────────────────────
write_default_config() {
  mkdir -p "$DATA_DIR" 2>/dev/null
  cat >"$CONFIG_FILE" <<'CFG'
# Developer Options Persist — configuration
# 1 = force on, 0 = force off, skip = leave this setting alone
adb_enabled=1
development_settings_enabled=0
extended_power_menu=1
adbinstall=1
adbinput=1
# mock_location_app: package name of the mock location app, or skip
mock_location_app=skip

# profile: fast | balanced | battery  (reaction time / battery trade-off)
profile=balanced
# log_level: 0 = errors only, 1 = normal, 2 = verbose
log_level=1
# engine: auto (react to changes as they happen) | poll (timed checks only)
engine=auto
CFG
  chmod 600 "$CONFIG_FILE" 2>/dev/null
  return 0
}

# ensure_config — create it, or add settings that a newer version introduced.
ensure_config() {
  if [ ! -f "$CONFIG_FILE" ]; then
    write_default_config
    return 0
  fi
  grep -q '^profile=' "$CONFIG_FILE" || echo "profile=balanced" >>"$CONFIG_FILE"
  grep -q '^log_level=' "$CONFIG_FILE" || echo "log_level=1" >>"$CONFIG_FILE"
  grep -q '^engine=' "$CONFIG_FILE" || echo "engine=auto" >>"$CONFIG_FILE"
  grep -q '^mock_location_app=' "$CONFIG_FILE" ||
    echo "mock_location_app=skip" >>"$CONFIG_FILE"
  chmod 600 "$CONFIG_FILE" 2>/dev/null
  return 0
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

# _trim — strips CR, an inline "# comment" and surrounding blanks from _t.
_trim() {
  _t=${_t%"$CR"}
  _t=${_t%%#*}
  while :; do
    case "$_t" in
      ' '* | '	'*) _t=${_t#?} ;;
      *' ' | *'	') _t=${_t%?} ;;
      *) break ;;
    esac
  done
}

# load_config [warn] — reads the file into CFG_<key> with builtins only.
# Hand-edited files are tolerated: CRLF line endings, blanks, inline comments.
# A value that is not valid falls back to a safe default (skip for managed
# keys), and with "warn" each one is reported in the log.
load_config() {
  for _lc_k in $KEYS; do
    eval "CFG_$_lc_k=skip"
  done
  CFG_profile=balanced
  CFG_log_level=1
  CFG_engine=auto
  CFG_BAD=""

  if [ -f "$CONFIG_FILE" ]; then
    while IFS= read -r _lc_line || [ -n "$_lc_line" ]; do
      case "$_lc_line" in
        *=*) ;;
        *) continue ;;
      esac
      _t=${_lc_line%%=*}
      _trim
      _lc_k=$_t
      _t=${_lc_line#*=}
      _trim
      _lc_v=$_t
      case "$_lc_k" in
        '' | '#'*) continue ;;
      esac
      case " $KEYS " in
        *" $_lc_k "*)
          if valid_value "$_lc_k" "$_lc_v"; then
            eval "CFG_$_lc_k=\$_lc_v"
          else
            CFG_BAD="$CFG_BAD $_lc_k=$_lc_v"
          fi
          continue ;;
      esac
      case "$_lc_k" in
        profile)
          case "$_lc_v" in
            fast | balanced | battery) CFG_profile=$_lc_v ;;
            *) CFG_BAD="$CFG_BAD profile=$_lc_v" ;;
          esac ;;
        log_level)
          case "$_lc_v" in
            0 | 1 | 2) CFG_log_level=$_lc_v ;;
            *) CFG_BAD="$CFG_BAD log_level=$_lc_v" ;;
          esac ;;
        engine)
          case "$_lc_v" in
            auto | poll) CFG_engine=$_lc_v ;;
            *) CFG_BAD="$CFG_BAD engine=$_lc_v" ;;
          esac ;;
      esac
    done <"$CONFIG_FILE"
  fi

  LOG_LEVEL_VAL=$CFG_log_level
  if [ "$1" = warn ] && [ -n "$CFG_BAD" ]; then
    log_warn "Ignored invalid config value(s):$CFG_BAD — using defaults for those"
  fi
  unset _lc_k _lc_v _lc_line _t
  return 0
}

# write_cfg <key> <value> — replaces the line in place, so the file keeps its
# order and comments, and appends the key if it was missing.
write_cfg() {
  lock_acquire "$CONFIG_LOCK" 5 || {
    log_warn "config lock busy, $1 not written"
    return 1
  }
  _wc_tmp="$CONFIG_FILE.tmp.$$"
  _wc_done=0
  {
    if [ -f "$CONFIG_FILE" ]; then
      while IFS= read -r _wc_l || [ -n "$_wc_l" ]; do
        _wc_l=${_wc_l%"$CR"}
        _t=${_wc_l%%=*}
        _trim
        case "$_wc_l" in
          *=*)
            if [ "$_t" = "$1" ]; then
              [ "$_wc_done" -eq 0 ] && printf '%s=%s\n' "$1" "$2"
              _wc_done=1
              continue
            fi ;;
        esac
        printf '%s\n' "$_wc_l"
      done <"$CONFIG_FILE"
    fi
    [ "$_wc_done" -eq 1 ] || printf '%s=%s\n' "$1" "$2"
  } >"$_wc_tmp" 2>/dev/null

  _wc_rc=1
  if [ -s "$_wc_tmp" ]; then
    chmod 600 "$_wc_tmp" 2>/dev/null
    mv -f "$_wc_tmp" "$CONFIG_FILE" 2>/dev/null && _wc_rc=0
  fi
  rm -f "$_wc_tmp" 2>/dev/null
  lock_release "$CONFIG_LOCK"
  unset _wc_tmp _wc_done _wc_l _t
  return "$_wc_rc"
}

# ── State (runtime values shown in the UI) ───────────────────────────────────
read_state() {
  _rs=""
  if [ -f "$STATE_FILE" ]; then
    while IFS= read -r _rs_l; do
      case "$_rs_l" in
        "$1="*) _rs=${_rs_l#*=} ;;
      esac
    done <"$STATE_FILE"
  fi
  printf '%s' "$_rs"
  unset _rs _rs_l
}

read_state_num() {
  _rsn=$(read_state "$1")
  case "$_rsn" in
    '' | *[!0-9]*) _rsn=0 ;;
  esac
  printf '%s' "$_rsn"
  unset _rsn
}

# write_state KEY=VALUE ... — one read, one write, one rename.
write_state() {
  [ -d "$RUN_DIR" ] || mkdir -p "$RUN_DIR" 2>/dev/null
  _ws_tmp="$STATE_FILE.tmp.$$"
  {
    if [ -f "$STATE_FILE" ]; then
      while IFS= read -r _ws_l; do
        _ws_skip=0
        for _ws_p in "$@"; do
          case "$_ws_l" in
            "${_ws_p%%=*}="*) _ws_skip=1 ;;
          esac
        done
        [ "$_ws_skip" -eq 0 ] && printf '%s\n' "$_ws_l"
      done <"$STATE_FILE"
    fi
    for _ws_p in "$@"; do
      printf '%s\n' "$_ws_p"
    done
  } >"$_ws_tmp" 2>/dev/null
  mv -f "$_ws_tmp" "$STATE_FILE" 2>/dev/null || rm -f "$_ws_tmp" 2>/dev/null
  unset _ws_tmp _ws_l _ws_p _ws_skip
  return 0
}

# ── Original values (captured before the module first writes anything) ──────
capture_originals() {
  [ -f "$ORIGINAL_FILE" ] && return 0
  mkdir -p "$DATA_DIR" 2>/dev/null
  _co_tmp="$ORIGINAL_FILE.tmp.$$"
  _co_settings_ok=0
  : >"$_co_tmp"
  for _co_k in $KEYS; do
    if read_live "$_co_k"; then
      printf '%s=%s\n' "$_co_k" "$LIVE" >>"$_co_tmp"
      case "$_co_k" in
        adbinstall | adbinput | mock_location_app) ;;
        *) _co_settings_ok=1 ;;
      esac
    fi
  done
  # Only keep the snapshot if the settings provider actually answered.
  if [ "$_co_settings_ok" -eq 1 ]; then
    chmod 600 "$_co_tmp" 2>/dev/null
    mv -f "$_co_tmp" "$ORIGINAL_FILE"
    log_info "Captured original values"
    _co_rc=0
  else
    rm -f "$_co_tmp"
    log_warn "Could not capture original values yet — settings provider not ready"
    _co_rc=1
  fi
  unset _co_tmp _co_k _co_settings_ok
  return "$_co_rc"
}

read_original() {
  _ro=""
  if [ -f "$ORIGINAL_FILE" ]; then
    while IFS= read -r _ro_l; do
      case "$_ro_l" in
        "$1="*) _ro=${_ro_l#*=} ;;
      esac
    done <"$ORIGINAL_FILE"
  fi
  printf '%s' "$_ro"
  unset _ro _ro_l
}

# restore_originals — shared by --restore. uninstall.sh carries its own copy
# of the same rules because it must work without this file.
restore_originals() {
  [ -f "$ORIGINAL_FILE" ] || return 1
  RESTORED=0
  for _ro_k in $KEYS; do
    grep -q "^$_ro_k=" "$ORIGINAL_FILE" 2>/dev/null || continue
    _ro_v=$(read_original "$_ro_k")
    case "$_ro_k:$_ro_v" in
      mock_location_app:none) ;;
      mock_location_app:*)
        case "$_ro_v" in '' | *[!A-Za-z0-9._,]*) continue ;; esac ;;
      adbinstall:* | adbinput:*)
        case "$_ro_v" in '' | [0-9] | [0-9][0-9]) ;; *) continue ;; esac ;;
      *:null) ;;
      *:'' | *:*[!0-9]*) continue ;;
    esac
    # Hidden Developer Options is the one state the user cannot leave on
    # their own, so it is always restored as visible.
    if [ "$_ro_k" = development_settings_enabled ]; then
      case "$_ro_v" in 0 | null) _ro_v=1 ;; esac
    fi
    set_live "$_ro_k" "$_ro_v"
    case "$_ro_v" in
      null) log_info "restored $_ro_k (removed — it did not exist before)" ;;
      '') log_info "restored $_ro_k (cleared — it was unset before)" ;;
      *) log_info "restored $_ro_k=$_ro_v" ;;
    esac
    RESTORED=$((RESTORED + 1))
  done
  unset _ro_k _ro_v
  return 0
}

# ── module.prop status ────────────────────────────────────────────────────────
STATUS_SUFFIXES="Working|Not Working|Stopped|Settings unavailable"

# update_module_prop <status> — compares against the file itself, so a fresh
# module.prop from an update gets its status back on the first pass (v5 kept
# the last status in the state file, which survives updates, and skipped it).
update_module_prop() {
  [ -f "$MODULE_PROP" ] || return 0
  _up_cur=""
  while IFS= read -r _up_l; do
    case "$_up_l" in
      description=*) _up_cur=${_up_l#description=} ;;
    esac
  done <"$MODULE_PROP"

  _up_base=$_up_cur
  _up_ifs=$IFS
  IFS='|'
  for _up_s in $STATUS_SUFFIXES; do
    case "$_up_base" in
      *" - $_up_s") _up_base=${_up_base%" - $_up_s"} ;;
    esac
  done
  IFS=$_up_ifs

  _up_new="$_up_base - $1"
  if [ "$_up_new" != "$_up_cur" ]; then
    _up_tmp="$MODULE_PROP.tmp.$$"
    while IFS= read -r _up_l; do
      case "$_up_l" in
        description=*) printf 'description=%s\n' "$_up_new" ;;
        *) printf '%s\n' "$_up_l" ;;
      esac
    done <"$MODULE_PROP" >"$_up_tmp" 2>/dev/null
    if [ -s "$_up_tmp" ]; then
      mv -f "$_up_tmp" "$MODULE_PROP" 2>/dev/null
      log_debug "module.prop status -> $1"
    else
      rm -f "$_up_tmp" 2>/dev/null
    fi
  fi
  unset _up_cur _up_base _up_new _up_tmp _up_l _up_s _up_ifs
  return 0
}

module_version() {
  _mv=""
  if [ -f "$MODULE_PROP" ]; then
    while IFS= read -r _mv_l; do
      case "$_mv_l" in
        version=*) _mv=${_mv_l#version=} ;;
      esac
    done <"$MODULE_PROP"
  fi
  printf '%s' "$_mv"
  unset _mv _mv_l
}

# ── Process helpers ───────────────────────────────────────────────────────────
# daemon_detach — leave the caller's cgroups and opt out of the low-memory
# killer. A daemon started from the WebUI is a child of the manager app's root
# shell and would otherwise be frozen or killed together with the app.
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
    # shellcheck disable=SC2086
    $CMD_SETSID "$@" </dev/null >/dev/null 2>&1 &
  elif [ -n "$CMD_NOHUP" ]; then
    # shellcheck disable=SC2086
    $CMD_NOHUP "$@" </dev/null >/dev/null 2>&1 &
  else
    "$@" </dev/null >/dev/null 2>&1 &
  fi
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

# wait_for_settings <timeout> — until the settings service answers properly.
wait_for_settings() {
  _ws=0
  while [ "$_ws" -lt "$1" ]; do
    read_live adb_enabled && {
      unset _ws
      return 0
    }
    sleep 2
    _ws=$((_ws + 2))
  done
  unset _ws
  return 1
}

# ── Mock location app scan ────────────────────────────────────────────────────
# Which installed apps request ACCESS_MOCK_LOCATION (the ones Settings offers,
# whether or not one is selected)?
#
# HyperOS 3 lists requested permissions only in single-package dumps, so the
# answer costs one `dumpsys package <pkg>` (~60 ms) per app. The scan is
# therefore incremental: `pm list packages -3 --show-versioncode` gives every
# user app with its version in one call, and only apps that are new or whose
# version changed are dumped again. Results are kept per package in
# MOCK_CACHE ("<pkg> <versionCode> <0|1>"); MOCK_STAMP holds the packages.xml
# mtime:size the cache matches, which makes the freshness check one stat.
# Mock location apps are never system apps.
MOCK_CACHE="$RUN_DIR/mock-scan"
MOCK_STAMP="$RUN_DIR/mock-scan.stamp"
MOCK_SCAN_LOCK="$LOCK_DIR/mock-scan"

packages_stamp() {
  [ -n "$CMD_STAT" ] && $CMD_STAT -c '%Y:%s' "$PACKAGES_XML" 2>/dev/null
}

# mock_cache_fresh — the cache matches the installed apps.
mock_cache_fresh() {
  [ -f "$MOCK_CACHE" ] && [ -f "$MOCK_STAMP" ] || return 1
  _mcf=""
  read -r _mcf <"$MOCK_STAMP" 2>/dev/null
  [ -n "$_mcf" ] && [ "$_mcf" = "$(packages_stamp)" ]
}

# mock_cached_apps — candidates from the cache, one per line (may be stale).
mock_cached_apps() {
  [ -f "$MOCK_CACHE" ] || return 0
  while read -r _mca_p _ _mca_m; do
    [ "$_mca_m" = 1 ] && printf '%s\n' "$_mca_p"
  done <"$MOCK_CACHE"
  unset _mca_p _mca_m
}

# mock_scan — bring the cache up to date. Returns 1 if another scan is running.
mock_scan() {
  mkdir -p "$RUN_DIR" "$LOCK_DIR" 2>/dev/null
  mkdir "$MOCK_SCAN_LOCK" 2>/dev/null || {
    # A scan is running, unless its owner is gone.
    _ms_o=""
    read -r _ms_o <"$MOCK_SCAN_LOCK/pid" 2>/dev/null
    if [ -n "$_ms_o" ] && pid_alive "$_ms_o"; then
      unset _ms_o
      return 1
    fi
    rm -rf "$MOCK_SCAN_LOCK"
    mkdir "$MOCK_SCAN_LOCK" 2>/dev/null || return 1
  }
  echo "$$" >"$MOCK_SCAN_LOCK/pid"

  _ms_stamp=$(packages_stamp)
  _ms_list=$(pm list packages -3 --show-versioncode 2>/dev/null)
  if [ -z "$_ms_list" ]; then
    # Package manager not answering — keep the old cache.
    rm -rf "$MOCK_SCAN_LOCK"
    unset _ms_stamp _ms_list _ms_o
    return 0
  fi

  _ms_tmp="$MOCK_CACHE.tmp.$$"
  _ms_new=0
  : >"$_ms_tmp"
  # Lines look like "package:com.example versionCode:123".
  printf '%s\n' "$_ms_list" | while read -r _ms_a _ms_b; do
    _ms_p=${_ms_a#package:}
    valid_pkg "$_ms_p" || continue
    _ms_v=${_ms_b#versionCode:}
    [ -n "$_ms_v" ] || _ms_v="?"
    _ms_hit=""
    if [ "$_ms_v" != "?" ] && [ -f "$MOCK_CACHE" ]; then
      while read -r _ms_cp _ms_cv _ms_cm; do
        if [ "$_ms_cp" = "$_ms_p" ] && [ "$_ms_cv" = "$_ms_v" ]; then
          _ms_hit=$_ms_cm
          break
        fi
      done <"$MOCK_CACHE"
    fi
    if [ -z "$_ms_hit" ]; then
      if dumpsys package "$_ms_p" 2>/dev/null |
        grep -c 'android\.permission\.ACCESS_MOCK_LOCATION' | grep -qv '^0$'; then
        _ms_hit=1
      else
        _ms_hit=0
      fi
    fi
    printf '%s %s %s\n' "$_ms_p" "$_ms_v" "$_ms_hit"
  done >"$_ms_tmp"

  if [ -s "$_ms_tmp" ]; then
    mv -f "$_ms_tmp" "$MOCK_CACHE"
    printf '%s\n' "$_ms_stamp" >"$MOCK_STAMP"
  fi
  rm -f "$_ms_tmp" 2>/dev/null
  rm -rf "$MOCK_SCAN_LOCK"
  unset _ms_stamp _ms_list _ms_tmp _ms_new _ms_o
  return 0
}

mock_scan_running() {
  _msr=""
  [ -d "$MOCK_SCAN_LOCK" ] && read -r _msr <"$MOCK_SCAN_LOCK/pid" 2>/dev/null
  [ -n "$_msr" ] && pid_alive "$_msr"
}

cleanup_legacy_runtime() {
  for _cl in $LEGACY_RUNTIME; do
    [ -e "$_cl" ] && rm -rf "$_cl" 2>/dev/null
  done
  unset _cl
  return 0
}
