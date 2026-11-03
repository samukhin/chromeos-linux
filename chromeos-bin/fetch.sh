#!/usr/bin/env bash
# Download and unpack the prebuilt ChromiumOS Chrome build Ash runs on.
#
# Usage: chromeos-bin/fetch.sh [--force]
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../scripts/common.sh"

FORCE=""
if [ "${1:-}" = "--force" ]; then
  FORCE=1
fi

REV="$(tr -d '[:space:]' < "$ASH_ROOT/chromeos-bin/REVISION")"
[ -n "$REV" ] || die "chromeos-bin/REVISION is empty"

URL="https://commondatastorage.googleapis.com/chromium-browser-snapshots/Linux_ChromiumOS_Full/$REV/chrome-chromeos.zip"

# Integrity pins for snapshot 1733743 (x86_64).
#   size/md5  — Google Cloud Storage object metadata (authoritative)
#   sha256    — computed from the downloaded bytes (cross-checks the md5)
EXPECTED_SIZE=319345898
EXPECTED_MD5=4280b6982c51408379cae379c6e53d84
EXPECTED_SHA256=daf7f9b77ecf903f17a5966253b11f9ea659f421fdf33fc0ce00ea8bcd16a054

STAGE="$ASH_ROOT/chromeos-bin/.stage"
TARGET="$ASH_ROOT/chromeos-bin/chrome"
ZIP="$STAGE/chrome-$REV.zip"

if [ -x "$TARGET/chrome" ] && [ -z "$FORCE" ]; then
  echo "chrome already fetched -> $TARGET (use --force to re-download)"
  exit 0
fi

need curl "curl — $APT_HINT curl / $PAC_HINT curl"
need unzip "unzip — $APT_HINT unzip / $PAC_HINT unzip"
need md5sum "md5sum — coreutils"
need sha256sum "sha256sum — coreutils"

mkdir -p "$STAGE"

if [ -f "$ZIP" ]; then
  echo "using cached download: $ZIP"
else
  echo "downloading $URL"
  if [ -f "$ZIP.part" ]; then
    curl -fL --retry 3 --retry-delay 2 -C - --output "$ZIP.part" "$URL"
  else
    curl -fL --retry 3 --retry-delay 2 --output "$ZIP.part" "$URL"
  fi
  mv "$ZIP.part" "$ZIP"
fi

size=$(wc -c < "$ZIP" | tr -d ' ')
[ "$size" = "$EXPECTED_SIZE" ] || die "size mismatch: got $size, expected $EXPECTED_SIZE"

md5=$(md5sum "$ZIP" | awk '{print $1}')
[ "$md5" = "$EXPECTED_MD5" ] || die "md5 mismatch: got $md5, expected $EXPECTED_MD5"

sha=$(sha256sum "$ZIP" | awk '{print $1}')
if [ -n "$EXPECTED_SHA256" ]; then
  [ "$sha" = "$EXPECTED_SHA256" ] || die "sha256 mismatch: got $sha, expected $EXPECTED_SHA256"
else
  echo "note: no pinned sha256 for this revision; computed: $sha"
fi
echo "checksums ok (size=$size md5=$md5 sha256=$sha)"

echo "unpacking..."
rm -rf "$STAGE/x"
mkdir -p "$STAGE/x"
unzip -q "$ZIP" -d "$STAGE/x"

# The zip carries a single top-level directory (fetchzip stripped it too).
if [ -d "$STAGE/x/chrome-chromeos" ]; then
  src="$STAGE/x/chrome-chromeos"
elif [ -x "$STAGE/x/chrome" ]; then
  src="$STAGE/x"
else
  die "unexpected zip layout"
fi

rm -rf "$TARGET"
mv "$src" "$TARGET"
chmod +x "$TARGET/chrome" "$TARGET/chrome_crashpad_handler" "$TARGET/chrome-wrapper" 2>/dev/null || true
rm -rf "$STAGE/x"

echo "chrome unpacked -> $TARGET"
