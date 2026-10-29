#!/bin/bash
# Builds the release artifacts, locally, and nothing else:
#
#   Scripts/release.sh
#
#   1. reads the version from Support/Info.plist (CFBundleShortVersionString)
#   2. Scripts/build-app.sh                     -> build/GabeTeX.app  (release configuration, ad-hoc signed,
#                                                  not installed)
#   3. Scripts/make-dmg.sh                      -> dist/GabeTeX.dmg
#   4. shasum -a 256                            -> dist/GabeTeX.dmg.sha256  ("<hash>  GabeTeX.dmg")
#   5. prints the version, size and checksum
#
# This script never publishes, uploads, tags, commits or installs anything. Attaching dist/GabeTeX.dmg to a
# GitHub release is a separate, manual step. The app is ad-hoc signed and NOT notarized (no Developer ID).
# The DMG file name carries no version on purpose: the stable URL
# https://github.com/gabe-rbo/GabeTeX-macOS/releases/latest/download/GabeTeX.dmg keeps working for every release.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

[ "$(uname -s)" = "Darwin" ] || { echo "release: needs macOS" >&2; exit 1; }

PLIST="$ROOT/Support/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
case "$VERSION" in
  [0-9]*.[0-9]*) ;;
  *) echo "release: unexpected CFBundleShortVersionString '$VERSION' in Support/Info.plist" >&2; exit 1 ;;
esac

APP="$ROOT/build/GabeTeX.app"
DIST="$ROOT/dist"
DMG="$DIST/GabeTeX.dmg"
SUM="$DIST/GabeTeX.dmg.sha256"

echo "==> GabeTeX $VERSION: building the app (release)"
CONFIG=release bash "$ROOT/Scripts/build-app.sh"           # no --install: nothing is copied anywhere

echo "==> GabeTeX $VERSION: building the disk image"
mkdir -p "$DIST"
rm -f "$DMG" "$SUM"
bash "$ROOT/Scripts/make-dmg.sh" "$APP" "$DMG"

echo "==> Checksum"
( cd "$DIST" && shasum -a 256 "GabeTeX.dmg" > "GabeTeX.dmg.sha256" )
( cd "$DIST" && shasum -a 256 -c "GabeTeX.dmg.sha256" >/dev/null )

BYTES="$(stat -f%z "$DMG")"
HASH="$(cut -d' ' -f1 "$SUM")"
echo
echo "GabeTeX $VERSION"
echo "  file     $DMG"
echo "  size     $(awk -v b="$BYTES" 'BEGIN { printf "%.2f MB", b / 1048576 }') ($BYTES bytes)"
echo "  sha256   $HASH"
echo "  checksum $SUM"
echo "  signing  ad-hoc, not notarized"
echo "Nothing was published, uploaded, tagged or installed."
