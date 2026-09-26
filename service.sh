#!/system/bin/sh
# shellcheck shell=ash disable=SC1091,SC3043,SC2034,SC2154,SC3045
#
# service.sh — boot flow, the enforcement daemon, and every command the WebUI
# calls.
#
# How the daemon stays cheap (v6):
#
#   The settings provider saves settings_global.xml / settings_secure.xml by
#   writing a .new file and renaming it into place, and init does the same
#   with /data/property/persistent_properties. The daemon runs one busybox
#   inotifyd on those directories (plus its own data directory, for the config
#   file) and reads its output from a FIFO with the `read` builtin. Waiting,
#   filtering and timekeeping are all builtins: an idle daemon spawns nothing.
#
#   Each source is only checked for the keys it holds, and each has a
#   cooldown. HyperOS rewrites settings_secure.xml every few seconds for
#   unrelated reasons, so secure checks are rate-limited per profile, while
#   the quiet sources (global settings, properties) are checked within a
#   second. A full verification of every key still runs on a long timer as a
#   safety net.
#
#   Without inotifyd (or with engine=poll) the daemon falls back to a timed
#   poll that stats the same files and checks only what changed.

MODDIR="${0%/*}"
case "$MODDIR" in
  '' | "$0" | .) MODDIR="/data/adb/modules/dev-options-persist" ;;
esac

. "$MODDIR/sh/common.sh"

ensure_dirs

# ── Checking and applying ─────────────────────────────────────────────────────
# RES_<key> holds the last result for each key: ok | fail | unread | skip.
for _k in $KEYS; do
  eval "RES_$_k=''"
done
unset _k

APPLIED=0

# check_keys <keys> — verify and correct. Returns 1 if the apply lock was
# busy (another process is applying right now); the caller retries later.
check_keys() {
  lock_acquire "$APPLY_LOCK" 3 || return 1
  APPLIED=0
  for _ck_k in $1; do
    eval "_ck_want=\$CFG_$_ck_k"
    eval "_ck_prev=\$RES_$_ck_k"
    if [ "$_ck_want" = skip ]; then
      eval "RES_$_ck_k=skip"
      continue
    fi

    if ! read_live "$_ck_k"; then
      # During a reboot the settings service goes away before the daemon
      # is killed; that is expected and not worth a warning.
      if [ "$_ck_prev" != unread ]; then
        if [ -n "$(getprop sys.shutdown.requested 2>/dev/null)" ]; then
          log_debug "$_ck_k: settings service gone — shutting down"
        else
          log_warn "$_ck_k: settings service not answering — will retry"
        fi
      fi
      eval "RES_$_ck_k=unread"
      continue
    fi
    if [ "$LIVE" = "$_ck_want" ]; then
      eval "RES_$_ck_k=ok"
      continue
    fi

    _ck_old=${LIVE:-<unset>}
    set_live "$_ck_k" "$_ck_want"
    if read_live "$_ck_k" && [ "$LIVE" = "$_ck_want" ]; then
      log_info "$_ck_k: $_ck_old -> $_ck_want"
      APPLIED=$((APPLIED + 1))
      eval "RES_$_ck_k=ok"
    else
      # Logged once per failure streak, not on every retry.
      [ "$_ck_prev" = fail ] ||
        log_error "$_ck_k could not be set to $_ck_want (still ${LIVE:-unreadable})"
      eval "RES_$_ck_k=fail"
    fi
  done
  lock_release "$APPLY_LOCK"

  if [ "$APPLIED" -gt 0 ]; then
    write_state "APPLIES=$(($(read_state_num APPLIES) + APPLIED))" \
      "LAST_APPLY=$(date +%s)"
    log_rotate
  fi
  refresh_status
  unset _ck_k _ck_want _ck_prev _ck_old
  return 0
}

