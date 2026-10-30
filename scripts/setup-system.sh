#!/usr/bin/env bash
# One-time root setup for chromeos-linux: D-Bus policy, runtime directories,
# lsb-release identity, shell stubs. Idempotent; run again after changing the
# user that runs Ash.
#
#   sudo ./scripts/setup-system.sh [--user NAME] [--no-mojo] [--force]
#   sudo ./scripts/setup-system.sh --undo
set -euo pipefail

ASH_ROOT="${ASH_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

die() { echo "setup-system: error: $*" >&2; exit 1; }
note() { echo "setup-system: $*"; }

# Apply a system D-Bus policy change.
#
# Prefer `reload`: dbus-broker re-reads <includedir>/etc/dbus-1/system.d (which
# holds our chromeos-bridges.conf) and pushes the fresh policy into the RUNNING
# broker — launcher_reload_config() -> launcher_set_policy() issues a SetPolicy
# call on org.bus1.DBus.Listener. The broker process is never torn down, so no
# connection drops: polkitd keeps org.freedesktop.PolicyKit1 (and thus never
# exits), and logind/NetworkManager are left alone.
#
# Fall back to `restart` only for buses that cannot reload (dbus-daemon reads
# policy solely at startup). Tearing the bus down makes every client lose its
# connection; polkitd then exits — it drops its name, and polkit.service is a
# static unit with no Restart=, so nothing brings it back but a future on-demand
# activation that may never come. Restart it on the new bus instead.
apply_dbus_policy() {
  if ! command -v systemctl >/dev/null 2>&1 || ! [ -d /run/systemd/system ]; then
    note "WARNING: no systemd running — restart dbus (or reboot) to pick up the policy"
    return 0
  fi
  if systemctl reload dbus.service >/dev/null 2>&1; then
    note "reloaded system D-Bus policy (bus kept running; polkit/logind untouched)"
  else
    note "reload unsupported — restarting system D-Bus (running services reconnect)"
    systemctl restart dbus.service >/dev/null 2>&1 ||
      note "WARNING: could not restart dbus — reboot before starting the session"
    systemctl restart polkit.service >/dev/null 2>&1 ||
      systemctl restart polkitd.service >/dev/null 2>&1 || true
  fi
}

# polkitd is static (started at boot, no Restart=): once the bus goes down under
# it, it exits and only a future on-demand activation revives it — leaving polkit
# (and logind, which leans on it) dormant. Start it if it is not already up so
# setup leaves the machine ready for the session. Idempotent: no-op while running.
ensure_polkit() {
  if ! command -v systemctl >/dev/null 2>&1; then return 0; fi
  if ! [ -d /run/systemd/system ]; then return 0; fi
  if systemctl is-active --quiet polkit.service 2>/dev/null; then return 0; fi
  if systemctl is-active --quiet polkitd.service 2>/dev/null; then return 0; fi
  systemctl start polkit.service >/dev/null 2>&1 ||
    systemctl start polkitd.service >/dev/null 2>&1 || true
  note "started polkit (it was not running)"
}

# systemd-logind must OWN org.freedesktop.login1 on the system bus: Xorg asks
# logind (TakeControl/TakeDevice) for the VT, and with no reply it falls back to
# opening /dev/tty1 directly — Permission denied for a non-root user, so startx
# dies with 'Cannot open virtual console 1'. A bus restart drops logind's
# connection while the unit stays 'active', and logind only claims the name when
# it (re)connects — so is-active passes while Xorg cannot start. Restarting the
# unit makes it reattach and re-own the name.
ensure_logind() {
  if ! command -v systemctl >/dev/null 2>&1 || ! [ -d /run/systemd/system ]; then
    return 0
  fi
  systemctl is-active --quiet systemd-logind.service 2>/dev/null || return 0
  command -v busctl >/dev/null 2>&1 || return 0
  busctl call org.freedesktop.DBus /org/freedesktop/DBus \
    org.freedesktop.DBus GetNameOwner s org.freedesktop.login1 >/dev/null 2>&1 && return 0
  note "systemd-logind is active but owns no D-Bus name — restarting it"
  systemctl restart systemd-logind.service >/dev/null 2>&1 ||
    note "WARNING: could not restart systemd-logind — Xorg will fail to open the VT"
}

