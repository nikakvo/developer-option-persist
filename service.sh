#!/system/bin/sh
# shellcheck shell=ash disable=SC1091,SC3043,SC2034,SC2154,SC3045
#
# service.sh - boot flow, the enforcement daemon, and every command the WebUI
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

# The WebUI and the command line start this under the system shell (mksh).
# There every $(...) costs about 20 ms on HyperOS, against under 2 ms in
# busybox ash, and --status took 2.5 s instead of 0.4 s. So it re-runs
# itself under the root manager's busybox, as the boot scripts already do.
if [ -z "$BB_ASH_VERSION" ] && [ -z "$DOP_REEXEC" ]; then
  for _bb in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /data/adb/ap/bin/busybox; do
    if [ -x "$_bb" ] && [ -f "$0" ]; then
      DOP_REEXEC=1
      export DOP_REEXEC
      exec "$_bb" sh "$0" "$@"
    fi
  done
  unset _bb
fi

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

# check_keys <keys> - verify and correct. Returns 1 if the apply lock was
# busy (another process is applying right now); the caller retries later.
check_keys() {
  APPLIED=0
  # Nothing to do for keys that are not managed and were never written:
  # no lock, no process at all (HyperOS rewrites settings_secure.xml every
  # few seconds, also when extended_power_menu is skip).
  _ck_need=0
  for _ck_k in $1; do
    eval "_ck_want=\$CFG_$_ck_k"
    if [ "$_ck_want" != skip ] || is_touched "$_ck_k"; then
      _ck_need=1
      break
    fi
  done
  if [ "$_ck_need" -eq 0 ]; then
    for _ck_k in $1; do
      eval "RES_$_ck_k=skip"
    done
    refresh_status
    unset _ck_k _ck_want _ck_need
    return 0
  fi

  lock_acquire "$APPLY_LOCK" 3 || return 1
  for _ck_k in $1; do
    eval "_ck_want=\$CFG_$_ck_k"
    eval "_ck_prev=\$RES_$_ck_k"
    if [ "$_ck_want" = skip ] && is_touched "$_ck_k"; then
      # The key is about to be handed back. The config this pass started
      # with may be stale (the WebUI can have managed the key again a moment
      # ago), so the file is read once more first.
      load_config
      eval "_ck_want=\$CFG_$_ck_k"
      if [ "$_ck_want" = skip ]; then
        # Handed back to the user: from now on Restore Original and
        # uninstall leave this key alone. An invalid value in a hand-edited
        # file only counts as skip for now; it does not hand the key back.
        case "$CFG_BAD " in
          *" $_ck_k="*) ;;
          *)
            set_touched "$_ck_k" 0
            log_info "$_ck_k: no longer managed - left as it is" ;;
        esac
      fi
    fi
    if [ "$_ck_want" = skip ]; then
      eval "RES_$_ck_k=skip"
      continue
    fi
    # adb_enabled=usb: the wanted value follows the cable.
    key_want "$_ck_k"
    _ck_want=$WANT
    if [ "$_ck_want" = nodetect ]; then
      [ "$_ck_prev" = fail ] ||
        log_error "$_ck_k=usb: this device does not show the USB cable state - USB debugging left as it is"
      eval "RES_$_ck_k=fail"
      continue
    fi

    if ! read_live "$_ck_k"; then
      # During a reboot the services go away before the daemon is killed;
      # that is expected, and the rest of the pass is skipped.
      if system_down; then
        log_debug "$_ck_k: system shutting down - checks skipped"
        eval "RES_$_ck_k=unread"
        break
      fi
      [ "$_ck_prev" = unread ] ||
        log_warn "$_ck_k: settings service not answering - will retry"
      eval "RES_$_ck_k=unread"
      continue
    fi
    if [ "$LIVE" = "$_ck_want" ]; then
      eval "RES_$_ck_k=ok"
      continue
    fi
    # A value that looks wrong while the system is going down is not trusted:
    # an unset-looking property then usually just means the property service
    # has stopped.
    if system_down; then
      log_debug "$_ck_k: system shutting down - not correcting"
      break
    fi

    # The first write since the module took this key over: the snapshot
    # gets the value from right before it, and the key is marked as one to
    # put back on Restore Original and uninstall.
    if ! is_touched "$_ck_k"; then
      set_original "$_ck_k" "$LIVE_RAW"
      set_touched "$_ck_k" 1
      log_info "Captured original $_ck_k=${LIVE_RAW:-<unset>}"
    fi

    _ck_old=${LIVE:-<unset>}
    set_live "$_ck_k" "$_ck_want"
    if read_live "$_ck_k" && [ "$LIVE" = "$_ck_want" ]; then
      log_info "$_ck_k: $_ck_old -> $_ck_want"
      APPLIED=$((APPLIED + 1))
      eval "RES_$_ck_k=ok"
    else
      # The chosen mock location app was uninstalled: Android has already
      # dropped its permission, so the choice is released instead of being
      # reported as a failure forever.
      if [ "$_ck_k" = mock_location_app ] && [ "$(pkg_state "$_ck_want")" = missing ]; then
        if write_cfg mock_location_app skip; then
          CFG_mock_location_app=skip
          set_touched mock_location_app 0
          eval "RES_$_ck_k=skip"
          log_info "mock_location_app: $_ck_want was uninstalled - no longer managed"
        fi
        continue
      fi
      # Unreadable after the write: the service went away in between. That
      # is "not answering", not a failed write.
      if ! read_live "$_ck_k"; then
        if system_down; then
          log_debug "$_ck_k: system shutting down - checks skipped"
        elif [ "$_ck_prev" != unread ]; then
          log_warn "$_ck_k: settings service not answering - will retry"
        fi
        eval "RES_$_ck_k=unread"
        continue
      fi
      # Logged once per failure streak, not on every retry.
      [ "$_ck_prev" = fail ] ||
        log_error "$_ck_k could not be set to $_ck_want (still ${LIVE:-<unset>})"
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
  unset _ck_k _ck_want _ck_prev _ck_old _ck_need
  return 0
}

