# Wingless

Minimal Wayland compositor without sacrificing beauty

## todo before mvp:
- Window switching - done
- Get zen browser working - done
- Commands - done
- Filter commads launchable from beacon - done
- Beacon suggestions should be fuzzy - done
- Desktop app launching from beacon with icons - done
- Test surface focus - done
- Popup / toplevel destruction tests. Eliminate all known panics and crashes - done
- Spotify working - done
- Finish XWayland, no bugs, no crashes, no issues - done
- Make popups pop in the middle (steam, kicad) - done
- Configuration - done
- Mouse dragging - done
- Drag and drop - done
- Fix right clicks zen browser - done
- Fix kicad crash - done (not really but solved anyway)
- Fix random spotify crash - done (doesn't crash anymore no idea what happened or when it got fixed) (it does crash afterall but very inconsistently)
- Clay UI - done
- Tab chooser on super key - done
- Volume changing popup - done
- Volume, time, power, restart in menu - done
- Copy paste lol - done
- Layouting / tiling - done
- OBS fake fullscreen init configure weird check - done
- Line 991 fix segfault in commit - done
- Screen recording - done, wf-recorder only
- Compositor icons (question mark or unknown icons, search icon, command icons) - done
- Volume slider based on real defaults - done
- Beacon placeholder - done
- Async icon loading - done
- Fix volume slider and volume control, should be clamped - done
- UI scaling, support different resolutions - done
- zwp_linux_dmabuf_v1 - done
- zxdg_output_manager_v1 - done
- Fix recoridng software causing cursor to disappear
- Multiple desktops

## todo after mvp:
- Refresh .desktop entries at runtime
- Popups positioned within the screen
- The Mute Button
- Design language and design toolkit
- Wifi and Bluetooth in menu
- Screenshotting
- Pointer constraints protocol (zwp_pointer_constraints_v1)
- SDF morphing. Shapes should bleed into each other when they're close, for example the shutdown / restart buttons
- Design menu properly
- Render all shadows in one pass to avoid shadow overlaps
- Change volume with keyboard sliders
- Support multiple monitors
- Beacon search using .desktop keywords
- Don't render windows that are behind one another
- Port to vulkan
- Get rid of wlroots
