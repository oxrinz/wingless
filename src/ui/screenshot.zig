const std = @import("std");
const zclay = @import("zclay");
const c = @import("../c.zig").c;
const gl = @import("../c.zig").gl;
const ui = @import("../ui.zig");
const main = @import("../main.zig");
const recording = @import("recording.zig");

pub const CaptureMode = enum { screenshot, recording };
var capture_mode: CaptureMode = .screenshot;

pub const State = enum { idle, capturing, capturing_fullscreen, selecting };
pub var state: State = .idle;

var cap_w: c_int = 0;
var cap_h: c_int = 0;
var cap_pixels: []u8 = &.{};
var cap_tex: c_uint = 0;

var drag_start_x: f32 = 0;
var drag_start_y: f32 = 0;
var cur_x: f32 = 0;
var cur_y: f32 = 0;
var has_selection: bool = false;
var is_dragging: bool = false;

var ss_hover: bool = false;
var ss_scale: f32 = 1.02;
var ss_fill: f32 = 1.0;
var rec_hover: bool = false;
var rec_scale: f32 = 1.0;
var rec_fill: f32 = 0.0;

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

var prog: c_uint = 0;
var vbo: c_uint = 0;
var pos_loc: c_int = -1;
var scene_loc: c_int = -1;
var sel_loc: c_int = -1;
var res_loc: c_int = -1;

const vert_src = @embedFile("../shaders/screenshot.vert");
const frag_src = @embedFile("../shaders/screenshot.frag");

fn compileShader(kind: c_uint, src: []const u8) c_uint {
    const sh = gl.glCreateShader(kind);
    var buf: [8048]u8 = undefined;
    if (src.len + 1 > buf.len) @panic("screenshot shader too long");
    @memcpy(buf[0..src.len], src);
    buf[src.len] = 0;
    var p: [*c]const u8 = @ptrCast(&buf[0]);
    var len: c_int = @intCast(src.len);
    gl.glShaderSource(sh, 1, &p, &len);
    gl.glCompileShader(sh);
    return sh;
}

fn ensureGL() void {
    if (prog != 0) return;

    const vs = compileShader(gl.GL_VERTEX_SHADER, vert_src);
    const fs = compileShader(gl.GL_FRAGMENT_SHADER, frag_src);
    prog = gl.glCreateProgram();
    gl.glAttachShader(prog, vs);
    gl.glAttachShader(prog, fs);
    gl.glLinkProgram(prog);
    gl.glDeleteShader(vs);
    gl.glDeleteShader(fs);

    pos_loc = gl.glGetAttribLocation(prog, "pos");
    scene_loc = gl.glGetUniformLocation(prog, "scene");
    sel_loc = gl.glGetUniformLocation(prog, "sel");
    res_loc = gl.glGetUniformLocation(prog, "resolution");

    gl.glGenBuffers(1, &vbo);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vbo);
    const verts = [_]f32{
        -1, -1, 1, -1, -1, 1,
        1,  -1, 1, 1,  -1, 1,
    };
    gl.glBufferData(gl.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, gl.GL_STATIC_DRAW);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, 0);
}

pub fn activate() void {
    activateWithMode(.screenshot);
}

pub fn activateFullscreen() void {
    if (state != .idle) return;
    capture_mode = .screenshot;
    state = .capturing_fullscreen;
    main.resetCursorToDefault();
}

pub fn activateRecordingRegion() void {
    activateWithMode(.recording);
}

fn activateWithMode(mode: CaptureMode) void {
    if (state != .idle) return;
    capture_mode = mode;
    state = .capturing;
    ui.open.menu = false;
    ui.open.beacon = false;
    main.resetCursorToDefault();
}

pub fn onMouseButton(pressed: bool, x: f32, y: f32) bool {
    if (state != .selecting) return false;
    if (pressed) {
        if (zclay.pointerOver(zclay.ElementId.ID("CaptureTypeScreenshot"))) {
            capture_mode = .screenshot;
            return true;
        }
        if (zclay.pointerOver(zclay.ElementId.ID("CaptureTypeRecord"))) {
            capture_mode = .recording;
            return true;
        }
        if (zclay.pointerOver(zclay.ElementId.ID("CaptureToolbar"))) {
            return true;
        }
        drag_start_x = x;
        drag_start_y = y;
        cur_x = x;
        cur_y = y;
        has_selection = true;
        is_dragging = true;
    } else {
        is_dragging = false;
        if (has_selection) {
            cur_x = x;
            cur_y = y;
            commitSelection();
            cancel();
        }
    }
    return true;
}

pub fn onMouseMotion(x: f32, y: f32) bool {
    if (state != .selecting) return false;
    cur_x = x;
    cur_y = y;
    return true;
}

