#!/usr/bin/env bash
# Check that everything needed to build and run chromeos-linux is installed,
# plus a session preflight that catches silent runtime misconfiguration.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

status=0

check() {                     # check <cmd> <needed-for> <apt pkg> <pacman pkg>
  if command -v "$1" >/dev/null 2>&1; then
    printf '  ok      %-16s %s\n' "$1" "$2"
  else
    printf '  MISSING %-16s %s  -> apt: %s | pacman: %s\n' "$1" "$2" "$3" "$4"
    status=1
  fi
}

echo "== build =="
check go            "Go compiler (bridges)"        golang-go        go
check meson         "sommelier build"              meson            meson
check ninja         "sommelier build"              ninja-build      ninja
check pkg-config    "sommelier build"              pkg-config       pkgconf
check wayland-scanner "sommelier build"            libwayland-bin   wayland
check python3       "sommelier patches"            python3          python
check gcc           "libdisplayfix.so"             build-essential  base-devel
check gawk          "chrome binary patches"        gawk             gawk
check nm            "chrome binary patches"        binutils         binutils
check objdump       "chrome binary patches"        binutils         binutils
check curl          "downloads + CDP"              curl             curl
check unzip         "chrome snapshot"              unzip            unzip
check tar           "sommelier sources"            tar              tar
check perl          "terminal injection"           perl             perl
if python3 -c 'import jinja2' 2>/dev/null; then
  echo "  ok      jinja2           sommelier codegen"
else
  echo "  MISSING jinja2           sommelier codegen -> apt: python3-jinja2 | pacman: python-jinja2"
  status=1
fi

echo "== runtime =="
check Xwayland      "X11 apps inside Ash"          xwayland         xorg-xwayland
check xrandr        "screen bounds / brightness"   x11-xserver-utils xorg-xrandr
check xrdb          "terminal colors"              x11-xserver-utils xorg-xrdb
check xhost         "X access fallback"            x11-xserver-utils xorg-xhost
check xauth         "X cookies"                    xauth            xorg-xauth
check pactl         "CRAS volume control"          pulseaudio-utils libpulse
check systemctl     "suspend/reboot from tray"     systemd          systemd
check rsvg-convert  "launcher icons (SVG)"         librsvg2-bin     librsvg
check dbus-daemon   "system bus"                   dbus-daemon      dbus
check nmcli        "networking (shill bridge)"    networkmanager   networkmanager
echo -n "  check   libXcomposite.so.1  (libxcomposite1 / libxcomposite): "
if ldd "$ASH_ROOT/dist/chrome/chrome" 2>/dev/null | grep -q "not found"; then
  echo "MISSING -> apt: libxcomposite1 | pacman: libxcomposite"
  status=1
elif [ -e "$ASH_ROOT/dist/chrome/chrome" ]; then
  echo "ok"
else
  echo "(build chrome first)"
fi

# XkbKeyboardLayoutEngine builds layouts (RU/EN quick-settings chip) through
# libxkbcommon, which reads its rules/keymap files from this directory. The
# shared lib itself is a DT_NEEDED of chrome (covered by the ldd check above),
# but without the data files every layout lookup silently falls back to US.
echo -n "  check   /usr/share/X11/xkb  (xkb data files for RU/EN typing): "
if [ -d /usr/share/X11/xkb ]; then
  echo "ok"
else
  echo "MISSING -> apt: xkb-data | pacman: xorg-xkbdata"
  status=1
fi

# Session preflight: durable runtime STATE that decides whether the session
# actually works, as opposed to "is the tool installed". These are the silent
# failure modes — everything builds and starts, but the launcher refuses to
# open apps or the Terminal dies with 'failed to execvp'. setup-system.sh
# creates the first four; a green doctor here means the session will work.

echo "== session preflight =="

ps_ok()   { printf '  ok      %-14s %s\n' "$1" "$2"; }
ps_miss() { printf '  MISSING %-14s %s  -> %s\n' "$1" "$2" "$3"; status=1; }

# Crostini gate: Chrome stats /dev/kvm at session start and, if absent, refuses
# EVERY Linux app launch with "Virtualization is not supported on this device"
# (no error in the UI — apps just don't open). A placeholder file is enough —
# but only on hosts WITHOUT KVM: a regular file where the real device belongs
# hides it from udev forever, so apps break for a different, silent reason.
if [ -c /dev/kvm ]; then
  ps_ok "/dev/kvm" "real KVM node (Crostini gate open)"
