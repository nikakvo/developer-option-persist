#!/system/bin/sh
# shellcheck shell=ash disable=SC1091,SC3043,SC2034,SC2154
#
# service.sh — boot flow, the enforcement daemon, and every command the WebUI
# calls.
#
# Battery notes, because this is the whole point of v4:
#
#   v3 ran a fixed 3-second loop. Each pass re-read all five config keys with
#   grep|cut|tr (15 processes), queried three settings and two properties, then
#   called update_module_status which read everything a SECOND time and rewrote
#   module.prop with sed -i. That is ~41 process spawns and one flash write
#   every 3 seconds — roughly 1.18 million spawns and 28,800 writes per day,
#   keeping the CPU from settling into deep sleep around the clock.
#
#   v4 keeps the config in shell variables, gates the expensive checks behind a
#   single stat() on the settings XML files, backs the interval off while idle,
#   and only touches module.prop when the status string actually changes. An
#   idle pass is 4 processes (sleep + stat + two getprop), and after a minute of
#   quiet the interval stretches to the profile maximum.

MODDIR="${0%/*}"
case "$MODDIR" in
  '' | "$0") MODDIR="/data/adb/modules/dev-options-persist" ;;
esac

. "$MODDIR/sh/common.sh"

mkdir -p "$DATA_DIR" "$LOG_DIR" "$LOCK_DIR" 2>/dev/null

# ── Daemon process helpers ────────────────────────────────────────────────────
daemon_pid() {
  _d=$(cat "$PID_FILE" 2>/dev/null)
  case "$_d" in
    '' | *[!0-9]*) _d=0 ;;
  esac
  printf '%s' "$_d"
  unset _d
}

daemon_is_running() {
  _dr=$(daemon_pid)
  [ "$_dr" -gt 0 ] || return 1
  [ -d "/proc/$_dr" ] || return 1
  grep -q 'service.sh' "/proc/$_dr/cmdline" 2>/dev/null || return 1
  unset _dr
  return 0
}

daemon_shutdown() {
  log_info "Daemon stopping (pid $$)"
  write_state "DAEMON=stopped" "DAEMON_PID=0"
  rm -f "$PID_FILE" 2>/dev/null
  exit 0
}

# ── Status string shown in module.prop ────────────────────────────────────────
BASE_DESC="Keeps USB debugging, Install via USB and extended power menu enabled while hiding Developer Options"

update_module_prop() {
  # Only rewrite when the status actually changed. v3 rewrote this file on
  # every single loop pass.
  _ump_new="$1"
  [ "$_ump_new" = "$(read_state MODULE_PROP_STATUS)" ] && {
    unset _ump_new
    return 0
  }
  [ -f "$MODULE_PROP" ] || {
    unset _ump_new
    return 0
  }

  _ump_tmp="$MODULE_PROP.tmp.$$"
  # Rebuilt with a plain read loop instead of sed -i, so nothing in the text
  # can ever be interpreted as a sed replacement pattern.
  {
    while IFS= read -r _ump_line; do
      case "$_ump_line" in
        description=*) printf 'description=%s - %s\n' "$BASE_DESC" "$_ump_new" ;;
        *) printf '%s\n' "$_ump_line" ;;
      esac
    done <"$MODULE_PROP"
  } >"$_ump_tmp" 2>/dev/null

  if [ -s "$_ump_tmp" ]; then
    mv -f "$_ump_tmp" "$MODULE_PROP" 2>/dev/null
    write_state "MODULE_PROP_STATUS=$_ump_new"
    log_debug "module.prop status -> $_ump_new"
  else
    rm -f "$_ump_tmp" 2>/dev/null
  fi
  unset _ump_new _ump_tmp _ump_line
  return 0
}

# ── Apply ─────────────────────────────────────────────────────────────────────
# Sets APPLIED (number of corrections) and DRIFT_OK (1 = everything matches).
apply_all() {
  APPLIED=0
  DRIFT_OK=1

  # The settings provider is gone during shutdown and not yet up early in boot.
  # A read then returns nothing at all — not "null", which is what an unset
  # setting looks like. Every write in the pass would fail, and the old code
  # logged one ERROR per key with an empty "(still )" value, which reads like a
  # broken module when it is really just a reboot in progress.
  _aa_probe=$(settings get global adb_enabled 2>/dev/null)
  if [ -z "$_aa_probe" ]; then
    log_warn "Settings provider is not responding (shutting down or still booting) — pass skipped"
    unset _aa_probe
    return 0
  fi
  unset _aa_probe

  for _aa_k in $KEYS; do
    eval "_aa_want=\$CFG_$_aa_k"
    case "$_aa_want" in
      '' | skip) continue ;;
    esac

    _aa_live=$(get_live "$_aa_k")
    [ "$_aa_live" = "$_aa_want" ] && continue

    set_live "$_aa_k" "$_aa_want"
    APPLIED=$((APPLIED + 1))

    _aa_now=$(get_live "$_aa_k")
    if [ "$_aa_now" = "$_aa_want" ]; then
      log_info "$_aa_k: $_aa_live -> $_aa_want"
    else
      DRIFT_OK=0
      log_error "$_aa_k could not be set to $_aa_want (still $_aa_now)"
    fi
  done

  if [ "$APPLIED" -gt 0 ]; then
    write_state "APPLIES=$(($(read_state_num APPLIES) + APPLIED))" \
      "LAST_APPLY=$(date +%s)"
  fi

  if [ "$DRIFT_OK" -eq 1 ]; then
    update_module_prop "Working"
  else
    update_module_prop "Not Working"
  fi

  unset _aa_k _aa_want _aa_live _aa_now
  return 0
}

