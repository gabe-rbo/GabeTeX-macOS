#!/bin/bash
# Builds GabeTeX.dmg: the drag-to-Applications installer image (GabeTeX icon on the left, an Applications
# shortcut on the right, a custom background, a custom volume icon).
#
#   Scripts/make-dmg.sh [path/to/GabeTeX.app] [out.dmg]
#   defaults:           build/GabeTeX.app       dist/GabeTeX.dmg
#
# - Refuses an app that is not signed (ad-hoc is fine): `codesign --verify --deep --strict` must pass.
# - Uses dmgbuild (pinned in Support/DMG/requirements.txt) from a private virtualenv, build/.dmg-venv, which
#   is created on first use. Nothing is installed system-wide; no Finder, AppleScript or GUI is involved.
# - Layout, window and icon positions: Support/DMG/dmgbuild-settings.py + layout.json.
#   Artwork: Support/DMG/background.tiff (regenerate with Scripts/make-dmg-background.swift).
# - The image is APFS inside a read-only LZMA-compressed container (ULMO). DMG_FILESYSTEM=HFS+ builds an HFS+
#   one instead (identical Finder layout, a few KB larger); only needed as a fallback.
# - Afterwards runs Support/DMG/verify-dmg.sh (mounts the finished image read-only and checks it).
# - Never uploads, publishes, tags or installs anything.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUPPORT="$ROOT/Support"
DMGDIR="$SUPPORT/DMG"
VOLNAME="GabeTeX"

die() { echo "make-dmg: $*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "this script needs macOS (hdiutil, codesign)"

APP_ARG="${1:-$ROOT/build/GabeTeX.app}"
OUT_ARG="${2:-$ROOT/dist/GabeTeX.dmg}"

# --- 1. The app: present and signed -----------------------------------------------------------------------
[ -d "$APP_ARG" ] || die "app not found: $APP_ARG (build it with Scripts/build-app.sh)"
APP="$(cd "$APP_ARG" && pwd)"
[ -f "$APP/Contents/Info.plist" ] || die "$APP is not an app bundle (no Contents/Info.plist)"
if ! SIGN_LOG="$(codesign --verify --deep --strict "$APP" 2>&1)"; then
  echo "$SIGN_LOG" >&2
  die "$APP is not signed (or its signature is broken); refusing to package it. Sign it first, e.g. Scripts/build-app.sh"
fi
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"

# A mounted volume with our name would make the image's background reference point at "GabeTeX 1".
[ ! -e "/Volumes/$VOLNAME" ] || die "a volume named /Volumes/$VOLNAME is mounted; eject it first (hdiutil detach \"/Volumes/$VOLNAME\")"

# --- 2. Output path ----------------------------------------------------------------------------------------
mkdir -p "$(dirname "$OUT_ARG")"
OUT="$(cd "$(dirname "$OUT_ARG")" && pwd)/$(basename "$OUT_ARG")"
case "$OUT" in *.dmg) ;; *) die "output must end in .dmg: $OUT" ;; esac
TMP="$(dirname "$OUT")/.GabeTeX-build-$$.dmg"
trap 'rm -f "$TMP"' EXIT

# --- 3. Artwork --------------------------------------------------------------------------------------------
if [ ! -f "$DMGDIR/background.tiff" ] || [ ! -f "$DMGDIR/layout.json" ]; then
  echo "Generating the background artwork..."
  swift "$ROOT/Scripts/make-dmg-background.swift" "$DMGDIR"
fi
[ -f "$SUPPORT/AppIcon.icns" ] || die "Support/AppIcon.icns is missing"

# --- 4. dmgbuild in a private virtualenv -------------------------------------------------------------------
VENV="$ROOT/build/.dmg-venv"
PY="$VENV/bin/python"
STAMP="$VENV/.requirements.sha256"
WANT="$(shasum -a 256 "$DMGDIR/requirements.txt" | cut -d' ' -f1)"
if [ ! -x "$PY" ] || [ "$(cat "$STAMP" 2>/dev/null || true)" != "$WANT" ]; then
  echo "Preparing the dmgbuild virtualenv (build/.dmg-venv)..."
  [ -x "$PY" ] || "${PYTHON:-/usr/bin/python3}" -m venv "$VENV"
  "$PY" -m pip install --disable-pip-version-check --quiet -r "$DMGDIR/requirements.txt"
  echo "$WANT" > "$STAMP"
fi

# --- 5. Build ----------------------------------------------------------------------------------------------
echo "Building $(basename "$OUT") from $APP (GabeTeX $APP_VERSION)..."
EXTRA=()
[ -z "${DMG_FILESYSTEM:-}" ] || EXTRA+=(-D "filesystem=$DMG_FILESYSTEM")   # test override: HFS+ or APFS
"$PY" -m dmgbuild -s "$DMGDIR/dmgbuild-settings.py" \
  -D "app=$APP" -D "support=$SUPPORT" ${EXTRA[@]+"${EXTRA[@]}"} \
  --detach-retries 20 "$VOLNAME" "$TMP"
rm -f "$OUT"
mv "$TMP" "$OUT"

# --- 6. Verify the finished image ------------------------------------------------------------------------
DMG_PYTHON="$PY" bash "$DMGDIR/verify-dmg.sh" "$OUT"

BYTES="$(stat -f%z "$OUT")"
echo "Built $OUT ($(awk -v b="$BYTES" 'BEGIN { printf "%.1f MB", b / 1048576 }'))"