pub fn onKey(sym: c_uint) bool {
    if (state != .selecting) return false;
    if (sym == c.XKB_KEY_Escape) {
        cancel();
        return true;
    }
    return false;
}

pub fn cancel() void {
    state = .idle;
    has_selection = false;
    is_dragging = false;
    if (cap_tex != 0) {
        gl.glDeleteTextures(1, &cap_tex);
        cap_tex = 0;
    }
    if (cap_pixels.len > 0) {
        std.heap.page_allocator.free(cap_pixels);
        cap_pixels = &.{};
    }
}

fn selRect() struct { x1: f32, y1: f32, x2: f32, y2: f32 } {
    return .{
        .x1 = @min(drag_start_x, cur_x),
        .y1 = @min(drag_start_y, cur_y),
        .x2 = @max(drag_start_x, cur_x),
        .y2 = @max(drag_start_y, cur_y),
    };
}

const SaveJob = struct {
    pixels: []u8,
    w: c_int,
    h: c_int,
};

fn stbiWriteCallback(context: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
    const list: *std.ArrayList(u8) = @ptrCast(@alignCast(context orelse return));
    const bytes: [*]u8 = @ptrCast(data orelse return);
    list.appendSlice(std.heap.page_allocator, bytes[0..@intCast(size)]) catch {};
}

fn saveThreadFn(job: SaveJob) void {
    defer std.heap.page_allocator.free(job.pixels);

    var png_buf: std.ArrayList(u8) = .empty;
    defer png_buf.deinit(std.heap.page_allocator);

    _ = c.stbi_write_png_to_func(stbiWriteCallback, &png_buf, job.w, job.h, 4, job.pixels.ptr, job.w * 4);

    var child = std.process.Child.init(
        &[_][]const u8{ "wl-copy", "--type", "image/png" },
        std.heap.page_allocator,
    );
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return;
    const stdin = child.stdin orelse return;
    _ = stdin.writeAll(png_buf.items) catch {};
    stdin.close();
    child.stdin = null;
    _ = child.wait() catch {};
}

fn spawnSave(pixels: []u8, w: c_int, h: c_int) void {
    const job = SaveJob{ .pixels = pixels, .w = w, .h = h };
    const t = std.Thread.spawn(.{}, saveThreadFn, .{job}) catch {
        std.heap.page_allocator.free(pixels);
        return;
    };
    t.detach();
}

fn copyFullscreenPixels(w: c_int, h: c_int) void {
    const pixels = std.heap.page_allocator.alloc(u8, cap_pixels.len) catch return;
    @memcpy(pixels, cap_pixels);
    spawnSave(pixels, w, h);
}

fn copySelectionPixels() void {
    const sel = selRect();
    const fw: f32 = @floatFromInt(cap_w);
    const fh: f32 = @floatFromInt(cap_h);

    const px_x: c_int = @intFromFloat(@max(0, @floor(sel.x1)));
    const px_y_top: c_int = @intFromFloat(@max(0, @floor(sel.y1)));
    const px_x2: c_int = @intFromFloat(@min(fw, @ceil(sel.x2)));
    const px_y_bot: c_int = @intFromFloat(@min(fh, @ceil(sel.y2)));

    const out_w: c_int = @max(1, px_x2 - px_x);
    const out_h: c_int = @max(1, px_y_bot - px_y_top);

    const out_pixels = std.heap.page_allocator.alloc(u8, @intCast(out_w * out_h * 4)) catch return;

    for (0..@intCast(out_h)) |row| {
        const screen_y: c_int = px_y_top + @as(c_int, @intCast(row));
        if (screen_y < 0 or screen_y >= cap_h) continue;
        const src_offset: usize = @intCast((screen_y * cap_w + px_x) * 4);
        const dst_offset: usize = row * @as(usize, @intCast(out_w)) * 4;
        @memcpy(out_pixels[dst_offset..][0..@intCast(out_w * 4)], cap_pixels[src_offset..][0..@intCast(out_w * 4)]);
    }

    spawnSave(out_pixels, out_w, out_h);
}

fn commitSelection() void {
    switch (capture_mode) {
        .screenshot => copySelectionPixels(),
        .recording => {
            const sel = selRect();
            const rx: c_int = @intFromFloat(@max(0, @floor(sel.x1)));
            const ry: c_int = @intFromFloat(@max(0, @floor(sel.y1)));
            const rw: c_int = @max(1, @as(c_int, @intFromFloat(@ceil(sel.x2))) - rx);
            const rh: c_int = @max(1, @as(c_int, @intFromFloat(@ceil(sel.y2))) - ry);
            recording.startRegion(cap_w, cap_h, rx, ry, rw, rh);
        },
    }
}

