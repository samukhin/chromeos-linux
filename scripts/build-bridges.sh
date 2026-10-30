#!/usr/bin/env bash
# Build the D-Bus bridge daemons and helpers (no Nix, plain `go build`).
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

need go "go — $APT_HINT golang-go / $PAC_HINT go"

cd "$ASH_ROOT/dbus-bridges"

if [ ! -d vendor ]; then
  if [ -d "$ASH_ROOT/.cache/go-mod" ]; then
    export GOMODCACHE="$ASH_ROOT/.cache/go-mod"
  fi
  if [ "${VENDOR:-0}" = "1" ]; then
    echo "vendoring dependencies"
    go mod vendor
  fi
fi

if [ -d vendor ]; then
  echo "building (vendored deps)"
  GOFLAGS=-mod=vendor go build -o "$ASH_ROOT/dist/bin/" ./cmd/...
else
  echo "building (module cache: ${GOMODCACHE:-$(go env GOMODCACHE)})"
  go build -o "$ASH_ROOT/dist/bin/" ./cmd/...
fi

for b in shill-bridge cras-bridge power-bridge session-bridge crostini-bridge \
         rmad-bridge stub-bridge mojo-stub register-apps; do
  [ -x "$ASH_ROOT/dist/bin/$b" ] || die "missing binary: dist/bin/$b"
done

echo "bridges -> $ASH_ROOT/dist/bin/"
