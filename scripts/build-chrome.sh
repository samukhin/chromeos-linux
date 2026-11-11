#!/usr/bin/env bash
# Turn the prebuilt ChromiumOS Chrome build into an Ash shell that runs on a
# stock Linux userspace.
#
# Ported from the Nix packaging this repo used to ship (the `chromefixed`
# derivation): the binary patches fail loudly when the binary no longer
# matches, and nothing is patchelf'ed — the snapshot already uses
# /lib64/ld-linux-x86-64.so.2 and RUNPATH=$ORIGIN, so it runs on a stock
# userspace as-is.
#
# This branch targets Ash directly on DRM/KMS (--ozone-platform=drm). The
# X11-only patches (DisplayConfigurator::Init, RunPendingConfiguration,
# HasInternalDisplay, the X11 keyboard engine and the XEvent key fix) are
# deliberately NOT applied: on DRM the native display delegate must be
# installed and the real KMS configuration must run.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SRC="$ASH_ROOT/chromeos-bin/chrome"
OUT="$ASH_ROOT/dist/chrome"
CHROME="$OUT/chrome"

need nm "nm — binutils ($APT_HINT binutils / $PAC_HINT binutils)"
need objdump "objdump — binutils ($APT_HINT binutils / $PAC_HINT binutils)"
need gawk "gawk — $APT_HINT gawk / $PAC_HINT gawk"
need "${CC:-cc}" "C compiler — $APT_HINT build-essential / $PAC_HINT base-devel"

[ -x "$SRC/chrome" ] || die "no source binary — run chromeos-bin/fetch.sh first"

echo "staging $SRC -> $OUT"
rm -rf "$OUT"
mkdir -p "$OUT"
cp -a "$SRC/." "$OUT/"
chmod u+w "$CHROME"

# --- helpers ---------------------------------------------------------------

# Bytes we are about to write; NULs keep this out of shell variables, so ask
# printf and count through a pipe instead.
payload_len() { printf "$1" | wc -c; }

# verify_and_patch <what> <offset> <expected-hex> <printf-fmt> [soft]
#   Checks that the binary still has <expected-hex> at <offset> (prefix
#   compare, same byte counts as the original script), then overwrites with
#   the payload. "soft" downgrades every failure to a warning.
verify_and_patch() {
  local what=$1 offset=$2 expected=$3 fmt=$4 mode=${5:-strict}
  local got prefix want

  [ -n "$offset" ] || { fail_or_warn "$mode" "$what: symbol/offset not found"; return 0; }

  got=$(dd if="$CHROME" bs=1 skip="$offset" count="$(payload_len "$fmt")" 2>/dev/null |
        od -An -v -tx1 | tr -d ' \n')
  want=$expected
  prefix=${got:0:${#expected}}

  if [ "$prefix" != "$want" ]; then
    fail_or_warn "$mode" "$what patch bytes changed at $offset: got '$prefix', expected '$want'"
    return 0
  fi

  printf "$fmt" | dd of="$CHROME" bs=1 seek="$offset" conv=notrunc 2>/dev/null
  echo "patched $what at $offset"
}

fail_or_warn() {
  if [ "$1" = "strict" ]; then
    die "$2"
  fi
  echo "WARNING: $2" >&2
}

# Same lookup, but silently empty when the symbol is absent: for patches that
# only some snapshots need (the code simply does not exist yet in older ones).
sym_va_opt() {
  nm -C "$CHROME" | SYM_PATTERN="$1" \
        awk '$0 ~ ENVIRON["SYM_PATTERN"] { print "0x"$1; exit }'
}

# Hex string -> printf octal-escape format (payloads whose bytes we compute,
# e.g. relative jump displacements, cannot be literals in the script).
hex_to_fmt() {
  awk -v h="$1" 'BEGIN {
    for (i = 1; i <= length(h); i += 2)
      printf "\\%03o", strtonum("0x" substr(h, i, 2))
  }'
}

# rel32 for `jmp <target>` at <site>: bytes of (target - (site + 5)) as hex.
# Accepts decimal or 0x-hex arguments (awk's -v does not parse 0x literals,
# hence the explicit strtonum).
rel32_hex() { # <target_va> <next_ip_va>
  awk -v t="$1" -v n="$2" 'BEGIN {
    if (t ~ /^0x/) t = strtonum(t)
    if (n ~ /^0x/) n = strtonum(n)
    d = t - n
    if (d < 0) d += 4294967296
    for (i = 0; i < 4; i++) printf "%02x", int(d / (256 ^ i)) % 256
  }'
}