# refresh_status - Not Working if any key failed; Working once every managed
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

# on_config_change - reload, then re-check everything against the new values.
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
    log_info "Engine setting changed to $CFG_engine - switching"
    RESELECT=1
  fi
  DG=1 DS=1 DP=1 DA=1
  DUE_G=0 DUE_S=0 DUE_P=0 DUE_A=0
  unset _occ_engine
}

# usb_watch - with adb_enabled=usb, a cable change makes the global keys due
# at once. Builtins only; called on every pass of the daemon loop.
CABLE_LAST=""
usb_watch() {
  if [ "$CFG_adb_enabled" != usb ]; then
    CABLE_LAST=""
    return 0
  fi
  usb_cable
  [ "$CABLE" = "$CABLE_LAST" ] && return 0
  if [ -n "$CABLE_LAST" ]; then
    case "$CABLE" in
      1) log_info "USB: connected to a computer" ;;
      0) log_info "USB: no computer connected" ;;
    esac
  fi
  CABLE_LAST=$CABLE
  DG=1
  DUE_G=0
}

# usb_cap - how long the daemon may wait before the next usb_watch, into T.
usb_cap() {
  [ "$CFG_adb_enabled" = usb ] && [ "$T" -gt "$USB_POLL" ] && T=$USB_POLL
  return 0
}

# process_dirty - run the checks that are due. Cooldowns only delay a check;
# a dirty flag is never dropped without the check having run.
process_dirty() {
  now_up
  if [ "$NOW" -ge "$NEXT_FULL" ]; then
    check_keys "$KEYS" && {
      DG=0 DS=0 DP=0 DA=0
      DUE_G=$((NOW + CD_FAST)) DUE_S=$((NOW + CD_SECURE)) DUE_P=$((NOW + CD_FAST))
      DUE_A=$((NOW + CD_FAST))
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
  if [ "$DA" -eq 1 ] && [ "$NOW" -ge "$DUE_A" ]; then
    check_keys "$KEYS_APPOP" && { DA=0; DUE_A=$((NOW + CD_FAST)); }
  fi
  return 0
}

# next_timeout <cap> - seconds until the next due check, into T.
next_timeout() {
  T=$((NEXT_FULL - NOW))
  [ "$DG" -eq 1 ] && [ $((DUE_G - NOW)) -lt "$T" ] && T=$((DUE_G - NOW))
  [ "$DS" -eq 1 ] && [ $((DUE_S - NOW)) -lt "$T" ] && T=$((DUE_S - NOW))
  [ "$DP" -eq 1 ] && [ $((DUE_P - NOW)) -lt "$T" ] && T=$((DUE_P - NOW))
  [ "$DA" -eq 1 ] && [ $((DUE_A - NOW)) -lt "$T" ] && T=$((DUE_A - NOW))
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
  # packages.xml is written in place (Android 14+ ResilientAtomicFile), so
  # /data/system also needs close-write events, not only renames.
  $CMD_INOTIFYD - "$SETTINGS_DIR:y" "$PROP_DIR:y" "$SYSTEM_DIR:wy" "$DATA_DIR:wy" \
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

# restart_watcher - returns 1 after five restarts in ten minutes, which means
# inotify does not work here and the poll engine should take over.
restart_watcher() {
  now_up
  if [ $((NOW - W_WINDOW)) -gt 600 ]; then
    W_WINDOW=$NOW
    W_RESTARTS=0
  fi
  W_RESTARTS=$((W_RESTARTS + 1))
  [ "$W_RESTARTS" -gt 5 ] && return 1
  log_warn "Event watcher exited - restarting it"
  stop_watcher
  start_watcher || return 1
  # Anything could have changed while it was down.
  DG=1 DS=1 DP=1 DA=1
  return 0
}

loop_events() {
  if ! start_watcher; then
    log_warn "Could not start the event watcher - using the poll engine"
    return 2
  fi
  write_state "MODE=events" "INTERVAL=0"
  log_info "Event engine running (inotifyd pid $WPID; cooldowns ${CD_FAST}s/${CD_SECURE}s, full check every ${FULL}s)"

  while :; do
    now_up
    next_timeout "$WATCH_CAP"
    usb_cap
    _ev="" _dir="" _name=""
    WAKE=0
    if read -t "$T" -r _ev _dir _name <&3; then
      case "$_ev" in
        *o* | *x*) DG=1 DS=1 DP=1 DA=1 ;; # queue overflow / watch lost
      esac
      case "$_dir" in
        "$SETTINGS_DIR")
          case "$_name" in
            settings_global.xml) DG=1 ;;
            settings_secure.xml | settings_system.xml) DS=1 ;;
          esac ;;
        "$PROP_DIR")
          [ "$_name" = persistent_properties ] && DP=1 ;;
        "$SYSTEM_DIR")
          # AppOps are saved about 10 s after a change; packages.xml moves
          # when an app is installed, updated or removed.
          case "$_name" in
            appops_accesses.xml | appops.xml | packages.xml) DA=1 ;;
          esac ;;
        "$DATA_DIR")
          case "$_name" in
            config | custom) on_config_change ;;
          esac ;;
      esac
    elif ! pid_alive "$WPID"; then
      restart_watcher || {
        log_error "Event watcher keeps exiting - switching to the poll engine"
        stop_watcher
        return 2
      }
    fi
    usb_watch
    process_dirty
    if [ "$RESELECT" -eq 1 ]; then
      stop_watcher
      return 0
    fi
  done
}

