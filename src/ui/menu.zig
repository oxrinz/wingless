const std = @import("std");
const zclay = @import("zclay");
const ui = @import("../ui.zig");
const main = @import("../main.zig");
const Focusable = main.Focusable;
const c = @import("../c.zig").c;

const BtnAction = enum { power, reboot };
const BtnCbData = struct { action: BtnAction };
var power_cb_data = BtnCbData{ .action = .power };
var reboot_cb_data = BtnCbData{ .action = .reboot };

var power_hover: bool = false;
var power_hover_brightness: f32 = 0.05;
var power_hover_scale: f32 = 1.0;
var reboot_hover: bool = false;
var reboot_hover_brightness: f32 = 0.05;
var reboot_hover_scale: f32 = 1.0;

var clock_buf: [16]u8 = undefined;
var clock_str: []u8 = clock_buf[0..0];

var date_buf: [32]u8 = undefined;
var date_str: []u8 = date_buf[0..0];

// this is public only because of the fullscreen blur
pub var menu_state: f32 = 0;

const max_thumbs = 16;
var thumb_hover: [max_thumbs]bool = [_]bool{false} ** max_thumbs;
var thumb_hover_scale: [max_thumbs]f32 = [_]f32{1.0} ** max_thumbs;
var thumb_hover_brightness: [max_thumbs]f32 = [_]f32{0.05} ** max_thumbs;

const ThumbCbData = struct { idx: usize, focusable: *Focusable };
var thumb_cb_data: [max_thumbs]ThumbCbData = undefined;

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

pub fn toggleMenu() void {
    if (ui.beacon_open == false) ui.menu_open = !ui.menu_open;
}

pub fn tick(dt: f32) void {
    menu_state = lerp(menu_state, if (ui.menu_open) 1.0 else 0.0, dt * 20.0);

    const ts = c.time(null);
    const tm = c.localtime(&ts);
    clock_str = std.fmt.bufPrint(&clock_buf, "{d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(tm.*.tm_hour)),
        @as(u32, @intCast(tm.*.tm_min)),
    }) catch clock_buf[0..0];

    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const month_idx: usize = @intCast(tm.*.tm_mon);
    const day_idx: usize = @intCast(tm.*.tm_wday);
    date_str = std.fmt.bufPrint(&date_buf, "{s}, {d} {s}", .{
        day_names[day_idx],
        @as(u32, @intCast(tm.*.tm_mday)),
        month_names[month_idx],
    }) catch date_buf[0..0];

    // animate hover states
    const speed = dt * 14.0;
    for (0..max_thumbs) |i| {
        const target_scale: f32 = if (thumb_hover[i]) 1.06 else 1.0;
        const target_brightness: f32 = if (thumb_hover[i]) 0.14 else 0.05;
        thumb_hover_scale[i] = lerp(thumb_hover_scale[i], target_scale, speed);
        thumb_hover_brightness[i] = lerp(thumb_hover_brightness[i], target_brightness, speed);
        thumb_hover[i] = false; // reset each frame, set again by OnHover
    }
    power_hover_brightness = lerp(power_hover_brightness, if (power_hover) 0.18 else 0.05, speed);
    power_hover_scale = lerp(power_hover_scale, if (power_hover) 1.06 else 1.0, speed);
    reboot_hover_brightness = lerp(reboot_hover_brightness, if (reboot_hover) 0.18 else 0.05, speed);
    reboot_hover_scale = lerp(reboot_hover_scale, if (reboot_hover) 1.06 else 1.0, speed);
    power_hover = false;
    reboot_hover = false;
}

pub fn isActive() bool {
    return ui.menu_open or menu_state > 0.0001;
}