POLICY_SRC="$ASH_ROOT/session/dbus-policies/chromeos-bridges.conf"
POLICY_DST="/etc/dbus-1/system.d/chromeos-bridges.conf"
TMPFILES_SRC="$ASH_ROOT/session/tmpfiles.d/chromeos-linux.conf"
TMPFILES_DST="/etc/tmpfiles.d/chromeos-linux.conf"
LSB="/etc/lsb-release"
LSB_BAK="/etc/lsb-release.chromeos-linux.bak"
MOJO=1
FORCE=0
TARGET_USER="${SUDO_USER:-}"
UNDO=0

while [ $# -gt 0 ]; do
  case "$1" in
    --user) TARGET_USER="${2:-}"; shift 2 ;;
    --user=*) TARGET_USER="${1#--user=}"; shift ;;
    --no-mojo) MOJO=0; shift ;;
    --force) FORCE=1; shift ;;
    --undo) UNDO=1; shift ;;
    -h|--help)
      sed -n '2,9p' "$0"; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

[ "$EUID" -eq 0 ] || die "must run as root (sudo ./scripts/setup-system.sh)"

# --- undo ------------------------------------------------------------------

if [ "$UNDO" = "1" ]; then
  rm -f "$POLICY_DST" "$TMPFILES_DST"
  for dir in /usr/local/bin /usr/bin; do
    for stub in vsh crosh; do
      if [ -L "$dir/$stub" ] &&
         grep -q "shell-stub" "$(readlink -f "$dir/$stub")" 2>/dev/null; then
        rm -f "$dir/$stub"
      fi
      if [ -f "$dir/$stub.chromeos-linux.bak" ]; then
        mv -f "$dir/$stub.chromeos-linux.bak" "$dir/$stub"
        note "restored $dir/$stub"
      fi
    done
  done
  if [ -f "$LSB_BAK" ]; then
    mv -f "$LSB_BAK" "$LSB"
    note "restored $LSB"
  fi
  apply_dbus_policy
  note "removed policy, tmpfiles, stubs"
  exit 0
fi

[ -n "$TARGET_USER" ] || die "cannot determine the target user — pass --user NAME"
[ "$TARGET_USER" != "root" ] || die "the Ash session should not run as root — pass --user NAME"
id "$TARGET_USER" >/dev/null 2>&1 || die "no such user: $TARGET_USER"

changed=0

# --- D-Bus policy ----------------------------------------------------------

[ -f "$POLICY_SRC" ] || die "missing $POLICY_SRC"
mkdir -p /etc/dbus-1/system.d
sed "s|<policy user=\"ash\">|<policy user=\"$TARGET_USER\">|" "$POLICY_SRC" > "$POLICY_DST.new"
if [ -f "$POLICY_DST" ] && cmp -s "$POLICY_DST.new" "$POLICY_DST"; then
  rm -f "$POLICY_DST.new"
else
  mv "$POLICY_DST.new" "$POLICY_DST"
  changed=1
  note "installed $POLICY_DST (user=$TARGET_USER)"
fi

# --- runtime directories ---------------------------------------------------

[ -f "$TMPFILES_SRC" ] || die "missing $TMPFILES_SRC"
mkdir -p /etc/tmpfiles.d
sed "s|@USER@|$TARGET_USER|g" "$TMPFILES_SRC" > "$TMPFILES_DST.new"
if [ -f "$TMPFILES_DST" ] && cmp -s "$TMPFILES_DST.new" "$TMPFILES_DST"; then
  rm -f "$TMPFILES_DST.new"
else
  mv "$TMPFILES_DST.new" "$TMPFILES_DST"
  changed=1
  note "installed $TMPFILES_DST"