pub fn tick(dt: f32) void {
    const speed = dt * 14.0;
    const ss_sel = capture_mode == .screenshot;
    const rec_sel = capture_mode == .recording;
    ss_scale = lerp(ss_scale, if (ss_hover) 1.06 else if (ss_sel) 1.02 else 1.0, speed);
    rec_scale = lerp(rec_scale, if (rec_hover) 1.06 else if (rec_sel) 1.02 else 1.0, speed);
    ss_fill = lerp(ss_fill, if (ss_sel) 1.0 else 0.0, speed);
    rec_fill = lerp(rec_fill, if (rec_sel) 1.0 else 0.0, speed);
    ss_hover = false;
    rec_hover = false;
}

fn onScreenshotBtnHover(_: zclay.ElementId, ptr_data: zclay.PointerData, _: ?*anyopaque) callconv(.c) void {
    ss_hover = true;
    if (ptr_data.state == .pressed_this_frame) capture_mode = .screenshot;
}

fn onRecordBtnHover(_: zclay.ElementId, ptr_data: zclay.PointerData, _: ?*anyopaque) callconv(.c) void {
    rec_hover = true;
    if (ptr_data.state == .pressed_this_frame) capture_mode = .recording;
}

pub fn layoutToolbar() void {
    if (state != .selecting or is_dragging) return;

    const s = ui.ui_scale;
    const font_size: u16 = @intFromFloat(17 * s);
    const ss_sz = ui.textSize("Screenshot", font_size);
    const rec_sz = ui.textSize("Record", font_size);

    const icon_sz: f32 = 20 * s;
    const icon_gap: f32 = 8 * s;
    const inner_pad: f32 = 14 * s;
    const outer_pad: f32 = 8 * s;
    const gap: f32 = 8 * s;
    const btn_h: f32 = @max(ss_sz.h, rec_sz.h) + inner_pad * 2;
    const ss_btn_w: f32 = icon_sz + icon_gap + ss_sz.w + inner_pad * 2;
    const rec_btn_w: f32 = icon_sz + icon_gap + rec_sz.w + inner_pad * 2;
    const total_w: f32 = ss_btn_w + rec_btn_w + gap + outer_pad * 2;
    const total_h: f32 = btn_h + outer_pad * 2;

    const hint_font_size: u16 = @intFromFloat(14 * s);
    zclay.UI()(.{
        .id = .ID("CaptureHint"),
        .floating = .{
            .attach_to = .to_root,
            .attach_points = .{ .element = .center_center, .parent = .center_center },
        },
        .layout = .{ .sizing = .{ .w = .fit, .h = .fit } },
    })({
        zclay.text("Draw an area to select", .{ .font_size = hint_font_size, .color = .{ 255, 255, 255, 90 } });
    });

    zclay.UI()(.{
        .id = .ID("CaptureToolbar"),
        .floating = .{
            .attach_to = .to_root,
            .attach_points = .{ .element = .center_top, .parent = .center_top },
            .offset = .{ .x = 0, .y = 30 * s },
        },
        .layout = .{
            .direction = .left_to_right,
            .sizing = .{ .w = .fixed(total_w), .h = .fixed(total_h) },
            .padding = .{
                .top = @intFromFloat(outer_pad),
                .bottom = @intFromFloat(outer_pad),
                .left = @intFromFloat(outer_pad),
                .right = @intFromFloat(outer_pad),
            },
            .child_gap = @intFromFloat(gap),
            .child_alignment = .{ .y = .center },
        },
    })({
        zclay.UI()(.{
            .id = .ID("CaptureTypeScreenshot"),
            .layout = .{
                .sizing = .{ .w = .fixed(ss_btn_w), .h = .fixed(btn_h) },
                .child_alignment = .{ .x = .center, .y = .center },
            },
            .custom = .{ .custom_data = ui.mkAnimatedGlassFill(14 * s, ss_scale, ss_fill, .top_to_bottom) },
        })({
            zclay.cdefs.Clay_OnHover(onScreenshotBtnHover, null);
            zclay.UI()(.{
                .id = .ID("CaptureTypeScreenshotRow"),
                .layout = .{
                    .direction = .left_to_right,
                    .sizing = .{ .w = .fixed(icon_sz + icon_gap + ss_sz.w), .h = .fixed(btn_h) },
                    .child_gap = @intFromFloat(icon_gap),
                    .child_alignment = .{ .y = .center },
                },
            })({
                zclay.UI()(.{
                    .id = .ID("CaptureTypeScreenshotIcon"),
                    .layout = .{ .sizing = .{ .w = .fixed(icon_sz), .h = .fixed(icon_sz) } },
                    .custom = .{ .custom_data = ui.mkIcon(std.heap.page_allocator, "screenshot-ui-area-symbolic", 1.0) },
                })({});
                zclay.UI()(.{
                    .id = .ID("CaptureTypeScreenshotLabel"),
                    .layout = .{ .sizing = .{ .w = .fixed(ss_sz.w), .h = .fixed(ss_sz.h) } },
                    .custom = .{ .custom_data = ui.mkGlassTextDark("Screenshot", font_size, false, ss_fill) },
                })({});
            });
        });

        zclay.UI()(.{
            .id = .ID("CaptureTypeRecord"),
            .layout = .{
                .sizing = .{ .w = .fixed(rec_btn_w), .h = .fixed(btn_h) },
                .child_alignment = .{ .x = .center, .y = .center },
            },
            .custom = .{ .custom_data = ui.mkAnimatedGlassFill(14 * s, rec_scale, rec_fill, .top_to_bottom) },
        })({
            zclay.cdefs.Clay_OnHover(onRecordBtnHover, null);
            zclay.UI()(.{
                .id = .ID("CaptureTypeRecordRow"),
                .layout = .{
                    .direction = .left_to_right,
                    .sizing = .{ .w = .fixed(icon_sz + icon_gap + rec_sz.w), .h = .fixed(btn_h) },
                    .child_gap = @intFromFloat(icon_gap),
                    .child_alignment = .{ .y = .center },
                },
            })({
                zclay.UI()(.{
                    .id = .ID("CaptureTypeRecordIcon"),
                    .layout = .{ .sizing = .{ .w = .fixed(icon_sz), .h = .fixed(icon_sz) } },
                    .custom = .{ .custom_data = ui.mkIcon(std.heap.page_allocator, "media-record-symbolic", 1.0) },
                })({});
                zclay.UI()(.{
                    .id = .ID("CaptureTypeRecordLabel"),
                    .layout = .{ .sizing = .{ .w = .fixed(rec_sz.w), .h = .fixed(rec_sz.h) } },
                    .custom = .{ .custom_data = ui.mkGlassTextDark("Record", font_size, false, rec_fill) },
                })({});
            });
        });
    });
}

