#!/usr/bin/env bash
# Turn the prebuilt ChromiumOS Chrome build into an Ash shell that runs on a
# stock Linux userspace (ported from the Nix `chromefixed` derivation): the
# binary patches fail loudly when the binary no longer matches, and nothing
# is patchelf'ed — the snapshot already uses /lib64/ld-linux-x86-64.so.2 and
# RUNPATH=$ORIGIN, so it runs on a stock userspace as-is.
#
# This branch targets Ash directly on DRM/KMS (--ozone-platform=drm). The
# X11-only patches (DisplayConfigurator::Init, RunPendingConfiguration,
# HasInternalDisplay, the X11 keyboard engine and the XEvent key fix) are
# deliberately NOT applied: on DRM the native display delegate must be
# installed and the real KMS configuration must run.
#
# A failed patch prints its whole site — file offset, VA, nearest
# symbol, code around it, expected vs actual, payload — enough to fix it in
# place. The rule every report repeats: never paste "actual" into
# `expected`; recompute the site from its symbol/anchor, then pin the new
# pristine bytes.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SRC="$ASH_ROOT/chromeos-bin/chrome"
OUT="$ASH_ROOT/dist/chrome"
CHROME="$OUT/chrome"

need nm "nm — binutils ($APT_HINT binutils / $PAC_HINT binutils)"
need objdump "objdump — binutils ($APT_HINT binutils / $PAC_HINT binutils)"
need readelf "readelf — binutils ($APT_HINT binutils / $PAC_HINT binutils)"
need gawk "gawk — $APT_HINT gawk / $PAC_HINT gawk"
need "${CC:-cc}" "C compiler — $APT_HINT build-essential / $PAC_HINT base-devel"

[ -x "$SRC/chrome" ] || die "no source binary — run chromeos-bin/fetch.sh first"

echo "staging $SRC -> $OUT"
rm -rf "$OUT"
mkdir -p "$OUT"
cp -a "$SRC/." "$OUT/"
chmod u+w "$CHROME"

# --- shared caches -----------------------------------------------------------

# One nm run for the whole script (~4s) instead of one per symbol lookup
# (15+ runs, ~60s of every build). Feeds sym_va and the failure report;
# removed on exit.
NM_CACHE=$(mktemp "${TMPDIR:-/tmp}/ash-nm.XXXXXX")
trap 'rm -f "$NM_CACHE"' EXIT
nm -C -S "$CHROME" > "$NM_CACHE"

# VA <-> file offset through the PT_LOAD segments: one mapping for the whole
# binary, .rela.dyn/.rodata included (the old .text-delta shortcut only
# worked for code, which is why data sites were pasted as raw file offsets).
LOADS=$(readelf -lW "$CHROME" | awk '$1 == "LOAD" { print $2, $3, $5 }')
[ -n "$LOADS" ] || die "no PT_LOAD segments in $CHROME"

# .rela.dyn bounds: rela_record() below looks a relocation up by r_offset
# inside this section only — 24-byte records, so alignment against the
# section start is enough to rule out a look-alike elsewhere in the binary.
RELA_META=$(readelf -SW "$CHROME" |
  awk '$2 == ".rela.dyn" { printf "%d %d", strtonum("0x" $5), strtonum("0x" $6) }')
[ -n "$RELA_META" ] || die "no .rela.dyn section in $CHROME"
read -r RELA_OFF RELA_SIZE <<< "$RELA_META"

va2off() { # <va> -> decimal file offset; exit 1 when unmapped
  local va=$(( $1 )) o v fs
  while read -r o v fs; do
    o=$((o)); v=$((v)); fs=$((fs))
    if [ "$va" -ge "$v" ] && [ "$va" -lt "$((v + fs))" ]; then
      echo $(( o + va - v )); return 0
    fi
  done <<< "$LOADS"
  return 1
}

off2va() { # <file offset> -> decimal VA; exit 1 when unmapped
  local off=$(( $1 )) o v fs
  while read -r o v fs; do
    o=$((o)); v=$((v)); fs=$((fs))
    if [ "$off" -ge "$o" ] && [ "$off" -lt "$((o + fs))" ]; then
      echo $(( v + off - o )); return 0
    fi
  done <<< "$LOADS"
  return 1
}

# --- helpers -----------------------------------------------------------------