read_state_num() {
  _rsn=$(read_state "$1")
  case "$_rsn" in
    '' | *[!0-9]*) _rsn=0 ;;
  esac
  printf '%s' "$_rsn"
  unset _rsn
}

# Fingerprint of everything that could mean "something changed": the two
# settings databases and our own config file. One stat call for all three.
fingerprint() {
  [ "$MTIME_GATE" -eq 1 ] || return 0
  $CMD_STAT -c %Y "$SETTINGS_GLOBAL_XML" "$SETTINGS_SECURE_XML" "$CONFIG_FILE" 2>/dev/null
}

# ── The daemon ────────────────────────────────────────────────────────────────
daemon_loop() {
  if daemon_is_running && [ "$(daemon_pid)" != "$$" ]; then
    log_warn "Daemon already running (pid $(daemon_pid)) — not starting a second one"
    return 0
  fi

  daemon_detach
  echo "$$" >"$PID_FILE"
  trap 'daemon_shutdown' TERM INT HUP

  load_config
  BASE=$(profile_base "$CFG_profile")
  MAXI=$(profile_max "$CFG_profile")
  FULL=$(profile_full "$CFG_profile")

  # Without stat we cannot gate on mtime, so fall back to a slow full poll
  # rather than hammering the settings provider.
  if [ "$MTIME_GATE" -eq 0 ]; then
    BASE="$MAXI"
    log_warn "mtime gate unavailable — falling back to a ${MAXI}s full poll"
  fi

  INTERVAL="$BASE"
  IDLE=0
  ELAPSED=0
  CHECKS=0
  FP=$(fingerprint)

  log_sep "Daemon started (pid $$, profile $CFG_profile, ${BASE}-${MAXI}s)"
  write_state "DAEMON=running" "DAEMON_PID=$$" "STARTED=$(date +%s)" \
    "PROFILE=$CFG_profile" "INTERVAL=$INTERVAL" "MTIME_GATE=$MTIME_GATE"

  while true; do
    sleep "$INTERVAL"

    NEED=0
    ELAPSED=$((ELAPSED + INTERVAL))
    CHECKS=$((CHECKS + 1))

    # 1. Cheap gate: did either settings database or our config change?
    if [ "$MTIME_GATE" -eq 1 ]; then
      NEW_FP=$(fingerprint)
      if [ "$NEW_FP" != "$FP" ]; then
        NEED=1
        FP="$NEW_FP"
      fi
    else
      NEED=1
    fi

    # 2. Properties are not covered by the settings databases, but getprop is
    #    a single cheap read, so managed properties are checked every pass.
    if [ "$NEED" -eq 0 ]; then
      case "$CFG_adbinstall" in
        '' | skip) ;;
        *) [ "$(getprop persist.security.adbinstall)" = "$CFG_adbinstall" ] || NEED=1 ;;
      esac
    fi
    if [ "$NEED" -eq 0 ]; then
      case "$CFG_adbinput" in
        '' | skip) ;;
        *) [ "$(getprop persist.security.adbinput)" = "$CFG_adbinput" ] || NEED=1 ;;
      esac
    fi

    # 3. Safety net: a full verification at least every FULL seconds, in case
    #    a ROM writes settings somewhere the gate cannot see.
    if [ "$ELAPSED" -ge "$FULL" ]; then
      NEED=1
      ELAPSED=0
    fi

    if [ "$NEED" -eq 1 ]; then
      if [ "$(file_mtime "$CONFIG_FILE")" != "$CFG_MTIME" ]; then
        load_config
        log_debug "Config reloaded"
        _nb=$(profile_base "$CFG_profile")
        MAXI=$(profile_max "$CFG_profile")
        FULL=$(profile_full "$CFG_profile")
        [ "$MTIME_GATE" -eq 1 ] && BASE="$_nb" || BASE="$MAXI"
        unset _nb
      fi

      apply_all
      log_rotate

      # Our own writes bumped the databases; re-read so the next pass does not
      # see them as an external change.
      FP=$(fingerprint)

      INTERVAL="$BASE"
      IDLE=0
    else
      IDLE=$((IDLE + 1))
      # Back off once the device has been quiet for a while.
      if [ "$IDLE" -ge 4 ] && [ "$INTERVAL" -ne "$MAXI" ]; then
        INTERVAL="$MAXI"
        log_debug "Idle — interval backed off to ${MAXI}s"
      fi
    fi
  done
}

