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

va=$(sym_va ' display::DisplayConfigurator::Init\(std::__Cr::unique_ptr<display::NativeDisplayDelegate')
verify_and_patch "DisplayConfigurator::Init (skip native display config)" \
  "$(va_to_offset "$va" "$DELTA" 13)" "807f2101753749" '\351\070\000\000\000\220\220'

va=$(sym_va ' exo::wayland::WaylandDmabufFeedbackManager::WaylandDmabufFeedbackManager\(exo::Display\*\)')
verify_and_patch "WaylandDmabufFeedbackManager (no dmabuf probing)" \
  "$(va_to_offset "$va" "$DELTA" 112)" "e8fdd63d08488bb80001000048" \
  '\111\307\107\010\000\000\000\000\351\137\004\000\000'

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
verify_and_patch "OzonePlatformX11::InitializeUI (real Xkb engine)" \
  "$(va_to_offset "$ui_va" "$DELTA" 390)" \
  "4989c64889c7e8a9ce7206488b7b204c8973204885ff740a488b07ff50084c8b73204c89f7" \
  '\110\215\270\310\000\000\000\111\211\306\350\353\317\162\006\114\211\367\111\215\266\310\000\000\000\350\020\320\162\006\114\211\163\040\114\211\367'

# Overwrite the (now dead) StubKeyboardLayoutEngine::Lookup with a thunk
# for StubInputController::SetCurrentLayoutByName(name, callback):
#   load keyboard_layout_engine_; when set, tail-jump to
#   engine->SetCurrentLayoutByName (vptr+0x20, identical signature), else
#   jump back into the original stub body. The stub engine is no longer
#   constructed after the patch above, so its Lookup is unreachable.
lookup_va=$(sym_va ' t ui::StubKeyboardLayoutEngine::Lookup\(')
verify_and_patch "StubKeyboardLayoutEngine::Lookup (forwarding thunk)" \
  "$(va_to_offset "$lookup_va" "$DELTA")" \
  "554889e5488b4708488b7f10" \
  '\110\213\005\201\042\022\010\110\205\300\164\011\110\211\307\110\213\000\377\140\040\351\204\267\030\371'

# Redirect the StubInputController vtable slot (vptr+0x80,
# .rela.dyn entry for 0x15834f20, R_X86_64_RELATIVE addend 0x719c0de) to
# the thunk: verify the whole 24-byte relocation, write it with the new
# addend (thunk VA 0xe010940).
verify_and_patch "StubInputController::SetCurrentLayoutByName -> thunk" \
  "$((0x1020b20))" \
  "204f8315000000000800000000000000dec0190700000000" \
  '\040\117\203\025\000\000\000\000\010\000\000\000\000\000\000\000\100\011\001\016\000\000\000\000'

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