# A payload is plain hex — the same form as `expected`, so the two sides
# read line against line at the call site. hex_fmt() renders it for
# printf: \xHH, the notation grep -P also reads back. The bytes
# themselves — NULs included — never sit in a shell variable: printf
# pipes them straight into dd.
hex_fmt() { sed 's/../\\x&/g' <<< "$1"; }

# Symbol address as 0x... from the nm cache (demangled). The pattern goes
# through the environment: awk -v would eat the backslashes in "\(...".
# Some symbols print twice (alias + real name) — first hit wins. Fails
# loudly unless soft.
sym_va() {
  local pattern=$1 mode=${2:-strict} out
  out=$(SYM_PATTERN="$pattern" \
        awk '$0 ~ ENVIRON["SYM_PATTERN"] && !found { print "0x"$1; found = 1 }' \
        "$NM_CACHE")
  [ -n "$out" ] || fail_or_warn "$mode" "symbol not found: $pattern"
  printf '%s' "$out"
}

# Nearest symbol at or before <va> — one pass, best address wins, no sort.
nearest_sym() { # <va> -> "name (+N bytes into it)"
  awk -v va="$1" 'BEGIN { best = -1 }
    $1 ~ /^[0-9a-f]+$/ { a = strtonum("0x" $1); if (a <= va && a > best) { best = a; ln = $0 } }
    END {
      if (ln == "") { print "(no symbol at or before this address)"; exit }
      sub(/^[0-9a-f]+( [0-9a-f]+)? [^ ] /, "", ln)
      printf "%s (+%d bytes into it)", ln, va - best
    }' "$NM_CACHE"
}

fail_or_warn() { # <strict|soft> <message>
  if [ "$1" = "strict" ]; then die "$2"; fi
  echo "WARNING: $2" >&2
}

# --- what a failed patch tells you -------------------------------------------
patch_report() { # <file-offset> <expected-hex> <actual-hex> <payload-hex>
  local offset=$1 expected=$2 actual=$3 fmt=$4 va start
  {
    printf '  file offset : %d (0x%x)\n' "$offset" "$offset"
    if va=$(off2va "$offset"); then
      printf '  address     : 0x%x\n' "$va"
      printf '  nearest sym : %s\n' "$(nearest_sym "$va")"
      printf '  code around the site:\n'
      objdump -d --start-address="$va" --stop-address="$((va + 40))" "$CHROME" 2>/dev/null |
        grep -E '^\s+[0-9a-f]+:' | sed 's/^/    /' || true
    fi
    printf '  expected    : %s\n' "$expected"
    printf '  actual      : %s\n' "$actual"
    printf '  payload     : %s (%d bytes would be written)\n' \
      "$fmt" "$(( ${#fmt} / 2 ))"
    start=$(( offset >= 44 ? offset - 44 : 0 ))
    printf '  bytes around file+%d (site under ^):\n' "$start"
    # 96 hex chars per row; the caret row follows the row containing the
    # site, so `^` always sits under its first byte.
    dd if="$CHROME" bs=1 skip="$start" count=112 2>/dev/null |
      od -An -v -tx1 | tr -d ' \n' | fold -w 96 |
      awk -v col=$(( (offset - start) * 2 )) '{
        print "    " $0
        if (col >= (NR - 1) * 96 && col < NR * 96)
          printf "%*s^ site starts here\n", col - (NR - 1) * 96 + 4, ""
      }'
    printf '  fix: never paste "actual" into expected — that pins the patch to\n'
    printf '       whatever sits there now (how rev 1733743 crashed InitializeUI).\n'
    printf '       Recompute the site from its symbol/anchor (nm/objdump), then\n'
    printf '       keep expected as the pristine bytes at the new site.\n'
  }
}

