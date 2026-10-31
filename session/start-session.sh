#!/usr/bin/env bash
# Bring up the ChromeOS D-Bus bridges and then the Ash session.
#
# This replaces the systemd units the NixOS module generated: every bridge runs
# as the current user with a small watchdog that restarts it, and everything is
# torn down when this script exits.
#
# Usage: ./session/start-session.sh
set -u

# Shared ASH_ROOT + die/log/note, prefixed with "[start-session] ".
ASH_MSG_PREFIX="[start-session] "
. "$(dirname "${BASH_SOURCE[0]}")/../scripts/common.sh"

BIN="$ASH_ROOT/dist/bin"
PROFILE="${ASH_PROFILE_DIR:-/var/lib/ash-profile}"
TEST_USER="${ASH_LOGIN_PROFILE:-test-user}"
LOGS="$PROFILE"
MOJO="${ASH_MOJO:-1}"

# Self-launch an X server when there is no display yet, so this script can be
# run directly (`./session/start-session.sh`) instead of `startx ./session/...`.
# Ash's Chrome needs a real X display (it runs --ozone-platform=x11). We re-exec
# ourselves under startx, which picks a free display and vt, runs us as its
# client, and tears the X server down when we exit. ASH_UNDER_STARTX guards
# against a loop if startx somehow fails to provide $DISPLAY.
if [ -z "${DISPLAY:-}" ] && [ "${ASH_UNDER_STARTX:-0}" != "1" ]; then
  command -v startx >/dev/null 2>&1 ||
    die "no \$DISPLAY and no startx — install xinit, or run inside an existing X session"
  export ASH_UNDER_STARTX=1
  log "no display; launching X via startx, then starting the session"
  # No server args on purpose: startx already picks the FIRST FREE display
  # (/usr/bin/startx scans for an unused :N) and adds the current vt with
  # -keeptty itself. Forcing ":0 vt1" would collide when :0 is busy (a real
  # session here once had to land on :1) or when not on tty1.
  exec startx "$ASH_ROOT/session/start-session.sh"
fi

# Detach the whole tree from the controlling terminal. Under startx/xinit the
# session inherits /dev/tty1 while staying a BACKGROUND process group there
# (xinit's own group is the foreground one), and a background group stops on
# any tty read/write: with no polkit agent running, pkexec's internal text
# agent prompts on the tty and the kernel delivers SIGTSTP/SIGTTIN to the
# ENTIRE group — Chrome, bridges, everything freezes in state T. In a fresh
# session with no ctty, /dev/tty reads fail with ENXIO instead.
#
# `--wait` covers the single case where setsid(1) must fork (we are already a
# process group leader): the parent then waits for the child instead of
# exiting, so startx/xinit still tracks the client to completion and its
# teardown is unaffected. util-linux is already required (mcookie).
if [ "${ASH_UNDER_SETSID:-0}" != "1" ]; then
  command -v setsid >/dev/null 2>&1 ||
    die "setsid missing — install util-linux"
  export ASH_UNDER_SETSID=1
  log "detaching from the controlling terminal (setsid)"
  exec setsid --wait "$0" "$@"
fi

# dist/bin/<name>-bridge for the daemons, dist/bin/<name> for helpers like
# mojo-stub.
bridge_bin() {
  local bin="$BIN/$1"
  [ -x "$bin" ] || bin="$BIN/$1-bridge"
  printf '%s' "$bin"
}

BRIDGES=(shill cras power session crostini rmad stub)
watchdogs=()
session_pid=""

cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  log "stopping"
  [ -n "$session_pid" ] && kill "$session_pid" 2>/dev/null
  for pid in "${watchdogs[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  # Bridges, register-apps and any leftover helpers.
  pkill -f "$BIN/" 2>/dev/null
  sleep 0.5
  pkill -f "$BIN/" 2>/dev/null
  exit "$rc"
}
trap cleanup EXIT INT TERM

[ -S /run/dbus/system_bus_socket ] ||
  die "no system D-Bus — is dbus/systemd running? (systemctl status dbus)"

if ! [ -d "$PROFILE" ] || ! [ -w "$PROFILE" ]; then
  die "profile dir $PROFILE is missing or not writable by $(id -un).
Run the one-time system setup first:  sudo ./scripts/setup-system.sh
(or point ASH_PROFILE_DIR at a directory you own)"
fi

if ! grep -qs 'org.chromium.flimflam' /etc/dbus-1/system.d/*.conf; then
  log "WARNING: no D-Bus policy for the org.chromium.* names in /etc/dbus-1/system.d/"
  log "         bridges will fail to register until you run: sudo ./scripts/setup-system.sh"
fi

for b in "${BRIDGES[@]}" register-apps; do
  [ -x "$(bridge_bin "$b")" ] || die "missing binary for '$b' — run: make bridges"
done
if [ "$MOJO" = "1" ]; then
  [ -x "$(bridge_bin mojo-stub)" ] || die "missing binary for 'mojo-stub' — run: make bridges"
fi

# --- bridges ---------------------------------------------------------------

# Watchdog: restart the bridge, backing off when it dies immediately (which
# usually means the D-Bus policy is missing).
start_bridge() {
  local name=$1
  shift
  # Either dist/bin/<name>-bridge or dist/bin/<name> (mojo-stub).
  local bin
  bin=$(bridge_bin "$name")
  (
    trap 'exit 0' INT TERM
    fast=0
    while true; do
      if [ $# -gt 0 ]; then
        env "$@" "$bin" >>"$LOGS/$name-bridge.log" 2>&1 &
      else
        "$bin" >>"$LOGS/$name-bridge.log" 2>&1 &
      fi
      bp=$!
      wait "$bp"
      code=$?
      if [ "$code" -ne 0 ] && [ "$code" -ne 130 ] && [ "$code" -ne 143 ]; then
        fast=$((fast + 1))
      else
        fast=0
      fi
      if [ "$fast" -ge 5 ]; then
        echo "[watchdog] $name died ${fast}x in a row; sleeping 30s" >>"$LOGS/bridges.log"
        sleep 30
        fast=0
      else
        echo "[watchdog] $name exited with $code; restarting" >>"$LOGS/bridges.log"
        sleep 2
      fi
    done
  ) &
  watchdogs+=($!)
  log "bridge: $name (log: $LOGS/$name-bridge.log)"
}

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [ ! -d "$XDG_RUNTIME_DIR" ]; then
  XDG_RUNTIME_DIR="${TMPDIR:-/tmp}/xdg-runtime-$(id -u)"
  mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
  export XDG_RUNTIME_DIR
fi
# Bridges other than power talk to the per-user PulseAudio/PipeWire socket.
PULSE_ENV=(PULSE_SERVER="unix:$XDG_RUNTIME_DIR/pulse/native")

for name in shill cras session crostini rmad; do
  start_bridge "$name" "${PULSE_ENV[@]}"
done
start_bridge power            # backlight/suspend paths want privileges; see README
start_bridge stub             # one-shot D-Bus stubs for daemons this setup lacks
if [ "$MOJO" = "1" ]; then
  start_bridge mojo-stub
fi

# --- session ---------------------------------------------------------------

mkdir -p "$PROFILE/$TEST_USER"
log "starting session"
ASH_ROOT="$ASH_ROOT" "$ASH_ROOT/session/chromeos-linux-session" &
session_pid=$!

wait "$session_pid"
session_code=$?
log "session exited with $session_code"
exit "$session_code"
