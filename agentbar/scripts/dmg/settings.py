# dmgbuild settings for AgentBar's .dmg window. Run by scripts/build-dmg.sh:
#   dmgbuild -s scripts/dmg/settings.py -D app=<path> -D readme=<path> -D background=<tiff> "AgentBar <version>" out.dmg
import os.path

app = defines["app"]
readme = defines["readme"]

format = "UDZO"
filesystem = "HFS+"
files = [app, readme]
symlinks = {"Applications": "/Applications"}
hide_extension = [os.path.basename(app)]
icon_locations = {
    os.path.basename(app): (170, 170),
    "Applications": (490, 170),
    os.path.basename(readme): (330, 385),
}
background = defines["background"]
window_rect = ((200, 160), (660, 470))  # matches the 660x470 background
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
arrange_by = None