# verify_and_patch <what> <file-offset> <expected-hex> <payload-hex> [soft]
#   The binary must hold <expected-hex> at <offset> (prefix compare), then
#   the payload overwrites it. Mismatch: full site report, then die — unless
#   "soft", which warns and writes nothing.
verify_and_patch() {
  local what=$1 offset=$2 expected=$3 fmt=$4 mode=${5:-strict} got
  [ -n "$offset" ] || { fail_or_warn "$mode" "$what: no site offset (see the symbol errors above)"; return 0; }
  got=$(dd if="$CHROME" bs=1 skip="$offset" count=$(( ${#fmt} / 2 )) 2>/dev/null |
        od -An -tx1 | tr -d ' \n')
  if [ "${got:0:${#expected}}" != "$expected" ]; then
    fail_or_warn "$mode" "$what: bytes changed at file offset $offset"$'\n'"$(patch_report "$offset" "$expected" "$got" "$fmt")"
    return 0
  fi
  printf "$(hex_fmt "$fmt")" | dd of="$CHROME" bs=1 seek="$offset" conv=notrunc 2>/dev/null
  echo "patched $what at $offset"
}

# patch_sym <what> <sym-regex> <expected-hex> <payload-hex> [<+-offset>] [soft]
#   The common shape of a patch: site = symbol (+ a compile-time offset like
#   `13`), so it moves with the code on a snapshot bump.
patch_sym() {
  local what=$1 pattern=$2 expected=$3 fmt=$4
  shift 4
  local extra=0 mode=strict a va offset
  for a in "$@"; do
    if [ "$a" = soft ]; then mode=soft; else extra=$a; fi
  done
  va=$(sym_va "$pattern" "$mode")
  [ -n "$va" ] || return 0
  if ! offset=$(va2off $(( va + extra ))); then
    fail_or_warn "$mode" "$what: VA $(( va + extra )) is not in any PT_LOAD segment"
    return 0
  fi
  verify_and_patch "$what" "$offset" "$expected" "$fmt" "$mode"
}

# patch_va <what> <va> <expected-hex> <payload-hex> [soft]
#   Same as patch_sym, but for a site already resolved to a VA (a .rodata
#   anchor, or a symbol+constant kept in a variable). Keeps every patch call
#   shaped the same instead of spelling out va2off at each site.
patch_va() {
  local what=$1 va=$2 expected=$3 fmt=$4 mode=${5:-strict} offset
  [ -n "$va" ] || { fail_or_warn "$mode" "$what: no site address"; return 0; }
  if ! offset=$(va2off $(( va ))); then
    fail_or_warn "$mode" "$what: VA $(( va )) is not in any PT_LOAD segment"
    return 0
  fi
  verify_and_patch "$what" "$offset" "$expected" "$fmt" "$mode"
}

le_hex() { # <value> <bytes> -> lowercase hex, the form od prints; a
  # negative value is proper two's complement (rel32 displacements)
  awk -v v="$1" -v n="$2" 'BEGIN {
    for (i = 0; i < n; i++) {
      b = v % 256; if (b < 0) b += 256
      printf "%02x", b
      v = (v - b) / 256
    }
  }'
}

rel32_hex() { # <target-va> <next-instruction-va> -> 4 bytes of hex
  le_hex "$(( $1 - $2 ))" 4
}

# A 24-byte .rela.dyn record (r_offset | r_info | addend) as one hex
# string: expected and payload differ only in the addend, while
# r_offset/r_info are compared too — a stale file offset cannot pass (a
# misaligned read puts a neighbouring r_info where R_X86_64_RELATIVE (8)
# has to be). Each argument goes through $(( )): callers pass raw sym_va
# "0x..." strings as well as computed decimals, and awk's % reads the
# former as 0.
rela_hex() { le_hex $(( $1 )) 8; le_hex $(( $2 )) 8; le_hex $(( $3 )) 8; }  # <r_offset> <r_info> <addend>

# File offset of the .rela.dyn record whose r_offset is <va>. A record opens
# with the 8-byte little-endian address, so one grep pass finds every
# occurrence of it in the binary; the .rela.dyn bounds plus 24-byte
# alignment against the section start pick the record out, and
# verify_and_patch then compares all 24 bytes. LC_ALL=C keeps grep -P on
# bytes — the VA pattern is not valid UTF-8.
rela_record() { # <r_offset-va> -> decimal file offset
  local va=$(( $1 )) pat off
  pat=$(hex_fmt "$(le_hex "$va" 8)")
  while read -r off; do
    off=$((off))
    if [ "$off" -ge "$RELA_OFF" ] && [ "$off" -lt "$((RELA_OFF + RELA_SIZE))" ] &&
       [ $(( (off - RELA_OFF) % 24 )) -eq 0 ]; then
      echo "$off"
      return 0
    fi
  done < <(LC_ALL=C grep -Poba -- "$pat" "$CHROME" | cut -d: -f1 || true)
  return 1
}

# patch_rela <what> <slot-va> <expected-addend> <payload-addend>
#   Rewrite the addend of the R_X86_64_RELATIVE record whose r_offset is
#   <slot-va>. rela_record() finds the record and dies loudly when it is
#   missing; the whole 24 bytes are still compared (rela_hex pins r_offset
#   and r_info too), so a shifted slot or a changed pristine addend fails
#   instead of patching the wrong slot.
patch_rela() {
  local what=$1 slot=$2 expected=$3 fmt=$4 rec
  rec=$(rela_record "$slot") ||
    die "$what: no .rela.dyn record for slot 0x$(printf %x "$slot")"
  verify_and_patch "$what" "$rec" \
    "$(rela_hex "$slot" 8 "$expected")" \
    "$(rela_hex "$slot" 8 "$fmt")"
}

# --- string patches ----------------------------------------------------------

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

# Default chrome-untrusted CSP: every chrome-untrusted data source that does
# not override GetContentSecurityPolicy gets `script-src
# chrome-untrusted://resources 'self';` (content::URLDataSource). Crosh is one
# of them — TerminalSource only overrides the policy for the SSH terminal,
# gated on crostini.terminal_ssh_allowed_by_policy — and it loads the same
# js/terminal.js, whose eval(localStorage.t||"") throws EvalError without
# 'unsafe-eval' (the page stays blank). The string is fixed-size (47 bytes,
# NUL-terminated) and cannot grow, so compress the source list to the scheme
# source `chrome-untrusted:` (a superset of //resources and 'self' for these
# pages) and spend the freed bytes on 'unsafe-eval'. This loosens script-src
# for every page using the default policy, not just crosh.
CROSH_CSP_OLD="script-src chrome-untrusted://resources 'self';"
[ "${#CROSH_CSP_OLD}" -eq 47 ] ||
  die "CROSH_CSP_OLD is ${#CROSH_CSP_OLD} bytes, expected 47 — padding would clobber the NUL"
CROSH_CSP_NEW=$(printf '%-47s' "script-src chrome-untrusted: 'unsafe-eval';")
[ "$(printf '%s' "$CROSH_CSP_NEW" | wc -c)" -eq 47 ] ||
  die "CROSH_CSP_NEW is not 47 bytes"

crosh_offset=""
crosh_count=0
while IFS=: read -r off _; do
  [ -n "$off" ] || continue
  crosh_offset=$off
  crosh_count=$((crosh_count + 1))
done < <(grep -Fboa "$CROSH_CSP_OLD" "$CHROME" || true)

case $crosh_count in
  0)
    echo "WARNING: chrome-untrusted default CSP not found in chrome binary" >&2
    ;;
  1)
    verify_and_patch "chrome-untrusted default CSP (crosh eval)" "$crosh_offset" \
      "$(printf '%s' "$CROSH_CSP_OLD" | od -An -v -tx1 | tr -d ' \n')" \
      "$(printf '%s' "$CROSH_CSP_NEW" | od -An -v -tx1 | tr -d ' \n')"
    ;;
  *)
    die "chrome-untrusted default CSP is not unique: $crosh_count matches"
    ;;
