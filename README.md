# Wingless

Minimal Wayland compositor without sacrificing beauty

<!-- stats -->
![Lines of code](https://img.shields.io/badge/lines_of_code-15858-blue) ![UI lines](https://img.shields.io/badge/ui_lines-7892-blue) ![Functions](https://img.shields.io/badge/functions-279-blue)
<!-- /stats -->

## improvement vectors:
- pointer protocol code
- menu ui
- common logic between menu beacon and screenshotting ui
- output management
- glass shaders
- glass morph

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
- Menu showing windows only specific to that screen

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