pub fn renderBackground(w: c_int, h: c_int) void {
    if (state != .selecting) return;
    if (prog == 0) return;

    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);

    gl.glUseProgram(prog);
    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, cap_tex);
    gl.glUniform1i(scene_loc, 0);
    if (has_selection) {
        const sel = selRect();
        gl.glUniform4f(sel_loc, sel.x1 / fw, sel.y1 / fh, sel.x2 / fw, sel.y2 / fh);
    } else {
        gl.glUniform4f(sel_loc, -1.0, -1.0, -1.0, -1.0);
    }
    gl.glUniform2f(res_loc, fw, fh);

    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vbo);
    gl.glEnableVertexAttribArray(@intCast(pos_loc));
    gl.glVertexAttribPointer(@intCast(pos_loc), 2, gl.GL_FLOAT, gl.GL_FALSE, 2 * @sizeOf(f32), @ptrFromInt(0));
    gl.glDrawArrays(gl.GL_TRIANGLES, 0, 6);
    gl.glDisableVertexAttribArray(@intCast(pos_loc));
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, 0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, 0);
    gl.glUseProgram(0);
}

pub fn onFrame(w: c_int, h: c_int) void {
    switch (state) {
        .idle, .selecting => {},
        .capturing, .capturing_fullscreen => {
            const is_fullscreen = state == .capturing_fullscreen;
            ensureGL();
            cap_w = w;
            cap_h = h;
            const pixel_count: usize = @intCast(w * h * 4);
            if (cap_pixels.len != pixel_count) {
                if (cap_pixels.len > 0) std.heap.page_allocator.free(cap_pixels);
                cap_pixels = std.heap.page_allocator.alloc(u8, pixel_count) catch {
                    state = .idle;
                    return;
                };
            }
            gl.glReadPixels(0, 0, w, h, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, cap_pixels.ptr);

            if (is_fullscreen) {
                copyFullscreenPixels(w, h);
                state = .idle;
                if (cap_pixels.len > 0) {
                    std.heap.page_allocator.free(cap_pixels);
                    cap_pixels = &.{};
                }
                return;
            }

            if (cap_tex != 0) gl.glDeleteTextures(1, &cap_tex);
            gl.glGenTextures(1, &cap_tex);
            gl.glBindTexture(gl.GL_TEXTURE_2D, cap_tex);
            gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
            gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
            gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
            gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
            gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, w, h, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, cap_pixels.ptr);
            gl.glBindTexture(gl.GL_TEXTURE_2D, 0);

            has_selection = false;
            state = .selecting;
        },
    }
}
