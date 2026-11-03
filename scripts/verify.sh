#!/usr/bin/env bash
# Sanity checks for everything `make` produces: no unresolved shared libs,
# right ELF interpreter, expected binaries present.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

status=0
fail() { echo "FAIL: $*" >&2; status=1; }
ok()   { echo "  ok: $*"; }

need ldd "ldd — libc-bin"

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

  # Three GPU patches from build-chrome.sh (what they are for — see the
  # comments there and the README). Sites are measured from symbols, never
  # pinned as constants: on a snapshot bump the symbols move with the code.
  # All three sites sit in .text, so the section delta is enough here
  # (build-chrome maps through every PT_LOAD because it also has data
  # sites). Every check runs its own nm on purpose: the demangled dump is
  # ~564 MB, too big for a shell variable on this 4 GB host (bash holds it
  # plus a here-string copy — the OOM killer then takes verify down with
  # 137 instead of a FAIL line), and caching it in a file would only move
  # those megabytes into tmpfs. So nm streams straight into awk, which
  # reads a line at a time.
  if ! have nm || ! have objdump; then
    echo "  skip: nm/objdump not installed"
  else
    read -r text_vma text_off < <(
      LC_ALL=C objdump -h "$ASH_ROOT/dist/chrome/chrome" |
        awk '$2==".text"{ print "0x"$4, "0x"$6 }') || true
    if [ -z "${text_vma:-}" ]; then
      # One clear failure instead of three confused ones: without .text the
      # delta would be 0 and every patch would "mismatch" on its own.
      fail ".text section not readable — GPU patch checks skipped"
    else
      delta=$(( text_off - text_vma ))

      check_gpu_patch() { # <label> <sym-regex> <extra-offset> <expected-hex>
        local va site off got expected=$4
        # ENVIRON instead of awk -v: -v would eat the backslashes in
        # \(...\) — the same trap build-chrome.sh documents. No early exit
        # in awk: it would SIGPIPE nm and pipefail/set -e would kill the
        # script with 141. First match wins via !found. `|| true` keeps a
        # dead nm from aborting verify — it surfaces as the FAIL below.
        va=$(nm -C "$ASH_ROOT/dist/chrome/chrome" | SYM_PATTERN="$2" \
             awk '!found && $0 ~ ENVIRON["SYM_PATTERN"] { print "0x"$1; found = 1 }') || true
        [ -n "$va" ] || { fail "$1: symbol not found"; return; }
        site=$(( va + ${3:-0} ))
        off=$(( site + delta ))
        # Read exactly as many bytes as expected has and compare in full:
        # the length needs no pin and a short read can never match.
        got=$(dd if="$ASH_ROOT/dist/chrome/chrome" bs=1 skip="$off" \
                count=$(( ${#expected} / 2 )) 2>/dev/null | od -An -tx1 | tr -d ' \n') || true
        if [ "$got" = "$expected" ]; then
          ok "$1"
        else
          fail "$1: bytes '$got' != '$expected' at file offset $off (VA 0x$(printf %x "$site"))"
        fi
      }

      # b8 01 00 00 00 c3 = mov $1,%eax; ret — the payload of patch 1.
      check_gpu_patch "IsSharedImageFormatSupported -> true" \
        ' t ui::NativePixmapEGLX11Binding::IsSharedImageFormatSupported\(' \
        0 b801000000c3
      # b8 02 00 00 00 c3 = mov $2,%eax; ret — the payload of patch 2.
      check_gpu_patch "GetNativePixmapSupportType -> kX11Pixmap" \
        ' t ui::\(anonymous namespace\)::GetNativePixmapSupportType\(\)' \
        0 b802000000c3
      # Patch 3: six NOPs over the `je` — Create+110, right after the
      # call gl::IsFormatSupported. The offset mirrors the pin in
      # build-chrome.sh and the bytes are its payload: both scripts get
      # updated together, and catching that they drifted apart is exactly
      # what verify is for.
      check_gpu_patch "NativePixmapEGLX11Binding::Create -> BGRX check dropped" \
        ' t ui::NativePixmapEGLX11Binding::Create\(' \
        110 909090909090
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
