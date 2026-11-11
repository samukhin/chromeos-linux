#!/usr/bin/env bash
# Bring up the ChromeOS D-Bus bridges and then the Ash session.
#
# Ash runs directly on DRM/KMS (--ozone-platform=drm): there is no X server
# and no host Wayland compositor. Start this from a free VT, with no other
# DRM master (no niri/Xorg/sway/...) and no X session on the same seat.
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
ASH_DRM_CARD="${ASH_DRM_CARD:-/dev/dri/card0}"

# Fail early with a clear message instead of letting Chrome die inside the
# display configurator (where the only symptom is a black screen in ash.log).
drm_preflight() {
  [ -e "$ASH_DRM_CARD" ] ||
    die "DRM mode: $ASH_DRM_CARD not found — is the graphics driver loaded?"
  [ -r "$ASH_DRM_CARD" ] && [ -w "$ASH_DRM_CARD" ] ||
    die "DRM mode: no read/write access to $ASH_DRM_CARD — add $(id -un) to the video group"

  # EventFactoryEvdev / DeviceManagerUdev enumerate devices through udev.
  [ -e /run/udev/control ] ||
    die "DRM mode: /run/udev/control missing — is systemd-udevd running?"

  local ev found=0
  for ev in /dev/input/event*; do
    [ -e "$ev" ] || continue
    if [ -r "$ev" ]; then found=1; break; fi
  done
  [ "$found" = 1 ] ||
    die "DRM mode: no readable /dev/input/event* — add $(id -un) to the input group"

  # Another compositor would hold DRM master, so Chrome could not modeset.
  local c
  for c in niri Xorg X sway Hyprland weston gnome-shell kwin_wayland; do
    pgrep -x "$c" >/dev/null 2>&1 &&
      die "DRM mode: $c is running and likely holds DRM master — stop it first"
  done

  # logind is not required for DRM, but an active seat session gives uaccess
  # ACLs for the card and input nodes.
  if [ -n "${XDG_SESSION_ID:-}" ] && command -v loginctl >/dev/null 2>&1; then
    loginctl show-session "$XDG_SESSION_ID" -p Active 2>/dev/null |
      grep -q 'Active=yes' ||
      log "WARNING: logind session $XDG_SESSION_ID is not active (running from SSH?)"
  else
    log "WARNING: XDG_SESSION_ID unset (running from SSH?) — input/DRM ACLs may be missing"
  fi

  # IsRunningAsSystemCompositor() must be true, otherwise DisplayConfigurator
  # skips the native configuration entirely and the screen stays black.
  # setup-system.sh puts the machine into ChromeOS mode via /etc/lsb-release.
  grep -qs '^CHROMEOS_RELEASE_NAME=' /etc/lsb-release ||
    die "DRM mode: /etc/lsb-release is not in ChromeOS mode — run: sudo ./scripts/setup-system.sh"

  # fuser is optional; warn if somebody already has the card open.
  if command -v fuser >/dev/null 2>&1; then
    local holders
    holders="$(fuser "$ASH_DRM_CARD" 2>/dev/null || true)"
    [ -z "$holders" ] ||
      log "WARNING: $ASH_DRM_CARD is already open by pid(s):$holders"
  fi

  log "DRM preflight ok (card=$ASH_DRM_CARD)"
}

# Detach the whole tree from the controlling terminal. A session that stays a
# BACKGROUND process group on a tty stops on any tty read/write: with no
# polkit agent running, pkexec's internal text agent prompts on the tty and
# the kernel delivers SIGTSTP/SIGTTIN to the ENTIRE group — Chrome, bridges,
# everything freezes in state T. In a fresh session with no ctty, /dev/tty
# reads fail with ENXIO instead.
#
# `--wait` covers the single case where setsid(1) must fork (we are already a
# process group leader): the parent then waits for the child instead of
# exiting, so a caller that tracks this script still sees it finish.
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

BRIDGES=(shill cras power session crostini rmad)
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

# --- log rotation -----------------------------------------------------------
# Session logs are opened with >> and never truncated, so a long-lived session
# grows them without bound (mojo-stub alone writes ~130 MB/day of referral
# chatter). Rotate anything over the cap BEFORE the bridges/session open them
# for append; a stale "*.log.1" from the previous run is simply overwritten.
LOG_CAP_MB=5
for f in "$LOGS"/*.log; do
  [ -f "$f" ] || continue
  if [ "$(du -m "$f" 2>/dev/null | cut -f1)" -ge "$LOG_CAP_MB" ] 2>/dev/null; then
    mv -f "$f" "$f.1" 2>/dev/null || true
    log "rotated $(basename "$f") (> ${LOG_CAP_MB}MB)"
  fi
done

# Ash owns the display in this branch; bail out before starting bridges if the
# DRM/input side cannot work.
drm_preflight

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
