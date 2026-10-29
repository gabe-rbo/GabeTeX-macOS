#!/bin/bash
# Headless check of a finished GabeTeX.dmg (no Finder, no GUI): verifies the image checksum, mounts it
# read-only without browsing, inspects the contents and the .DS_Store, then detaches.
#
#   Support/DMG/verify-dmg.sh [path/to/GabeTeX.dmg]            (default: dist/GabeTeX.dmg)
#   DMG_PYTHON=<python with ds_store + mac_alias>               (default: build/.dmg-venv/bin/python)
#
# Exit status 0 only if every check passes. Called by Scripts/make-dmg.sh.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
DMG="${1:-$ROOT/dist/GabeTeX.dmg}"
PY="${DMG_PYTHON:-$ROOT/build/.dmg-venv/bin/python}"

FAILS=0
ok()  { echo "  ok   $*"; }
bad() { echo "  FAIL $*" >&2; FAILS=$((FAILS + 1)); }
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }

[ -f "$DMG" ] || { echo "verify-dmg: no such file: $DMG" >&2; exit 2; }
[ -x "$PY" ] || { echo "verify-dmg: python with ds_store not found: $PY" >&2; exit 2; }
DMG="$(cd "$(dirname "$DMG")" && pwd)/$(basename "$DMG")"

echo "Verifying $DMG"

# --- image ---------------------------------------------------------------------------------------------------
if VERIFY_OUT="$(hdiutil verify "$DMG" 2>&1)"; then
  ok "hdiutil verify: $(echo "$VERIFY_OUT" | tail -1)"
else
  echo "$VERIFY_OUT" >&2; bad "hdiutil verify"
fi
INFO="$(hdiutil imageinfo "$DMG" 2>/dev/null || true)"
FORMAT="$(echo "$INFO" | awk -F': ' '/^Format:/ {print $2; exit}')"
FORMAT_DESC="$(echo "$INFO" | awk -F': ' '/^Format Description:/ {print $2; exit}')"
echo "  format: $FORMAT ($FORMAT_DESC)"

