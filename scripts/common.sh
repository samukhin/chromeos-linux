# shellcheck shell=bash
# Shared helpers for EVERY chromeos-linux script: the build ones (scripts/,
# chromeos-bin/), the runtime ones (setup-system.sh, smoke-test.sh) and the
# session (session/). Sourced, not executed.
#
# A script sets ASH_MSG_PREFIX before sourcing, so the shared log/die/note keep
# reading as if they were local to that script:
#
#   ASH_MSG_PREFIX="setup-system: "  ->  "setup-system: error: ..."
#   ASH_MSG_PREFIX="[session] "      ->  "[session] error: ..."
#
# Leaving it unset (the build scripts) preserves the plain historical wording
# ("error: ..."). The prefix is read at CALL time, so setting it after the
# source line works too.
: "${ASH_MSG_PREFIX:=}"

if [ -z "${ASH_ROOT:-}" ]; then
  ASH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
export ASH_ROOT

# die <message> — report on stderr and abort.
die() {
  printf '%serror: %s\n' "$ASH_MSG_PREFIX" "$*" >&2
  exit 1
}

# log <message> — progress/warnings on stderr.
log() {
  printf '%s%s\n' "$ASH_MSG_PREFIX" "$*" >&2
}

# note <message> — results on stdout.
note() {
  printf '%s%s\n' "$ASH_MSG_PREFIX" "$*"
}

# need <command> [install hint]
need() {
  command -v "$1" >/dev/null 2>&1 || die "missing '$1' — $2"
}

# have <command> -> 0 if present
have() {
  command -v "$1" >/dev/null 2>&1
}

# detect_drm_card — print the /dev/dri/cardN Ash should own.
#
# Honours ASH_DRM_CARD when it is set. Otherwise the card index is discovered
# at runtime because it is not stable: simpledrm can take card0 at boot and the
# real driver (i915, amdgpu, ...) then shows up as card1, so a hard-coded card0
# silently leaves the screen black.
#
# Preference order: writable card with a connected connector, connected card
# (so the preflight can report the permission problem), any writable card,
# any card. Returns 1 when /dev/dri has no card at all.
detect_drm_card() {
  if [ -n "${ASH_DRM_CARD:-}" ]; then
    printf '%s\n' "$ASH_DRM_CARD"
    return 0
  fi

  local card name status pass connected
  for pass in rw-connected connected rw any; do
    for card in /dev/dri/card[0-9]*; do
      [ -c "$card" ] || continue
      name="${card##*/}"
      case "$pass" in
        rw-connected|rw)
          [ -r "$card" ] && [ -w "$card" ] || continue
          ;;
      esac
      case "$pass" in
        rw-connected|connected)
          connected=0
          for status in "/sys/class/drm/$name"-*/status; do
            [ -e "$status" ] || continue
            if [ "$(cat "$status" 2>/dev/null)" = "connected" ]; then
              connected=1
              break
            fi
          done
          [ "$connected" = 1 ] || continue
          ;;
      esac
      printf '%s\n' "$card"
      return 0
    done
  done
  return 1
}

APT_HINT="Debian/Ubuntu: apt install"
PAC_HINT="Arch: pacman -S"