# refresh_status — Not Working if any key failed; Working once every managed
# key has been verified. While the settings service is down the previous
# status is kept rather than flapping.
refresh_status() {
  _rs_fail=0
  _rs_unread=0
  _rs_unknown=0
  for _rs_k in $KEYS; do
    eval "_rs_v=\$RES_$_rs_k"
    case "$_rs_v" in
      fail) _rs_fail=1 ;;
      unread) _rs_unread=1 ;;
      '') _rs_unknown=1 ;;
    esac
  done
  if [ "$_rs_fail" -eq 1 ]; then
    update_module_prop "Not Working"
  elif [ "$_rs_unread" -eq 0 ] && [ "$_rs_unknown" -eq 0 ]; then
    update_module_prop "Working"
  fi
  unset _rs_fail _rs_unread _rs_unknown _rs_k _rs_v
}

# ── Daemon lifecycle ──────────────────────────────────────────────────────────
WPID=""
SLEEP_PID=""

daemon_shutdown() {
  trap - TERM INT HUP USR1
  [ -n "$WPID" ] && kill "$WPID" 2>/dev/null
  [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
  rm -f "$PID_FILE" "$WATCHER_PID_FILE" "$FIFO" 2>/dev/null
  write_state "DAEMON=stopped" "DAEMON_PID=0" "WATCHER_PID=0"
  update_module_prop "Stopped"
  log_info "Daemon stopping (pid $$)"
  exit 0
}

# USR1 from `--config`: in the poll engine, wake up now instead of at the end
# of the tick. (The event engine sees the config file change on its own.)
WAKE=0
daemon_wake() {
  WAKE=1
  [ -n "$SLEEP_PID" ] && kill "$SLEEP_PID" 2>/dev/null
}

apply_profile() {
  set_profile_vars "$CFG_profile"
  ACTIVE_PROFILE=$CFG_profile
}

# on_config_change — reload, then re-check everything against the new values.
on_config_change() {
  _occ_engine=$CFG_engine
  load_config warn
  log_debug "Config reloaded"
  if [ "$CFG_profile" != "$ACTIVE_PROFILE" ]; then
    apply_profile
    now_up
    NEXT_FULL=$((NOW + FULL))
    write_state "PROFILE=$CFG_profile"
    log_info "Profile is now $CFG_profile"
  fi
  if [ "$CFG_engine" != "$_occ_engine" ]; then
    log_info "Engine setting changed to $CFG_engine — switching"
    RESELECT=1
  fi
  DG=1 DS=1 DP=1
  DUE_G=0 DUE_S=0 DUE_P=0
  unset _occ_engine
}

# process_dirty — run the checks that are due. Cooldowns only delay a check;
# a dirty flag is never dropped without the check having run.
process_dirty() {
  now_up
  if [ "$NOW" -ge "$NEXT_FULL" ]; then
    check_keys "$KEYS" && {
      DG=0 DS=0 DP=0
      DUE_G=$((NOW + CD_FAST)) DUE_S=$((NOW + CD_SECURE)) DUE_P=$((NOW + CD_FAST))
      NEXT_FULL=$((NOW + FULL))
      log_debug "Full verification"
    }
    return 0
  fi
  if [ "$DG" -eq 1 ] && [ "$NOW" -ge "$DUE_G" ]; then
    check_keys "$KEYS_GLOBAL" && { DG=0; DUE_G=$((NOW + CD_FAST)); }
  fi
  if [ "$DS" -eq 1 ] && [ "$NOW" -ge "$DUE_S" ]; then
    check_keys "$KEYS_SECURE" && { DS=0; DUE_S=$((NOW + CD_SECURE)); }
  fi
  if [ "$DP" -eq 1 ] && [ "$NOW" -ge "$DUE_P" ]; then
    check_keys "$KEYS_PROP" && { DP=0; DUE_P=$((NOW + CD_FAST)); }
  fi
  return 0
}

# next_timeout <cap> — seconds until the next due check, into T.
next_timeout() {
  T=$((NEXT_FULL - NOW))
  [ "$DG" -eq 1 ] && [ $((DUE_G - NOW)) -lt "$T" ] && T=$((DUE_G - NOW))
  [ "$DS" -eq 1 ] && [ $((DUE_S - NOW)) -lt "$T" ] && T=$((DUE_S - NOW))
  [ "$DP" -eq 1 ] && [ $((DUE_P - NOW)) -lt "$T" ] && T=$((DUE_P - NOW))
  [ "$T" -gt "$1" ] && T=$1
  [ "$T" -lt 1 ] && T=1
}

# ── Event engine ──────────────────────────────────────────────────────────────
WATCH_CAP=60 # the watcher's health is checked at least this often
W_RESTARTS=0
W_WINDOW=0

start_watcher() {
  rm -f "$FIFO" 2>/dev/null
  [ -n "$CMD_MKFIFO" ] || return 1
  $CMD_MKFIFO "$FIFO" 2>/dev/null || return 1
  # Opened read-write so the open never blocks and a dead writer cannot turn
  # every read into an instant EOF. Death is detected by pid_alive instead.
  exec 3<>"$FIFO"
  # shellcheck disable=SC2086
  $CMD_INOTIFYD - "$SETTINGS_DIR:y" "$PROP_DIR:y" "$DATA_DIR:wy" \
    >&3 2>/dev/null </dev/null &
  WPID=$!
  echo "$WPID" >"$WATCHER_PID_FILE" 2>/dev/null
  write_state "WATCHER_PID=$WPID"
  return 0
}

stop_watcher() {
  [ -n "$WPID" ] && kill "$WPID" 2>/dev/null
  [ -n "$WPID" ] && wait "$WPID" 2>/dev/null
  WPID=""
  exec 3<&- 2>/dev/null
  rm -f "$FIFO" "$WATCHER_PID_FILE" 2>/dev/null
}

# restart_watcher — returns 1 after five restarts in ten minutes, which means
# inotify does not work here and the poll engine should take over.
restart_watcher() {
  now_up
  if [ $((NOW - W_WINDOW)) -gt 600 ]; then
    W_WINDOW=$NOW
    W_RESTARTS=0
  fi
  W_RESTARTS=$((W_RESTARTS + 1))
  [ "$W_RESTARTS" -gt 5 ] && return 1
  log_warn "Event watcher exited — restarting it"
  stop_watcher
  start_watcher || return 1
  # Anything could have changed while it was down.
  DG=1 DS=1 DP=1
  return 0
}

loop_events() {
  if ! start_watcher; then
    log_warn "Could not start the event watcher — using the poll engine"
    return 2
  fi
  write_state "MODE=events" "INTERVAL=0"
  log_info "Event engine running (inotifyd pid $WPID; cooldowns ${CD_FAST}s/${CD_SECURE}s, full check every ${FULL}s)"

  while :; do
    now_up
    next_timeout "$WATCH_CAP"
    _ev="" _dir="" _name=""
    WAKE=0
    if read -t "$T" -r _ev _dir _name <&3; then
      case "$_ev" in
        *o* | *x*) DG=1 DS=1 DP=1 ;; # queue overflow / watch lost
      esac
      case "$_dir" in
        "$SETTINGS_DIR")
          case "$_name" in
            settings_global.xml) DG=1 ;;
            settings_secure.xml) DS=1 ;;
          esac ;;
        "$PROP_DIR")
          [ "$_name" = persistent_properties ] && DP=1 ;;
        "$DATA_DIR")
          [ "$_name" = config ] && on_config_change ;;
      esac
    elif ! pid_alive "$WPID"; then
      restart_watcher || {
        log_error "Event watcher keeps exiting — switching to the poll engine"
        stop_watcher
        return 2
      }
    fi
    process_dirty
    if [ "$RESELECT" -eq 1 ]; then
      stop_watcher
      return 0
    fi
  done
}