# Symbol address as 0x... from GNU nm (demangled). Fails loudly unless soft.
# The pattern goes through the environment: passing it with awk -v would eat
# the backslashes in "\(..." before the regex engine sees them.
sym_va() {
  local pattern=$1 mode=${2:-strict} out
  out=$(nm -C "$CHROME" | SYM_PATTERN="$pattern" \
        awk '$0 ~ ENVIRON["SYM_PATTERN"] { print "0x"$1 }')
  if [ -z "$out" ]; then
    fail_or_warn "$mode" "symbol not found: $pattern"
  fi
  printf '%s' "$out"
}

# VMA -> file offset using the .text section delta (same approximation the
# Nix build used).
text_delta() {
  objdump -h "$CHROME" | awk '$2 == ".text" {
    printf "%d\n", strtonum("0x"$6) - strtonum("0x"$4)
  }'
}

va_to_offset() { # <va> <delta> [+extra]
  awk -v va="$1" -v delta="$2" -v extra="${3:-0}" \
    'BEGIN { printf "%d\n", strtonum(va) + extra + delta }'
}

# --- string patches --------------------------------------------------------

OLD_STUB='chrome.terminalPrivate.openVmshellProcess([], () => {})'
NEW_STUB='eval(localStorage.t||"")'
OFFSET=$( (grep -Fboa "$OLD_STUB" "$CHROME" | head -1 | cut -d: -f1) || true)
if [ -n "$OFFSET" ]; then
  printf '%-55s' "$NEW_STUB" | head -c 55 |
    dd of="$CHROME" bs=1 seek="$OFFSET" conv=notrunc 2>/dev/null
  echo "patched terminal.js stub at offset $OFFSET"
else
  echo "WARNING: terminal.js stub not found in chrome binary" >&2
fi

# CSP relaxation so the injected Terminal page can eval its UI.
while IFS=: read -r csp_offset _; do
  printf "'unsafe-eval'     " | head -c 18 |
    dd of="$CHROME" bs=1 seek="$csp_offset" conv=notrunc 2>/dev/null
  echo "patched CSP wasm-unsafe-eval -> unsafe-eval at $csp_offset"
done < <(grep -Fboa "'wasm-unsafe-eval'" "$CHROME" || true)

# --- symbol patches --------------------------------------------------------

DELTA=$(text_delta)
[ -n "$DELTA" ] || die ".text section not found in $CHROME"

# DisplayConfigurator::Init and RunPendingConfiguration are intentionally left
# untouched: on DRM, Shell::InitializeDisplayManager() hands the configurator a
# DrmNativeDisplayDelegate, ForceInitialConfigure() calls its Initialize(), and
# the real KMS modeset must run. The X11 branch used to patch both of them out
# because the X11 delegate is null.

# Only newer snapshots have WaylandDmabufFeedbackManager, so on an older
# binary there is no dmabuf probing to disable.
dmabuf_va=$(sym_va_opt ' exo::wayland::WaylandDmabufFeedbackManager::WaylandDmabufFeedbackManager\(exo::Display\*\)')
if [ -n "$dmabuf_va" ]; then
  verify_and_patch "WaylandDmabufFeedbackManager (no dmabuf probing)" \
    "$(va_to_offset "$dmabuf_va" "$DELTA" 112)" "e8fdd63d08488bb80001000048" \
    '\111\307\107\010\000\000\000\000\351\137\004\000\000'