esac

# --- symbol patches ----------------------------------------------------------
# Sites are "symbol + constant" (patch_sym): they move with the code. Only
# the expected bytes are pinned — when those change, the report hands over
# the new bytes, the nearest symbol and the disassembly, so updating is
# mechanical.

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
# Original bytes at constructor+0x70 for reference: e8fdd63d08488bb80001000048

patch_sym "RedirectChromeLogging (no-op)" \
  ' ash::RedirectChromeLogging\(base::CommandLine const&\)' "55" "c3"

patch_sym "OnDisconnect (no-op)" \
  ' ash::mojo_service_manager::.*::OnDisconnect\(' "55" "c3"

# System UI blur (shelf, quick settings, hotseat) is gated on RAM, not GPU:
# chromeos::features::IsSystemBlurEnabled() is literally
#   return base::SysInfo::AmountOfTotalPhysicalMemory() > 4GiB;   (0x100000000)
# read from /proc/meminfo, no FeatureList or override — yet the compositor
# draws backdrop filters on any GPU (viz::SoftwareRenderer has its own
# GetBackdropFilterShader). Force it true; costs some FPS on <=4 GiB hosts.
# Prologue -> "mov $1,%eax; ret" (no push, so the stack stays balanced).
patch_sym "IsSystemBlurEnabled (always true, blur on any RAM)" \
  ' chromeos::features::IsSystemBlurEnabled\(\)' "55" "b801000000c3"