# ── Commands ──────────────────────────────────────────────────────────────────
cmd_apply() {
  load_config
  apply_all
  log_info "Manual apply: $APPLIED correction(s)"
  echo "applied=$APPLIED"
  if daemon_is_running; then
    echo "daemon=running"
  else
    log_warn "Daemon was not running — starting it"
    cmd_daemon_start >/dev/null
    daemon_is_running && echo "daemon=restarted" || echo "daemon=failed"
  fi
  echo "rc=0"
}

cmd_restore() {
  if [ ! -f "$ORIGINAL_FILE" ]; then
    log_error "No original snapshot to restore from"
    echo "rc=1"
    return 1
  fi
  log_sep "Restoring original values"
  for _cr_k in $KEYS; do
    _cr_v=$(read_original "$_cr_k")
    case "$_cr_v" in
      '' | null) continue ;;
    esac
    # Hidden Developer Options is the one state a user cannot get out of on
    # their own. If the snapshot was taken while they were already hidden
    # (e.g. upgrading from v3, which had no snapshot at all), restoring that
    # value verbatim would trap them, so it is always restored as visible.
    if [ "$_cr_k" = "development_settings_enabled" ] && [ "$_cr_v" = "0" ]; then
      _cr_v=1
      log_warn "snapshot had Developer Options hidden — restoring them as visible instead"
    fi
    set_live "$_cr_k" "$_cr_v"
    log_info "restored $_cr_k=$_cr_v"
  done
  unset _cr_k _cr_v
  echo "rc=0"
  return 0
}

cmd_config() {
  case " $KEYS " in
    *" $1 "*)
      case "$2" in
        0 | 1 | skip) ;;
        *)
          echo "rc=1"
          return 1
          ;;
      esac
      ;;
    *)
      case "$1" in
        profile)
          case "$2" in
            fast | balanced | battery) ;;
            *)
              echo "rc=1"
              return 1
              ;;
          esac
          ;;
        log_level)
          case "$2" in
            0 | 1 | 2) ;;
            *)
              echo "rc=1"
              return 1
              ;;
          esac
          ;;
        *)
          echo "rc=1"
          return 1
          ;;
      esac
      ;;
  esac

  write_cfg "$1" "$2" || {
    echo "rc=1"
    return 1
  }
  load_config
  log_info "Config: $1=$2"

  # Apply immediately so the UI does not have to wait for the next poll.
  apply_all

  # A profile change does NOT restart the daemon. The config file is part of
  # the daemon's mtime fingerprint, so it reloads the new intervals on its own
  # next pass. Restarting from here used to replace a healthy boot-started
  # daemon with one parented to the manager app, which then died with the app.
  if [ "$1" = "profile" ]; then
    log_info "Profile change picked up on the next daemon pass"
  fi

  echo "applied=$APPLIED"
  echo "rc=0"
  return 0
}

cmd_daemon_start() {
  if daemon_is_running; then
    echo "daemon=already-running"
    echo "rc=0"
    return 0
  fi
  spawn_detached sh "$MODDIR/service.sh" --daemon
  _i=0
  while [ "$_i" -lt 5 ]; do
    sleep 1
    if daemon_is_running; then
      echo "daemon=started"
      echo "rc=0"
      unset _i
      return 0
    fi
    _i=$((_i + 1))
  done
  log_error "Daemon failed to start"
  echo "daemon=failed"
  echo "rc=1"
  unset _i
  return 1
}

cmd_daemon_stop() {
  _p=$(daemon_pid)
  if [ "$_p" -gt 0 ] && [ -d "/proc/$_p" ]; then
    kill "$_p" 2>/dev/null
    _i=0
    while [ -d "/proc/$_p" ] && [ "$_i" -lt 4 ]; do
      sleep 1
      _i=$((_i + 1))
    done
    [ -d "/proc/$_p" ] && kill -9 "$_p" 2>/dev/null
    log_info "Daemon stopped (was pid $_p)"
  fi
  rm -f "$PID_FILE" 2>/dev/null
  write_state "DAEMON=stopped" "DAEMON_PID=0"
  echo "daemon=stopped"
  echo "rc=0"
  unset _p _i
  return 0
}

