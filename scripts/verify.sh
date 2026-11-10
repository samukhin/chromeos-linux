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
for f in chrome chrome_crashpad_handler chrome_crashpad_handler.real \
         chromeos-ash libminigbm.so; do
  [ -e "$ASH_ROOT/dist/chrome/$f" ] || fail "dist/chrome/$f missing"
done
if [ -e "$ASH_ROOT/dist/chrome/libdisplayfix.so" ]; then
  fail "dist/chrome/libdisplayfix.so present — this is the DRM branch, X11 shim must be gone"
fi
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

  # LC_ALL=C: readelf localizes that header ("Запрашиваемый интерпретатор
  # программы:" under ru_RU), so the sed below would match nothing and the
  # check would print <unreadable> on any non-English system.
  interp=$(LC_ALL=C readelf -l "$ASH_ROOT/dist/chrome/chrome" |
           sed -n 's/.*Requesting program interpreter: \(.*\)\]$/\1/p' | head -1)
  ok "chrome interpreter: ${interp:-<unreadable>}"
  rpath=$(LC_ALL=C readelf -d "$ASH_ROOT/dist/chrome/chrome" | awk -F'[][]' '/RPATH|RUNPATH/ { print $2; exit }')
  ok "chrome rpath: ${rpath:-<none>}"

  if grep -qF 'eval(localStorage.t||"")' "$ASH_ROOT/dist/chrome/chrome"; then
    ok "terminal stub patch applied"
  else
    fail "terminal stub patch missing"
  fi

  # DRM branch: the X11-only patches must NOT be present. These are the exact
  # original instruction bytes the old X11 build overwrote; if the binary still
  # has them, the real KMS configuration runs (DisplayConfigurator::Init,
  # RunPendingConfiguration) and the first display can become internal.
  if have nm && have objdump && have gawk; then
    chrome="$ASH_ROOT/dist/chrome/chrome"
    delta=$(objdump -h "$chrome" | awk '$2 == ".text" {
      printf "%d\n", strtonum("0x"$6) - strtonum("0x"$4)
    }')
    if [ -z "$delta" ]; then
      fail "cannot find .text section in chrome"
    else
      sym_va() {
        # nm gets SIGPIPE when awk stops at the first match; the `|| true`
        # keeps `set -o pipefail` from treating that as a failure.
        local out
        out=$(nm -C "$chrome" | SYM_PATTERN="$1" \
          awk '$0 ~ ENVIRON["SYM_PATTERN"] { print "0x"$1; exit }') || true
        printf '%s' "$out"
      }
      bytes_at() { # <offset> <count>
        dd if="$chrome" bs=1 skip="$1" count="$2" 2>/dev/null |
          od -An -v -tx1 | tr -d ' \n'
      }
      va_offset() { awk -v va="$1" -v delta="$2" -v extra="${3:-0}" \
        'BEGIN { printf "%d\n", strtonum(va) + extra + delta }'; }

      va=$(sym_va ' display::DisplayConfigurator::Init\(std::.*unique_ptr<display::NativeDisplayDelegate')
      if [ -z "$va" ]; then
        fail "DisplayConfigurator::Init symbol not found"
      elif [ "$(bytes_at "$(va_offset "$va" "$delta" 13)" 7)" = "807f2100743848" ]; then
        ok "DisplayConfigurator::Init is original (native display config enabled)"
      else
        fail "DisplayConfigurator::Init still patched — DRM modeset will be skipped"
      fi

      va=$(sym_va ' display::DisplayConfigurator::RunPendingConfiguration\(\)')
      if [ -z "$va" ]; then
        fail "RunPendingConfiguration symbol not found"
      elif [ "$(bytes_at "$(va_offset "$va" "$delta")" 1)" = "55" ]; then
        ok "RunPendingConfiguration is original (push %rbp)"
      else
        fail "RunPendingConfiguration still patched to a no-op"
      fi

      va=$(sym_va ' display::HasInternalDisplay\(\)')
      if [ -z "$va" ]; then
        fail "HasInternalDisplay symbol not found"
      elif [ "$(bytes_at "$(va_offset "$va" "$delta")" 3)" = "554889" ]; then
        ok "HasInternalDisplay is original (push %rbp; mov %rsp,%rbp)"
      else
        fail "HasInternalDisplay still forced to true"
      fi
    fi
  else
    echo "  skip: nm/objdump/gawk not installed"
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