# ── Poll engine ───────────────────────────────────────────────────────────────
poll_fingerprint() {
  [ -n "$CMD_STAT" ] || return 0
  # shellcheck disable=SC2086
  $CMD_STAT -c %Y "$SETTINGS_GLOBAL_XML" "$SETTINGS_SECURE_XML" \
    "$PROP_FILE" "$CONFIG_FILE" 2>/dev/null | tr '\n' ' '
}

loop_poll() {
  write_state "MODE=poll" "INTERVAL=$POLL" "WATCHER_PID=0"
  log_info "Poll engine running (every ${POLL}s, full check every ${FULL}s)"
  # shellcheck disable=SC2046
  set -- $(poll_fingerprint)
  _pg=$1 _ps=$2 _pp=$3 _pc=$4

  while :; do
    sleep "$POLL" &
    SLEEP_PID=$!
    wait "$SLEEP_PID"
    SLEEP_PID=""

    if [ -n "$CMD_STAT" ]; then
      # shellcheck disable=SC2046
      set -- $(poll_fingerprint)
      [ "$1" != "$_pg" ] && DG=1
      [ "$2" != "$_ps" ] && DS=1
      [ "$3" != "$_pp" ] && DP=1
      if [ "$4" != "$_pc" ] || [ "$WAKE" -eq 1 ]; then
        WAKE=0
        on_config_change
        write_state "INTERVAL=$POLL"
      fi
      _pg=$1 _ps=$2 _pp=$3 _pc=$4
    else
      [ "$WAKE" -eq 1 ] && {
        WAKE=0
        on_config_change
      }
      load_config
      DG=1 DS=1 DP=1
    fi
    # No cooldowns here: the tick already is one.
    DUE_G=0 DUE_S=0 DUE_P=0
    process_dirty
    [ "$RESELECT" -eq 1 ] && return 0
  done
}