# ── Poll engine ───────────────────────────────────────────────────────────────
# poll_fingerprint - "<file> <mtime>" per existing file. Parsed by name, so
# a missing file cannot shift the others.
poll_fingerprint() {
  [ -n "$CMD_STAT" ] || return 0
  # shellcheck disable=SC2086
  $CMD_STAT -c '%n %Y' "$SETTINGS_GLOBAL_XML" "$SETTINGS_SECURE_XML" \
    "$SETTINGS_SYSTEM_XML" "$PROP_FILE" "$CONFIG_FILE" "$CUSTOM_FILE" \
    "$SYSTEM_DIR/appops_accesses.xml" \
    "$SYSTEM_DIR/appops.xml" "$PACKAGES_XML" 2>/dev/null
}

# read_fingerprint - sets F_G F_S F_P F_C F_A from poll_fingerprint.
read_fingerprint() {
  F_G="" F_S="" F_P="" F_C="" F_A=""
  while read -r _rf_n _rf_t; do
    case "$_rf_n" in
      "$SETTINGS_GLOBAL_XML") F_G=$_rf_t ;;
      "$SETTINGS_SECURE_XML" | "$SETTINGS_SYSTEM_XML") F_S="$F_S$_rf_t." ;;
      "$PROP_FILE") F_P=$_rf_t ;;
      "$CONFIG_FILE" | "$CUSTOM_FILE") F_C="$F_C$_rf_t." ;;
      *) F_A="$F_A$_rf_t." ;;
    esac
  done <<FP
$(poll_fingerprint)
FP
  unset _rf_n _rf_t
}

loop_poll() {
  write_state "MODE=poll" "INTERVAL=$POLL" "WATCHER_PID=0"
  log_info "Poll engine running (every ${POLL}s, full check every ${FULL}s)"
  read_fingerprint
  _pg=$F_G _ps=$F_S _pp=$F_P _pc=$F_C _pa=$F_A
  now_up
  _pnext=$((NOW + POLL))

  while :; do
    # With adb_enabled=usb the tick is shortened to USB_POLL for the cable
    # check; the files are still compared only once per POLL.
    T=$POLL
    usb_cap
    sleep "$T" &
    SLEEP_PID=$!
    wait "$SLEEP_PID"
    SLEEP_PID=""
    now_up
    usb_watch
    if [ "$NOW" -lt "$_pnext" ] && [ "$WAKE" -eq 0 ]; then
      DUE_G=0
      process_dirty
      [ "$RESELECT" -eq 1 ] && return 0
      continue
    fi
    _pnext=$((NOW + POLL))

    if [ -n "$CMD_STAT" ]; then
      read_fingerprint
      [ "$F_G" != "$_pg" ] && DG=1
      [ "$F_S" != "$_ps" ] && DS=1
      [ "$F_P" != "$_pp" ] && DP=1
      [ "$F_A" != "$_pa" ] && DA=1
      if [ "$F_C" != "$_pc" ] || [ "$WAKE" -eq 1 ]; then
        WAKE=0
        on_config_change
        write_state "INTERVAL=$POLL"
      fi
      _pg=$F_G _ps=$F_S _pp=$F_P _pc=$F_C _pa=$F_A
    else
      [ "$WAKE" -eq 1 ] && {
        WAKE=0
        on_config_change
      }
      load_config
      DG=1 DS=1 DP=1 DA=1
    fi
    # No cooldowns here: the tick already is one.
    DUE_G=0 DUE_S=0 DUE_P=0 DUE_A=0
    process_dirty
    [ "$RESELECT" -eq 1 ] && return 0
  done
}