cmd_status() {
  load_config

  _drift=0
  for _st_k in $KEYS; do
    eval "_st_want=\$CFG_$_st_k"
    _st_live=$(get_live "$_st_k")
    printf 'CFG_%s=%s\n' "$_st_k" "$_st_want"
    printf 'LIVE_%s=%s\n' "$_st_k" "$_st_live"
    printf 'ORIG_%s=%s\n' "$_st_k" "$(read_original "$_st_k")"
    printf 'KIND_%s=%s\n' "$_st_k" "$(key_kind "$_st_k")"
    printf 'TARGET_%s=%s\n' "$_st_k" "$(key_target "$_st_k")"
    printf 'LABEL_%s=%s\n' "$_st_k" "$(key_label "$_st_k")"
    case "$_st_want" in
      '' | skip) printf 'MATCH_%s=skip\n' "$_st_k" ;;
      *)
        if [ "$_st_live" = "$_st_want" ]; then
          printf 'MATCH_%s=1\n' "$_st_k"
        else
          printf 'MATCH_%s=0\n' "$_st_k"
          _drift=$((_drift + 1))
        fi
        ;;
    esac
  done

  if daemon_is_running; then
    _dstate="running"
  else
    _dstate="stopped"
  fi

  printf 'KEYS=%s\n' "$KEYS"
  printf 'VERSION=%s\n' "$(sed -n 's/^version=//p' "$MODULE_PROP" 2>/dev/null | head -n 1)"
  printf 'DAEMON=%s\n' "$_dstate"
  printf 'DAEMON_PID=%s\n' "$(daemon_pid)"
  printf 'STARTED=%s\n' "$(read_state STARTED)"
  printf 'PROFILE=%s\n' "$CFG_profile"
  printf 'POLL_BASE=%s\n' "$(profile_base "$CFG_profile")"
  printf 'POLL_MAX=%s\n' "$(profile_max "$CFG_profile")"
  printf 'MTIME_GATE=%s\n' "$MTIME_GATE"
  printf 'APPLIES=%s\n' "$(read_state_num APPLIES)"
  printf 'LAST_APPLY=%s\n' "$(read_state LAST_APPLY)"
  printf 'DRIFT=%s\n' "$_drift"
  printf 'HAS_ORIGINAL=%s\n' "$([ -f "$ORIGINAL_FILE" ] && echo 1 || echo 0)"
  printf 'LOG_LEVEL=%s\n' "$CFG_log_level"
  printf 'LOG_SIZE=%s\n' "$(file_size "$LOG_FILE")"
  printf 'BUSYBOX=%s\n' "${BUSYBOX:-none}"
  printf 'NOW=%s\n' "$(date +%s)"
  printf 'rc=0\n'
  unset _st_k _st_want _st_live _drift _dstate
}

cmd_log() {
  _l="${1:-300}"
  case "$_l" in
    '' | *[!0-9]*) _l=300 ;;
  esac
  tail -n "$_l" "$LOG_FILE" 2>/dev/null
  unset _l
}

cmd_clear_log() {
  : >"$LOG_FILE" 2>/dev/null
  log_info "Log cleared from the UI"
  echo "rc=0"
}

cmd_b64cmd() {
  if [ -n "$CMD_BASE64" ]; then
    printf '%s\n' "$CMD_BASE64"
  else
    printf 'base64\n'
  fi
}

# ── Boot flow ─────────────────────────────────────────────────────────────────
boot_flow() {
  wait_for_prop sys.boot_completed 1 180
  sleep 5 # let the settings provider settle

  migrate_legacy_config
  [ -f "$CONFIG_FILE" ] || write_default_config
  load_config
  log_rotate
  log_sep "Boot (profile $CFG_profile, mtime gate $MTIME_GATE)"

  if ! command -v settings >/dev/null 2>&1; then
    log_error "The 'settings' command is unavailable — nothing can be enforced"
  fi

  capture_originals
  apply_all
  log_info "Boot apply: $APPLIED correction(s)"

  daemon_loop
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
case "$1" in
  --status) cmd_status ;;
  --log) cmd_log "$2" ;;
  --clear-log) cmd_clear_log ;;
  --b64cmd) cmd_b64cmd ;;
  --apply) cmd_apply ;;
  --restore) cmd_restore ;;
  --config) cmd_config "$2" "$3" ;;
  --daemon) daemon_loop ;;
  --daemon-start) cmd_daemon_start ;;
  --daemon-stop) cmd_daemon_stop ;;
  '') boot_flow ;;
  *)
    echo "unknown command: $1"
    echo "rc=1"
    exit 1
    ;;
esac
