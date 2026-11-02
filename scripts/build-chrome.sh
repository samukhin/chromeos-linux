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
# nm prints several symbols twice (alias + real name); keep only the first
# hit and keep scanning — no `exit`, or nm dies of SIGPIPE and `pipefail`
# turns that into a failure.
sym_va() {
  local pattern=$1 mode=${2:-strict} out
  out=$(nm -C "$CHROME" | SYM_PATTERN="$pattern" \
        awk '$0 ~ ENVIRON["SYM_PATTERN"] && !found { print "0x"$1; found = 1 }')
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

# printf octal escapes for the low <n> bytes of <value>, little-endian.
# Every multi-byte constant below is built from one number this way, so the
# expected bytes and the payload can never drift apart — and a negative
# rel32 comes out as proper two's complement.
le_octal() { # <value> <bytes>
  awk -v v="$1" -v n="$2" 'BEGIN {
    for (i = 0; i < n; i++) {
      b = v % 256; if (b < 0) b += 256
      printf "\\%03o", b
      v = (v - b) / 256
    }
  }'
}

# rel32 displacement between two VAs as four octal escapes: the target and
# the address of the byte after the call/jmp.
rel32_octal() { # <target-va> <next-instruction-va>
  le_octal "$(( $1 - $2 ))" 4
}

# The same low <n> bytes as two lowercase hex digits per byte — the form
# verify_and_patch compares against od's dump.
le_hex() { # <value> <bytes>
  awk -v v="$1" -v n="$2" 'BEGIN {
    for (i = 0; i < n; i++) {
      b = v % 256; if (b < 0) b += 256
      printf "%02x", b
      v = (v - b) / 256
    }
  }'
}

# A 24-byte .rela.dyn record (r_offset | r_info | addend): the hex form for
# the expected-bytes check and the printf form for the payload. Feeding the
# same three numbers to both means r_offset and r_info are always compared,
# not just the addend: a stale file offset no longer matches, because a
# misaligned read puts a neighbouring r_info where R_X86_64_RELATIVE (8)
# has to be.
rela_expect() { # <r_offset> <r_info> <addend>
  le_hex "$1" 8
  le_hex "$2" 8
  le_hex "$3" 8
}

