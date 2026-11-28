#!/bin/sh
# shellcheck disable=SC2016 # check arguments in single quotes are eval-ed on purpose
# tests/run.sh - checks for this repo without any test framework.
#
#   sh tests/run.sh
#
# POSIX sh (bash as sh, dash, busybox ash). The module scripts run for real
# against PATH stubs of the Android tools (settings, getprop, setprop, appops,
# pm, dumpsys) that keep their state in files, a module copy and a data
# directory (DOP_DATA_DIR) in a scratch directory under TMPDIR. One case starts
# the daemon (event engine, a stand-in inotifyd) and stops it with --restore.
# Checks whose tool is missing (node) are reported as skip.
# tests/webui-toasts.js checks the WebUI's toasts under node.

REPO=$(cd "$(dirname "$0")/.." && pwd) || exit 1
W=$(mktemp -d "${TMPDIR:-/tmp}/dop-tests.XXXXXX") || exit 1
_bg="" # pids of a daemon case, killed if the run ends early
trap '[ -z "$_bg" ] || kill $_bg 2>/dev/null; rm -rf "$W"' EXIT
trap 'exit 130' INT TERM

PASS=0 FAIL=0 SKIP=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
nok() { FAIL=$((FAIL + 1)); echo "FAIL $1"; }
skip() { SKIP=$((SKIP + 1)); echo "skip $1"; }
check() {
  _name=$1
  shift
  if "$@"; then ok "$_name"; else nok "$_name"; fi
}

if [ -n "${BB_ASH_VERSION:-}" ]; then SHELL_ID="busybox ash $BB_ASH_VERSION"
elif [ -n "${BASH_VERSION:-}" ]; then SHELL_ID="bash $BASH_VERSION (as sh)"
else SHELL_ID="sh ($(readlink -f /bin/sh 2>/dev/null))"; fi
echo "# shell: $SHELL_ID"

# -- Stubs --
B="$W/bin"
mkdir -p "$B"
cat >"$B/settings" <<'EOF'
#!/bin/sh
S="$FAKE/settings"
case "$1" in
  get) if [ -f "$S/$2/$3" ]; then cat "$S/$2/$3"; else echo null; fi ;;
  put) mkdir -p "$S/$2" && printf '%s\n' "$4" >"$S/$2/$3" ;;
  delete) rm -f "$S/$2/$3" ;;
  list)
    for f in "$S/$2"/*; do
      [ -f "$f" ] && printf '%s=%s\n' "${f##*/}" "$(cat "$f")"
    done
    exit 0 ;;
  *) exit 1 ;;
esac
EOF
cat >"$B/getprop" <<'EOF'
#!/bin/sh
P="$FAKE/props"
if [ "$#" -eq 0 ]; then
  for f in "$P"/*; do
    [ -f "$f" ] && printf '[%s]: [%s]\n' "${f##*/}" "$(cat "$f")"
  done
  exit 0
fi
if [ -f "$P/$1" ]; then cat "$P/$1"; else echo; fi
EOF
cat >"$B/setprop" <<'EOF'
#!/bin/sh
mkdir -p "$FAKE/props" && printf '%s\n' "$2" >"$FAKE/props/$1"
EOF
cat >"$B/appops" <<'EOF'
#!/bin/sh
A="$FAKE/appops"
mkdir -p "$A"
case "$1" in
  query-op)
    # appops-out: a canned answer (an error text) instead of the holders
    if [ -f "$FAKE/appops-out" ]; then cat "$FAKE/appops-out"; exit 0; fi
    for f in "$A"/*; do [ -f "$f" ] && echo "${f##*/}"; done; exit 0 ;;
  set) if [ "$4" = allow ]; then : >"$A/$2"; else rm -f "$A/$2"; fi ;;
  get) if [ -f "$FAKE/pkgs/$2" ]; then echo "MOCK_LOCATION: default"; else echo "Error: No UID for $2"; fi ;;
esac
EOF
cat >"$B/pm" <<'EOF'
#!/bin/sh
case "$1:$2" in
  path:android) echo "package:/system/framework/framework-res.apk" ;;
  path:*) [ -f "$FAKE/pkgs/$2" ] && echo "package:/data/app/$2/base.apk" ;;
