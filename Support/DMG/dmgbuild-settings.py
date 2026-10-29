# dmgbuild settings for GabeTeX.dmg. Used by Scripts/make-dmg.sh:
#
#   python -m dmgbuild -s Support/DMG/dmgbuild-settings.py -D app=<GabeTeX.app> -D support=<Support dir> \
#          GabeTeX GabeTeX.dmg
#
# dmgbuild runs this file with the `defines` dictionary in scope. Every geometry number comes from
# Support/DMG/layout.json, which Scripts/make-dmg-background.swift writes next to the background picture it
# draws, so the icons always land in the slots of the artwork.
#
# Coordinates: points, origin at the top-left of the Finder window's *content area*. Finder's WindowBounds is the
# whole window frame (content + title bar), so the frame is 32 pt taller than the 660 x 420 picture area.

import json
import os

support = defines["support"]  # noqa: F821  (provided by dmgbuild)
application = defines["app"]  # noqa: F821
dmg_dir = os.path.join(support, "DMG")

with open(os.path.join(dmg_dir, "layout.json"), encoding="utf-8") as handle:
    layout = json.load(handle)

frame = layout["windowFrame"]
icons = layout["icons"]

# MARK: Image

volume_name = "GabeTeX"
format = "ULMO"  # LZMA-compressed read-only image (macOS 10.15+; GabeTeX needs macOS 26)
filesystem = defines.get("filesystem", "APFS")  # noqa: F821
size = None  # dmgbuild sizes the scratch image itself and shrinks it before converting

# MARK: Contents

# (source, name inside the image): the name is fixed so the icon_locations key below always matches.
files = [(application, "GabeTeX.app")]
symlinks = {"Applications": "/Applications"}
# No hide_extensions: SetFile -a E would put com.apple.FinderInfo on the bundle, which `codesign --strict` rejects.
icon = os.path.join(support, "AppIcon.icns")  # volume icon: .VolumeIcon.icns + the custom-icon flag
badge_icon = None

# MARK: Window

background = os.path.join(dmg_dir, "background.tiff")  # 1x + 2x TIFF drawn by make-dmg-background.swift
window_rect = (
    (int(frame["x"]), int(frame["y"])),
    (int(frame["width"]), int(frame["height"])),
)
default_view = "icon-view"
show_toolbar = False
show_status_bar = False
show_pathbar = False
show_sidebar = False
show_tab_view = False

# MARK: Icon view

icon_size = int(layout["iconSize"])
text_size = int(layout["textSize"])
label_pos = "bottom"
arrange_by = None
show_icon_preview = False
show_item_info = False
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)

icon_locations = {
    name: (int(position["x"]), int(position["y"])) for name, position in icons.items()
}