# ── Daemon entry ──────────────────────────────────────────────────────────────
daemon_main() {
  if daemon_is_running && [ "$(daemon_pid)" != "$$" ]; then
    log_warn "Daemon already running (pid $(daemon_pid)) — not starting a second one"
    return 0
  fi

  daemon_detach
  # Traps first: `--config` signals whatever the PID file names.
  trap 'daemon_shutdown' TERM INT HUP
  trap 'daemon_wake' USR1
  echo "$$" >"$PID_FILE"

  load_config warn
  apply_profile
  write_state "DAEMON=running" "DAEMON_PID=$$" "STARTED=$(date +%s)" \
    "PROFILE=$CFG_profile" "WATCHER_PID=0" "PAUSED=0"
  log_sep "Daemon started (pid $$, profile $CFG_profile, engine $CFG_engine)"

  # Everything is checked once at start.
  now_up
  DG=0 DS=0 DP=0
  DUE_G=0 DUE_S=0 DUE_P=0
  NEXT_FULL=0
  process_dirty
  if [ "$APPLIED" -gt 0 ]; then
    log_info "Start-up check: $APPLIED correction(s)"
  fi

  while :; do
    RESELECT=0
    _dm_rc=2
    if [ "$CFG_engine" = auto ] && [ -n "$CMD_INOTIFYD" ] &&
      [ -d "$SETTINGS_DIR" ] && [ -d "$PROP_DIR" ]; then
      loop_events
      _dm_rc=$?
    fi
    if [ "$_dm_rc" -eq 2 ]; then
      [ "$CFG_engine" = auto ] && [ -z "$CMD_INOTIFYD" ] &&
        log_warn "busybox inotifyd not found — using the poll engine"
      loop_poll
    fi
  done
}

