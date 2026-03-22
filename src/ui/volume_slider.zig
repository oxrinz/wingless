const std = @import("std");
const zclay = @import("zclay");
const ui = @import("../ui.zig");
const main = @import("../main.zig");

pub var volume: f32 = 0.5;
var fill_state: f32 = 0.5;  // lerped fill amount for smooth volume bar

// pos_state drives the x offset (slow — gives a visible slide in/out)
// glass_state drives anim_scale (fast open, held at 1 during close until off screen)
var pos_state: f32 = 0;
var glass_state: f32 = 0;

var hide_countdown: f32 = 0;
var prev_menu_open: bool = false;

var dragging: bool = false;
var cursor_y: f32 = 0;
var last_sent_volume: f32 = -1;
var vol_hovered: bool = false;
var vol_hover_scale: f32 = 1.0;
var vol_hover_brightness: f32 = 0.05;

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn clampedLerp(a: f32, b: f32, t: f32) f32 {
    return std.math.clamp(lerp(a, b, @min(t, 1.0)), 0.0, 1.0);
}

pub fn onVolumeChanged() void {
    hide_countdown = 2.0;
}

pub fn onCursorMove(y: f32) void {
    cursor_y = y;
}

pub fn onMouseButton(pressed: bool) void {
    if (!pressed and dragging) {
        dragging = false;
        const pct: u8 = @intFromFloat(std.math.clamp(volume, 0, 1) * 100);
        var buf: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, "{d}%", .{pct}) catch return;
        main.spawnCmd(&[_][]const u8{ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", s });
        last_sent_volume = volume;
    } else if (!pressed) {
        dragging = false;
    }
}

pub fn tick(dt: f32) void {
    // opening the menu cancels the standalone countdown —
    // the slider now lives and dies with the menu
    if (ui.menu_open and !prev_menu_open) {
        hide_countdown = 0;
    }
    prev_menu_open = ui.menu_open;

    if (hide_countdown > 0 and !ui.menu_open) {
        hide_countdown -= dt;
        if (hide_countdown < 0) hide_countdown = 0;
    }

    if (dragging and !ui.menu_open) hide_countdown = @max(hide_countdown, 0.5);

    const should_show = ui.menu_open or hide_countdown > 0;

    // position: slow lerp so the slide is actually visible
    pos_state = clampedLerp(pos_state, if (should_show) 1.0 else 0.0, dt * 5.0);

    // glass scale: pop in fast on open; during close, stay at 1 until
    // the element is off screen (pos_state < 0.1), then drop quickly
    const glass_target: f32 = if (should_show) 1.0 else if (pos_state > 0.1) 1.0 else 0.0;
    glass_state = clampedLerp(glass_state, glass_target, dt * 20.0);

    // smooth fill
    fill_state = clampedLerp(fill_state, std.math.clamp(volume, 0, 1), dt * 10.0);

    if (dragging) {
        const pad: f32 = 6;
        const inner_h: f32 = 288;
        const data = zclay.getElementData(zclay.ElementId.ID("VolumeSlider"));
        if (data.found) {
            const bb = data.bounding_box;
            const rel_y = cursor_y - bb.y - pad;
            volume = 1.0 - std.math.clamp(rel_y / inner_h, 0, 1);

        }
    }

    const speed = dt * 14.0;
    const vol_target_scale: f32 = if (vol_hovered) 1.08 else 1.0;
    const vol_target_brightness: f32 = if (vol_hovered) 0.14 else 0.05;
    vol_hover_scale = lerp(vol_hover_scale, vol_target_scale, speed);
    vol_hover_brightness = lerp(vol_hover_brightness, vol_target_brightness, speed);
    vol_hovered = false;
}

pub fn isActive() bool {
    return pos_state > 0.001 or glass_state > 0.001 or hide_countdown > 0 or ui.menu_open;
}

pub fn layout() void {
    if (!isActive()) return;

    const track_h: f32 = 300;
    const track_w: f32 = 44;
    const pad: f32 = 6;

    // short off-screen distance so the entire slide is within the visible zone
    const vol_x_off: f32 = lerp(70.0, -24.0, pos_state);

    zclay.UI()(.{
        .id = .ID("VolumeSlider"),
        .floating = .{
            .attach_to = .to_root,
            .attach_points = .{ .element = .right_center, .parent = .right_center },
            .offset = .{ .x = vol_x_off, .y = 0 },
        },
        .layout = .{
            .direction = .top_to_bottom,
            .sizing = .{ .w = .fixed(track_w), .h = .fixed(track_h) },
            .padding = .{ .top = @intFromFloat(pad), .bottom = @intFromFloat(pad), .left = @intFromFloat(pad), .right = @intFromFloat(pad) },
        },
        .custom = .{ .custom_data = ui.mkAnimatedGlassFill(44, glass_state * vol_hover_scale, fill_state, .top_to_bottom, 8.0, vol_hover_brightness) },
    })({
        zclay.cdefs.Clay_OnHover(struct {
            pub fn callback(_: zclay.ElementId, ptr_data: zclay.PointerData, _: ?*anyopaque) callconv(.c) void {
                vol_hovered = true;
                if (ptr_data.state == .pressed_this_frame or ptr_data.state == .pressed) {
                    dragging = true;
                }
            }
        }.callback, null);
    });
}