fi

if command -v systemd-tmpfiles >/dev/null 2>&1; then
  systemd-tmpfiles --create "$TMPFILES_DST"
else
  # Minimal fallback: type path mode user group
  while read -r type path mode user group _; do
    case "$type" in d|D) mkdir -p "$path"; chown "$user:$group" "$path"; chmod "$mode" "$path" ;;
                    f|F) mkdir -p "$(dirname "$path")"; touch "$path"; chown "$user:$group" "$path"; chmod "$mode" "$path" ;;
    esac
  done < "$TMPFILES_DST"
fi
# The profile is created by tmpfiles, but be explicit when it was missing.
mkdir -p "/var/lib/ash-profile/test-user"
chown -R "$TARGET_USER:users" /var/lib/ash-profile

# --- lsb-release -----------------------------------------------------------

if [ "$MOJO" = "1" ]; then
  keys=(
    "DEVICETYPE=CHROMEBOOK"
    "CHROMEOS_RELEASE_NAME=Chrome OS"
  )
else
  keys=("DEVICETYPE=CHROMEBOOK")
fi

if [ -f "$LSB" ] && ! [ -f "$LSB_BAK" ]; then
  cp -a "$LSB" "$LSB_BAK"
  note "backed up existing $LSB -> $LSB_BAK"
fi
for kv in "${keys[@]}"; do
  key=${kv%%=*}
  if [ -f "$LSB" ] && grep -q "^$key=" "$LSB"; then
    sed -i "s|^$key=.*|$kv|" "$LSB"
  else
    printf '%s\n' "$kv" >> "$LSB"
  fi
done
note "updated $LSB (${keys[*]})"

# --- shell stubs -----------------------------------------------------------

# Ash's terminalPrivate builds an ABSOLUTE path (kVmShellCommand ->
# "/usr/bin/vsh", kCroshCommand -> "/usr/bin/crosh") and execvp()s it, so PATH
# is never consulted: the stub MUST be at /usr/bin for the SWA's exec to find
# it. We also link them into /usr/local/bin so a bare `vsh`/`crosh` typed at a
# prompt still resolves. The stub is a symlink into the tree (single source of
# truth); any pre-existing non-symlink is backed up unless --force.

for dir in /usr/local/bin /usr/bin; do
  for stub in vsh crosh; do
    dest="$dir/$stub"
    if [ -e "$dest" ] && [ ! -L "$dest" ]; then
      if [ "$FORCE" = "1" ]; then
        mv -f "$dest" "$dest.chromeos-linux.bak"
        ln -sf "$ASH_ROOT/session/stubs/shell-stub.sh" "$dest"
        note "replaced $dest (old file -> $dest.chromeos-linux.bak)"
      else
        note "WARNING: $dest exists and is not ours — leaving it alone (--force to replace)"
      fi
    elif [ -L "$dest" ]; then
      ln -sf "$ASH_ROOT/session/stubs/shell-stub.sh" "$dest"
    else
      ln -sf "$ASH_ROOT/session/stubs/shell-stub.sh" "$dest"
      note "installed $dest"
    fi
  done
done

# --- reload D-Bus if the policy changed ------------------------------------

if [ "$changed" = "1" ]; then
  apply_dbus_policy
fi

# Whatever happened above (reloaded in place, restarted and restored, or policy
# untouched), leave polkit running: a session that starts with polkit dormant
# wedges logind as soon as something needs authorization.
ensure_polkit

# And leave logind actually able to answer: Xorg needs it to take the VT, so a
# logind that is 'active' but name-less on the bus breaks the session start.
ensure_logind

cat <<EOF

setup-system: done
  user            $TARGET_USER
  dbus policy     $POLICY_DST
  tmpfiles        $TMPFILES_DST
  lsb-release     $LSB  (mode: $([ "$MOJO" = 1 ] && echo mojo+dbus-bridges || echo dbus-bridges))

Next:
  make                      # build everything (as your user)
  ./session/start-session.sh
EOF