# ── Daemon entry ──────────────────────────────────────────────────────────────
daemon_main() {
  if daemon_is_running && [ "$(daemon_pid)" != "$$" ]; then
    log_warn "Daemon already running (pid $(daemon_pid)) - not starting a second one"
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
  DG=0 DS=0 DP=0 DA=0
  DUE_G=0 DUE_S=0 DUE_P=0 DUE_A=0
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
        log_warn "busybox inotifyd not found - using the poll engine"
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
      log_warn "Daemon was not running - starting it"
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
  load_config
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
    log_info "Enforcement paused - press Apply Now or reboot to resume"
  fi
  echo "restored=$RESTORED"
  echo "paused=$_cr_paused"
  echo "rc=0"
  unset _cr_paused
  return 0
}

# --snapshot - takes the current value of every setting the module has
# changed as its new original, so Restore Original and uninstall put back
# today's values instead of the ones from before the module. Keys the module
# has not written yet keep their normal behaviour (snapshot right before the
# first write).
cmd_snapshot() {
  load_config
  ensure_touched
  if ! lock_acquire "$APPLY_LOCK" 5; then
    echo "error=busy"
    echo "rc=1"
    return 1
  fi
  _cs_n=0
  _cs_bad=0
  for _cs_k in $KEYS; do
    is_touched "$_cs_k" || continue
    if read_live "$_cs_k"; then
      set_original "$_cs_k" "$LIVE_RAW"
      log_info "snapshot: $_cs_k=$LIVE_RAW"
      _cs_n=$((_cs_n + 1))
    else
      log_warn "snapshot: $_cs_k unreadable - old original kept"
      _cs_bad=$((_cs_bad + 1))
    fi
  done
  lock_release "$APPLY_LOCK"
  log_info "New snapshot taken: $_cs_n value(s), $_cs_bad unreadable"
  echo "snapped=$_cs_n"
  echo "unreadable=$_cs_bad"
  echo "rc=0"
  unset _cs_n _cs_bad _cs_k
  return 0
}

# --export - writes the current config (managed keys + tuning, already
# validated by load_config) to EXPORT_DIR/dop-config-<date>.txt.
cmd_export() {
  load_config
  if ! mkdir -p "$EXPORT_DIR" 2>/dev/null || [ ! -d "$EXPORT_DIR" ]; then
    log_error "Export: cannot create $EXPORT_DIR"
    echo "error=no-dir"
    echo "rc=1"
    return 1
  fi
  _ce_name="dop-config-$(date '+%Y%m%d-%H%M%S' 2>/dev/null).txt"
  _ce_tmp="$EXPORT_DIR/.$_ce_name.tmp"
  {
    printf '# Dev Options Persist config export\n'
    printf '# version '; module_version; printf '\n'
    printf '# created %s\n' "$(_ts)"
    for _ce_k in $BASE_KEYS; do
      eval "_ce_v=\$CFG_$_ce_k"
      printf '%s=%s\n' "$_ce_k" "$_ce_v"
    done
    for _ce_k in $CUSTOM_KEYS; do
      key_info "$_ce_k"
      eval "_ce_v=\$CFG_$_ce_k"
      printf 'custom=%s %s %s\n' "$KIND" "$TARGET" "$_ce_v"
    done
    printf 'profile=%s\nlog_level=%s\nengine=%s\n' "$CFG_profile" "$CFG_log_level" "$CFG_engine"
  } >"$_ce_tmp" 2>/dev/null
  if [ -s "$_ce_tmp" ] && mv -f "$_ce_tmp" "$EXPORT_DIR/$_ce_name" 2>/dev/null; then
    log_info "Export: config saved to $EXPORT_DIR/$_ce_name"
    echo "file=$_ce_name"
    echo "dir=$EXPORT_DIR"
    echo "rc=0"
    _ce_rc=0
  else
    rm -f "$_ce_tmp" 2>/dev/null
    log_error "Export: could not write $EXPORT_DIR/$_ce_name"
    echo "error=write"
    echo "rc=1"
    _ce_rc=1
  fi
  unset _ce_name _ce_tmp _ce_k _ce_v
  return "$_ce_rc"
}

# --backups - lists the config files in EXPORT_DIR, newest first:
# BACKUP=<name>|<size in bytes>
cmd_backups() {
  echo "dir=$EXPORT_DIR"
  if [ -d "$EXPORT_DIR" ]; then
    # ls -t sorts by time; names are checked below, so odd files are skipped.
    for _cb_f in $(ls -t "$EXPORT_DIR" 2>/dev/null); do
      case "$_cb_f" in
        *[!A-Za-z0-9._-]* | .*) continue ;;
        *.txt | *.conf) ;;
        *) continue ;;
      esac
      [ -f "$EXPORT_DIR/$_cb_f" ] || continue
      echo "BACKUP=$_cb_f|$(file_size "$EXPORT_DIR/$_cb_f")"
    done
  fi
  echo "rc=0"
  unset _cb_f
}

