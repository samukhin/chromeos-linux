#!/usr/bin/env bash
# Stubs for the ChromeOS shell entry points (`vsh`, `crosh`).
#
# Ash's Terminal SWA normally asks ChromeOS for a VM shell. On this build the
# in-binary call is patched to evaluate the injected terminal UI instead, so
# these are only reached if something shells out directly. Both land in an
# interactive bash; crosh gets a short banner to feel less out of place.
set -euo pipefail

log_dir="${ASH_LOG_DIR:-${TMPDIR:-/tmp}/chromeos-linux}"
mkdir -p "$log_dir" 2>/dev/null || true
{
  echo "[$(date --iso-8601=seconds 2>/dev/null || date)] $(basename "$0") $*"
  echo "stdin isatty=$([ -t 0 ] && echo YES || echo NO)"
  echo "DISPLAY=${DISPLAY:-<unset>} WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-<unset>}"
} >>"$log_dir/shell-stub.log" 2>&1 || true

cd "$HOME" 2>/dev/null || cd /tmp

# Linux apps must render into the Xwayland/sommeler stack that Ash actually
# composites, which lives on display :10 (--x-display=10 in chromeos-linux-session).
# Ash launches these apps inheriting Chrome's own $DISPLAY (the host Xorg, e.g.
# :1), so without this override their windows go to the host X server and never
# appear inside the session. Only override when unset/foreign so an app that was
# deliberately pointed elsewhere keeps its display.
case "${DISPLAY:-}" in
  :10|:10.*) ;;
  *) DISPLAY=:10; export DISPLAY ;;
esac

if [ "$(basename "$0")" = "crosh" ]; then
  echo "ChromeOS shell (crosh) is not available here; dropping you into bash."
  echo "Type 'exit' to leave."
fi

exec "${SHELL:-/bin/bash}" -i
