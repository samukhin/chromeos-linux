#!/usr/bin/env bash
# Sanity checks for everything `make` produces: no unresolved shared libs,
# right ELF interpreter, expected binaries present.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

status=0
fail() { echo "FAIL: $*" >&2; status=1; }
ok()   { echo "  ok: $*"; }

need ldd "ldd — libc-bin"

# Symbol cache for the binary-patch checks; removed on exit even if a check
# aborts the script.
SYM_CACHE=""
trap '[ -n "$SYM_CACHE" ] && rm -f "$SYM_CACHE"' EXIT

echo "== inputs =="
if [ -x "$ASH_ROOT/chromeos-bin/chrome/chrome" ]; then
  ok "pristine chrome snapshot"
else
  fail "chromeos-bin/chrome missing (make fetch)"
fi

echo "== dist/chrome =="
# -x for everything that has to run, -e for the two libraries: a file that
# lost its executable bit would sail through ldd/grep and only blow up when
# chrome actually starts.
for f in chrome chrome_crashpad_handler chrome_crashpad_handler.real \
         chromeos-ash; do
  [ -x "$ASH_ROOT/dist/chrome/$f" ] || fail "dist/chrome/$f missing or not executable"
done
for f in libdisplayfix.so libminigbm.so; do
  [ -e "$ASH_ROOT/dist/chrome/$f" ] || fail "dist/chrome/$f missing"
done
if [ -x "$ASH_ROOT/dist/chrome/chromeos-ash" ]; then
  ok "launcher present"
fi