# --import <file name> - reads a config file from EXPORT_DIR and applies
# every valid line through --config, so each value gets the same checks as a
# tap in the WebUI. Invalid or unknown lines are skipped and logged.
cmd_import() {
  case "$1" in
    '' | *[!A-Za-z0-9._-]* | .*)
      echo "error=bad-name"
      echo "rc=1"
      return 1 ;;
  esac
  _ci_f="$EXPORT_DIR/$1"
  if [ ! -f "$_ci_f" ]; then
    echo "error=not-found"
    echo "rc=1"
    return 1
  fi
  # A config file is a few hundred bytes; anything big is not one.
  if [ "$(file_size "$_ci_f")" -gt 16384 ]; then
    log_warn "Import: $1 is too big to be a config file - ignored"
    echo "error=too-big"
    echo "rc=1"
    return 1
  fi
  log_sep "Importing config from $1"
  load_config
  _ci_set=0
  _ci_same=0
  _ci_bad=0
  _ci_pairs=""
  _ci_cust=""
  while IFS= read -r _ci_l || [ -n "$_ci_l" ]; do
    case "$_ci_l" in
      *=*) ;;
      *) continue ;;
    esac
    _t=${_ci_l%%=*}
    _trim
    _ci_k=$_t
    _t=${_ci_l#*=}
    _trim
    _ci_v=$_t
    case "$_ci_k" in
      '' | '#'*) continue ;;
    esac
    # custom=<kind> <target> <value>
    if [ "$_ci_k" = custom ]; then
      set -f
      # shellcheck disable=SC2086
      set -- $_ci_v
      set +f
      if [ "$#" -eq 3 ] && valid_custom_target "$1" "$2" && valid_custom_value "$3"; then
        _ci_cust="$_ci_cust $1|$2|$3"
      else
        log_warn "Import: skipped invalid line: custom=$_ci_v"
        _ci_bad=$((_ci_bad + 1))
      fi
      continue
    fi
    _ci_ok=0
    case " $BASE_KEYS " in
      *" $_ci_k "*) valid_value "$_ci_k" "$_ci_v" && _ci_ok=1 ;;
      *)
        case "$_ci_k:$_ci_v" in
          profile:fast | profile:balanced | profile:battery) _ci_ok=1 ;;
          log_level:0 | log_level:1 | log_level:2) _ci_ok=1 ;;
          engine:auto | engine:poll) _ci_ok=1 ;;
        esac ;;
    esac
    if [ "$_ci_ok" -ne 1 ]; then
      log_warn "Import: skipped invalid line: $_ci_k=$_ci_v"
      _ci_bad=$((_ci_bad + 1))
      continue
    fi
    _ci_pairs="$_ci_pairs $_ci_k=$_ci_v"
  done <"$_ci_f"

  # Applied after reading, so the file is closed before any write.
  for _ci_p in $_ci_pairs; do
    _ci_k=${_ci_p%%=*}
    _ci_v=${_ci_p#*=}
    load_config
    eval "_ci_cur=\$CFG_$_ci_k"
    if [ "$_ci_cur" = "$_ci_v" ]; then
      _ci_same=$((_ci_same + 1))
      continue
    fi
    case "$(cmd_config "$_ci_k" "$_ci_v")" in
      *rc=0*) _ci_set=$((_ci_set + 1)) ;;
      *)
        log_warn "Import: $_ci_k=$_ci_v not applied on this device"
        _ci_bad=$((_ci_bad + 1)) ;;
    esac
  done
  for _ci_p in $_ci_cust; do
    _ci_kind=${_ci_p%%|*}
    _ci_v=${_ci_p##*|}
    _ci_t=${_ci_p#*|}
    _ci_t=${_ci_t%|*}
    load_config
    _ci_have=0
    for _ci_k in $CUSTOM_KEYS; do
      key_info "$_ci_k"
      eval "_ci_cur=\$CFG_$_ci_k"
      [ "$KIND" = "$_ci_kind" ] && [ "$TARGET" = "$_ci_t" ] && [ "$_ci_cur" = "$_ci_v" ] && _ci_have=1
    done
    if [ "$_ci_have" -eq 1 ]; then
      _ci_same=$((_ci_same + 1))
      continue
    fi
    case "$(cmd_custom_add "$_ci_kind" "$_ci_t" "$_ci_v")" in
      *rc=0*) _ci_set=$((_ci_set + 1)) ;;
      *)
        log_warn "Import: custom $_ci_kind/$_ci_t=$_ci_v not added"
        _ci_bad=$((_ci_bad + 1)) ;;
    esac
  done
  log_info "Import done: $_ci_set changed, $_ci_same already set, $_ci_bad skipped"
  echo "changed=$_ci_set"
  echo "same=$_ci_same"
  echo "skipped=$_ci_bad"
  echo "rc=0"
  unset _ci_f _ci_set _ci_same _ci_bad _ci_pairs _ci_l _ci_k _ci_v _ci_ok _ci_p _ci_cur _t \
    _ci_cust _ci_kind _ci_t _ci_have
  return 0
}

