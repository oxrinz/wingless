# Wingless

Minimal Wayland compositor without sacrificing beauty

<!-- stats -->
![Lines of code](https://img.shields.io/badge/lines_of_code-15910-blue) ![UI lines](https://img.shields.io/badge/ui_lines-7938-blue) ![Functions](https://img.shields.io/badge/functions-279-blue)
<!-- /stats -->

## Installation

### Dependencies

On Arch Linux:
```
sudo pacman -S libinput libxcb mesa libglvnd wlroots wayland libxkbcommon pixman systemd
```

### Build

Zig 0.15.2.
```
zig build
```

The binary will be at `zig-out/bin/wingless`.

To build and run directly:
```
zig build run
```

Make sure to create `~/.wingless` before running or it will probably break... lol. Also add a background

### Config

`~/.wingless` is a flat key-value config file. Lines starting with `#` are comments.

| Key | Type | Description |
|-----|------|-------------|
| `BACKGROUND` | path | Wallpaper image path |
| `POINTER_SENSITIVITY` | float | Mouse acceleration speed (-1 to 1, default: 0) |
| `KEY_REPEAT_RATE` | int | Key repeat rate in Hz (default: 60) |
| `KEY_REPEAT_DELAY` | int | Key repeat delay in ms (default: 200) |
| `BIND` | `<modifier> <key> <function>` | Add a keybind on top of the defaults |

Modifiers: `super`, `super_shift`, `none`

Key names use XKB notation: `n`, `Tab`, `space`, `XF86AudioRaiseVolume`, etc.

Functions: `tab_next`, `tab_prev`, `close_focused`, `toggle_fullscreen`, `toggle_menu`, `toggle_beacon`, `volume_up`, `volume_down`, `volume_mute`, `snap_left`, `snap_right`, `move_to_next_output`, `screenshot`, `screenshot_fullscreen`, `record`, `record_fullscreen`, `shutdown`, `reboot`

```
# Wingless config

BACKGROUND = /home/user/wallpaper.jpg;
POINTER_SENSITIVITY = 0.5;
KEY_REPEAT_RATE = 50;
KEY_REPEAT_DELAY = 300;

BIND = super n tab_next;
BIND = super p tab_prev;
BIND = super q close_focused;
BIND = super space toggle_beacon;
BIND = super Tab toggle_menu;
BIND = none XF86AudioRaiseVolume volume_up;
BIND = none XF86AudioLowerVolume volume_down;
BIND = none XF86AudioMute volume_mute;
```

### Recording

Recordings done through the recording tool will be placed in your home folder with the name wingless-<timestamp>.mp4. They won't be copied to your clipboard (yet).
Recording keybind works as a toggle, same keys to start and end recordings.


## improvement vectors:
- menu ui
- common logic between menu beacon and screenshotting ui
- output management
- glass shaders
- glass morph
- input

## todo:
- Bluetooth in menu
- Design language and client library
- Multiple desktops
- Don't render windows that are behind one another
- Port to vulkan
- Get rid of wlroots
- Figure out which protocols obs is missing
- wf-recorder shows everything brighter than what it actually is in discord?
- Settings app
- Different glass refraction styles
- Menu window borders should be consistent regardless of window size
- Add something that'd tell users if nm is not installed instead of silently failing
- Notification system
- Frostpunk black when tabbing back in bug
- Moving windows from one monitor to another in menu
- Reordering windows in the menu
- Operation get to 12k lines
- Better glass highlights

## done
- Window switching
- Get zen browser working
- Commands
- Filter commads launchable from beacon
- Beacon suggestions should be fuzzy
- Desktop app launching from beacon with icons
- Test surface focus
- Popup / toplevel destruction tests. Eliminate all known panics and crashes
- Spotify working
- Finish XWayland, no bugs, no crashes, no issues
- Make popups pop in the middle (steam, kicad)
- Configuration
- Mouse dragging
- Drag and drop
- Fix right clicks zen browser
- Fix kicad crash - not really but solved anyway
- Fix random spotify crash - (doesn't crash anymore no idea what happened or when it got fixed) (it does crash afterall but very inconsistently) (fixed for real now)
- Clay
- Tab chooser on super key
- Volume changing popup
- Volume, time, power, restart in menu
- Copy paste lol
- Layouting / tiling
- OBS fake fullscreen init configure weird check
- Line 991 fix segfault in commit
- Screen recording - f-recorder only
- Compositor icons (question mark or unknown icons, search icon, command icons)
- Volume slider based on real defaults
- Beacon placeholder
- Async icon loading
- Fix volume slider and volume control, should be clamped
- UI scaling, support different resolutions
- zwp_linux_dmabuf_v1
- zxdg_output_manager_v1
- Fix recoridng software causing cursor to disappear
- Change volume with keyboard sliders
- Beacon search using .desktop keywords
- Pointer constraints protocol (zwp_pointer_constraints_v1)
- The Mute Button
- Popups positioned within the screen
- Refresh .desktop entries at runtime
- Repeated input in UI
- Input propagation logic rework
- Fully polish beacon
- Menu window positioning
- Async region screenshotting
- Async screenshotting
- Menu clickable after closing bug
- Menu window options should be static, old window replaces the clicked window's position
- Fix inconsistent brightness menu buttons
- Render all shadows in one pass to avoid shadow overlaps
- Wifi in menu
- Beacon opening on left side bug
- Space and other keys sometimes propagating through beacon fix, released keys shouldn't be propagated when the pressed key is handled
- SDF morphing. Shapes should bleed into each other when they're close, for example the shutdown / restart buttons
- Power buttons rework
- Dragging windows with the status bar
- Transparency protocol
- Finalize glass shader
- Screenrecording
- Region screenrecording
- NetworkManager wifi
- Screenshotting / screenrecording proper ui
- Fix cursor constraints to work in cs2
- Cursor setting
- Cursor visibility protocol
- Menu button morphing
- Support multiple monitors
- Rick roll
- Resize request protocol
- Figure out icons properly
- Sound IO settings
- Better rim highlighting
- Glass brightness
- XWayland resize
- Calsans X Poppins
