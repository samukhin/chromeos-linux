#!/usr/bin/env bash
# Build sommelier (ChromiumOS X<->Wayland bridge) from the pinned upstream
# snapshot, with the same source patches the Nix build applied.
#
# Ash hosts a Wayland compositor; sommelier puts an Xwayland in front of it so
# Linux/X11 apps (DISPLAY=:10) and Ash share one screen.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

REV=441a1c98fc925856a0baa903018b84d71e97458a
URL="https://chromium.googlesource.com/chromiumos/platform2/+archive/$REV/vm_tools/sommelier.tar.gz"
# sha256 of the *unpacked tree*, not of the tarball. googlesource's +archive/
# endpoint regenerates the tar on every request: the bytes and size differ each
# time (PAX headers embed mtimes), so a pin on the container can never match.
# The commit hash in REV pins the content, and this digest verifies it did not
# silently change. Computed over type, mode, path and content (or symlink
# target) of every entry, sorted, so it is independent of mtimes/owners.
EXPECTED_TREE_SHA256=4b28179e62c45bde03dc9ca111f4e71c766ecf87e4b5eeab73b76dab1d3f8f44

# tree_hash <dir>: deterministic digest of a directory tree.
tree_hash() {
  ( cd "$1" && find . -mindepth 1 \
      \( -type d -printf 'd %m %p\n' \) -o \
      \( -type l -printf 'l %m %p -> %l\n' \) -o \
      \( -type f -printf 'f %m %p ' -exec sha256sum {} \; \) |
    LC_ALL=C sort ) | sha256sum | awk '{print $1}'
}

CACHE="$ASH_ROOT/.cache"
TARBALL="$CACHE/sommelier.tar.gz"
SRC="$CACHE/sommelier/src"
BUILD="$CACHE/sommelier/build"
OUT="$ASH_ROOT/dist/sommelier"

need meson "meson — $APT_HINT meson / $PAC_HINT meson"
need ninja "ninja — $APT_HINT ninja-build / $PAC_HINT ninja"
need pkg-config "pkg-config — $APT_HINT pkg-config / $PAC_HINT pkgconf"
need tar "tar — tar"
need python3 "python3 — $APT_HINT python3 / $PAC_HINT python"
need wayland-scanner "wayland-scanner — $APT_HINT libwayland-bin / $PAC_HINT wayland"

for pc in wayland-client wayland-server xkbcommon libdrm gbm pixman-1 \
          xcb xcb-composite xcb-shape xcb-xfixes; do
  pkg-config --exists "$pc" || die "missing $pc.pc — $APT_HINT libwayland-dev libxkbcommon-dev libdrm-dev libgbm-dev libpixman-1-dev libxcb1-dev libxcb-composite0-dev libxcb-shape0-dev libxcb-xfixes0-dev / $PAC_HINT wayland libxkbcommon libdrm libgbm pixman libxcb"
done

python3 -c 'import jinja2' 2>/dev/null ||
  die "python module jinja2 missing — $APT_HINT python3-jinja2 / $PAC_HINT python-jinja2"

mkdir -p "$CACHE"

if [ ! -f "$TARBALL" ]; then
  echo "downloading $URL"
  curl -fL --retry 3 --retry-delay 2 --output "$TARBALL.part" "$URL"
  mv "$TARBALL.part" "$TARBALL"
fi
echo "unpacking sources"
rm -rf "$SRC"
mkdir -p "$SRC"
tar xzf "$TARBALL" -C "$SRC"
[ -f "$SRC/meson.build" ] || die "unexpected sommelier tarball layout"

# Verify the unpacked content (the tarball itself is not reproducible).
tree=$(tree_hash "$SRC")
[ "$tree" = "$EXPECTED_TREE_SHA256" ] ||
  die "sommelier source tree hash mismatch: got $tree, expected $EXPECTED_TREE_SHA256
  (the pinned commit's content changed, or the download was corrupted — re-run
   with a fresh .cache/sommelier.tar.gz)"

chmod +x "$SRC/gen-shim.py" 2>/dev/null || true

cd "$SRC"

# 1. Don't touch virtgpu when running with --noop-driver (no ChromeOS GPU).
grep -q 'drm_fd = noop_driver ? -1 : open_virtgpu' sommelier.cc ||
  sed -i 's|drm_fd = open_virtgpu(\&drm_device);|drm_fd = noop_driver ? -1 : open_virtgpu(\&drm_device);|' sommelier.cc
