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

APT_HINT="Debian/Ubuntu: apt install"
PAC_HINT="Arch: pacman -S"