# --- hide demo system web apps from the launcher ---------------------------
# SystemWebAppManager::CreateInstallOptionsForSystemApp sets
# add_to_launcher = delegate->ShouldShowInLauncher(). For the demo SWAs below
# that slot (vptr+0x50 == 'vtable for' symbol+0x60) holds the base
# SystemWebAppDelegate's "return true" body (five of the six delegates do
# not override it; Media's own override is ICF-merged into it), so each app
# lands in the launcher menu. Redirect the .rela.dyn addend to the ICF-merged
# "xor %eax,%eax; ret" body that the already-hidden delegates (Eche, Crosh,
# Sanitize, ...) share: the app stays installed (media-app still opens files
# and chrome:// URLs) but is not added to the launcher. To restore an app,
# revert its line. Each record is found by r_offset (vtable symbol + 0x60)
# and must still carry the pristine addend, so a slot that changed fails
# loudly instead of hiding the wrong thing.
# Record = r_offset(8) | r_info(8 = R_X86_64_RELATIVE) | addend(8).
SWA_RETURN_TRUE=$(sym_va ' t ash::SystemWebAppDelegate::ShouldShowInLauncher\(\) const')
SWA_RETURN_FALSE=$(sym_va ' t EcheSystemAppDelegate::ShouldShowInLauncher\(\) const')
swa_hide() { # <name> <vtable-regex>
  local vt
  vt=$(sym_va "$2")
  patch_rela "hide SWA from launcher: $1" \
    "$(( vt + 0x60 ))" "$SWA_RETURN_TRUE" "$SWA_RETURN_FALSE"
}
swa_hide "Галерея (media-app)"      ' vtable for MediaSystemAppDelegate$'
swa_hide "Sample System Web App"    ' vtable for SampleSystemAppDelegate$'
swa_hide "Возможности (help-app)"   ' vtable for ash::HelpAppSystemAppDelegate$'
swa_hide "Камера (camera-app)"      ' vtable for CameraSystemAppDelegate$'
swa_hide "Скринкаст (projector)"    ' vtable for ProjectorSystemWebAppDelegate$'
swa_hide "Игры и приложения (mall)" ' vtable for MallSystemAppDelegate$'

# --- GPU: ozone X11 pixmap import ------------------------------------------
# Without these, X11 clients on the sommelier display get white windows and a
# GPU log full of "OzoneImageBacking::ProduceSkiaGanesh failed to create GL
# representation" (774x per session). Three blockers on the NativePixmap -> GL
# path OzoneImageBacking uses; exo hands us BGRX_8888, and ANGLE here has no
# EGL_EXT_image_dma_buf_import.

# 1) IsSharedImageFormatSupported -> true: the original only accepts
#    BGRA_8888, so CanImportNativePixmap() said no to the BGRX surfaces exo
#    actually produces. Prologue -> "mov $1,%eax; ret".
#    expected = 55 48 89 e5 5d e9 — push %rbp; mov %rsp,%rbp; pop %rbp;
#    jmp (the tail call; its rel32 lies outside the 6 pinned bytes).
patch_sym "IsSharedImageFormatSupported (accept BGRX)" \
  ' t ui::NativePixmapEGLX11Binding::IsSharedImageFormatSupported\(' \
  "554889e55de9" "b801000000c3"

# 2) GetNativePixmapSupportType -> kX11Pixmap (2): it prefers kDMABuf when
#    EGL_EXT_image_dma_buf_import exists, which ANGLE never exposes here, and
#    CanImportNativeGLXPixmap() only asks dri3/glx. Prologue -> mov $2,%eax.
#    expected = 55 48 89 e5 e8 + rel32 low byte — push %rbp; mov %rsp,%rbp;
#    call GetGLDisplayEGL: the 6-byte payload overwrites exactly that, so the
#    low byte is derived from the callee symbol instead of being pasted.
gmps_va=$(sym_va ' t ui::\(anonymous namespace\)::GetNativePixmapSupportType\(\)')
gld_va=$(sym_va ' t gl::GLSurfaceEGL::GetGLDisplayEGL\(')
patch_va "GetNativePixmapSupportType (kX11Pixmap)" \
  "$gmps_va" \
  "554889e5e8$(le_hex $(( gld_va - gmps_va - 9 )) 1)" \
  "b802000000c3"