elif [ -e /sys/class/misc/kvm ]; then
  # The driver is loaded but /dev/kvm is not a device node: either our
  # placeholder from an earlier setup, or udev has not created the node yet.
  ps_miss "/dev/kvm" "placeholder hides the real KVM device (driver is loaded)" \
          "sudo ./scripts/setup-system.sh  (drops the stub and triggers udev)"
elif [ -e /dev/kvm ]; then
  ps_ok "/dev/kvm" "Crostini gate: launcher apps can open (placeholder)"
else
  ps_miss "/dev/kvm" "apps will NOT open (Crostini blocked)" \
          "sudo ./scripts/setup-system.sh  (reboot also recreates it via tmpfiles)"
fi

# Terminal entry points: Ash builds the ABSOLUTE path /usr/bin/vsh (and
# /usr/bin/crosh) and execvp()s it — PATH is never consulted, so the stub must
# live in /usr/bin. Without it the Terminal SWA shows 'failed to execvp'.
for stub in vsh crosh; do
  if [ -e "/usr/bin/$stub" ]; then
    ps_ok "/usr/bin/$stub" "Terminal entry point present"
  else
    ps_miss "/usr/bin/$stub" "Terminal: 'failed to execvp /usr/bin/$stub'" \
            "sudo ./scripts/setup-system.sh"
  fi
done

# D-Bus policy: without it the bridges cannot own org.chromium.* on the system
# bus, so nothing (launcher, terminal, power, ...) talks to them.
if [ -f /etc/dbus-1/system.d/chromeos-bridges.conf ]; then
  ps_ok "dbus policy" "bridges can own org.chromium.*"
else
  ps_miss "dbus policy" "bridges cannot register on the system bus" \
          "sudo ./scripts/setup-system.sh"
fi

# systemd-logind: the tray's suspend/reboot and session teardown depend on it.
# (A past failure mode: polkitd dying wedged logind. polkitd exits the moment
# the system bus goes down under it — it drops org.freedesktop.PolicyKit1, and
# polkit.service is a static unit with no Restart=, so nothing revives it but a
# future on-demand activation. setup-system used to trigger exactly that by
# running `restart dbus` on every policy change; it now reloads the bus in
# place (no connection drops) and re-ensures polkit. We still watch logind
# because it is what visibly breaks when polkit is gone.)
#
# is-active alone is NOT enough: a bus restart drops logind's connection while
# the unit stays 'active', and logind only claims org.freedesktop.login1 when it
# (re)connects. Name-less logind = Xorg's TakeControl/TakeDevice call gets no
# reply, it falls back to opening /dev/tty1 directly and dies with
# 'Cannot open virtual console 1 (Permission denied)'. So check the name owner.
if command -v systemctl >/dev/null 2>&1; then
  if ! systemctl is-active --quiet systemd-logind 2>/dev/null; then
    ps_miss "logind" "systemd-logind NOT active (suspend/reboot/tray dead)" \
            "systemctl status systemd-logind"
  elif command -v busctl >/dev/null 2>&1 &&
       ! busctl call org.freedesktop.DBus /org/freedesktop/DBus \
         org.freedesktop.DBus GetNameOwner s org.freedesktop.login1 >/dev/null 2>&1; then
    ps_miss "logind" "active but owns no D-Bus name (Xorg cannot take the VT)" \
            "sudo ./scripts/setup-system.sh  (restarts logind) or: sudo systemctl restart systemd-logind"
  else
    ps_ok "logind" "systemd-logind active and owns the bus name"
  fi
fi

# Bridges: only meaningful while a session is actually up. Gate on the session
# script itself rather than a hardcoded /tmp/.X11-unix/X0 socket — startx picks
# the first FREE display, so a real session can land on :1 and the X0 probe
# would silently skip this check. Not a setup-system.sh artefact (start-session.sh
# launches them), so this stays a soft signal that never fails a fresh machine.
if pgrep -f 'session/chromeos-linux-session' >/dev/null 2>&1; then
  for name in shill cras session crostini rmad power; do
    if pgrep -f "dist/bin/${name}-bridge" >/dev/null 2>&1; then
      ps_ok "${name}-bridge" "running"
    else
      printf '  WARN    %-14s not running (session is up)  -> check %s-bridge.log\n' \
             "${name}-bridge" "${name}"
    fi
  done
fi

echo
if [ "$status" -eq 0 ]; then
  echo "doctor: all requirements present; session preflight clean"
else
  echo "doctor: some requirements are missing (see above)"
fi
exit "$status"
