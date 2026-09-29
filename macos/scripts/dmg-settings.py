# dmgbuild settings for the Mobdev disk image: the app and a shortcut to Applications on the background
# from scripts/make-dmg-background.swift, which uses the same window size and icon positions.
#   dmgbuild -s scripts/dmg-settings.py -D app=build/Mobdev.app -D background=Resources/DMGBackground.png \
#     Mobdev build/dist/Mobdev.dmg
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
name = os.path.basename(app)

format = "ULFO"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")

# DMGBackground@2x.png next to it is picked up for Retina displays.
background = defines["background"]  # noqa: F821
# The window height includes Finder's 32 pt title bar above the 660 × 400 background.
window_rect = ((200, 140), (660, 432))
icon_locations = {name: (175, 190), "Applications": (485, 190)}
icon_size = 128
text_size = 13
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