else
  echo "skipped WaylandDmabufFeedbackManager patch (symbol not in this snapshot)"
fi

va=$(sym_va ' ash::RedirectChromeLogging\(base::CommandLine const&\)')
verify_and_patch "RedirectChromeLogging (no-op)" \
  "$(va_to_offset "$va" "$DELTA")" "55" '\303'

# The service manager moved from chromeos:: to ash:: between snapshots;
# the leading space keeps the pattern off RemoteSetImpl<...>::OnDisconnect.
va=$(sym_va ' (chromeos|ash)::mojo_service_manager::.*::OnDisconnect\(')
verify_and_patch "OnDisconnect (no-op)" \
  "$(va_to_offset "$va" "$DELTA")" "55" '\303'

# --- wayland damage freeze fix ------------------------------------------------
#
# Native-Wayland clients freeze on screen while wl_surface.frame callbacks
# keep firing (Alacritty: typed text appears only when a desktop-level event,
# e.g. the launcher, forces a full redraw). Mesa's wayland swrast signals
# "the whole surface changed" with
#   wl_surface.damage(0, 0, INT_MAX, INT_MAX)
# and exo::Surface::Damage unions that raw rect into its pending-damage
# cc::Region. SkRegion::op silently DISCARDS rects whose right/bottom ==
# INT_MAX (it compares both against $0x7fffffff and, on a match, performs
# the union with an empty rect instead), so the damage region stays empty:
# viz schedules no redraw, the compositor shows the old buffer, and frame
# callbacks are still sent per vsync — the client renders on happily into a
# buffer nobody sees. Any event that damages the whole desktop through
# another path (window map, launcher open) then draws the stale surface with
# its latest content in one jump.
#
# Fix at the choke point: a cave clamps all four damage coordinates of the
# incoming gfx::Rect to [0, 30000] before the union. 30000 px covers any
# real output while width*height stays inside int32 for any downstream area
# math; for well-behaved clients (coords within the surface) the clamp is a
# no-op. The cave overwrites an int3 padding run, hijacks the 6-byte
# function prologue (push %rbp / mov %rsp,%rbp / push %r15), replays those
# instructions and jumps back to entry+6 — only %rax and flags are touched,
# and the prologue reads no flags before its own `testb`.
#
# Cave payload (105 bytes): the same 24-byte clamp block over each int32
# field of the rect at %rsi — offsets 0/4/8/12 = left/top/right/bottom
# (the memory operand is oo for offsets 4/8/12, plain (%rsi) for offset 0):
#   8b 46 oo          mov  oo(%rsi),%eax     ; load the field
#   3d 30 75 00 00    cmp  $0x7530,%eax      ; high clamp: min(v, 30000)
#   7e 05             jle  +5
#   b8 30 75 00 00    mov  $0x7530,%eax
#   85 c0             test %eax,%eax         ; low clamp: max(v, 0)
#   7d 02             jge  +2
#   31 c0             xor  %eax,%eax
#   89 46 oo          mov  %eax,oo(%rsi)
# then the replayed prologue (55 48 89 e5 41 57) and e9 rel32 back to
# entry+6; the trailing 00 00 00 00 is the displacement placeholder the
# build splices in below. The cave region is verified to be int3 before
# writing and the entry against the original prologue, so any snapshot
# drift fails loudly.

cave_va=0x700b213
entry_va=$(sym_va ' exo::Surface::Damage\(gfx::Rect const&\)')

CAVE_HEX='8b063d307500007e05b83075000085c07d0231c089068b46043d307500007e05b83075000085c07d0231c08946048b46083d307500007e05b83075000085c07d0231c08946088b460c3d307500007e05b83075000085c07d0231c089460c554889e54157e900000000'
cave_hex=$CAVE_HEX