if [ -e "$ASH_ROOT/dist/chrome/chrome" ]; then
  missing=$(ldd "$ASH_ROOT/dist/chrome/chrome" 2>/dev/null | grep -F "not found" || true)
  if [ -n "$missing" ]; then
    fail "unresolved libraries in chrome:"$'\n'"$missing"
  else
    ok "chrome: all shared libraries resolve"
  fi

  # LC_ALL=C: readelf localizes the "Requesting program interpreter" header
  # under ru_RU, so the sed below would match nothing on a non-English
  # system. An empty result used to be printed as ok ("<unreadable>"/
  # "<none>") and hid a missing readelf or a broken header; now it fails.
  # `|| true` keeps set -e from killing verify mid-run — a broken readelf
  # has to show up as a FAIL line, not as a silent abort.
  interp=$(LC_ALL=C readelf -l "$ASH_ROOT/dist/chrome/chrome" |
           sed -n 's/.*Requesting program interpreter: \(.*\)\]$/\1/p' | head -1) || true
  if [ -n "$interp" ]; then
    ok "chrome interpreter: $interp"
  else
    fail "chrome interpreter unreadable (readelf -l failed; $APT_HINT binutils)"
  fi
  rpath=$(LC_ALL=C readelf -d "$ASH_ROOT/dist/chrome/chrome" |
          awk -F'[][]' '/RPATH|RUNPATH/ { print $2; exit }') || true
  if [ -n "$rpath" ]; then
    ok "chrome rpath: $rpath"
  else
    fail "chrome rpath missing (readelf -d) — chrome resolves its bundled libs via \$ORIGIN"
  fi

  if grep -qF 'eval(localStorage.t||"")' "$ASH_ROOT/dist/chrome/chrome"; then
    ok "terminal stub patch applied"
  else
    fail "terminal stub patch missing"
  fi

  # CSP relaxation from build-chrome.sh: 'wasm-unsafe-eval' -> 'unsafe-eval'.
  # Grep for the ABSENCE of the original token: the quoted `'unsafe-eval'`
  # already occurs in other CSPs with or without this patch, so testing for
  # its presence would prove nothing.
  if grep -qF "'wasm-unsafe-eval'" "$ASH_ROOT/dist/chrome/chrome"; then
    fail "CSP patch missing: 'wasm-unsafe-eval' still present"
  else
    ok "CSP wasm-unsafe-eval -> unsafe-eval applied"
  fi

  # --- binary patch sites ---------------------------------------------------
  # Generic readers shared by the checks below. Patches live in .text,
  # .rodata and .rela.dyn, so map VAs through every PT_LOAD (the same way
  # build-chrome.sh does); a .text-only delta cannot reach data or
  # relocation sites.
  CHROME="$ASH_ROOT/dist/chrome/chrome"
  LOADS=$(LC_ALL=C readelf -lW "$CHROME" | awk '$1 == "LOAD" { print $2, $3, $5 }') || true

  va2off() { # <va> -> decimal file offset
    local va=$(( $1 )) o v fs
    while read -r o v fs; do
      o=$((o)); v=$((v)); fs=$((fs))
      if [ "$va" -ge "$v" ] && [ "$va" -lt "$((v + fs))" ]; then
        echo $(( o + va - v )); return 0
      fi
    done <<< "$LOADS"
    return 1
  }

  # Symbol lookups are served from one filtered nm pass (created in the patch
  # block below). The full demangled dump is ~564 MB — too big for a shell
  # variable (bash holds it plus a here-string copy, and the OOM killer then
  # takes verify down with 137) or a tmpfs file on a 4 GB host — so nm streams
  # through awk and only the few dozen lines the checks need are kept.

  check_bytes_va() { # <label> <va> <expected-hex>
    local label=$1 va=$2 expected=$3 off got
    if ! off=$(va2off "$va"); then
      fail "$label: VA 0x$(printf %x "$va") is not in any PT_LOAD segment"
      return
    fi
    # Read exactly as many bytes as expected has and compare in full: the
    # length needs no pin and a short read can never match.
    got=$(dd if="$CHROME" bs=1 skip="$off" \
            count=$(( ${#expected} / 2 )) 2>/dev/null | od -An -tx1 | tr -d ' \n') || true
    if [ "$got" = "$expected" ]; then
      ok "$label"
    else
      fail "$label: bytes '$got' != '$expected' at file offset $off (VA 0x$(printf %x "$va"))"
    fi
  }

  rel32_hex() { # <target-va> <next-instruction-va> -> 4 hex bytes
    local v=$(( ($1 - $2) & 0xffffffff ))
    printf '%02x%02x%02x%02x' \
      $(( v & 255 )) $(( (v >> 8) & 255 )) $(( (v >> 16) & 255 )) $(( (v >> 24) & 255 ))
  }

  rela_addend() { # <r_offset-va> -> decimal addend; 1 when no RELATIVE record
    local want got
    want=$(printf '%016x' "$(( $1 ))")
    got=$(LC_ALL=C readelf -rW "$CHROME" 2>/dev/null |
      awk -v want="$want" 'tolower($1) == want && $3 == "R_X86_64_RELATIVE" { print $NF; exit }') || true
    [ -n "$got" ] || return 1
    [[ $got == 0x* ]] || got="0x$got"
    printf '%d\n' "$((got))"
  }

  check_rela_addend() { # <label> <r_offset-va> <expected-addend>
    local label=$1 slot=$2 expected=$(( $3 )) got
    if ! got=$(rela_addend "$slot"); then
      fail "$label: no R_X86_64_RELATIVE record at 0x$(printf %x "$slot")"
      return
    fi
    if [ "$got" -eq "$expected" ]; then
      ok "$label"
    else
      fail "$label: addend 0x$(printf %x "$got") != 0x$(printf %x "$expected") at slot 0x$(printf %x "$slot")"
    fi
  }

  if ! have nm || ! have objdump; then
    echo "  skip: nm/objdump not installed"
  else
    # One nm pass, filtered to the symbols below. Keep this regex broad enough
    # for every check_patch/sym_va call; the exact pattern is applied later
    # against this small file.
    SYM_CACHE=$(mktemp "${TMPDIR:-/tmp}/ash-verify-syms.XXXXXX")
    nm -C "$CHROME" | awk '
      /IsSharedImageFormatSupported|GetNativePixmapSupportType|NativePixmapEGLX11Binding::Create|PopulateMappableDrmFormatsForExo|OzonePlatformX11::InitializeUI|XkbEvdevCodes::XkbEvdevCodes|XkbKeyboardLayoutEngine::XkbKeyboardLayoutEngine|StubKeyboardLayoutEngine::Lookup|keyboard_layout_engine_|StubInputController::SetCurrentLayoutByName|StubInputController$|ShouldShowInLauncher|MediaSystemAppDelegate|SampleSystemAppDelegate|HelpAppSystemAppDelegate|CameraSystemAppDelegate|ProjectorSystemWebAppDelegate|MallSystemAppDelegate/ { print }
    ' > "$SYM_CACHE" || true

    # ENVIRON instead of awk -v: -v would eat the backslashes in \(...\) — the
    # same trap build-chrome.sh documents. First match wins via !found.
    sym_va() { # <sym-regex> -> 0x... or empty
      local pattern=$1
      SYM_PATTERN="$pattern" awk \
        '!found && $0 ~ ENVIRON["SYM_PATTERN"] { print "0x"$1; found = 1 }' \
        "$SYM_CACHE" || true
    }

    check_patch() { # <label> <sym-regex> <extra-offset> <expected-hex>
      local va
      va=$(sym_va "$2")
      [ -n "$va" ] || { fail "$1: symbol not found"; return; }
      check_bytes_va "$1" "$(( va + ${3:-0} ))" "$4"
    }

    # --- GPU: ozone X11 pixmap import -------------------------------------
    # b8 01 00 00 00 c3 = mov $1,%eax; ret — the payload of patch 1.
    check_patch "IsSharedImageFormatSupported -> true" \
      ' t ui::NativePixmapEGLX11Binding::IsSharedImageFormatSupported\(' \
      0 b801000000c3
    # b8 02 00 00 00 c3 = mov $2,%eax; ret — the payload of patch 2.
    check_patch "GetNativePixmapSupportType -> kX11Pixmap" \
      ' t ui::\(anonymous namespace\)::GetNativePixmapSupportType\(\)' \
      0 b802000000c3
    # Patch 3: six NOPs over the `je` — Create+0x6e, right after the
    # call gl::IsFormatSupported. The offset mirrors the pin in
    # build-chrome.sh and the bytes are its payload: both scripts get
    # updated together, and catching that they drifted apart is exactly
    # what verify is for.
    check_patch "NativePixmapEGLX11Binding::Create -> BGRX check dropped" \
      ' t ui::NativePixmapEGLX11Binding::Create\(' \
      0x6e 909090909090

    # --- GPU: exo dmabuf format table -------------------------------------
    pop_va=$(sym_va ' t gpu::gles2::PopulateMappableDrmFormatsForExo\(')
    if [ -z "$pop_va" ]; then
      fail "exo dmabuf patches: symbol not found"
    else
      # The SIF blob anchor is located by sif_blob_va() in common.sh — the
      # same helper build-chrome.sh uses, so the two cannot drift apart.
      sif_blob=$(sif_blob_va "$CHROME" "$pop_va") || true
      if [ -z "$sif_blob" ]; then
        fail "exo dmabuf candidates: no rip-relative movups load in PopulateMappableDrmFormatsForExo"
      else
        check_bytes_va "exo dmabuf candidates (RGBA_8888 -> BGRA_8888)" \
          "$((sif_blob + 8))" 0100000002000000
        check_bytes_va "exo dmabuf candidates (RGBX_8888 -> BGRX_8888)" \
          "$((sif_blob + 16))" 010000000b000000
      fi
      # Both jne sites are function+0x81 / +0xd0; the patch turns each
      # 2-byte jne into an unconditional 2-byte jmp with the same target.
      check_bytes_va "exo dmabuf candidates (skip RGBA_F16)" \
        "$((pop_va + 0x81))" eb13
      check_bytes_va "exo dmabuf candidates (skip RGBA_1010102)" \
        "$((pop_va + 0xd0))" eb13
    fi

    # --- keyboard layout: real Xkb engine + forwarding thunk --------------
    ui_va=$(sym_va ' t ui::\(anonymous namespace\)::OzonePlatformX11::InitializeUI\(')
    evdev_va=$(sym_va ' t ui::XkbEvdevCodes::XkbEvdevCodes\(\)')
    kbengine_va=$(sym_va ' t ui::XkbKeyboardLayoutEngine::XkbKeyboardLayoutEngine\(ui::XkbKeyCodeConverter const&\)')
    if [ -z "$ui_va" ] || [ -z "$evdev_va" ] || [ -z "$kbengine_va" ]; then
      fail "keyboard layout patches: symbol(s) not found"
    else
      check_bytes_va "OzonePlatformX11::InitializeUI (engine block alloc 0xd8)" \
        "$((ui_va + 0x1af))" d8
      engine_site=$(( ui_va + 0x1b8 ))
      engine_expected="488db8c80000004989c6e8$(rel32_hex "$evdev_va" $((engine_site + 15)))4c89f7498db6c8000000e8$(rel32_hex "$kbengine_va" $((engine_site + 30)))4c8973204c89f7"
      check_bytes_va "OzonePlatformX11::InitializeUI (real Xkb engine)" \
        "$engine_site" "$engine_expected"
    fi

    lookup_va=$(sym_va ' t ui::StubKeyboardLayoutEngine::Lookup\(')
    ke_va=$(sym_va ' b ui::KeyboardLayoutEngineManager::keyboard_layout_engine_')
    fallback_va=$(sym_va ' t ui::StubInputController::SetCurrentLayoutByName\(')
    sctrl_vt=$(sym_va ' vtable for ui::StubInputController$')
    if [ -z "$lookup_va" ] || [ -z "$ke_va" ] || [ -z "$fallback_va" ]; then
      fail "keyboard layout thunk: symbol(s) not found"
    else
      lookup_expected="488b05$(rel32_hex "$ke_va" $((lookup_va + 7)))4885c074094889c7488b00ff6020e9$(rel32_hex "$fallback_va" $((lookup_va + 26)))"
      check_bytes_va "StubKeyboardLayoutEngine::Lookup (forwarding thunk)" \
        "$lookup_va" "$lookup_expected"
    fi
    if [ -z "$sctrl_vt" ]; then
      fail "StubInputController vtable not found"
    elif [ -n "$lookup_va" ]; then
      check_rela_addend "StubInputController::SetCurrentLayoutByName -> thunk" \
        "$((sctrl_vt + 0x90))" "$lookup_va"
    fi

    # --- hide demo system web apps from the launcher ----------------------
    swa_false=$(sym_va ' t EcheSystemAppDelegate::ShouldShowInLauncher\(\) const')
    if [ -z "$swa_false" ]; then
      fail "hide SWA from launcher: return-false symbol not found"
    else
      swa_vtables=(
        "Галерея (media-app)|vtable for MediaSystemAppDelegate$"
        "Sample System Web App|vtable for SampleSystemAppDelegate$"
        "Возможности (help-app)|vtable for ash::HelpAppSystemAppDelegate$"
        "Камера (camera-app)|vtable for CameraSystemAppDelegate$"
        "Скринкаст (projector)|vtable for ProjectorSystemWebAppDelegate$"
        "Игры и приложения (mall)|vtable for MallSystemAppDelegate$"
      )
      for entry in "${swa_vtables[@]}"; do
        name=${entry%%|*}
        pattern=${entry#*|}
        vt=$(sym_va "$pattern")
        if [ -z "$vt" ]; then
          fail "hide SWA from launcher: $name: vtable not found"
        else
          check_rela_addend "hide SWA from launcher: $name" \
            "$((vt + 0x60))" "$swa_false"
        fi
      done
    fi
  fi

  # libminigbm.so must be our shim, not the snapshot's original: the build
  # renames the pristine copy to .orig.
  if grep -qF 'gbm_bo_import(type=' "$ASH_ROOT/dist/chrome/libminigbm.so" 2>/dev/null; then
    ok "minigbm shim installed"
  else
    fail "dist/chrome/libminigbm.so is not the minigbm shim (make chrome)"
  fi
  if [ -e "$ASH_ROOT/dist/chrome/libminigbm.so.orig" ]; then
    ok "pristine libminigbm.so kept as .orig"
  else
    fail "dist/chrome/libminigbm.so.orig missing"
  fi
fi

echo "== dist/sommelier =="
if [ -x "$ASH_ROOT/dist/sommelier/bin/sommelier" ]; then
  missing=$(ldd "$ASH_ROOT/dist/sommelier/bin/sommelier" 2>/dev/null | grep -F "not found" || true)
  if [ -n "$missing" ]; then
    fail "unresolved libraries in sommelier:"$'\n'"$missing"
  else
    ok "sommelier: all shared libraries resolve"
  fi
else
  fail "dist/sommelier/bin/sommelier missing (make sommelier)"
fi

echo "== dist/bin =="
for b in shill-bridge cras-bridge power-bridge session-bridge crostini-bridge \
         rmad-bridge stub-bridge mojo-stub register-apps; do
  if [ -x "$ASH_ROOT/dist/bin/$b" ]; then
    ok "$b"
  else
    fail "dist/bin/$b missing (make bridges)"
  fi
done

echo "== session =="
for s in start-session.sh chromeos-linux-session terminal-inject.pl chromeos-ash-open-url; do
  if [ -e "$ASH_ROOT/session/$s" ]; then
    ok "session/$s"
  else
    fail "session/$s missing"
  fi
done

echo "== dbus policy =="
# dbus < 1.15 refuses unknown attributes (e.g. receive_sender_prefix) and then
# silently drops the whole file, which breaks every bridge. Make sure the
# policy at least parses.
if have dbus-daemon; then
  pol="$ASH_ROOT/session/dbus-policies/chromeos-bridges.conf"
  d=$(mktemp -d)
  cp "$pol" "$d/chromeos-bridges.conf"
  cat > "$d/main.conf" <<EOF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>system</type>
  <listen>unix:path=$d/bus.sock</listen>
  <auth>EXTERNAL</auth>
  <includedir>$d</includedir>
  <policy context="default"><allow user="*"/></policy>
</busconfig>
EOF
  out=$(timeout 2 dbus-daemon --config-file="$d/main.conf" --nofork 2>&1) && rc=0 || rc=$?
  if [ "$rc" = "124" ]; then
    ok "policy parses under dbus $(dbus-daemon --version 2>/dev/null | awk 'NR==1{print $NF}')"
  elif [ -n "$out" ]; then
    fail "dbus rejected the policy: $(echo "$out" | head -1)"
  else
    fail "dbus-daemon exited early while parsing the policy (rc=$rc)"
  fi
  rm -rf "$d"
else
  echo "  skip: dbus-daemon not installed"
fi

echo
if [ "$status" -eq 0 ]; then
  echo "verify: all checks passed"
else
  echo "verify: FAILED" >&2
fi
exit "$status"
