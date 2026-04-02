const std = @import("std");
const zclay = @import("zclay");
const ui = @import("../ui.zig");
const main = @import("../main.zig");

pub var volume: f32 = 0.5;
var fill_state: f32 = 0.5;
const max_volume: f32 = 1.0;

pub fn init() void {
    const result = std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &[_][]const u8{ "wpctl", "get-volume", "@DEFAULT_AUDIO_SINK@" },
    }) catch return;
    defer std.heap.page_allocator.free(result.stdout);
    defer std.heap.page_allocator.free(result.stderr);
    const prefix = "Volume: ";
    const line = std.mem.trimRight(u8, result.stdout, " \n\r");
    if (std.mem.startsWith(u8, line, prefix)) {
        const rest = line[prefix.len..];
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        volume = std.math.clamp(std.fmt.parseFloat(f32, rest[0..end]) catch 0.5, 0.0, max_volume);
        fill_state = std.math.clamp(volume / max_volume, 0.0, 1.0);
    }
}

var pos_state: f32 = 0;
var glass_state: f32 = 0;

var hide_countdown: f32 = 0;
var prev_menu_open: bool = false;

var dragging: bool = false;
var cursor_x: f32 = 0;
var cursor_y: f32 = 0;
var last_sent_volume: f32 = -1;
var vol_hovered: bool = false;
var vol_hover_scale: f32 = 1.0;

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn clampedLerp(a: f32, b: f32, t: f32) f32 {
    return std.math.clamp(lerp(a, b, @min(t, 1.0)), 0.0, 1.0);
}

pub fn onVolumeChanged() void {
    hide_countdown = 2.0;
}

pub fn onCursorMove(x: f32, y: f32) void {
    cursor_x = x;
    cursor_y = y;
}

fn calcVolumeFromCursor() void {
    const pad: f32 = 6 * ui.ui_scale;
    const inner_h: f32 = 288 * ui.ui_scale;
    const data = zclay.getElementData(zclay.ElementId.ID("VolumeSlider"));
    if (data.found) {
        const bb = data.bounding_box;
        const clamped_y = std.math.clamp(cursor_y, bb.y, bb.y + bb.height);
        const rel_y = clamped_y - bb.y - pad;
        volume = max_volume * (1.0 - std.math.clamp(rel_y / inner_h, 0, 1));
    }
}

fn sendVolume() void {
    if (@abs(volume - last_sent_volume) < 0.005) return;
    var buf: [16]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d:.2}", .{std.math.clamp(volume, 0, max_volume)}) catch return;
    main.spawnCmd(&[_][]const u8{ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", s });
    last_sent_volume = volume;
}

pub fn onMouseButton(pressed: bool) void {
    if (pressed) {
        const data = zclay.getElementData(zclay.ElementId.ID("VolumeSlider"));
        if (data.found) {
            const bb = data.bounding_box;
            if (cursor_x >= bb.x and cursor_x <= bb.x + bb.width and cursor_y >= bb.y and cursor_y <= bb.y + bb.height) {
                dragging = true;
                calcVolumeFromCursor();
            }
        }
    } else if (dragging) {
        dragging = false;
        last_sent_volume = -1;
        sendVolume();
    } else {
        dragging = false;
    }
}

pub fn tick(dt: f32) void {
    if (ui.open.menu and !prev_menu_open) {
        hide_countdown = 0;
    }
    prev_menu_open = ui.open.menu;

    if (hide_countdown > 0 and !ui.open.menu) {
        hide_countdown -= dt;
        if (hide_countdown < 0) hide_countdown = 0;
    }

    if (dragging and !ui.open.menu) hide_countdown = @max(hide_countdown, 0.5);

    const should_show = ui.open.menu or hide_countdown > 0;

    pos_state = clampedLerp(pos_state, if (should_show) 1.0 else 0.0, dt * 5.0);

    const glass_target: f32 = if (should_show) 1.0 else if (pos_state > 0.1) 1.0 else 0.0;
    glass_state = clampedLerp(glass_state, glass_target, dt * 20.0);

    fill_state = clampedLerp(fill_state, std.math.clamp(volume / max_volume, 0, 1), dt * 10.0);

    if (dragging) {
        calcVolumeFromCursor();
        sendVolume();
    }

    const speed = dt * 14.0;
    const vol_target_scale: f32 = if (vol_hovered) 1.08 else 1.0;
    vol_hover_scale = lerp(vol_hover_scale, vol_target_scale, speed);
    vol_hovered = false;
}

pub fn isActive() bool {
    return pos_state > 0.001 or glass_state > 0.001 or hide_countdown > 0 or ui.open.menu;
}

pub fn layout() void {
    if (!isActive()) return;

    const s = ui.ui_scale;
    const track_h: f32 = 300 * s;
    const track_w: f32 = 44 * s;
    const pad: f32 = 6 * s;
    const vol_x_off: f32 = lerp(70.0 * s, -24.0 * s, pos_state);

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
        .custom = .{ .custom_data = ui.mkAnimatedGlassFill(22, glass_state * vol_hover_scale, fill_state, .top_to_bottom) },
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
