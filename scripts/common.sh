# shellcheck shell=bash
# Shared helpers for chromeos-linux build scripts. Sourced, not executed.

if [ -z "${ASH_ROOT:-}" ]; then
  ASH_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fi
export ASH_ROOT

die() {
  echo "error: $*" >&2
  exit 1
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