# write_custom <skip id> <set id> <kind> <target> <value> - rewrites
# CUSTOM_FILE from the loaded custom keys: drops <skip id>, and sets (or
# appends) <set id>. Needs load_config first.
write_custom() {
  lock_acquire "$CONFIG_LOCK" 5 || {
    log_warn "config lock busy, custom keys not written"
    return 1
  }
  _wcu_tmp="$CUSTOM_FILE.tmp.$$"
  _wcu_done=0
  {
    printf '# Custom keys: <id> <kind> <target> <value>. Managed by the WebUI.\n'
    for _wcu_k in $CUSTOM_KEYS; do
      [ "$_wcu_k" = "$1" ] && continue
      if [ "$_wcu_k" = "$2" ]; then
        printf '%s %s %s %s\n' "$2" "$3" "$4" "$5"
        _wcu_done=1
        continue
      fi
      key_info "$_wcu_k"
      eval "_wcu_v=\$CFG_$_wcu_k"
      printf '%s %s %s %s\n' "$_wcu_k" "$KIND" "$TARGET" "$_wcu_v"
    done
    [ -n "$2" ] && [ "$_wcu_done" -eq 0 ] && printf '%s %s %s %s\n' "$2" "$3" "$4" "$5"
  } >"$_wcu_tmp" 2>/dev/null
  _wcu_rc=1
  if [ -s "$_wcu_tmp" ]; then
    chmod 600 "$_wcu_tmp" 2>/dev/null
    mv -f "$_wcu_tmp" "$CUSTOM_FILE" 2>/dev/null && _wcu_rc=0
  fi
  rm -f "$_wcu_tmp" 2>/dev/null
  lock_release "$CONFIG_LOCK"
  unset _wcu_tmp _wcu_done _wcu_k _wcu_v
  return "$_wcu_rc"
}

# --custom-add <kind> <target> <value> - manage any setting: kind is global,
# secure, system or prop (persist.* only). The same kind + target again
# changes the value.
cmd_custom_add() {
  if ! valid_custom_target "$1" "$2"; then
    echo "error=bad-target"
    echo "rc=1"
    return 1
  fi
  if ! valid_custom_value "$3"; then
    echo "error=bad-value"
    echo "rc=1"
    return 1
  fi
  load_config
  _cca_id=""
  _cca_max=0
  _cca_n=0
  for _cca_k in $CUSTOM_KEYS; do
    _cca_n=$((_cca_n + 1))
    _cca_num=${_cca_k#c}
    [ "$_cca_num" -gt "$_cca_max" ] && _cca_max=$_cca_num
    key_info "$_cca_k"
    [ "$KIND" = "$1" ] && [ "$TARGET" = "$2" ] && _cca_id=$_cca_k
  done
  _cca_new=0
  if [ -z "$_cca_id" ]; then
    if [ "$_cca_n" -ge "$CUSTOM_MAX" ] || [ "$_cca_max" -ge 999 ]; then
      echo "error=full"
      echo "rc=1"
      unset _cca_id _cca_max _cca_n _cca_k _cca_num _cca_new
      return 1
    fi
    _cca_id="c$((_cca_max + 1))"
    _cca_new=1
  fi
  # A new id may have been used by a deleted key: start it clean, so its
  # snapshot is taken fresh right before the first write.
  if [ "$_cca_new" -eq 1 ] && lock_acquire "$APPLY_LOCK" 5; then
    set_touched "$_cca_id" 0
    drop_original "$_cca_id"
    lock_release "$APPLY_LOCK"
  fi
  if ! write_custom "" "$_cca_id" "$1" "$2" "$3"; then
    echo "rc=1"
    unset _cca_id _cca_max _cca_n _cca_k _cca_num _cca_new
    return 1
  fi
  load_config
  if [ "$_cca_new" -eq 1 ]; then
    log_info "Custom: added $1/$2=$3"
  else
    log_info "Custom: $1/$2 is now $3"
  fi
  daemon_is_running && kill -USR1 "$(daemon_pid)" 2>/dev/null
  APPLIED=0
  check_keys "$_cca_id"
  echo "id=$_cca_id"
  echo "applied=$APPLIED"
  echo "rc=0"
  unset _cca_id _cca_max _cca_n _cca_k _cca_num _cca_new
  return 0
}

# --custom-peek <kind> <target> - prints the current value, so the WebUI can
# show it before the key is added. Read only.
cmd_custom_peek() {
  case "$2" in
    '' | .* | *[!A-Za-z0-9_.-]*)
      echo "error=bad-target"
      echo "rc=1"
      return 1 ;;
  esac
  case "$1:$2" in
    global:* | secure:* | system:*) _cp_v=$(settings get "$1" "$2" 2>/dev/null) ;;
    prop:persist.?*) _cp_v=$(getprop "$2" 2>/dev/null) ;;
    *)
      echo "error=bad-target"
      echo "rc=1"
      return 1 ;;
  esac
  case "$_cp_v" in
    *'Failure calling'* | *'Exception'* | *'cmd: '*)
      echo "error=unreadable"
      echo "rc=1"
      unset _cp_v
      return 1 ;;
  esac
  printf 'value=%s\n' "$_cp_v"
  echo "rc=0"
  unset _cp_v
}

