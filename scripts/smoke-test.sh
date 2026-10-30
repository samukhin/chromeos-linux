#!/usr/bin/env bash
# Smoke-test the D-Bus bridges against the running *system* bus.
#
# No X, no Chrome: each bridge is started, we wait for its org.chromium.*
# name to appear on the bus (which only succeeds if the D-Bus policy from
# scripts/setup-system.sh is in place), poke at least one real method where
# that is cheap, and shut it down again.
#
#   ./scripts/smoke-test.sh
set -u

# Shared ASH_ROOT + die/log/note, prefixed with "smoke-test: ".
ASH_MSG_PREFIX="smoke-test: "
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

BIN="$ASH_ROOT/dist/bin"
TIMEOUT="${ASH_SMOKE_TIMEOUT:-6}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ash-smoke.XXXXXX")"

pass=0
fail=0
pids=()

cleanup() {
  local pid
  for pid in "${pids[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  sleep 0.3
  for pid in "${pids[@]:-}"; do
    [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
  done
  if [ "$fail" -eq 0 ]; then
    rm -rf "$TMP"
  else
    echo
    note "bridge logs kept in $TMP"
    local f
    for f in "$TMP"/*.log; do
      [ -s "$f" ] || continue
      echo "----- $(basename "$f") (last 8 lines) -----"
      tail -n 8 "$f" | sed 's/^/    /'
    done
  fi
}
trap cleanup EXIT INT TERM

ok()   { echo "  PASS  $*"; pass=$((pass + 1)); }
bad()  { echo "  FAIL  $*"; fail=$((fail + 1)); }

list_names() {
  dbus-send --system --print-reply --dest=org.freedesktop.DBus \
    /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null |
    grep -o '"[^"]*"' | tr -d '"'
}

wait_for_name() {          # wait_for_name <bus name> <logfile> -> 0 if it shows up
  local name=$1 logfile=$2 i
  for i in $(seq 1 $((TIMEOUT * 2))); do
    if list_names | grep -qx "$name"; then
      return 0
    fi
    if ! kill -0 "${pids[-1]}" 2>/dev/null; then
      return 1
    fi
    sleep 0.5
  done
  return 1
}

start_bridge() {           # start_bridge <name> [env VAR=VAL ...]
  local name=$1
  shift
  local bin="$BIN/$name"
  [ -x "$bin" ] || bin="$BIN/$name-bridge"
  if ! [ -x "$bin" ]; then
    bad "$name: binary missing (run: make bridges)"
    return 1
  fi
  env "$@" "$bin" >"$TMP/$name.log" 2>&1 &
  pids+=($!)
}

stop_last() {
  local pid=${pids[-1]}
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
}

if ! [ -S /run/dbus/system_bus_socket ]; then
  log "no system D-Bus socket at /run/dbus/system_bus_socket"
  die "start it first (systemctl start dbus / dbus-daemon --system --fork)"
fi
have dbus-send || die "dbus-send missing"

echo "== policy =="
if grep -qs 'org.chromium.flimflam' /etc/dbus-1/system.d/*.conf; then
  echo "  ok    D-Bus policy present in /etc/dbus-1/system.d/"
else
  echo "  FAIL  no org.chromium policy installed — run: sudo ./scripts/setup-system.sh"
  fail=$((fail + 1))
fi

PULSE_ENV="PULSE_SERVER=unix:${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native"
XDG_ENV="XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

echo "== shill (network) =="
start_bridge shill "$XDG_ENV"
if wait_for_name "org.chromium.flimflam" "$TMP/shill.log"; then
  ok "org.chromium.flimflam owned"
else
  bad "org.chromium.flimflam not owned — see $TMP/shill.log"
fi
stop_last

echo "== cras (audio) =="
start_bridge cras "$PULSE_ENV" "$XDG_ENV"
if wait_for_name "org.chromium.cras" "$TMP/cras.log"; then
  ok "org.chromium.cras owned"
  if out=$(dbus-send --system --print-reply --dest=org.chromium.cras \
      /org/chromium/cras org.chromium.cras.Control.GetVolumeState 2>&1); then
    ok "Control.GetVolumeState -> $(echo "$out" | tr '\n' ' ' | tr -s ' ' | cut -c1-90)"
  else
    bad "Control.GetVolumeState: $out"
  fi
else
  bad "org.chromium.cras not owned — see $TMP/cras.log"
fi
stop_last

echo "== power =="
start_bridge power "$XDG_ENV"
if wait_for_name "org.chromium.PowerManager" "$TMP/power.log"; then
  ok "org.chromium.PowerManager owned"
else
  bad "org.chromium.PowerManager not owned — see $TMP/power.log"
fi
stop_last

echo "== session + UserDataAuth =="
start_bridge session "$XDG_ENV"
if wait_for_name "org.chromium.SessionManager" "$TMP/session.log"; then
  ok "org.chromium.SessionManager owned"
else
  bad "org.chromium.SessionManager not owned — see $TMP/session.log"
fi
if list_names | grep -qx "org.chromium.UserDataAuth"; then
  ok "org.chromium.UserDataAuth owned"
else
  bad "org.chromium.UserDataAuth not owned"
fi
if out=$(dbus-send --system --print-reply --dest=org.chromium.SessionManager \
    /org/chromium/SessionManager \
    org.chromium.SessionManagerInterface.RetrieveSessionState 2>&1); then
  ok "SessionManagerInterface.RetrieveSessionState -> $(echo "$out" | grep string || echo "$out")"
else
  bad "RetrieveSessionState: $out"
fi
stop_last

echo "== crostini (Linux app plumbing) =="
start_bridge crostini "$XDG_ENV"
crostini_names=(
  org.chromium.VmConcierge
  org.chromium.VmCicerone
  org.chromium.DlcService
  org.chromium.ImageLoader
  org.chromium.debugd
)
missing=""
for n in "${crostini_names[@]}"; do
  if ! wait_for_name "$n" "$TMP/crostini.log"; then
    missing="$missing $n"
  fi
done
if [ -z "$missing" ]; then
  ok "all crostini names owned (${#crostini_names[@]})"
else
  bad "not owned:$missing — see $TMP/crostini.log"
fi
stop_last

echo "== rmad =="
start_bridge rmad "$XDG_ENV"
if wait_for_name "org.chromium.Rmad" "$TMP/rmad.log"; then
  ok "org.chromium.Rmad owned"
else
  bad "org.chromium.Rmad not owned — see $TMP/rmad.log"
fi
stop_last

echo "== mojo-stub =="
if [ -x "$BIN/mojo-stub" ]; then
  "$BIN/mojo-stub" >"$TMP/mojo.log" 2>&1 &
  pids+=($!)
  for _ in $(seq 1 10); do
    [ -S /run/mojo/service_manager.sock ] && break
    sleep 0.3
  done
  if [ -S /run/mojo/service_manager.sock ]; then
    ok "/run/mojo/service_manager.sock present"
  else
    bad "socket not created (is /run/mojo writable? see $TMP/mojo.log)"
  fi
  stop_last
else
  bad "dist/bin/mojo-stub missing (run: make bridges)"
fi

echo "== register-apps =="
prefs="$TMP/Preferences"
echo '{}' > "$prefs"
if out=$("$BIN/register-apps" "$prefs" 2>&1) && grep -q '"crostini"' "$prefs"; then
  n=$(echo "$out" | grep -o 'wrote [0-9]* apps' || true)
  ok "wrote crostini registry ${n:-}"
else
  bad "register-apps: $out"
fi

echo
echo "smoke-test: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