# ── Commands ──────────────────────────────────────────────────────────────────
cmd_apply() {
  load_config
  check_keys "$KEYS" || {
    echo "applied=0"
    echo "rc=1"
    return 1
  }
  log_info "Manual apply: $APPLIED correction(s)"
  echo "applied=$APPLIED"
  if daemon_is_running; then
    echo "daemon=running"
  else
    if [ "$(read_state_num PAUSED)" -eq 1 ]; then
      log_info "Resuming enforcement"
    else
      log_warn "Daemon was not running — starting it"
    fi
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
  # A running daemon would put the managed values straight back, so
  # enforcement is paused until Apply Now or the next reboot.
  if daemon_is_running; then
    cmd_daemon_stop >/dev/null
    _cr_paused=1
  else
    _cr_paused=0
  fi
  lock_acquire "$APPLY_LOCK" 5
  restore_originals
  lock_release "$APPLY_LOCK"
  if [ "$_cr_paused" -eq 1 ]; then
    write_state "PAUSED=1"
    log_info "Enforcement paused — press Apply Now or reboot to resume"
  fi
  echo "restored=$RESTORED"
  echo "paused=$_cr_paused"
  echo "rc=0"
  unset _cr_paused
  return 0
}

cmd_config() {
  _cc_ok=0
  case " $KEYS " in
    *" $1 "*)
      case "$2" in 0 | 1 | skip) _cc_ok=1 ;; esac ;;
    *)
      case "$1:$2" in
        profile:fast | profile:balanced | profile:battery) _cc_ok=1 ;;
        log_level:0 | log_level:1 | log_level:2) _cc_ok=1 ;;
        engine:auto | engine:poll) _cc_ok=1 ;;
      esac ;;
  esac
  if [ "$_cc_ok" -ne 1 ]; then
    echo "rc=1"
    return 1
  fi

  write_cfg "$1" "$2" || {
    echo "rc=1"
    return 1
  }
  load_config
  log_info "Config: $1=$2"
  daemon_is_running && kill -USR1 "$(daemon_pid)" 2>/dev/null

  # Applied right here so the UI sees the result immediately. The daemon
  # also notices the config change and re-checks; by then it matches.
  APPLIED=0
  case " $KEYS " in
    *" $1 "*) check_keys "$1" ;;
  esac

  echo "applied=$APPLIED"
  echo "rc=0"
  unset _cc_ok
  return 0
}

cmd_daemon_start() {
  if daemon_is_running; then
    echo "daemon=already-running"
    echo "rc=0"
    return 0
  fi
  # shellcheck disable=SC2086
  spawn_detached $DAEMON_SH "$MODDIR/service.sh" --daemon
  _i=0
  while [ "$_i" -lt 10 ]; do
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
  if kill_verified "$_p" "$DAEMON_NEEDLE" 3; then
    log_info "Daemon stopped (was pid $_p)"
  fi
  # A daemon killed with -9 cannot stop its watcher itself.
  kill_verified "$(read_pidfile "$WATCHER_PID_FILE")" "inotifyd" 1
  rm -f "$PID_FILE" "$WATCHER_PID_FILE" "$FIFO" 2>/dev/null
  write_state "DAEMON=stopped" "DAEMON_PID=0" "WATCHER_PID=0"
  echo "daemon=stopped"
  echo "rc=0"
  unset _p
  return 0
}