# --custom-names <kind> - every name of that kind with its current value, for
# the suggestions in the WebUI: N=<name>|<value>. Read only. Names that the
# module could not manage are left out.
cmd_custom_names() {
  case "$1" in
    global | secure | system)
      settings list "$1" 2>/dev/null | while IFS= read -r _cn_l; do
        _cn_k=${_cn_l%%=*}
        case "$_cn_k" in '' | .* | *[!A-Za-z0-9_.-]*) continue ;; esac
        [ "$_cn_k" = "$_cn_l" ] && continue
        printf 'N=%s|%.40s\n' "$_cn_k" "${_cn_l#*=}"
      done ;;
    prop)
      getprop 2>/dev/null | while IFS= read -r _cn_l; do
        case "$_cn_l" in '[persist.'*']: ['*) ;; *) continue ;; esac
        _cn_k=${_cn_l#\[}
        _cn_k=${_cn_k%%]*}
        case "$_cn_k" in *[!A-Za-z0-9_.-]*) continue ;; esac
        _cn_v=${_cn_l#*]: \[}
        printf 'N=%s|%.40s\n' "$_cn_k" "${_cn_v%]}"
      done ;;
    *)
      echo "error=bad-kind"
      echo "rc=1"
      return 1 ;;
  esac
  echo "rc=0"
}

# --custom-del <id> - stop managing a custom key. Like "not managed" for the
# built-in keys, the setting is left as it is now.
cmd_custom_del() {
  load_config
  case " $CUSTOM_KEYS " in
    *" $1 "*) ;;
    *)
      echo "error=not-found"
      echo "rc=1"
      return 1 ;;
  esac
  key_info "$1"
  _ccd_kind=$KIND
  _ccd_t=$TARGET
  if ! write_custom "$1" ""; then
    echo "rc=1"
    unset _ccd_kind _ccd_t
    return 1
  fi
  if lock_acquire "$APPLY_LOCK" 5; then
    set_touched "$1" 0
    drop_original "$1"
    lock_release "$APPLY_LOCK"
  fi
  load_config
  log_info "Custom: removed $_ccd_kind/$_ccd_t - left as it is"
  daemon_is_running && kill -USR1 "$(daemon_pid)" 2>/dev/null
  echo "rc=0"
  unset _ccd_kind _ccd_t
  return 0
}

cmd_config() {
  _cc_ok=0
  # Custom keys are changed with --custom-add, not here.
  case " $BASE_KEYS " in
    *" $1 "*)
      valid_value "$1" "$2" && _cc_ok=1 ;;
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
  if [ "$1" = adb_enabled ] && [ "$2" = usb ]; then
    usb_cable
    if [ "$CABLE" = none ]; then
      log_warn "adb_enabled=usb: this device does not show the USB cable state - not set"
      echo "error=no-usb-detect"
      echo "rc=1"
      return 1
    fi
  fi
  if [ "$1" = mock_location_app ] && [ "$2" != skip ] &&
    [ "$(pkg_state "$2")" = missing ]; then
    log_warn "mock_location_app: $2 is not installed - not set"
    echo "error=not-installed"
    echo "rc=1"
    return 1
  fi

  write_cfg "$1" "$2" || {
    echo "rc=1"
    return 1
  }
  load_config
  # A log level change is always written, also when the new level is 0, so
  # the WebUI log shows it at once.
  if [ "$1" = log_level ]; then _log INFO "Config: $1=$2"; else log_info "Config: $1=$2"; fi
  daemon_is_running && kill -USR1 "$(daemon_pid)" 2>/dev/null

  # Applied right here so the UI sees the result immediately. The daemon
  # also notices the config change and re-checks; by then it matches.
  APPLIED=0
  case " $KEYS " in
    *" $1 "*) check_keys "$1" ;;
  esac
  # check_keys hands a key set to skip back at once (needs the apply lock);
  # if the lock was busy, do it here so the next takeover is captured fresh.
  if [ "$2" = skip ] && is_touched "$1" && lock_acquire "$APPLY_LOCK" 5; then
    if is_touched "$1"; then
      set_touched "$1" 0
      log_info "$1: no longer managed - left as it is"
    fi
    lock_release "$APPLY_LOCK"
  fi

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

  # Printed straight from the helpers instead of through $(...): every
  # subshell is a fork, and this runs on every WebUI refresh.
  _drift=0
  usb_cable
  _st_cable=$CABLE
  live_cache_fill
  for _st_k in $KEYS; do
    eval "_st_want=\$CFG_$_st_k"
    key_want "$_st_k"
    _st_now=$WANT
    if read_live "$_st_k"; then
      _st_live=$LIVE
      _st_ok=1
    else
      _st_live="unreadable"
      _st_ok=0
    fi
    printf 'CFG_%s=%s\n' "$_st_k" "$_st_want"
    printf 'WANT_%s=%s\n' "$_st_k" "$_st_now"
    printf 'LIVE_%s=%s\n' "$_st_k" "$_st_live"
    orig_lookup "$_st_k"
    printf 'ORIG_%s=%s\n' "$_st_k" "$ORIG"
    printf 'ORIGHAS_%s=%s\n' "$_st_k" "$ORIG_HAS"
    printf 'KIND_%s=' "$_st_k"; key_kind "$_st_k"; echo
    printf 'TARGET_%s=' "$_st_k"; key_target "$_st_k"; echo
    printf 'LABEL_%s=' "$_st_k"; key_label "$_st_k"; echo
    printf 'TYPE_%s=' "$_st_k"; key_type "$_st_k"; echo
    if is_touched "$_st_k"; then
      printf 'TOUCHED_%s=1\n' "$_st_k"
    else
      printf 'TOUCHED_%s=0\n' "$_st_k"
    fi
    if [ "$_st_want" = skip ]; then
      printf 'MATCH_%s=skip\n' "$_st_k"
    elif [ "$_st_ok" -eq 1 ] && [ "$_st_live" = "$_st_now" ]; then
      printf 'MATCH_%s=1\n' "$_st_k"
    else
      printf 'MATCH_%s=0\n' "$_st_k"
      _drift=$((_drift + 1))
    fi
  done

  _st_pid=$(daemon_pid)
  if pid_is "$_st_pid" "$DAEMON_NEEDLE"; then
    _dstate="running"
    _mode=""
    _wpid=0
    if [ -f "$STATE_FILE" ]; then
      while IFS= read -r _st_l; do
        case "$_st_l" in
          MODE=*) _mode=${_st_l#MODE=} ;;
          WATCHER_PID=*) _wpid=${_st_l#WATCHER_PID=} ;;
        esac
      done <"$STATE_FILE"
    fi
  else
    _dstate="stopped"
    _mode="none"
    _wpid=0
  fi

  printf 'KEYS=%s\n' "$KEYS"
  printf 'CUSTOM_KEYS=%s\n' "$CUSTOM_KEYS"
  printf 'CUSTOM_MAX=%s\n' "$CUSTOM_MAX"
  printf 'USB_CABLE=%s\n' "$_st_cable"
  printf 'VERSION='; module_version; echo
  printf 'DAEMON=%s\n' "$_dstate"
  printf 'DAEMON_PID=%s\n' "$_st_pid"
  printf 'STARTED='; read_state STARTED; echo
  printf 'MODE=%s\n' "${_mode:-none}"
  printf 'WATCHER_PID=%s\n' "${_wpid:-0}"
  printf 'ENGINE=%s\n' "$CFG_engine"
  printf 'PAUSED='; read_state_num PAUSED; echo
  if [ -n "$CMD_INOTIFYD" ]; then echo 'INOTIFYD=1'; else echo 'INOTIFYD=0'; fi
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
  printf 'APPLIES='; read_state_num APPLIES; echo
  printf 'LAST_APPLY='; read_state LAST_APPLY; echo
  printf 'DRIFT=%s\n' "$_drift"
  if [ -f "$ORIGINAL_FILE" ]; then echo 'HAS_ORIGINAL=1'; else echo 'HAS_ORIGINAL=0'; fi
  printf 'LOG_LEVEL=%s\n' "$CFG_log_level"
  printf 'LOG_SIZE='; file_size "$LOG_FILE"; echo
  printf 'BUSYBOX=%s\n' "${BUSYBOX:-none}"
  printf 'NOW='; date +%s
  printf 'rc=0\n'
  unset _st_k _st_want _st_now _st_cable _st_live _st_ok _st_pid _st_l _drift _dstate _mode _wpid
}