pub fn layout(focusables: ?[]*Focusable) void {
    if (menu_state <= 0.0001) return;

    const s = ui.ui_scale;
    const clock_x_off: f32 = lerp(-300.0 * s, 40.0 * s, menu_state);
    // const shadow_x_off: f32 = lerp(-620.0, -320.0, menu_state);

    // TODO: add shadow behind clock text
    //    zclay.UI()(.{
    //        .id = .ID("ClockShadow"),
    //        .floating = .{
    //            .attach_to = .to_root,
    //            .attach_points = .{ .element = .left_bottom, .parent = .left_bottom },
    //            .offset = .{ .x = shadow_x_off, .y = -40 },
    //        },
    //        .layout = .{
    //            .sizing = .{ .w = .fixed(300), .h = .fixed(140) },
    //        },
    //        .custom = .{ .custom_data = ui.mkAnimatedShadow(120, menu_state, 1.00) },
    //    })({});

    // text element, 40px from left and bottom edges
    zclay.UI()(.{
        .id = .ID("ClockText"),
        .floating = .{
            .attach_to = .to_root,
            .attach_points = .{ .element = .left_bottom, .parent = .left_bottom },
            .offset = .{ .x = clock_x_off, .y = -40 * s },
        },
        .layout = .{
            .direction = .top_to_bottom,
            .sizing = .{ .w = .fit, .h = .fit },
            .padding = .{ .top = @intFromFloat(10 * s), .bottom = @intFromFloat(10 * s), .left = 0, .right = 0 },
            .child_gap = @intFromFloat(12 * s),
        },
    })({
        const date_font_size: u16 = @intFromFloat(24 * s);
        const date_sz = ui.textSize(date_str, date_font_size);
        zclay.UI()(.{
            .id = .ID("DateText"),
            .layout = .{ .sizing = .{ .w = .fixed(date_sz.w), .h = .fixed(date_sz.h) } },
            .custom = .{ .custom_data = ui.mkGlassText(date_str, date_font_size, false) },
        })({});
        const clock_font_size: u16 = @intFromFloat(96 * s);
        const clock_sz = ui.textSize(clock_str, clock_font_size);
        zclay.UI()(.{
            .id = .ID("ClockText2"),
            .layout = .{ .sizing = .{ .w = .fixed(clock_sz.w), .h = .fixed(clock_sz.h) } },
            .custom = .{ .custom_data = ui.mkGlassText(clock_str, clock_font_size, true) },
        })({});
    });

    const btn_slide: f32 = lerp(120.0 * s, -40.0 * s, menu_state);

    // Reboot button
    zclay.UI()(.{
        .id = .ID("RebootBtn"),
        .floating = .{
            .attach_to = .to_root,
            .attach_points = .{ .element = .right_bottom, .parent = .right_bottom },
            .offset = .{ .x = btn_slide - 66 * s, .y = -40 * s },
        },
        .layout = .{
            .sizing = .{ .w = .fixed(54 * s), .h = .fixed(54 * s) },
            .child_alignment = .{ .x = .center, .y = .center },
        },
        .custom = .{ .custom_data = ui.mkAnimatedGlass(54 * s, menu_state * reboot_hover_scale, 10.0 * s, reboot_hover_brightness) },
    })({
        zclay.cdefs.Clay_OnHover(struct {
            pub fn callback(_: zclay.ElementId, ptr_data: zclay.PointerData, _: ?*anyopaque) callconv(.c) void {
                reboot_hover = true;
                if (ptr_data.state == .pressed_this_frame) main.spawnCmd(&[_][]const u8{ "systemctl", "reboot" });
            }
        }.callback, null);
        zclay.UI()(.{
            .id = .ID("RebootIcon"),
            .layout = .{ .sizing = .{ .w = .fixed(32 * s * reboot_hover_scale), .h = .fixed(32 * s * reboot_hover_scale) } },
            .custom = .{ .custom_data = ui.mkIconByName(std.heap.page_allocator, "_restart") },
        })({});
    });

    // Power button
    zclay.UI()(.{
        .id = .ID("PowerBtn"),
        .floating = .{
            .attach_to = .to_root,
            .attach_points = .{ .element = .right_bottom, .parent = .right_bottom },
            .offset = .{ .x = btn_slide, .y = -40 * s },
        },
        .layout = .{
            .sizing = .{ .w = .fixed(54 * s), .h = .fixed(54 * s) },
            .child_alignment = .{ .x = .center, .y = .center },
        },
        .custom = .{ .custom_data = ui.mkAnimatedGlass(54 * s, menu_state * power_hover_scale, 10.0 * s, power_hover_brightness) },
    })({
        zclay.cdefs.Clay_OnHover(struct {
            pub fn callback(_: zclay.ElementId, ptr_data: zclay.PointerData, _: ?*anyopaque) callconv(.c) void {
                power_hover = true;
                if (ptr_data.state == .pressed_this_frame) main.spawnCmd(&[_][]const u8{ "systemctl", "poweroff" });
            }
        }.callback, null);
        zclay.UI()(.{
            .id = .ID("PowerIcon"),
            .layout = .{ .sizing = .{ .w = .fixed(32 * s * power_hover_scale), .h = .fixed(32 * s * power_hover_scale) } },
            .custom = .{ .custom_data = ui.mkIconByName(std.heap.page_allocator, "_power") },
        })({});
    });

    if (focusables == null) return;

    const focs = focusables.?;
    const scale: f32 = 0.2;
    const menu_gap: f32 = 80.0 * s;
    const padding: f32 = 16.0 * s;

    zclay.UI()(.{
        .id = .ID("Menu"),
        .layout = .{
            .sizing = .grow,
            .child_alignment = .{ .x = .center, .y = .center },
            .child_gap = @as(u16, @intFromFloat(menu_gap)),
        },
    })({
        for (focs, 0..) |focusable, i| {
            if (i >= max_thumbs) break;
            const surf = focusable.surface();
            const surf_w: f32 = @floatFromInt(surf.current.width);
            const surf_h: f32 = @floatFromInt(surf.current.height);
            const thumb_w = surf_w * scale + padding * 2.0;
            const thumb_h = surf_h * scale + padding * 2.0;
            thumb_cb_data[i] = .{ .idx = i, .focusable = focusable };
            const combined_scale = menu_state * thumb_hover_scale[i];
            zclay.UI()(.{
                .id = .IDI("Thumb", @intCast(i)),
                .layout = .{
                    .child_alignment = .{ .x = .center, .y = .center },
                    .sizing = .{ .w = .fixed(thumb_w), .h = .fixed(thumb_h) },
                },
                .custom = .{ .custom_data = ui.mkAnimatedGlass(36, combined_scale, 10.0, thumb_hover_brightness[i]) },
            })({
                zclay.cdefs.Clay_OnHover(struct {
                    pub fn callback(_: zclay.ElementId, ptr_data: zclay.PointerData, user_data: ?*anyopaque) callconv(.c) void {
                        const d: *ThumbCbData = @ptrCast(@alignCast(user_data.?));
                        thumb_hover[d.idx] = true;
                        if (ptr_data.state == .pressed_this_frame) {
                            main.focus_toplevel(d.focusable);
                            ui.menu_open = false;
                        }
                    }
                }.callback, &thumb_cb_data[i]);
                zclay.UI()(.{
                    .id = .IDI("ThumbSurface", @intCast(i)),
                    .layout = .{
                        .sizing = .{ .w = .fixed(surf_w * scale), .h = .fixed(surf_h * scale) },
                    },
                    .custom = .{ .custom_data = ui.mkWindowSurface(focusable, scale, combined_scale) },
                })({});
            });
        }
    });
}