rela_fmt() { # <r_offset> <r_info> <addend>
  le_octal "$1" 8
  le_octal "$2" 8
  le_octal "$3" 8
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

va=$(sym_va ' display::DisplayConfigurator::Init\(std::__Cr::unique_ptr<display::NativeDisplayDelegate')
verify_and_patch "DisplayConfigurator::Init (skip native display config)" \
  "$(va_to_offset "$va" "$DELTA" 13)" "75474889fb80bf" '\351\104\000\000\000\220\220'

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

va=$(sym_va ' display::DisplayConfigurator::RunPendingConfiguration\(\)')
verify_and_patch "RunPendingConfiguration (no-op)" \
  "$(va_to_offset "$va" "$DELTA")" "55" '\303'

va=$(sym_va ' ash::RedirectChromeLogging\(base::CommandLine const&\)')
verify_and_patch "RedirectChromeLogging (no-op)" \
  "$(va_to_offset "$va" "$DELTA")" "55" '\303'

va=$(sym_va ' ash::mojo_service_manager::.*::OnDisconnect\(')
verify_and_patch "OnDisconnect (no-op)" \
  "$(va_to_offset "$va" "$DELTA")" "55" '\303'

va=$(sym_va ' display::HasInternalDisplay\(\)' soft)
verify_and_patch "HasInternalDisplay (returns true)" \
  "$(va_to_offset "$va" "$DELTA")" "55" '\260\001\303' soft

# HasInternalDisplay() above is a white lie, and it has to stay one: ash is
# written for a machine that always has an internal panel. The lie only works
# if internal_display_ids() is actually populated, otherwise the very next
# caller — DisplayManager::OnNativeDisplaysChanged(), reached from
# InitFromCommandLine() — does
#     if (HasInternalDisplay() && !found_internal_in_list)
#         internal_id = Display::InternalDisplayId();
# and InternalDisplayId() CHECKs "1u == ids.size()" (display.cc:309): Chrome
# dies with a black screen before the first frame, restarts, dies, ... The
# ids are filled by MaybeInitInternalDisplay(), which is gated on
# ForceFirstDisplayInternal(): true only with --use-first-display-as-internal
# or when StatisticsProvider vouches for the board — neither happens on a
# plain Linux host, so ids stayed empty. Force it true: the first (normally
# the only) host display is registered as the internal one, which is exactly
# what the switch above asks for.
va=$(sym_va ' display::ForceFirstDisplayInternal\(\)')
verify_and_patch "ForceFirstDisplayInternal (first display is internal)" \
  "$(va_to_offset "$va" "$DELTA")" "55" '\260\001\303'

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
# the DRM platform) + XkbEvdevCodes converter (0x10) = 0xd8, was 0x20.
verify_and_patch "OzonePlatformX11::InitializeUI (engine block alloc 0xd8)" \
  "$(va_to_offset "$ui_va" "$DELTA" 381)" "20" '\330'

# Replace the StubKeyboardLayoutEngine construction with:
#   lea 0xc8(%rax),%rdi / mov %rax,%r14 / call XkbEvdevCodesC1 /
#   mov %r14,%rdi / lea 0xc8(%r14),%rsi / call XkbKeyboardLayoutEngineC1 /
#   mov %r14,0x20(%rbx) / mov %r14,%rdi
# then falls through into the existing SetKeyboardLayoutEngine call.
# Both call displacements depend on where this block sits, so derive them
# from the constructor symbols — a pasted dump is stale after every
# snapshot bump, which is exactly how the previous revision broke ld.so.
evdev_va=$(sym_va ' t ui::XkbEvdevCodes::XkbEvdevCodes\(\)')
kbengine_va=$(sym_va ' t ui::XkbKeyboardLayoutEngine::XkbKeyboardLayoutEngine\(ui::XkbKeyCodeConverter const&\)')
engine_site=$((ui_va + 390))
verify_and_patch "OzonePlatformX11::InitializeUI (real Xkb engine)" \
  "$(va_to_offset "$engine_site" "$DELTA")" \
  "4989c64889c7e84577e806488b43204c8973204885c0740d488b084889c7ff51084c8b7320" \
  '\110\215\270\310\000\000\000\111\211\306\350'"$(rel32_octal "$evdev_va" $((engine_site + 15)))"'\114\211\367\111\215\266\310\000\000\000\350'"$(rel32_octal "$kbengine_va" $((engine_site + 30)))"'\114\211\163\040\114\211\367'

# Overwrite the (now dead) StubKeyboardLayoutEngine::Lookup with a thunk
# for StubInputController::SetCurrentLayoutByName(name, callback):
#   mov rax,[keyboard_layout_engine_]; test rax,rax; je fallback;
#   mov rdi,rax; mov rax,[rax]; jmp [rax+0x20]   <- XkbKeyboardLayoutEngine
#                                                   ::SetCurrentLayoutByName
#   fallback: jmp original StubInputController::SetCurrentLayoutByName body.
# Slot offsets are relative to vptr (= 'vtable for' symbol + 0x10: offset-to-
# top + RTTI precede the virtual functions), so SetCurrentLayoutByName sits at
# symbol+0x30 == vptr+0x20. vptr+0x30 is UsesISOLevel5Shift — a silent no-op
# that never runs the callback, which hid the bug (no failure logs at all).
# keyboard_layout_engine_ is a plain .bss global (type 'b'), so the
# RIP-relative load is correct. The stub engine is no longer constructed
# after the patch above, so its Lookup is unreachable.
lookup_va=$(sym_va ' t ui::StubKeyboardLayoutEngine::Lookup\(')
ke_va=$(sym_va ' b ui::KeyboardLayoutEngineManager::keyboard_layout_engine_')
fallback_va=$(sym_va ' t ui::StubInputController::SetCurrentLayoutByName\(')
verify_and_patch "StubKeyboardLayoutEngine::Lookup (forwarding thunk)" \
  "$(va_to_offset "$lookup_va" "$DELTA")" \
  "554889e54c8b4f104d85c974" \
  '\110\213\005'"$(rel32_octal "$ke_va" $((lookup_va + 7)))"'\110\205\300\164\011\110\211\307\110\213\000\377\140\040\351'"$(rel32_octal "$fallback_va" $((lookup_va + 26)))"

# Redirect the real StubInputController vtable slot for
# SetCurrentLayoutByName (vptr+0x80, .rela.dyn entry at file 0x12b8dd0,
# R_X86_64_RELATIVE addend 0x75607de = the stub body) to the thunk:
# verify the whole 24-byte relocation, write it with the new addend
# (thunk VA 0xebb39e8 = StubKeyboardLayoutEngine::Lookup).
verify_and_patch "StubInputController::SetCurrentLayoutByName -> thunk" \
  "$((0x12b8dd0))" \
  "$(rela_expect $((0x168c6868)) 8 $((0x75607de)))" \
  "$(rela_fmt $((0x168c6868)) 8 $((0xebb39e8)))"

# --- hide demo system web apps from the launcher ---------------------------
# SystemWebAppManager::CreateInstallOptionsForSystemApp sets
# add_to_launcher = delegate->ShouldShowInLauncher(). For the demo SWAs below
# that slot (vptr+0x50 == 'vtable for' symbol+0x60) inherits the ICF-merged
# "return true" stub (0x6aea380), so every one of them lands in the launcher
# menu. Redirect the .rela.dyn addend to a "xor %eax,%eax; ret" gadget
# (0x6ae8570) so ShouldShowInLauncher() returns false: the app stays
# installed (media-app keeps working as a file viewer, chrome:// URLs still
# open) but is not added to the launcher. To restore an app, revert the
# corresponding line here.
# Each record is r_offset(8) | r_info(8=R_X86_64_RELATIVE) | addend(8).
# rela_expect/rela_fmt derive the expected bytes and the payload from the
# same three numbers, so the check covers r_offset and r_info as well as the
# addend and a stale file offset cannot pass it.
SWA_RETURN_TRUE=$((0x6aea380))    # ICF-merged "return true" stub
SWA_RETURN_FALSE=$((0x6ae8570))   # "xor %eax,%eax; ret" gadget
swa_hide() { # <name> <rela-file-offset> <r_offset>
  verify_and_patch "hide SWA from launcher: $1" "$2" \
    "$(rela_expect "$3" 8 "$SWA_RETURN_TRUE")" \
    "$(rela_fmt "$3" 8 "$SWA_RETURN_FALSE")"
}
swa_hide "Галерея (media-app)"      "$((0x1d7b568))" "$((0x16de9aa8))"
swa_hide "Sample System Web App"    "$((0x1d76408))" "$((0x16de7b38))"
swa_hide "Возможности (help-app)"   "$((0x1d774a0))" "$((0x16de80f0))"
swa_hide "Камера (camera-app)"      "$((0x1d71da0))" "$((0x16de6230))"
swa_hide "Скринкаст (projector)"    "$((0x1d74c08))" "$((0x16de72b8))"
swa_hide "Игры и приложения (mall)" "$((0x1d75b08))" "$((0x16de7808))"

# --- GPU: ozone X11 pixmap import ------------------------------------------
# Without these, X11 clients on the sommelier display get white windows and a
# GPU log full of "OzoneImageBacking::ProduceSkiaGanesh failed to create GL
# representation" (774x per session). Three separate blockers, all on the
# NativePixmap -> GL path that OzoneImageBacking uses; exo hands us
# BGRX_8888, and ANGLE here has no EGL_EXT_image_dma_buf_import.

# 1) NativePixmapEGLX11Binding::IsSharedImageFormatSupported -> true. The
#    original only accepts BGRA_8888, so CanImportNativePixmap() said no to
#    the BGRX surfaces exo actually produces. vaddr 0x7d2a730, prologue
#    "push %rbp; mov %rsp,%rbp; sub $0x10,%rsp" -> "mov $1,%eax; ret".
va=$(sym_va ' t ui::NativePixmapEGLX11Binding::IsSharedImageFormatSupported\(')
verify_and_patch "IsSharedImageFormatSupported (accept BGRX)" \
  "$(va_to_offset "$va" "$DELTA")" "554889e55de9" '\270\001\000\000\000\303'

# 2) GetNativePixmapSupportType -> kX11Pixmap (2). It prefers kDMABuf when
#    EGL_EXT_image_dma_buf_import is present, which ANGLE never exposes here,
#    and CanImportNativeGLXPixmap() only asks dri3/glx, not GL. vaddr
#    0x7d2e92a, same prologue -> "mov $2,%eax; ret".
va=$(sym_va ' t ui::\(anonymous namespace\)::GetNativePixmapSupportType\(\)')
verify_and_patch "GetNativePixmapSupportType (kX11Pixmap)" \
  "$(va_to_offset "$va" "$DELTA")" "554889e5e80f" '\270\002\000\000\000\303'

# 3) Inside NativePixmapEGLX11Binding::Create: an inlined
#    gl::IsFormatSupported(format) rejects kBGRX_8888 ("je -> 'format is
#    unsupported'" VLOG, nothing in the release log). NOP the branch — the
#    caller already vetted the format in patch 1. Create+132, vaddr 0x7d2aa86.
va=$(sym_va ' t ui::NativePixmapEGLX11Binding::Create\(')
verify_and_patch "NativePixmapEGLX11Binding::Create (drop BGRX check)" \
  "$(va_to_offset "$va" "$DELTA" 132)" "0f8554020000" \
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
#      - the rodata SIF blob it seeds the local flat_tree from (list at
#        0x354565c: kBGR_565, kRGBA_8888, kRGBX_8888, two YUV entries):
#        RGBA_8888 -> BGRA_8888, RGBX_8888 -> BGRX_8888 (AR24/XR24 then also
#        survive the filter and get seeded, so clients still get a 32-bit
#        colour format);
#      - skip the two feature-gated RGB-order emplaces, kRGBA_F16 (AB4H) and
#        kRGBA_1010102 (AB30), by turning their "feature off -> skip" jne
#        into an unconditional jmp.
#    PopulateVkDrmFormatsAndModifiers()/PopulateDRMCapabilities() run first
#    and can insert AB24/XB24 straight from the driver — the remove_if above
#    is what drops them again.
verify_and_patch "exo dmabuf candidates (RGBA_8888 -> BGRA_8888)" \
  "$((0x3545664))" "0100000000000000" '\001\000\000\000\002\000\000\000'
verify_and_patch "exo dmabuf candidates (RGBX_8888 -> BGRX_8888)" \
  "$((0x354566c))" "010000000a000000" '\001\000\000\000\013\000\000\000'
# Both jne sites are found through the function symbol (+119 / +198), so a
# snapshot bump that moves the body moves the patch with it.
exo_va=$(sym_va ' t gpu::gles2::PopulateMappableDrmFormatsForExo\(')
verify_and_patch "exo dmabuf candidates (skip RGBA_F16)" \
  "$(va_to_offset "$exo_va" "$DELTA" 119)" "7513" '\353\023'
verify_and_patch "exo dmabuf candidates (skip RGBA_1010102)" \
  "$(va_to_offset "$exo_va" "$DELTA" 198)" "7513" '\353\023'

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
