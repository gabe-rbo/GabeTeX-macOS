#!/bin/bash
# Builds GabeTeX.app with the Command Line Tools (no Xcode needed).
#   Scripts/build-app.sh            → build/GabeTeX.app (release)
#   CONFIG=debug Scripts/build-app.sh
#   Scripts/build-app.sh --install  → also copies to ~/Applications/GabeTeX.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
CONFIG="${CONFIG:-release}"

swift build -c "$CONFIG" --product GabeTeX
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

APP="$ROOT/build/GabeTeX.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/GabeTeX" "$APP/Contents/MacOS/GabeTeX"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
[ -f "$ROOT/Support/AppIcon.icns" ] && cp "$ROOT/Support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
for lproj in "$ROOT"/Resources/*.lproj; do
  cp -R "$lproj" "$APP/Contents/Resources/"
done
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d.%H%M)" "$APP/Contents/Info.plist" >/dev/null
codesign --force --sign - --timestamp=none "$APP" >/dev/null
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  mkdir -p "$HOME/Applications"
  DEST="$HOME/Applications/GabeTeX.app"
  if [ -d "$DEST" ]; then mv "$DEST" "$HOME/.Trash/GabeTeX-$(date +%s).app"; fi
  cp -R "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
  echo "Installed $DEST"
fi
