# dmgbuild settings for the ClaudeWatcher disk image. Used by scripts/build-dmg.sh, which
# passes -D app=<ClaudeWatcher.app> -D background=<background.png> [-D icon=<AppIcon.icns>].
#
# dmgbuild writes the .DS_Store itself (no Finder, no AppleScript), so this runs headless.
# Geometry must match scripts/dmg-background.swift (window 660x400 pt, icon centers).
import os.path

app = defines["app"]  # noqa: F821 (injected by dmgbuild)
app_name = os.path.basename(app)

# Contents
format = "ULMO"  # LZMA (macOS 10.15+; the app needs 26). ~20% smaller than UDZO.
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}

# Volume icon: the app's .icns when one is passed (-D icon=...), else the default disk icon.
icon = defines.get("icon") or None  # noqa: F821

# Window
background = defines["background"]  # noqa: F821; background@2x.png next to it is picked up
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_icon_preview = False

# Icon view
arrange_by = None
icon_size = 128
text_size = 13
label_pos = "bottom"
icon_locations = {
    app_name: (170, 170),
    "Applications": (490, 170),
}