# --- mount ---------------------------------------------------------------------------------------------------
MNT="$(mktemp -d "${TMPDIR:-/tmp}/gabetex-dmg-verify.XXXXXX")"
MNT="$(cd "$MNT" && pwd -P)"          # /tmp is a symlink: use the real path, as `mount` and hdiutil do
ATTACHED=0
cleanup() {
  if [ "$ATTACHED" = 1 ]; then
    hdiutil detach "$MNT" -quiet >/dev/null 2>&1 || { sleep 2; hdiutil detach "$MNT" -force -quiet >/dev/null 2>&1; }
  fi
  rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT
if ! ATTACH_OUT="$(hdiutil attach -nobrowse -readonly -noverify -noautoopen -mountpoint "$MNT" "$DMG" 2>&1)"; then
  echo "$ATTACH_OUT" >&2; bad "hdiutil attach"; echo "verify-dmg: FAILED ($FAILS)" >&2; exit 1
fi
ATTACHED=1
ok "mounted read-only at $MNT"
echo "  filesystem: $(mount | awk -v m=" on $MNT " 'index($0, m) { sub(/^[^(]*\(/, ""); sub(/,.*/, ""); print; exit }')"
echo "  top level: $(ls -A "$MNT" | tr '\n' ' ')"

# --- contents ------------------------------------------------------------------------------------------------
check "GabeTeX.app present"                          test -d "$MNT/GabeTeX.app"
check "GabeTeX.app: codesign --verify --deep --strict" codesign --verify --deep --strict "$MNT/GabeTeX.app"
check "Applications is a symlink to /Applications"   test "$(readlink "$MNT/Applications" 2>/dev/null)" = "/Applications"

# Visible items must be exactly the app and the shortcut.
VISIBLE="$(ls "$MNT" | tr '\n' ' ')"
check "only GabeTeX.app and Applications are visible (found: $VISIBLE)" test "$VISIBLE" = "Applications GabeTeX.app "

BG=""
for candidate in "$MNT/.background.tiff" "$MNT"/.background/*.tiff; do [ -f "$candidate" ] && BG="$candidate" && break; done
if [ -n "$BG" ]; then
  ok "background found: ${BG#$MNT/}"
  check "background equals Support/DMG/background.tiff" cmp -s "$BG" "$HERE/background.tiff"
else
  bad "no .background.tiff (or .background/*.tiff) in the image"
fi

check ".DS_Store exists"                             test -s "$MNT/.DS_Store"
check ".VolumeIcon.icns exists"                      test -s "$MNT/.VolumeIcon.icns"
check ".VolumeIcon.icns equals Support/AppIcon.icns" cmp -s "$MNT/.VolumeIcon.icns" "$ROOT/Support/AppIcon.icns"

# --- Finder metadata: custom-icon flag and .DS_Store ---------------------------------------------------------
"$PY" - "$MNT" "$HERE/layout.json" <<'PY'
import json, os, shutil, subprocess, sys, tempfile

mnt, layout_path = sys.argv[1], sys.argv[2]
layout = json.load(open(layout_path, encoding="utf-8"))
failures = 0

def ok(msg):
    print("  ok   " + msg)

def bad(msg):
    global failures
    failures += 1
    print("  FAIL " + msg, file=sys.stderr)

def expect(what, actual, expected):
    if actual == expected:
        ok("%s = %r" % (what, actual))
    else:
        bad("%s = %r, expected %r" % (what, actual, expected))

# Volume has the custom-icon flag (kHasCustomIcon = 0x0400 in the Finder flags at FinderInfo[8:10]).
try:
    raw = subprocess.run(["/usr/bin/xattr", "-px", "com.apple.FinderInfo", mnt], capture_output=True, text=True, check=True).stdout
    info = bytes.fromhex("".join(raw.split()))
    flags = int.from_bytes(info[8:10], "big")
    (ok if flags & 0x0400 else bad)("volume custom-icon flag (Finder flags 0x%04x)" % flags)
except Exception as exc:
    bad("cannot read the volume's FinderInfo: %s" % exc)

# .DS_Store (copied out: the volume is read-only).
from ds_store import DSStore
from mac_alias import Alias

tmp = tempfile.mkdtemp(prefix="gabetex-dsstore-")
try:
    copy = os.path.join(tmp, "DS_Store")
    shutil.copyfile(os.path.join(mnt, ".DS_Store"), copy)
    entries = {}
    with DSStore.open(copy, "r") as store:
        for entry in store:
            code = entry.code.decode("ascii") if isinstance(entry.code, bytes) else entry.code
            entries[(entry.filename, code)] = entry.value
finally:
    shutil.rmtree(tmp, ignore_errors=True)

def need(key):
    if key not in entries:
        bad(".DS_Store has no %s record for %r" % (key[1], key[0]))
        return None
    return entries[key]

frame = layout["windowFrame"]
bwsp = need((".", "bwsp"))
if bwsp is not None:
    expect("bwsp WindowBounds", bwsp.get("WindowBounds"),
           "{{%d, %d}, {%d, %d}}" % (frame["x"], frame["y"], frame["width"], frame["height"]))
    for key in ("ShowToolbar", "ShowStatusBar", "ShowPathbar", "ShowSidebar", "ContainerShowSidebar", "ShowTabView"):
        expect("bwsp " + key, bwsp.get(key), False)

icvp = need((".", "icvp"))
if icvp is not None:
    expect("icvp iconSize", icvp.get("iconSize"), float(layout["iconSize"]))
    expect("icvp textSize", icvp.get("textSize"), float(layout["textSize"]))
    expect("icvp backgroundType (2 = picture)", icvp.get("backgroundType"), 2)
    expect("icvp showIconPreview", icvp.get("showIconPreview"), False)
    expect("icvp showItemInfo", icvp.get("showItemInfo"), False)
    expect("icvp labelOnBottom", icvp.get("labelOnBottom"), True)
    expect("icvp arrangeBy", icvp.get("arrangeBy"), "none")
    blob = icvp.get("backgroundImageAlias")
    if blob:
        try:
            alias = Alias.from_bytes(blob)
            expect("background alias target", alias.target.filename, ".background.tiff")
            expect("background alias volume name", alias.volume.name, "GabeTeX")
        except Exception as exc:
            bad("cannot decode backgroundImageAlias: %s" % exc)
    else:
        bad("icvp has no backgroundImageAlias")

if need((".", "pBBk")) is not None:
    ok("pBBk background bookmark present")

icvl = need((".", "icvl"))
if icvl is not None:
    expect("icvl view", tuple(icvl)[1] if isinstance(icvl, (tuple, list)) else icvl, b"icnv")

for name, point in layout["icons"].items():
    loc = need((name, "Iloc"))
    if loc is not None:
        expect("Iloc %s" % name, (int(loc[0]), int(loc[1])), (int(point["x"]), int(point["y"])))

sys.exit(1 if failures else 0)
PY
[ $? -eq 0 ] || FAILS=$((FAILS + 1))

# --- size ----------------------------------------------------------------------------------------------------
DMG_BYTES="$(stat -f%z "$DMG")"
APP_KB="$(du -sk "$MNT/GabeTeX.app" | cut -f1)"
echo "  size: $(awk -v b="$DMG_BYTES" 'BEGIN { printf "%.2f MB", b / 1048576 }') image, $(awk -v k="$APP_KB" 'BEGIN { printf "%.2f MB", k / 1024 }') app inside"
check "image is not larger than the app plus 8 MB of artwork/metadata" \
  test "$DMG_BYTES" -le $((APP_KB * 1024 + 8 * 1048576))

if [ "$FAILS" -eq 0 ]; then
  echo "verify-dmg: all checks passed"
  exit 0
fi
echo "verify-dmg: $FAILS check(s) FAILED" >&2
exit 1