# 3) In NativePixmapEGLX11Binding::Create an inlined gl::IsFormatSupported
#    rejects kBGRX_8888 ("je -> 'format is unsupported'" VLOG, silent in the
#    release log). NOP the branch — the caller vetted the format in patch 1.
#    Site: the `je` right after `call gl::IsFormatSupported` (Create+0x6e).
#    expected = 0f 84 <rel32>: the displacement is a within-function
#    distance to the VLOG block — no symbol to derive it from, so it stays a
#    pinned number like the jnes below. The payload is 6 nops and does not
#    depend on it; if a snapshot moves the target, refresh create_skip from
#    the patch report and leave create_site alone unless the `je` itself
#    moves.
create_site=$((0x6e))
create_skip=$((0xce))
patch_sym "NativePixmapEGLX11Binding::Create (drop BGRX check)" \
  ' t ui::NativePixmapEGLX11Binding::Create\(' \
  "0f84$(le_hex "$create_skip" 4)" "909090909090" "$create_site"

# 4) exo must not advertise RGB-order dmabuf formats (AB24/XB24/AB30/AB4H).
#    Ash imports every client dmabuf through the X11-pixmap path (patch 2),
#    where the fourcc is lost and the channel order comes from the depth-32
#    X visual (memory B,G,R,A) — red and blue swap in every wayland-native
#    client (helium, Qt); shm clients and Xwayland are unaffected (their
#    memory already is B,G,R,A).
#    PopulateMappableDrmFormatsForExo() is the last writer of
#    gpu::Capabilities::drm_formats_and_modifiers — the map behind both the
#    advertised feedback format_table and create_buffer's IsFormatSupported.
#    It remove_if()s fourccs outside a local candidate set and re-seeds the
#    map from that set when nothing survives. Make the set BGR-order:
#      - the rodata SIF blob it seeds from (kBGR_565, kRGBA_8888,
#        kRGBX_8888, two YUV — address from the function's rip-relative
#        movups load below): RGBA_8888 -> BGRA_8888,
#        RGBX_8888 -> BGRX_8888 (AR24/XR24 then survive too);
#      - turn the two feature-gated "off -> skip" jne — kRGBA_F16 (AB4H) and
#        kRGBA_1010102 (AB30) — into unconditional jmp.
#    PopulateVkDrmFormatsAndModifiers()/PopulateDRMCapabilities() run first
#    and can insert AB24/XB24 straight from the driver — remove_if drops them.
# Blob address: the first rip-relative movups in the function loads it (16
# bytes); the two rewritten SIF entries sit at blob+8 and blob+16. The anchor
# is located by sif_blob_va() in common.sh — shared with verify.sh, which
# checks the same spots.
pop_va=$(sym_va ' t gpu::gles2::PopulateMappableDrmFormatsForExo\(')
sif_blob=$(sif_blob_va "$CHROME" "$pop_va")
[ -n "$sif_blob" ] || die "exo dmabuf candidates: no rip-relative movups load in PopulateMappableDrmFormatsForExo (SIF blob anchor)"
patch_va "exo dmabuf candidates (RGBA_8888 -> BGRA_8888)" \
  "$(( sif_blob + 8 ))" "0100000000000000" "0100000002000000"
patch_va "exo dmabuf candidates (RGBX_8888 -> BGRX_8888)" \
  "$(( sif_blob + 16 ))" "010000000a000000" "010000000b000000"
# Both jne sites are function+0x81 / +0xd0. The patch swaps each 2-byte jne
# for a 2-byte jmp with the SAME displacement (same length, same target), so
# one pinned number per site feeds expected and payload — a layout drift is a
# one-number fix and cannot leave the two sides pointing at different targets.
f16_skip=$((0x13))   # jne displacement, pinned for the current snapshot
ab30_skip=$((0x13))
patch_va "exo dmabuf candidates (skip RGBA_F16)" \
  "$(( pop_va + 0x81 ))" \
  "75$(le_hex "$f16_skip" 1)" "eb$(le_hex "$f16_skip" 1)"
patch_va "exo dmabuf candidates (skip RGBA_1010102)" \
  "$(( pop_va + 0xd0 ))" \
  "75$(le_hex "$ab30_skip" 1)" "eb$(le_hex "$ab30_skip" 1)"

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