# cmd_mock_apps - the WebUI picker. Answers at once from the cache; when the
# installed apps have changed, a scan is started in the background and
# SCAN=running tells the WebUI to ask again shortly. The configured package
# is reported separately (CONFIG=), never as an APP= line.
cmd_mock_apps() {
  load_config
  if mock_holders; then
    printf 'HOLDER=%s\n' "$MOCK"
  else
    printf 'HOLDER=unreadable\n'
    MOCK=""
  fi
  printf 'CONFIG=%s\n' "$CFG_mock_location_app"

  if mock_cache_fresh; then
    printf 'SCAN=fresh\n'
  else
    mock_scan_running ||
      spawn_detached $DAEMON_SH "$MODDIR/service.sh" --mock-scan
    printf 'SCAN=running\n'
  fi
  {
    mock_cached_apps
    _ma_ifs=$IFS
    IFS=,
    for _ma_p in $MOCK; do
      [ "$_ma_p" = none ] || printf '%s\n' "$_ma_p"
    done
    IFS=$_ma_ifs
  } | sort -u | while IFS= read -r _ma_p; do
    valid_pkg "$_ma_p" && printf 'APP=%s\n' "$_ma_p"
  done
  printf 'rc=0\n'
  unset _ma_p _ma_ifs
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
    log_warn "service.sh started while the daemon is running (pid $(daemon_pid)) - ignored"
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
  ensure_touched
  log_rotate

  if ! command -v settings >/dev/null 2>&1; then
    log_error "The 'settings' command is unavailable - nothing can be enforced"
  elif ! wait_for_settings 90; then
    log_warn "Settings service still not answering after boot - continuing"
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
  --mock-apps) cmd_mock_apps ;;
  --mock-scan)
    # Out of the manager app's cgroup, so a frozen app cannot stall it.
    daemon_detach
    mock_scan
    ;;
  --apply) cmd_apply ;;
  --restore) cmd_restore ;;
  --snapshot) cmd_snapshot ;;
  --export) cmd_export ;;
  --backups) cmd_backups ;;
  --import) cmd_import "$2" ;;
  --custom-add) cmd_custom_add "$2" "$3" "$4" ;;
  --custom-del) cmd_custom_del "$2" ;;
  --custom-peek) cmd_custom_peek "$2" "$3" ;;
  --custom-names) cmd_custom_names "$2" ;;
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