cave_len=$((${#cave_hex} / 2))
# The cave must end in `e9 00 00 00 00` (jmp rel32 placeholder) so the
# build can splice in the real displacement.
case ${cave_hex: -10} in
  e900000000) ;;
  *) die "damage-clamp cave does not end with the jmp rel32 placeholder" ;;
esac

# Back-jump: from the cave's trailing jmp (next IP = cave_va + cave_len)
# to entry_va + 6, the first instruction past the hijacked prologue.
back_rel=$(rel32_hex "$((entry_va + 6))" "$((cave_va + cave_len))")
cave_hex="${cave_hex:0: -8}${back_rel}"
cave_off=$(va_to_offset "$cave_va" "$DELTA")
verify_and_patch "exo::Surface::Damage (damage clamp cave)" \
  "$cave_off" \
  "$(printf 'cc%.0s' $(seq 1 "$cave_len"))" \
  "$(hex_to_fmt "$cave_hex")"

# Entry: replace the 6-byte prologue (55 48 89 e5 41 57 — push %rbp /
# mov %rsp,%rbp / push %r15) with `jmp rel32` (5 bytes) + nop (1 byte); the
# split falls exactly on instruction boundaries, and the cave replays both
# instructions before jumping back to entry+6.
fwd_rel=$(rel32_hex "$cave_va" "$((entry_va + 5))")
verify_and_patch "exo::Surface::Damage (entry -> damage clamp cave)" \
  "$(va_to_offset "$entry_va" "$DELTA")" \
  "554889e54157" \
  "$(hex_to_fmt "e9${fwd_rel}90")"

# --- GPU: native pixmap import gate ----------------------------------------
# Without this, every X11 client on the sommelier display gets a white window
# and the GPU log fills with
#   SharedImageFactory: Could not find SharedImageBackingFactory with params:
#   usage: |Gles2|Raster|Display|Scanout, format: 15, gmb_type: platform
# (see also the libminigbm shim below — the two together close the
# dmabuf -> exo -> OzoneImageBacking path).
#
# OzoneImageBackingFactory::IsSupported ends in a call to the active GL
# ozone's CanImportNativePixmap(); for the X11/EGL ozone that is
# ui::{anonymous}::GLOzoneEGLX11::CanImportNativePixmap (folded together with
# the Gbm twin at one address), and it reads a capability flag filled during
# EGL initialization instead of asking the driver for the extensions we
# actually need (EGL_EXT_image_dma_buf_import, which the host Mesa exposes).
# With the flag unset the factory refuses every platform GMB and viz has
# nowhere to put an exo dmabuf — hence the white window.
#
# This is the 1040000 analogue of the three NativePixmapEGLX11Binding patches
# the 1670871 build needed (see /home/user/patch.diff): in this older snapshot
# there is no IsSharedImageFormatSupported/GetNativePixmapSupportType pair —
# the whole decision sits in this one predicate. Force it true; the import
# itself then runs through gl::GLImageNativePixmap::Initialize, which accepts
# BGRX_8888 (its allow-mask has bit 12 set) and hands the dmabuf to Mesa EGL.
# Prologue `push %rbp / mov %rsp,%rbp / call` -> `mov $1,%eax / ret`.
va=$(sym_va ' t ui::\(anonymous namespace\)::GLOzoneEGLX11::CanImportNativePixmap\(\)')
verify_and_patch "GLOzoneEGLX11::CanImportNativePixmap (always true)" \
  "$(va_to_offset "$va" "$DELTA")" "554889e5e8" \
  '\270\001\000\000\000\303'

# ...but that alone is not enough on this host: the GPU process runs plain
# GLX (it links libGLX_mesa — no ANGLE, no libEGL at all), so the active
# ozone is GLOzoneGLX, whose CanImportNativePixmap() is the shared
# `return false` thunk folded together with GLOzoneEGL::'s and
# gl::GLImage::GetNativePixmap's — patching that address would corrupt all
# three. The gate that actually refuses the platform GMB lives inside
# OzoneImageBackingFactory::IsSupported itself, in two conditional jumps:
#   +0x43  je fail   — after CanImportNativePixmapToVulkan(); only taken on
#                      the Vulkan branch (al set), NOP it so the result is
#                      ignored;
#   +0x5d  je true   — skips the GLOzone CanImportNativePixmap probe; make
#                      it unconditional so IsSupported always says yes and
#                      the real import runs downstream (a genuine import
#                      failure still surfaces as a null backing, which
#                      ash.log shows).
# Prologue-relative offsets, so the usual byte verification applies.
va=$(sym_va ' gpu::OzoneImageBackingFactory::IsSupported\(')
verify_and_patch "OzoneImageBackingFactory::IsSupported (ignore Vulkan import gate)" \
  "$(va_to_offset "$va" "$DELTA" 67)" "7430" '\220\220'
verify_and_patch "OzoneImageBackingFactory::IsSupported (skip GL ozone import gate)" \
  "$(va_to_offset "$va" "$DELTA" 93)" "7412" '\353\022'

# --- libminigbm shim (Mesa stand-in) ---------------------------------------
# Chrome is built against ChromeOS' minigbm, whose usage bits and import type
# codes differ from Mesa's (GBM_BO_IMPORT_FD_MODIFIER: 0x5505 vs 0x5504), so
# Mesa's gbm returns NULL and the GPU process never finds a shared image
# backing. Swap the pristine snapshot aside and build the shim in its place;
# it dlopens libgbm.so.1 at load time. See scripts/minigbm_shim.c.
[ -f "$OUT/libminigbm.so" ] || die "no pristine libminigbm.so in $OUT"
mv "$OUT/libminigbm.so" "$OUT/libminigbm.so.orig"
echo "kept pristine $OUT/libminigbm.so.orig"
"${CC:-cc}" -shared -fPIC -O2 -o "$OUT/libminigbm.so" \
  "$ASH_ROOT/scripts/minigbm_shim.c" -ldl
echo "built minigbm shim -> $OUT/libminigbm.so ($(stat -c%s "$OUT/libminigbm.so") bytes)"

# --- touchpad shim (LD_PRELOAD) -------------------------------------------
# The generic snapshot has no ChromeOS libgestures/libinput glue, so Ash's
# evdev backend drops EV_ABS (touchpad) and REL_WHEEL entirely; only REL_X/Y
# from the TrackPoint survives. This interposer rewrites the touchpad's MT
# stream into REL_X/REL_Y + tap/click buttons the existing converter already
# understands. It is preloaded by session/chromeos-linux-session. See
# scripts/ash_touchpad_shim.c.
"${CC:-cc}" -shared -fPIC -O2 -o "$OUT/libash-touchpad.so" \
  "$ASH_ROOT/scripts/ash_touchpad_shim.c" -ldl -pthread -lm
echo "built touchpad shim -> $OUT/libash-touchpad.so ($(stat -c%s "$OUT/libash-touchpad.so") bytes)"

# --- crashpad handler ------------------------------------------------------

mv "$OUT/chrome_crashpad_handler" "$OUT/chrome_crashpad_handler.real"
cat > "$OUT/chrome_crashpad_handler" <<'CWRAP'
#!/usr/bin/env bash
has_db=0
for arg in "$@"; do
  case "$arg" in --database*) has_db=1; break;; esac
done
if [ "$has_db" -eq 0 ]; then
  mkdir -p "${TMPDIR:-/tmp}/ash-crashes"
  set -- "$@" --database="${TMPDIR:-/tmp}/ash-crashes"
fi
exec "$(dirname "$0")/chrome_crashpad_handler.real" "$@"
CWRAP
chmod +x "$OUT/chrome_crashpad_handler"

# --- launcher --------------------------------------------------------------

cat > "$OUT/chromeos-ash" <<'WRAP'
#!/usr/bin/env bash
# Launcher for the patched Ash Chrome binary.
#
# DRM mode: Ash owns the KMS display itself, so there is no DISPLAY or
# XAUTHORITY to set up here. The session script passes --ozone-platform=drm.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$HERE/chrome" "$@"
WRAP
chmod +x "$OUT/chromeos-ash"

echo "patched chrome -> $OUT"
echo "launcher        -> $OUT/chromeos-ash"
