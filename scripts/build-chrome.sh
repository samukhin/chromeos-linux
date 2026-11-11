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
        od -An -tx1 | tr -d ' \n')
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

# WaylandDmabufFeedbackManager: the patch that used to live here zeroed the
# version field at this+8 and skipped the gpu::Capabilities probe that fills
# the dmabuf format/modifier table. Consequences of each state, all measured:
#   version 0 -> Server::Initialize() skips wl_global_create() for
#                zwp_linux_dmabuf_v1 entirely: the host advertises no dmabuf
#                and every client stays on wl_shm (the original behaviour);
#   version 4 -> the global appears, but SendFeedback() then NULL-derefs the
#                never-filled format table (SEGV in ash.log) the moment a
#                client asks for default feedback;
#   unpatched -> the probe runs and fills the table. This is the state under
#                test now. If it reproduces the original non-ChromeOS
#                crash/hang, restore the patch (git restore this file).
# Original bytes at constructor+112 for reference: e8fdd63d08488bb80001000048

va=$(sym_va ' ash::RedirectChromeLogging\(base::CommandLine const&\)')
verify_and_patch "RedirectChromeLogging (no-op)" \
  "$(va_to_offset "$va" "$DELTA")" "55" '\303'

va=$(sym_va ' ash::mojo_service_manager::.*::OnDisconnect\(')
verify_and_patch "OnDisconnect (no-op)" \
  "$(va_to_offset "$va" "$DELTA")" "55" '\303'

# System UI blur (shelf, quick settings, hotseat) is gated on RAM, not GPU:
# chromeos::features::IsSystemBlurEnabled() is literally
#   return base::SysInfo::AmountOfTotalPhysicalMemory() > 4GiB;   (0x100000000)
# read from /proc/meminfo, with no FeatureList or command-line override.
# So on a <=4 GiB host (VirtualBox guests, typical Haswell laptops) the panel
# and quick settings render opaque even though the compositor draws backdrop
# filters fine on any GPU — viz::SoftwareRenderer has its own
# GetBackdropFilterShader, so no hardware is actually required. Force it true
# so blur works regardless of installed RAM. Costs some FPS on small-RAM hosts.
# Prologue: push %rbp; mov %rsp,%rbp; call ... -> mov $1,%eax; ret (no push, so
# the stack stays balanced).
va=$(sym_va ' chromeos::features::IsSystemBlurEnabled\(\)')
verify_and_patch "IsSystemBlurEnabled (always true, blur on any RAM)" \
  "$(va_to_offset "$va" "$DELTA")" "55" '\270\001\000\000\000\303'

# --- GPU: ozone X11 pixmap import ------------------------------------------
# Without these, X11 clients on the sommelier display get white windows and a
# GPU log full of "OzoneImageBacking::ProduceSkiaGanesh failed to create GL
# representation" (774x per session). Three separate blockers, all on the
# NativePixmap -> GL path that OzoneImageBacking uses; exo hands us
# BGRX_8888, and ANGLE here has no EGL_EXT_image_dma_buf_import.

# 1) NativePixmapEGLX11Binding::IsSharedImageFormatSupported -> true. The
#    original only accepts BGRA_8888, so CanImportNativePixmap() said no to
#    the BGRX surfaces exo actually produces. vaddr 0x78e1fee, prologue
#    "push %rbp; mov %rsp,%rbp; sub $0x10,%rsp" -> "mov $1,%eax; ret".
va=$(sym_va ' t ui::NativePixmapEGLX11Binding::IsSharedImageFormatSupported\(')
verify_and_patch "IsSharedImageFormatSupported (accept BGRX)" \
  "$(va_to_offset "$va" "$DELTA")" "554889e54883" '\270\001\000\000\000\303'

# 2) GetNativePixmapSupportType -> kX11Pixmap (2). It prefers kDMABuf when
#    EGL_EXT_image_dma_buf_import is present, which ANGLE never exposes here,
#    and CanImportNativeGLXPixmap() only asks dri3/glx, not GL. vaddr
#    0x78e688e, same prologue -> "mov $2,%eax; ret".
va=$(sym_va ' t ui::\(anonymous namespace\)::GetNativePixmapSupportType\(\)')
verify_and_patch "GetNativePixmapSupportType (kX11Pixmap)" \
  "$(va_to_offset "$va" "$DELTA")" "554889e5e8af" '\270\002\000\000\000\303'

# 3) Inside NativePixmapEGLX11Binding::Create: an inlined
#    gl::IsFormatSupported(format) rejects kBGRX_8888 ("je -> 'format is
#    unsupported'" VLOG, nothing in the release log). NOP the branch — the
#    caller already vetted the format in patch 1. Create+132, vaddr 0x78e223a.
va=$(sym_va ' t ui::NativePixmapEGLX11Binding::Create\(')
verify_and_patch "NativePixmapEGLX11Binding::Create (drop BGRX check)" \
  "$(va_to_offset "$va" "$DELTA" 132)" "0f84a2000000" \
  '\220\220\220\220\220\220'

# 4) exo must not advertise RGB-order dmabuf formats (AB24/XB24/AB30/AB4H).
#    Ash imports every client dmabuf through the X11-pixmap path (patch 2),
#    where the fourcc is lost and the channel order comes from the depth-32
#    X visual (memory B,G,R,A). A buffer whose memory is R,G,R,A -> R and B
#    swap: "red becomes blue" in every wayland-native client (helium, Qt).
#    shm clients and Xwayland are unaffected because their memory already is
#    B,G,R,A.
#
#    gpu::gles2::PopulateMappableDrmFormatsForExo() is the last writer of
#    gpu::Capabilities::drm_formats_and_modifiers (offset 0x18) — the map
#    WaylandDmabufFeedbackManager copies into its format table, so it drives
#    both the advertised zwp_linux_dmabuf_feedback format_table and the
#    IsFormatSupported() check behind zwp_linux_dmabuf.create_buffer. It
#    remove_if()s every fourcc whose SharedImageFormat is not in a local
#    candidate set and, if nothing survives, re-seeds the map from that set.
#    Make the candidate set BGR-order:
#      - the rodata SIF list it memcpy's: RGBA_8888 -> BGRA_8888,
#        RGBX_8888 -> BGRX_8888 (AR24/XR24 then also survive the filter and
#        get seeded, so clients still get a 32-bit colour format);
#      - skip the two conditional RGB-order candidates, RGBA_F16 (AB4H) and
#        RGBA_1010102 (AB30), by turning their "feature off -> skip" jne into
#        an unconditional jmp.
#    PopulateVkDrmFormatsAndModifiers()/PopulateDRMCapabilities() run first
#    and can insert AB24/XB24 straight from the driver — the remove_if above
#    is what drops them again.
verify_and_patch "exo dmabuf candidates (RGBA_8888 -> BGRA_8888)" \
  "$((0x337b0c4))" "0100000000000000" '\001\000\000\000\002\000\000\000'
verify_and_patch "exo dmabuf candidates (RGBX_8888 -> BGRX_8888)" \
  "$((0x337b0cc))" "010000000c000000" '\001\000\000\000\015\000\000\000'
va=$(sym_va ' gpu::gles2::PopulateMappableDrmFormatsForExo\(')
verify_and_patch "exo dmabuf candidates (skip RGBA_F16)" \
  "$(va_to_offset "$va" "$DELTA" 122)" "7513" '\353\023'
verify_and_patch "exo dmabuf candidates (skip RGBA_1010102)" \
  "$(va_to_offset "$va" "$DELTA" 201)" "7513" '\353\023'

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
