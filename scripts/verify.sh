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
         chromeos-ash libdisplayfix.so libminigbm.so; do
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

  # Три GPU-патча из build-chrome.sh (зачем они — см. там же и в README).
  # Смещения считаем от символов, а не держим в константах: при обновлении
  # снапшота символы сдвинутся вместе с кодом.
  if have nm && have objdump; then
    read -r text_vma text_off < <(
      LC_ALL=C objdump -h "$ASH_ROOT/dist/chrome/chrome" |
        awk '$2==".text"{ print "0x"$4, "0x"$6 }') || true
    [ -n "${text_vma:-}" ] || fail ".text section not readable"
    delta=$(( ${text_off:-0} - ${text_vma:-0} ))

    check_gpu_patch() { # <label> <symbol regex> <extra offset> <6 bytes>
      local va off got
      # Без exit в awk: ранний выход дал бы nm SIGPIPE, а set -e подхватил
      # бы 141 и убил verify на середине. Первый матч берём в shell'е.
      va=$(nm -C "$ASH_ROOT/dist/chrome/chrome" | SYM_PATTERN="$2" \
           awk '$0 ~ ENVIRON["SYM_PATTERN"] { print "0x"$1 }')
      va=${va%%$'\n'*}
      [ -n "$va" ] || { fail "$1: symbol not found"; return; }
      off=$(( va + delta + ${3:-0} ))
      got=$(dd if="$ASH_ROOT/dist/chrome/chrome" bs=1 skip="$off" count=6 \
              2>/dev/null | od -An -tx1 | tr -d ' \n') || true
      if [ "$got" = "$4" ]; then
        ok "$1"
      else
        fail "$1: bytes '$got' != '$4' at $off"
      fi
    }

    check_gpu_patch "IsSharedImageFormatSupported -> true" \
      ' t ui::NativePixmapEGLX11Binding::IsSharedImageFormatSupported\(' \
      0 b801000000c3
    check_gpu_patch "GetNativePixmapSupportType -> kX11Pixmap" \
      ' t ui::\(anonymous namespace\)::GetNativePixmapSupportType\(\)' \
      0 b802000000c3
    check_gpu_patch "NativePixmapEGLX11Binding::Create -> BGRX check dropped" \
      ' t ui::NativePixmapEGLX11Binding::Create\(' \
      132 909090909090
  else
    echo "  skip: nm/objdump not installed"
  fi

  # libminigbm.so обязан быть нашим шимом, а не оригиналом снапшота:
  # оригинал при сборке переименовывается в .orig.
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
         rmad-bridge mojo-stub register-apps; do
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
