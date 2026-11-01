#!/usr/bin/env bash
# Turn the prebuilt ChromiumOS Chrome build into an Ash shell that runs on a
# stock Linux userspace.
#
# Ported from the Nix packaging this repo used to ship (the `chromefixed`
# derivation): the binary patches fail loudly when the binary no longer
# matches, and nothing is patchelf'ed — the snapshot already uses
# /lib64/ld-linux-x86-64.so.2 and RUNPATH=$ORIGIN, so it runs on a stock
# userspace as-is, with libdisplayfix.so injected by the launcher.
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

# The libc++ ABI namespace demangles as `std::Cr` here and `std::__Cr` in
# later snapshots, so keep the namespace out of the pattern. The checked
# bytes are `cmpb $0,0x21(%rdi) / je +0x38` plus the next opcode; the patch
# turns that conditional skip into an unconditional jump to the same target
# (Init+0x4b, the delegate-cleanup epilogue).
va=$(sym_va ' display::DisplayConfigurator::Init\(std::.*unique_ptr<display::NativeDisplayDelegate')
verify_and_patch "DisplayConfigurator::Init (skip native display config)" \
  "$(va_to_offset "$va" "$DELTA" 13)" "807f2100743848" '\351\071\000\000\000\220\220'

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

va=$(sym_va ' display::DisplayConfigurator::RunPendingConfiguration\(\)')
verify_and_patch "RunPendingConfiguration (no-op)" \
  "$(va_to_offset "$va" "$DELTA")" "55" '\303'

va=$(sym_va ' ash::RedirectChromeLogging\(base::CommandLine const&\)')
verify_and_patch "RedirectChromeLogging (no-op)" \
  "$(va_to_offset "$va" "$DELTA")" "55" '\303'

# The service manager moved from chromeos:: to ash:: between snapshots;
# the leading space keeps the pattern off RemoteSetImpl<...>::OnDisconnect.
va=$(sym_va ' (chromeos|ash)::mojo_service_manager::.*::OnDisconnect\(')
verify_and_patch "OnDisconnect (no-op)" \
  "$(va_to_offset "$va" "$DELTA")" "55" '\303'

va=$(sym_va ' display::HasInternalDisplay\(\)' soft)
verify_and_patch "HasInternalDisplay (returns true)" \
  "$(va_to_offset "$va" "$DELTA")" "55" '\260\001\303' soft

# --- keyboard layout engine (RU/EN quick-settings chip drives typing) -------
# OzonePlatformX11::InitializeUI registers StubKeyboardLayoutEngine, whose
# Lookup always falls back to the hardcoded US layout, and the input
# controller's SetCurrentLayoutByName is a no-op stub — so switching RU/EN
# in Ash quick settings only moved the tray indicator. Mirror what
# OzonePlatformDrm does instead: build an XkbEvdevCodes converter plus a
# real XkbKeyboardLayoutEngine in one block, hand it to
# KeyboardLayoutEngineManager, and forward the input controller's
# SetCurrentLayoutByName through a thunk to the registered engine.

ui_va=$(sym_va ' t ui::\(anonymous namespace\)::OzonePlatformX11::InitializeUI\(')

# new[] size for the combined block: XkbKeyboardLayoutEngine (0xc8, same as
# the DRM platform) + XkbEvdevCodes converter (0x10) = 0xd8, was 0x20. The
# immediate is the second byte of `mov $0x20,%edi` at +333.
verify_and_patch "OzonePlatformX11::InitializeUI (engine block alloc 0xd8)" \
  "$(va_to_offset "$ui_va" "$DELTA" 334)" "20" '\330'

# Replace the StubKeyboardLayoutEngine construction with:
#   lea 0xc8(%rax),%rdi / mov %rax,%rbx / call XkbEvdevCodesC1 /
#   mov %rbx,%rdi / lea 0xc8(%rbx),%rsi / call XkbKeyboardLayoutEngineC1 /
#   mov %rbx,0x20(%r14) / mov %rbx,%rdi
# then falls through into the existing SetKeyboardLayoutEngine call. This
# snapshot keeps the fresh engine in %rbx and `this` in %r14 (the 1670871
# build had them the other way round), which is why the registers below
# differ from that revision's patch.
verify_and_patch "OzonePlatformX11::InitializeUI (real Xkb engine)" \
  "$(va_to_offset "$ui_va" "$DELTA" 343)" \
  "4889c34889c7e88e9bea03498b7e2049895e204885ff740a488b07ff5008498b5e204889df" \
  '\110\215\270\310\000\000\000\110\211\303\350\204\234\352\003\110\211\337\110\215\263\310\000\000\000\350\251\234\352\003\111\211\136\040\110\211\337'