cmd_status() {
  load_config
  set_profile_vars "$CFG_profile"

  _drift=0
  for _st_k in $KEYS; do
    eval "_st_want=\$CFG_$_st_k"
    if read_live "$_st_k"; then
      _st_live=$LIVE
      _st_ok=1
    else
      _st_live="unreadable"
      _st_ok=0
    fi
    printf 'CFG_%s=%s\n' "$_st_k" "$_st_want"
    printf 'LIVE_%s=%s\n' "$_st_k" "$_st_live"
    printf 'ORIG_%s=%s\n' "$_st_k" "$(read_original "$_st_k")"
    printf 'KIND_%s=%s\n' "$_st_k" "$(key_kind "$_st_k")"
    printf 'TARGET_%s=%s\n' "$_st_k" "$(key_target "$_st_k")"
    printf 'LABEL_%s=%s\n' "$_st_k" "$(key_label "$_st_k")"
    if [ "$_st_want" = skip ]; then
      printf 'MATCH_%s=skip\n' "$_st_k"
    elif [ "$_st_ok" -eq 1 ] && [ "$_st_live" = "$_st_want" ]; then
      printf 'MATCH_%s=1\n' "$_st_k"
    else
      printf 'MATCH_%s=0\n' "$_st_k"
      _drift=$((_drift + 1))
    fi
  done

  if daemon_is_running; then
    _dstate="running"
    _mode=$(read_state MODE)
    _wpid=$(read_state WATCHER_PID)
  else
    _dstate="stopped"
    _mode="none"
    _wpid=0
  fi

  printf 'KEYS=%s\n' "$KEYS"
  printf 'VERSION=%s\n' "$(module_version)"
  printf 'DAEMON=%s\n' "$_dstate"
  printf 'DAEMON_PID=%s\n' "$(daemon_pid)"
  printf 'STARTED=%s\n' "$(read_state STARTED)"
  printf 'MODE=%s\n' "${_mode:-none}"
  printf 'WATCHER_PID=%s\n' "${_wpid:-0}"
  printf 'ENGINE=%s\n' "$CFG_engine"
  printf 'PAUSED=%s\n' "$(read_state_num PAUSED)"
  printf 'INOTIFYD=%s\n' "$([ -n "$CMD_INOTIFYD" ] && echo 1 || echo 0)"
  printf 'PROFILE=%s\n' "$CFG_profile"
  printf 'CD_FAST=%s\n' "$CD_FAST"
  printf 'CD_SECURE=%s\n' "$CD_SECURE"
  printf 'FULL=%s\n' "$FULL"
  printf 'POLL=%s\n' "$POLL"
  # Kept for the v5 WebUI until it is updated.
  if [ "$_mode" = poll ]; then
    printf 'POLL_BASE=%s\nPOLL_MAX=%s\n' "$POLL" "$FULL"
  else
    printf 'POLL_BASE=%s\nPOLL_MAX=%s\n' "$CD_SECURE" "$FULL"
  fi
  printf 'MTIME_GATE=1\n'
  printf 'APPLIES=%s\n' "$(read_state_num APPLIES)"
  printf 'LAST_APPLY=%s\n' "$(read_state LAST_APPLY)"
  printf 'DRIFT=%s\n' "$_drift"
  printf 'HAS_ORIGINAL=%s\n' "$([ -f "$ORIGINAL_FILE" ] && echo 1 || echo 0)"
  printf 'LOG_LEVEL=%s\n' "$CFG_log_level"
  printf 'LOG_SIZE=%s\n' "$(file_size "$LOG_FILE")"
  printf 'BUSYBOX=%s\n' "${BUSYBOX:-none}"
  printf 'NOW=%s\n' "$(date +%s)"
  printf 'rc=0\n'
  unset _st_k _st_want _st_live _st_ok _drift _dstate _mode _wpid
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
  if daemon_is_running; then
    log_warn "service.sh started while the daemon is running (pid $(daemon_pid)) — ignored"
    return 0
  fi
  # Anything in run/ is from the previous boot.
  rm -f "$PID_FILE" "$WATCHER_PID_FILE" "$FIFO" "$STATE_FILE".tmp.* 2>/dev/null
  rm -rf "$LOCK_DIR" 2>/dev/null
  mkdir -p "$LOCK_DIR" 2>/dev/null
  cleanup_legacy_runtime

  wait_for_prop sys.boot_completed 1 180
  migrate_legacy_config
  ensure_config
  load_config
  log_rotate

  if ! command -v settings >/dev/null 2>&1; then
    log_error "The 'settings' command is unavailable — nothing can be enforced"
  elif ! wait_for_settings 90; then
    log_warn "Settings service still not answering after boot — continuing"
  fi

  log_sep "Boot $(module_version) (profile $CFG_profile, engine $CFG_engine)"
  capture_originals
  daemon_main
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
  --daemon) daemon_main ;;
  --daemon-start) cmd_daemon_start ;;
  --daemon-stop) cmd_daemon_stop ;;
  '') boot_flow ;;
  *)
    echo "unknown command: $1"
    echo "rc=1"
    exit 1
    ;;
esac