esac
exit 0
EOF
printf '#!/bin/sh\nexit 0\n' >"$B/dumpsys"
chmod 755 "$B"/*
PATH="$B:$PATH"
export PATH

# newcase <name> - a fresh module copy, data directory and fake device:
# adb_enabled=0, development_settings_enabled=1, screen_off_timeout=30000.
newcase() {
  C="$W/case/$1"
  M="$C/mod/dev-options-persist"
  FAKE="$C/fake"
  DOP_DATA_DIR="$C/data"
  DOP_EXPORT_DIR="$C/export"
  export FAKE DOP_DATA_DIR DOP_EXPORT_DIR
  mkdir -p "$M/sh" "$FAKE/settings/global" "$FAKE/settings/system" "$FAKE/props" "$FAKE/pkgs"
  for f in service.sh uninstall.sh customize.sh module.prop sh/common.sh; do
    cp "$REPO/$f" "$M/$f"
  done
  echo 0 >"$FAKE/settings/global/adb_enabled"
  echo 1 >"$FAKE/settings/global/development_settings_enabled"
  echo 30000 >"$FAKE/settings/system/screen_off_timeout"
  echo 1 >"$FAKE/props/sys.boot_completed"
}

svc() { sh "$M/service.sh" "$@" 2>&1; }
sget() { sh "$B/settings" get "$1" "$2"; }
has() { grep -qx -- "$2" "$1" 2>/dev/null; }
hasnt() { ! grep -qx -- "$2" "$1" 2>/dev/null; }
outhas() { printf '%s\n' "$OUT" | grep -qx -- "$1"; }

# -- Declared checks --
for f in customize.sh service.sh uninstall.sh sh/common.sh META-INF/com/google/android/update-binary; do
  check "sh -n $f" sh -n "$REPO/$f"
done
check "sh -n tests/run.sh" sh -n "$REPO/tests/run.sh"

# -- Module behaviour --
newcase enforce
OUT=$(svc --config adb_enabled 1)
check "--config adb_enabled 1: rc=0 applied=1" eval 'outhas rc=0 && outhas applied=1'
check "--config adb_enabled 1: setting written" test "$(sget global adb_enabled)" = 1
check "--config adb_enabled 1: original captured" has "$DOP_DATA_DIR/original" adb_enabled=0
check "--config adb_enabled 1: key marked managed" has "$DOP_DATA_DIR/managed" adb_enabled
check "--config adb_enabled 1: config line" has "$DOP_DATA_DIR/config" adb_enabled=1
OUT=$(svc --status)
check "--status: rc=0, live value matches" eval 'outhas rc=0 && outhas LIVE_adb_enabled=1 && outhas MATCH_adb_enabled=1'
OUT=$(svc --config adb_enabled skip)
check "--config adb_enabled skip: handed back" eval 'outhas rc=0 && hasnt "$DOP_DATA_DIR/managed" adb_enabled'
check "--config adb_enabled skip: value left as it is" test "$(sget global adb_enabled)" = 1

newcase invalid
OUT=$(svc --config adb_enabled 7)
check "--config adb_enabled 7: rejected" eval 'outhas rc=1 && test ! -f "$DOP_DATA_DIR/config"'
OUT=$(svc --config no_such_key 1)
check "--config no_such_key: rejected" outhas rc=1
OUT=$(svc --import ../config)
check "--import ../config: bad name" eval 'outhas error=bad-name && outhas rc=1'
svc --no-such-command >/dev/null
check "unknown command exits 1" test "$?" = 1

# Two adjacent key names are not one key.
newcase multikey
OUT=$(svc --config "adbinstall adbinput" skip)
check "--config with two key names: rejected" eval 'outhas rc=1 && test ! -f "$DOP_DATA_DIR/config"'
mkdir -p "$DOP_DATA_DIR"
printf 'adbinstall adbinput=skip\nadb_enabled=1\n' >"$DOP_DATA_DIR/config"
_err=$(sh "$M/service.sh" --status 2>&1 >/dev/null)
check "config line with two key names: no command run for it" test -z "$_err"
svc --custom-add system screen_off_timeout 600000 >/dev/null
svc --custom-add system other_timeout 5 >/dev/null
OUT=$(svc --custom-del "c1 c2")
check "--custom-del with two ids: not found" eval 'outhas error=not-found && outhas rc=1'

newcase restore
svc --config adb_enabled 1 >/dev/null
svc --config development_settings_enabled 0 >/dev/null
check "restore setup: values enforced" eval 'test "$(sget global adb_enabled)" = 1 && test "$(sget global development_settings_enabled)" = 0'
OUT=$(svc --restore)
check "--restore: rc=0 restored=2" eval 'outhas rc=0 && outhas restored=2'
check "--restore: adb_enabled back to 0" test "$(sget global adb_enabled)" = 0
check "--restore: Developer Options left visible" test "$(sget global development_settings_enabled)" = 1

# Another live process holds the apply lock: --restore must change nothing
# and leave that lock alone.
newcase restore-busy
svc --config adb_enabled 1 >/dev/null
sleep 30 &
_holder=$!
mkdir -p "$DOP_DATA_DIR/run/locks/apply"
echo "$_holder" >"$DOP_DATA_DIR/run/locks/apply/pid"
OUT=$(svc --restore)
check "--restore with the apply lock busy: rc=1 error=busy" eval 'outhas rc=1 && outhas error=busy'
check "--restore with the apply lock busy: lock left to its owner" has "$DOP_DATA_DIR/run/locks/apply/pid" "$_holder"
check "--restore with the apply lock busy: nothing restored" test "$(sget global adb_enabled)" = 1
OUT=$(svc --apply)
check "--apply with the apply lock busy: rc=1 error=busy" eval 'outhas rc=1 && outhas error=busy'
kill "$_holder" 2>/dev/null
wait "$_holder" 2>/dev/null

# Stale-lock takeover. Waiter B finds the lock of a dead process; before B
# acts, waiter A (a live process) takes the same stale lock over. B must
# not remove A's fresh lock: A keeps it and B gets nothing. The interleaving
# is fixed by B's pid_alive, which runs A to completion when it is asked
# about the dead pid.
newcase lock-takeover
L="$DOP_DATA_DIR/run/locks/example"
mkdir -p "$L"
_dead=$(sh -c 'echo $$')
echo "$_dead" >"$L/pid"
OUT=$(MODDIR="$M" DEAD="$_dead" L="$L" C="$C" sh -c '. "$MODDIR/sh/common.sh"
pid_alive() {
  if [ "$1" = "$DEAD" ]; then
    if [ ! -f "$C/hook" ]; then
      : >"$C/hook"
      sh -c ". \"$MODDIR/sh/common.sh\"; lock_acquire \"$L\" 0 && echo \$\$ >\"$C/a.ready\"; exec sleep 30" >/dev/null 2>&1 &
      _w=0
      while [ ! -s "$C/a.ready" ] && [ "$_w" -lt 300 ]; do sleep 0.1; _w=$((_w + 1)); done
    fi
    return 1
  fi
  [ -r "/proc/$1/stat" ]
}
lock_acquire "$L" 0
echo "b_rc=$?"' 2>&1)
_a=$(cat "$C/a.ready" 2>/dev/null)
check "stale lock, two waiters: the first one took it over" test -n "$_a"
check "stale lock, two waiters: the second one does not get it" outhas b_rc=1
check "stale lock, two waiters: the lock still names the first one" has "$L/pid" "$_a"
check "stale lock, two waiters: no takeover guard left" test ! -e "$L.takeover"
[ -n "$_a" ] && kill "$_a" 2>/dev/null
newcase lock-stale
L="$DOP_DATA_DIR/run/locks/example"
mkdir -p "$L"
_dead=$(sh -c 'echo $$')
echo "$_dead" >"$L/pid"
OUT=$(MODDIR="$M" L="$L" sh -c '. "$MODDIR/sh/common.sh"; lock_acquire "$L" 0; echo "rc=$?"; echo "me=$$"' 2>&1)
check "stale lock, one waiter: taken over at once" eval 'outhas rc=0 && has "$L/pid" "$(printf "%s\n" "$OUT" | sed -n "s/^me=//p")"'
rm -rf "$L"
mkdir -p "$L"
OUT=$(MODDIR="$M" L="$L" sh -c '. "$MODDIR/sh/common.sh"; lock_acquire "$L" 5; echo "rc=$?"; echo "me=$$"' 2>&1)
check "lock without an owner: taken over after three looks" eval 'outhas rc=0 && has "$L/pid" "$(printf "%s\n" "$OUT" | sed -n "s/^me=//p")"'
rm -rf "$L"
mkdir -p "$L" "$L.takeover"
echo "$_dead" >"$L/pid"
OUT=$(MODDIR="$M" L="$L" sh -c '. "$MODDIR/sh/common.sh"; lock_acquire "$L" 0; echo "rc=$?"' 2>&1)
check "stale lock while a takeover guard exists: left alone" eval 'outhas rc=1 && has "$L/pid" "$_dead"'

newcase custom
OUT=$(svc --custom-add system screen_off_timeout 600000)
check "--custom-add: rc=0 id=c1" eval 'outhas rc=0 && outhas id=c1'
check "--custom-add: value written" test "$(sget system screen_off_timeout)" = 600000
check "--custom-add: custom file line" has "$DOP_DATA_DIR/custom" "c1 system screen_off_timeout 600000"
check "--custom-add: original captured" has "$DOP_DATA_DIR/original" c1=30000
OUT=$(svc --custom-add system 'bad name' 1)
check "--custom-add bad target: rejected" eval 'outhas error=bad-target && outhas rc=1'
OUT=$(svc --custom-del c1)
check "--custom-del c1: removed, value left" eval 'outhas rc=0 && ! grep -q "^c1 " "$DOP_DATA_DIR/custom" && test "$(sget system screen_off_timeout)" = 600000'

# Custom add (new id) and delete need the apply lock to clear the id's
# managed mark and original; while another live process holds it they
# answer error=busy and change nothing.
newcase custom-busy
svc --custom-add system screen_off_timeout 600000 >/dev/null
for _f in custom original managed; do cp "$DOP_DATA_DIR/$_f" "$C/$_f.before"; done
sleep 30 &
_holder=$!
mkdir -p "$DOP_DATA_DIR/run/locks/apply"
echo "$_holder" >"$DOP_DATA_DIR/run/locks/apply/pid"
OUT=$(svc --custom-del c1)
check "--custom-del with the apply lock busy: rc=1 error=busy" eval 'outhas rc=1 && outhas error=busy'
check "--custom-del with the apply lock busy: custom list, managed mark and original kept" eval 'cmp -s "$C/custom.before" "$DOP_DATA_DIR/custom" && cmp -s "$C/managed.before" "$DOP_DATA_DIR/managed" && cmp -s "$C/original.before" "$DOP_DATA_DIR/original"'
OUT=$(svc --custom-add system example_new 5)
check "--custom-add of a new key with the apply lock busy: rc=1 error=busy, nothing added" eval 'outhas rc=1 && outhas error=busy && cmp -s "$C/custom.before" "$DOP_DATA_DIR/custom"'
check "busy custom add/del: lock left to its owner" has "$DOP_DATA_DIR/run/locks/apply/pid" "$_holder"
kill "$_holder" 2>/dev/null
wait "$_holder" 2>/dev/null
OUT=$(svc --custom-add system example_new 5)
check "--custom-add with the apply lock free: added and applied" eval 'outhas rc=0 && outhas id=c2 && outhas applied=1 && test "$(sget system example_new)" = 5'
OUT=$(svc --custom-del c1)
check "--custom-del with the apply lock free: removed with its mark and original" eval 'outhas rc=0 && ! grep -q "^c1 " "$DOP_DATA_DIR/custom" && hasnt "$DOP_DATA_DIR/managed" c1 && ! grep -q "^c1=" "$DOP_DATA_DIR/original"'
check "custom add/del: apply lock released" test ! -e "$DOP_DATA_DIR/run/locks/apply"

# Restore Original puts custom values back with the same rules as
# uninstall.sh: any custom-charset value; an empty one only for a property.
newcase restore-custom
echo abc >"$FAKE/settings/system/example_mode"
echo "a,b" >"$FAKE/props/persist.example.list"
echo >"$FAKE/settings/system/example_empty"
svc --custom-add system example_mode xyz >/dev/null
svc --custom-add prop persist.example.list c,d >/dev/null
svc --custom-add system example_empty 5 >/dev/null
OUT=$(svc --restore)
check "--restore custom: rc=0 restored=2" eval 'outhas rc=0 && outhas restored=2'
check "--restore custom: text value back" test "$(sget system example_mode)" = abc
check "--restore custom: property with , back" test "$(cat "$FAKE/props/persist.example.list")" = "a,b"
check "--restore custom: empty setting left as it is" test "$(sget system example_empty)" = 5

# A value over several lines must not reach the snapshot, where its second
# line would read as the original of another key.
newcase multiline
svc --config adb_enabled 1 >/dev/null
printf 'a\nadb_enabled=1\n' >"$FAKE/settings/system/screen_off_timeout"
svc --custom-add system screen_off_timeout 600000 >/dev/null
check "multi-line value: no foreign line in the snapshot" has "$DOP_DATA_DIR/original" adb_enabled=0
check "multi-line value: snapshot holds one adb_enabled line" test "$(grep -c '^adb_enabled=' "$DOP_DATA_DIR/original")" = 1
check "multi-line value: not kept as c1's original" eval '! grep -q "^c1=" "$DOP_DATA_DIR/original"'
check "multi-line value: key still written and managed" eval 'test "$(sget system screen_off_timeout)" = 600000 && has "$DOP_DATA_DIR/managed" c1'
newcase multiline-capture
mkdir -p "$DOP_DATA_DIR"
echo "c1 system screen_off_timeout 600000" >"$DOP_DATA_DIR/custom"
printf 'a\nadb_enabled=1\n' >"$FAKE/settings/system/screen_off_timeout"
MODDIR="$M" sh -c '. "$MODDIR/sh/common.sh"; load_config; capture_originals' >/dev/null 2>&1
check "multi-line value at capture: snapshot taken without it" eval 'has "$DOP_DATA_DIR/original" adb_enabled=0 && ! grep -q -e "^c1=" -e "^adb_enabled=1" "$DOP_DATA_DIR/original"'

# A failed write (full /data, here a file size limit) must keep the old
# file. Only the module call runs under the limit; checks run outside it.
limited() { (trap '' XFSZ; ulimit -f "$1"; shift; "$@") >/dev/null 2>&1; }
common() { MODDIR="$M" sh -c '. "$MODDIR/sh/common.sh"; load_config; '"$1"; }
newcase wfail
svc --config adb_enabled 1 >/dev/null
limited 0 sh "$M/service.sh" --snapshot
check "write failure: --snapshot keeps the snapshot" has "$DOP_DATA_DIR/original" adb_enabled=0
limited 0 common 'set_touched adbinput 1'
check "write failure: set_touched keeps the managed list" has "$DOP_DATA_DIR/managed" adb_enabled
limited 0 common 'drop_original c9'
check "write failure: drop_original keeps the snapshot" has "$DOP_DATA_DIR/original" adb_enabled=0
_i=0
while [ "$_i" -lt 60 ]; do
  echo "# padding line $_i so the config is well over two kilobytes long ......"
  _i=$((_i + 1))
done >>"$DOP_DATA_DIR/config"
echo "adbinput=skip" >>"$DOP_DATA_DIR/config"
cp "$DOP_DATA_DIR/config" "$C/config.before"
limited 1 sh "$M/service.sh" --config adbinput 1
check "write failure: --config keeps the whole config" cmp -s "$C/config.before" "$DOP_DATA_DIR/config"
: >"$DOP_DATA_DIR/custom"
_i=1
while [ "$_i" -le 30 ]; do
  echo "c$_i system example_setting_with_a_long_name_number_${_i}_for_the_custom_file_size 1" >>"$DOP_DATA_DIR/custom"
  _i=$((_i + 1))
done
cp "$DOP_DATA_DIR/custom" "$C/custom.before"
limited 1 sh "$M/service.sh" --custom-add system example_other 2
check "write failure: --custom-add keeps the whole custom list" cmp -s "$C/custom.before" "$DOP_DATA_DIR/custom"
check "write failure: no temp files left" test -z "$(find "$DOP_DATA_DIR" -name '*.tmp.*')"
# The snapshot or the managed list cannot be written (here: a big file under
# a size limit): the key must not be changed or marked managed, the error is
# logged once per key, and two passes in one process log it once.
twopass() { sh -c 'set -- --status; . "$0" >/dev/null; check_keys adb_enabled; check_keys adb_enabled' "$M/service.sh"; }
pad() {
  _i=0
  while [ "$_i" -lt 60 ]; do
    echo "example_pad_$_i=a line that only makes this file larger than two kilobytes"
    _i=$((_i + 1))
  done >>"$1"
}
newcase nosnap
mkdir -p "$DOP_DATA_DIR/logs"
echo adb_enabled=1 >"$DOP_DATA_DIR/config"
: >"$DOP_DATA_DIR/managed"
pad "$DOP_DATA_DIR/original"
: >"$DOP_DATA_DIR/logs/service.log"
limited 1 twopass
check "original not saved: key not changed" test "$(sget global adb_enabled)" = 0
check "original not saved: key not marked managed" hasnt "$DOP_DATA_DIR/managed" adb_enabled
check "original not saved: logged once for two passes" test "$(grep -c 'adb_enabled: the original value could not be saved' "$DOP_DATA_DIR/logs/service.log")" = 1
check "original not saved: status Not Working" eval 'grep -q "^description=.* - Not Working$" "$M/module.prop"'
twopass >/dev/null 2>&1
check "original saved again: key written and managed" eval 'test "$(sget global adb_enabled)" = 1 && has "$DOP_DATA_DIR/managed" adb_enabled && has "$DOP_DATA_DIR/original" adb_enabled=0'
newcase nomanaged
mkdir -p "$DOP_DATA_DIR/logs"
echo adb_enabled=1 >"$DOP_DATA_DIR/config"
: >"$DOP_DATA_DIR/managed"
pad "$DOP_DATA_DIR/managed"
: >"$DOP_DATA_DIR/logs/service.log"
limited 1 twopass
check "managed list not saved: key not changed" test "$(sget global adb_enabled)" = 0
check "managed list not saved: logged once for two passes" test "$(grep -c 'adb_enabled: the original value could not be saved' "$DOP_DATA_DIR/logs/service.log")" = 1
newcase nosnapshot
svc --config adb_enabled 1 >/dev/null
pad "$DOP_DATA_DIR/original"
cp "$DOP_DATA_DIR/original" "$C/original.before"
OUT=$( (trap '' XFSZ; ulimit -f 1; sh "$M/service.sh" --snapshot) 2>/dev/null)
check "--snapshot write failure: rc=1, not counted as snapped" eval 'outhas rc=1 && outhas snapped=0 && outhas failed=1'
check "--snapshot write failure: snapshot unchanged" cmp -s "$C/original.before" "$DOP_DATA_DIR/original"

# A printf that loses the data and still exits 0 (an external printf on a
# full file system does that): every writer must notice the short file and
# keep the old one. Here printf is a function that drops its first line
# and writes the rest.
lossy() { MODDIR="$M" sh -c '. "$MODDIR/sh/common.sh"; load_config; printf() { if [ -z "$_lp" ]; then _lp=1; return 0; fi; command printf "$@"; }; '"$1" >/dev/null 2>&1; }
newcase lossy
svc --config adb_enabled 1 >/dev/null
svc --custom-add system example_mode 5 >/dev/null
for _f in config original managed custom; do cp "$DOP_DATA_DIR/$_f" "$C/$_f.before"; done
lossy 'write_cfg adbinput 1'
check "silent short write: write_cfg keeps the config" cmp -s "$C/config.before" "$DOP_DATA_DIR/config"
lossy 'set_original adb_enabled 5'
check "silent short write: set_original keeps the snapshot" cmp -s "$C/original.before" "$DOP_DATA_DIR/original"
lossy 'drop_original adb_enabled'
check "silent short write: drop_original keeps the snapshot" cmp -s "$C/original.before" "$DOP_DATA_DIR/original"
lossy 'set_touched adbinput 1'
check "silent short write: set_touched keeps the managed list" cmp -s "$C/managed.before" "$DOP_DATA_DIR/managed"
sh -c 'set -- --status; . "$0" >/dev/null; printf() { if [ -z "$_lp" ]; then _lp=1; return 0; fi; command printf "$@"; }; write_custom "" c9 system example_other 1' "$M/service.sh" >/dev/null 2>&1
check "silent short write: write_custom keeps the custom list" cmp -s "$C/custom.before" "$DOP_DATA_DIR/custom"
rm -f "$DOP_DATA_DIR/original" "$DOP_DATA_DIR/managed"
lossy 'capture_originals'
check "silent short write: capture_originals leaves no short snapshot" test ! -e "$DOP_DATA_DIR/original"
cp "$C/original.before" "$DOP_DATA_DIR/original"
lossy 'ensure_touched'
check "silent short write: ensure_touched leaves no short managed list" test ! -e "$DOP_DATA_DIR/managed"
check "silent short write: no temp files left" test -z "$(find "$DOP_DATA_DIR" -name '*.tmp.*')"

newcase wfail-capture
limited 0 common 'capture_originals'
check "write failure: capture_originals leaves no empty snapshot" test ! -e "$DOP_DATA_DIR/original"
newcase wfail-touched
mkdir -p "$DOP_DATA_DIR"
echo adb_enabled=1 >"$DOP_DATA_DIR/config"
echo adb_enabled=0 >"$DOP_DATA_DIR/original"
limited 0 common 'ensure_touched'
check "write failure: ensure_touched leaves no empty managed list" test ! -e "$DOP_DATA_DIR/managed"

# A hand-edited config may end without a newline: a setting that
# ensure_config adds must not join that last line.
newcase nonewline
mkdir -p "$DOP_DATA_DIR"
printf 'adb_enabled=1\nprofile=balanced\nlog_level=1\nmock_location_app=skip\nadbinput=0' >"$DOP_DATA_DIR/config"
OUT=$(common 'ensure_config; load_config; echo "adbinput=$CFG_adbinput engine=$CFG_engine bad=$CFG_BAD"' 2>&1)
check "config without a final newline: last value kept by ensure_config" outhas "adbinput=0 engine=auto bad="
check "config without a final newline: missing setting added on its own line" has "$DOP_DATA_DIR/config" engine=auto
printf 'adb_enabled=1\nprofile=balanced\nlog_level=1\nmock_location_app=skip\nengine=poll\n' >"$DOP_DATA_DIR/config"
cp "$DOP_DATA_DIR/config" "$C/config.before"
common 'ensure_config' >/dev/null 2>&1
check "complete config with a final newline: ensure_config leaves it byte for byte" cmp -s "$C/config.before" "$DOP_DATA_DIR/config"

# A package name holding "rror" (com.example.mirror) is a holder, not
# appops error text; real error answers still read as unreadable.
newcase mirror
: >"$FAKE/pkgs/com.example.mirror"
svc --config mock_location_app com.example.mirror >/dev/null
OUT=$(svc --status)
check "mock app com.example.mirror: read back and matching" eval 'outhas LIVE_mock_location_app=com.example.mirror && outhas MATCH_mock_location_app=1'
holders() { common 'if mock_holders; then echo "holders=$MOCK"; else echo holders=fail; fi' 2>&1; }
printf 'Error: Unknown operation string: android:mock_location\n' >"$FAKE/appops-out"
check "appops answer 'Error: ...': unreadable" test "$(holders)" = holders=fail
printf 'cmd: Failure calling service appops: Failed transaction (2147483646)\n' >"$FAKE/appops-out"
check "appops answer 'Failure calling service': unreadable" test "$(holders)" = holders=fail
printf 'Exception occurred while executing query-op:\njava.lang.IllegalStateException\n\tat com.android.server.appop.AppOpsService.onShellCommand(AppOpsService.java:1)\n' >"$FAKE/appops-out"
check "appops answer with an exception trace: unreadable" test "$(holders)" = holders=fail
printf 'java.lang.OutOfMemoryError\n' >"$FAKE/appops-out"
check "appops answer naming a java Error: unreadable" test "$(holders)" = holders=fail
printf 'No operations.\n' >"$FAKE/appops-out"
check "appops answer 'No operations.': no holder" test "$(holders)" = holders=none
rm -f "$FAKE/appops-out"
newcase mirror-uninstall
mkdir -p "$DOP_DATA_DIR" "$FAKE/appops"
: >"$FAKE/pkgs/com.example.mirror"
: >"$FAKE/pkgs/com.example.other"
: >"$FAKE/appops/com.example.mirror"
echo mock_location_app=com.example.other >"$DOP_DATA_DIR/original"
echo mock_location_app >"$DOP_DATA_DIR/managed"
sh "$M/uninstall.sh" >/dev/null 2>&1
check "uninstall.sh with com.example.mirror holding the app op: original app back" eval 'test -f "$FAKE/appops/com.example.other" && test ! -f "$FAKE/appops/com.example.mirror"'
_i=0
while [ -d "$DOP_DATA_DIR" ] && [ "$_i" -lt 50 ]; do
  sleep 0.2
  _i=$((_i + 1))
done

# A custom value holding "Exception" reads back as cmd's failure text, so it
# is refused; one already stored is ignored without breaking the rest.
newcase exception-value
OUT=$(svc --custom-add system example_mode Exception)
check "--custom-add value Exception: refused" eval 'outhas error=bad-value && outhas rc=1 && test ! -s "$DOP_DATA_DIR/custom"'
OUT=$(svc --custom-add system example_mode ExampleException1)
check "--custom-add value containing Exception: refused" eval 'outhas error=bad-value && outhas rc=1'
OUT=$(svc --custom-add system example_mode except.ion-1)
check "--custom-add ordinary value: accepted" eval 'outhas rc=0 && has "$DOP_DATA_DIR/custom" "c1 system example_mode except.ion-1"'
mkdir -p "$DOP_EXPORT_DIR"
printf 'custom=system example_other Exception\ncustom=system example_third 7\n' >"$DOP_EXPORT_DIR/example.txt"
OUT=$(svc --import example.txt)
check "--import custom value Exception: skipped, the valid line added" eval 'outhas skipped=1 && outhas changed=1 && ! grep -q Exception "$DOP_DATA_DIR/custom"'
newcase exception-stored
mkdir -p "$DOP_DATA_DIR"
printf 'c1 system example_mode Exception\nc2 system example_ok 5\n' >"$DOP_DATA_DIR/custom"
OUT=$(svc --status)
check "stored custom value Exception: --status rc=0, the line ignored, the next one kept" eval 'outhas rc=0 && outhas "CUSTOM_KEYS=c2"'
OUT=$(MODDIR="$M" sh -c '. "$MODDIR/sh/common.sh"; ensure_config; load_config; ensure_touched; capture_originals; echo "keys=$CUSTOM_KEYS"' 2>&1)
check "stored custom value Exception: boot steps run, c2 still managed" outhas "keys=c2"
svc --custom-add system example_new 1 >/dev/null
check "stored custom value Exception: dropped from the file by the next custom write" eval '! grep -q "^c1 " "$DOP_DATA_DIR/custom" && has "$DOP_DATA_DIR/custom" "c2 system example_ok 5"'

# --restore while the daemon runs the event engine: the daemon waits in
# `read -t` on the watcher's FIFO and must stop through its TERM trap
# (watcher killed, FIFO removed, status Stopped), then the original value
# is restored and enforcement stays paused. The watcher is a stand-in
# inotifyd that sends nothing; the daemon watches directories of the case.
gone() {
  for _p in "$@"; do
    [ -r "/proc/$_p/stat" ] || continue
    read -r _ _ _st _ <"/proc/$_p/stat" 2>/dev/null
    [ "$_st" = Z ] || return 1
  done
  return 0
}
if [ "$(id -u)" = 0 ]; then
  skip "--restore with the event engine (runs as root: daemon_detach would move this run into other cgroups)"
elif ! printf 'x\n' | sh -c 'read -t 1 _v 2>/dev/null && [ "$_v" = x ]' 2>/dev/null; then
  skip "--restore with the event engine (this sh has no read -t)"
else
  newcase events-restore
  svc --config adb_enabled 1 >/dev/null
  mkdir -p "$C/sys" "$C/prop"
  printf '#!/bin/sh\nwhile :; do sleep 1; done\n' >"$C/inotifyd"
  sh -c '_i=$1 _s=$2 _p=$3; set -- --status; . "$0" >/dev/null; CMD_INOTIFYD="sh $_i"; SETTINGS_DIR=$_s; PROP_DIR=$_p; daemon_main' \
    "$M/service.sh" "$C/inotifyd" "$C/sys" "$C/prop" >/dev/null 2>&1 &
  _dp=$!
  _bg=$_dp
  _i=0
  while ! grep -q '^MODE=events' "$DOP_DATA_DIR/run/state" 2>/dev/null && [ "$_i" -lt 50 ]; do
    sleep 0.2
    _i=$((_i + 1))
  done
  _wp=$(cat "$DOP_DATA_DIR/run/watcher.pid" 2>/dev/null)
  _bg="$_dp $_wp"
  check "event engine running before --restore" eval 'grep -q "^MODE=events" "$DOP_DATA_DIR/run/state" && test -n "$_wp"'
  OUT=$(svc --restore)
  check "--restore with the event engine: rc=0 restored=1 paused=1" eval 'outhas rc=0 && outhas restored=1 && outhas paused=1'
  check "--restore with the event engine: adb_enabled back to 0" test "$(sget global adb_enabled)" = 0
  check "--restore with the event engine: daemon stopped through its TERM trap" grep -q "Daemon stopping (pid $_dp)" "$DOP_DATA_DIR/logs/service.log"
  check "--restore with the event engine: no daemon or watcher left" gone $_dp $_wp
  check "--restore with the event engine: FIFO removed, status Stopped" eval 'test ! -e "$DOP_DATA_DIR/run/events" && grep -q "^description=.* - Stopped$" "$M/module.prop"'
  kill $_bg 2>/dev/null
  wait "$_dp" 2>/dev/null
  _bg=""
fi

newcase backup
svc --config adb_enabled 1 >/dev/null
OUT=$(svc --export)
_file=$(printf '%s\n' "$OUT" | sed -n 's/^file=//p')
check "--export: file written" eval 'outhas rc=0 && test -n "$_file" && has "$DOP_EXPORT_DIR/$_file" adb_enabled=1'
OUT=$(svc --backups)
check "--backups: lists it" eval 'printf "%s\n" "$OUT" | grep -q "^BACKUP=$_file|"'
svc --config adb_enabled skip >/dev/null
OUT=$(svc --import "$_file")
check "--import: value back in the config" eval 'outhas rc=0 && has "$DOP_DATA_DIR/config" adb_enabled=1'

newcase install
OUT=$(MODPATH="$M" sh -c 'ui_print() { :; }; set_perm() { :; }; set_perm_recursive() { :; }; . "$MODPATH/customize.sh"' 2>&1)
check "customize.sh: default config written" has "$DOP_DATA_DIR/config" adb_enabled=1
check "customize.sh: originals captured" has "$DOP_DATA_DIR/original" adb_enabled=0
check "customize.sh: empty managed list" eval 'test -f "$DOP_DATA_DIR/managed" && test ! -s "$DOP_DATA_DIR/managed"'

newcase uninstall
svc --config adb_enabled 1 >/dev/null
sh "$M/uninstall.sh" >/dev/null 2>&1
_i=0
while [ -d "$DOP_DATA_DIR" ] && [ "$_i" -lt 50 ]; do
  sleep 0.2
  _i=$((_i + 1))
done
check "uninstall.sh: adb_enabled restored" test "$(sget global adb_enabled)" = 0
check "uninstall.sh: data directory removed" test ! -d "$DOP_DATA_DIR"

# -- WebUI toasts for service.sh answers (tests/webui-toasts.js) --
if command -v node >/dev/null 2>&1; then
  node "$REPO/tests/webui-toasts.js" >"$W/ui.out" 2>&1
  _urc=$?
  _un=0
  while IFS= read -r _l; do
    case "$_l" in
      "ok   "*) ok "webui ${_l#ok   }"; _un=$((_un + 1)) ;;
      "FAIL "*) nok "webui ${_l#FAIL }"; _un=$((_un + 1)) ;;
      "     "*) echo "$_l" ;;
    esac
  done <"$W/ui.out"
  if [ "$_urc" != 0 ] || [ "$_un" -eq 0 ]; then
    nok "webui toast checks exited $_urc after $_un checks"
    tail -n 5 "$W/ui.out"
  fi
else
  skip "WebUI toast checks (no node)"
fi

echo "# $PASS passed, $FAIL failed, $SKIP skipped ($SHELL_ID)"
[ "$FAIL" -eq 0 ]