# Overwrite the (now dead) StubKeyboardLayoutEngine::Lookup with a thunk
# for StubInputController::SetCurrentLayoutByName(name):
#   load keyboard_layout_engine_; when set, tail-jump to
#   engine->SetCurrentLayoutByName (vptr+0x18, identical signature), else
#   jump back into the original stub body. The stub engine is no longer
#   constructed after the patch above, so its Lookup is unreachable.
lookup_va=$(sym_va ' t ui::StubKeyboardLayoutEngine::Lookup\(')
verify_and_patch "StubKeyboardLayoutEngine::Lookup (forwarding thunk)" \
  "$(va_to_offset "$lookup_va" "$DELTA")" \
  "554889e5488b47084c8b4f10" \
  '\110\213\005\167\013\310\005\110\205\300\164\011\110\211\307\110\213\000\377\140\030\351\334\246\303\373'

# Redirect the StubInputController vtable slot (vptr+0x68 — the 14th entry
# of ui::InputController, verified against InputControllerEvdev, whose
# SetCurrentLayoutByName has a body of its own — .rela.dyn entry for
# 0xe0b1eb0, R_X86_64_RELATIVE addend 0x483ca20) to the thunk: verify the
# whole 24-byte relocation, write it with the new addend (thunk VA
# 0x8c0232a, this snapshot's StubKeyboardLayoutEngine::Lookup).
verify_and_patch "StubInputController::SetCurrentLayoutByName -> thunk" \
  "$((0x710270))" \
  "b01e0b0e00000000080000000000000020ca830400000000" \
  '\260\036\013\016\000\000\000\000\010\000\000\000\000\000\000\000\052\043\300\010\000\000\000\000'

# --- key press crash fix ----------------------------------------------------
#
# ui::(anonymous namespace)::GetEventPropertiesFromXEvent(type, event):
# for key types (7/8) it does `cmpl $0x36,0x4(%rdx)` (event is a core
# KeyPress/KeyRelease?) and, when the tag differs, falls into
#   xor %eax,%eax ; mov %rax,-0x48(%rbp) ; mov 0x20(%rax),%ebx
# i.e. dereferences NULL+0x20 -> SEGV. The original ChromeOS X server only
# delivered core key events (tag 0x36), so that branch was dead upstream;
# a modern Xorg delivers XI2 DeviceEvents (tag 0x1f) and every key press
# crashes Chrome ("Received signal 11 SEGV_MAPERR ... 000000000020").
#
# Retarget the `jne 8baf832` (75 22) to `jne 8baf816` (75 06): a foreign
# tag then lands on `cmp $6,%esi / jne <tail>`, and key types 7/8 skip to
# the function tail, returning an empty properties map — the same thing
# the neighboring helpers do for events they don't recognize. Key events
# themselves are built before this call, so nothing else changes.
props_va=$(sym_va ' t ui::\(anonymous namespace\)::GetEventPropertiesFromXEvent\(')
verify_and_patch "GetEventPropertiesFromXEvent (XI2 key events -> empty props)" \
  "$(va_to_offset "$props_va" "$DELTA" 46)" \
  "7522" \
  '\165\006'

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

# --- libdisplayfix + launcher ---------------------------------------------

"${CC:-cc}" -shared -fPIC -Wl,-soname,libdisplayfix.so \
  -o "$OUT/libdisplayfix.so" "$ASH_ROOT/scripts/displayfix.c"

cat > "$OUT/chromeos-ash" <<'WRAP'
#!/usr/bin/env bash
# Launcher for the patched Ash Chrome binary.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Ash is a ChromeOS build: it expects a live X display and a readable cookie.
if [ -z "${DISPLAY:-}" ]; then
  export DISPLAY=:0
fi
if [ -z "${XAUTHORITY:-}" ] || [ ! -r "${XAUTHORITY:-}" ]; then
  if [ -r /tmp/ash-xauth ]; then
    export XAUTHORITY=/tmp/ash-xauth
  fi
fi

# The shim back-fills DISPLAY/XAUTHORITY for processes that bypass this
# wrapper (Chrome re-execs). It is a no-op when the environment is sane.
export LD_PRELOAD="$HERE/libdisplayfix.so${LD_PRELOAD:+:$LD_PRELOAD}"

exec "$HERE/chrome" "$@"
WRAP
chmod +x "$OUT/chromeos-ash"

echo "patched chrome -> $OUT"
echo "launcher        -> $OUT/chromeos-ash"