grep -q 'noop_driver ? -1 : open_virtgpu' sommelier.cc ||
  die "sommelier.cc patch failed (pattern not found)"

# 2. Buffer/compositor patches: exo relabels XRGB8888 shm buffers to
#    ARGB8888, sommelier has to carry that through and set an opaque region.
python3 - <<'PYEOF'
import sys

with open('compositor/sommelier-shm.cc') as f:
    src = f.read()

old = '    assert(host->proxy);\n    sl_create_host_buffer'
new = (
    '    assert(host->proxy);\n'
    '    uint32_t exo_format = (format == WL_SHM_FORMAT_XRGB8888) ? WL_SHM_FORMAT_ARGB8888\n'
    '                        : (format == WL_SHM_FORMAT_XBGR8888) ? WL_SHM_FORMAT_ABGR8888\n'
    '                        : format;\n'
    '    struct sl_host_buffer* hb = sl_create_host_buffer'
)
if old not in src:
    print('ERROR: assert pattern not found in sommelier-shm.cc', file=sys.stderr)
    sys.exit(1)
src = src.replace(old, new, 1)

old2 = 'height, stride, format),'
new2 = 'height, stride, exo_format),'
if old2 not in src:
    print('ERROR: stride/format pattern not found in sommelier-shm.cc', file=sys.stderr)
    sys.exit(1)
src = src.replace(old2, new2, 1)

old3 = '                          width, height, /*is_drm=*/true);\n    return;\n  }'
new3 = '                          width, height, /*is_drm=*/true);\n    hb->shm_format = format;\n    return;\n  }'
if old3 not in src:
    print('ERROR: is_drm pattern not found in sommelier-shm.cc', file=sys.stderr)
    sys.exit(1)
src = src.replace(old3, new3, 1)

with open('compositor/sommelier-shm.cc', 'w') as f:
    f.write(src)
print('sommelier-shm.cc patched: XRGB8888->ARGB8888 relabel + shm_format stored')

with open('compositor/sommelier-compositor.cc') as f:
    src = f.read()

old4 = ('    host->contents_shm_format = host_buffer->shm_format;\n'
        '    host->proxy_buffer = host_buffer->proxy;\n'
        '    buffer_proxy = host_buffer->proxy;')
new4 = ('    host->contents_shm_format = host_buffer->shm_format;\n'
        '    host->proxy_buffer = host_buffer->proxy;\n'
        '    buffer_proxy = host_buffer->proxy;\n'
        '    if (host_buffer->shm_format == WL_SHM_FORMAT_XRGB8888 && host->proxy &&\n'
        '        host->ctx->compositor && host->ctx->compositor->internal) {\n'
        '      struct wl_region* op = wl_compositor_create_region(host->ctx->compositor->internal);\n'
        '      if (op) {\n'
        '        wl_region_add(op, 0, 0, host_buffer->width, host_buffer->height);\n'
        '        wl_surface_set_opaque_region(host->proxy, op);\n'
        '        wl_region_destroy(op);\n'
        '      }\n'
        '    }')
if old4 not in src:
    print('ERROR: compositor attach pattern not found', file=sys.stderr)
    sys.exit(1)
src = src.replace(old4, new4, 1)

with open('compositor/sommelier-compositor.cc', 'w') as f:
    f.write(src)
print('sommelier-compositor.cc patched: opaque region set for XRGB relabeled buffers')
PYEOF

XWAYLAND_BIN="$(command -v Xwayland || true)"
if [ -z "$XWAYLAND_BIN" ]; then
  XWAYLAND_BIN=/usr/bin/Xwayland
  echo "WARNING: Xwayland not found in PATH, recording $XWAYLAND_BIN" >&2
fi

echo "configuring (xwayland=$XWAYLAND_BIN)"
rm -rf "$BUILD"
meson setup "$BUILD" --prefix "$OUT" \
  -Dwith_tests=false \
  -Dxwayland_path="$XWAYLAND_BIN" \
  >/dev/null

echo "compiling"
meson compile -C "$BUILD" >/dev/null

echo "installing -> $OUT"
rm -rf "$OUT"
meson install -C "$BUILD" >/dev/null

[ -x "$OUT/bin/sommelier" ] || die "sommelier binary missing after install"
echo "sommelier -> $OUT/bin/sommelier"
