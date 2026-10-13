# dmgbuild settings for the CHERRY Utility installer DMG (used by Scripts/make-dmg.sh).
# Defines passed with -D: app (path to CherryUtility.app), icon (volume .icns), background (1x PNG; the @2x sibling
# is combined into a HiDPI TIFF by dmgbuild).
# The window and icon positions match Design/icons/DMGBackground.svg: a 660×400 pt canvas with the app at (165, 200)
# and the Applications link at (495, 200), 128 pt icons, the dashed arrow between them.
import os.path

app = defines["app"]  # noqa: F821 (dmgbuild injects `defines`)
app_name = os.path.basename(app)

format = "UDZO"
compression_level = 9
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]  # noqa: F821
background = defines["background"]  # noqa: F821

window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
show_item_info = False
arrange_by = None
label_pos = "bottom"
text_size = 13
icon_size = 128
icon_locations = {app_name: (165, 200), "Applications": (495, 200)}
