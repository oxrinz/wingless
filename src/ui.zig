const std = @import("std");
pub const zclay = @import("zclay");

const config = @import("config.zig");
const rendering = @import("ui/rendering.zig");
pub const beacon = @import("ui/beacon.zig");
pub const menu = @import("ui/menu.zig");
pub const volume_slider = @import("ui/volume_slider.zig");
pub const screenshot = @import("ui/screenshot.zig");
pub const recording = @import("ui/recording.zig");

const main = @import("main.zig");
const WinglessOutput = main.WinglessOutput;
const WinglessServer = main.WinglessServer;
const Focusable = main.Focusable;

const c = @import("c.zig").c;
const gl = @import("c.zig").gl;

const glass_vert_src = @embedFile("shaders/glass.vert");
const glass_common_src = @embedFile("shaders/glass_common.glsl");
const glass_frag_src = glass_common_src ++ @embedFile("shaders/glass.frag");
const glass_blob_frag_src = glass_common_src ++ @embedFile("shaders/glass_blob.frag");
const text_frag_src = @embedFile("shaders/glass_text.frag");

pub const AnimState = struct { elapsed: u64 };

var last_ns: i128 = 0;

pub const OpenFlags = packed struct(u8) {
    menu: bool = false,
    beacon: bool = false,
    _: u6 = 0,
};
pub var open: OpenFlags = .{};
pub var pointer_down: bool = false;
pub var screen_width: f32 = 0;
pub var screen_height: f32 = 0;
pub var cursor_screen_width: f32 = 0;
pub var cursor_screen_height: f32 = 0;
pub var ui_scale: f32 = 1.0;
pub var output_refresh_hz: u32 = 60;

var glass_font: Font = undefined;
var display_font: Font = undefined;
var icon_cache: std.StringHashMap(?Icon) = undefined;
var icon_path_index: std.StringHashMap([]const u8) = undefined;
var default_icon: Icon = undefined;

const PendingIcon = struct {
    name: []const u8,
    pixels: [*c]u8,
    w: c_int,
    h: c_int,
};
var pending_icons: std.ArrayList(PendingIcon) = .empty;
var pending_mutex: std.Thread.Mutex = .{};
var icon_index_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

pub const Icon = struct {
    tex: c_uint,
    w: u32,
    h: u32,
};

pub const GlassBackgroundProgram = struct {
    prog: c_uint,
    pos_loc: c_int,
    scene_loc: c_int,
    quad_pos_loc: c_int,
    size_loc: c_int,
    roundness: c_int,
    fill_amount_loc: c_int,
    fill_direction_loc: c_int,
    refraction_band_loc: c_int,
    resolution_loc: c_int,
    blur_amount_loc: c_int,
};

pub const GlassBlobProgram = struct {
    prog: c_uint,
    pos_loc: c_int,
    scene_loc: c_int,
    resolution_loc: c_int,
    centers_loc: c_int,
    scales_loc: c_int,
    widths_loc: c_int,
    heights_loc: c_int,
    radius_loc: c_int,
    morph_k_loc: c_int,
    open_state_loc: c_int,
    mask_center_loc: c_int,
    mask_half_ex_loc: c_int,
    mask_half_ey_loc: c_int,
    mask_radius_loc: c_int,
};

pub const FillDir = enum(i32) {
    none = 0,
    bottom_to_top = 1,
    top_to_bottom = 2,
    left_to_right = 3,
    right_to_left = 4,
};

pub const GlassTextProgram = struct {
    prog: c_uint,
    pos_loc: c_int,
    uv_loc: c_int,
    atlas_loc: c_int,
    scene_loc: c_int,
    px_range_loc: c_int,
    thickness_loc: c_int,
    glass_mode_loc: c_int,
    dark_amount_loc: c_int,
    resolution_loc: c_int,
};

pub const FillProgram = struct {
    prog: c_uint,
    pos_loc: c_int,
    color_loc: c_int,
};

pub const RoundFillProgram = struct {
    prog: c_uint,
    pos_loc: c_int,
    color_loc: c_int,
    quad_pos_loc: c_int,
    size_loc: c_int,
    roundness_loc: c_int,
    resolution_loc: c_int,
};

pub const SpinnerProgram = struct {
    prog: c_uint,
    pos_loc: c_int,
    color_loc: c_int,
    quad_pos_loc: c_int,
    size_loc: c_int,
    resolution_loc: c_int,
    time_loc: c_int,
};

pub const MAX_SHADOW_COUNT: usize = 16;
pub const MAX_BLOB_COUNT: usize = 4;

pub const ShadowProgram = struct {
    prog: c_uint,
    pos_loc: c_int,
    resolution_loc: c_int,
    pos_locs: [MAX_SHADOW_COUNT]c_int,
    size_locs: [MAX_SHADOW_COUNT]c_int,
    roundness_locs: [MAX_SHADOW_COUNT]c_int,
    intensity_locs: [MAX_SHADOW_COUNT]c_int,
    blob_centers_loc: c_int,
    blob_scales_loc: c_int,
    blob_widths_loc: c_int,
    blob_heights_loc: c_int,
    blob_radius_loc: c_int,
    blob_morph_k_loc: c_int,
    blob_intensity_loc: c_int,
    blob_mask_center_loc: c_int,
    blob_mask_half_ex_loc: c_int,
    blob_mask_half_ey_loc: c_int,
    blob_mask_radius_loc: c_int,
};

pub const BlurProgram = struct {
    prog: c_uint,
    pos_loc: c_int,
    scene_loc: c_int,
    intensity_loc: c_int,
    direction_loc: c_int,
    resolution_loc: c_int,
};

pub const TextProgram = struct {
    prog: c_uint,
    pos_loc: c_int,
    uv_loc: c_int,
    atlas_loc: c_int,
    px_range_loc: c_int,
    thickness_loc: c_int,
    color_loc: c_int,
};

pub const ImageProgram = struct {
    prog: c_uint,
    pos_loc: c_int,
    uv_loc: c_int,
    image_loc: c_int,
    size_loc: c_int,
    quad_pos_loc: c_int,
    roundness_loc: c_int,
    alpha_loc: c_int,
};

pub const WindowProgram = struct {
    prog: c_uint,
    pos_loc: c_int,
    uv_loc: c_int,
    image_loc: c_int,
    size_loc: c_int,
    quad_pos_loc: c_int,
    clip_pos_loc: c_int,
    clip_size_loc: c_int,
    roundness_loc: c_int,
    border_width_loc: c_int,
    border_color_loc: c_int,
};

const Glyph = struct {
    w: f32,
    h: f32,
    x_off: f32,
    y_off: f32,
    advance: f32,
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

pub const Font = struct {
    atlas_tex: c_uint,
    glyphs: [256]?Glyph,
    px_range: f32,
};

pub const CustomData = union(enum) {
    glass: struct { roundness: f32, animated: bool = false, anim_scale: f32 = 1.0, fill_amount: f32 = 0.0, fill_dir: i32 = 0 },
    window_surface: struct { focusable: *Focusable, scale: f32, anim_scale: f32 = 1.0 },
    icon: struct { icon: Icon, alpha: f32 = 1.0 },
    shadow: struct { roundness: f32, animated: bool = false, anim_scale: f32 = 1.0, intensity: f32 },
    glass_text: struct { text: []const u8, font_size: u16, bold: bool = false, dark_amount: f32 = 0.0 },
    rect: struct { roundness: f32, a: f32, r: f32 = 1.0, g: f32 = 1.0, b: f32 = 1.0 },
    spinner: struct { time: f32 },
    glass_blob: struct {
        centers: [16]f32,
        scales: [8]f32,
        widths: [8]f32,
        heights: [8]f32,
        radius: f32,
        morph_k: f32,
        shadow_x: f32, shadow_y: f32, shadow_w: f32, shadow_h: f32, shadow_r: f32,
        open_state: f32,
        mask_cx: f32, mask_cy: f32, mask_half_ex: f32, mask_half_ey: f32, mask_r: f32,
    },
};

pub const RenderContext = struct {
    output: *WinglessOutput,
    screen_width: f32,
    screen_height: f32,
    scene_tex: *c.wlr_texture,
    font: *const Font,
    display_font: *const Font,
};

var custom_pool: [256]CustomData = undefined;
var custom_pool_idx: usize = 0;

pub fn mkGlass(roundness: f32) *anyopaque {
    const d = &custom_pool[custom_pool_idx];
    custom_pool_idx += 1;
    d.* = .{ .glass = .{ .roundness = roundness } };
    return d;
}

pub fn mkAnimatedGlass(roundness: f32, anim_scale: f32) *anyopaque {
    const d = &custom_pool[custom_pool_idx];
    custom_pool_idx += 1;
    d.* = .{ .glass = .{ .roundness = roundness, .animated = true, .anim_scale = anim_scale } };
    return d;
}

pub fn mkGlassFill(roundness: f32, fill_amount: f32, fill_dir: FillDir) *anyopaque {
    const d = &custom_pool[custom_pool_idx];
    custom_pool_idx += 1;
    d.* = .{ .glass = .{ .roundness = roundness, .fill_amount = fill_amount, .fill_dir = @intFromEnum(fill_dir) } };
    return d;
}

pub fn mkAnimatedGlassFill(roundness: f32, anim_scale: f32, fill_amount: f32, fill_dir: FillDir) *anyopaque {
    const d = &custom_pool[custom_pool_idx];
    custom_pool_idx += 1;
    d.* = .{ .glass = .{ .roundness = roundness, .animated = true, .anim_scale = anim_scale, .fill_amount = fill_amount, .fill_dir = @intFromEnum(fill_dir) } };
    return d;
}

pub fn mkWindowSurface(focusable: *Focusable, scale: f32, anim_scale: f32) *anyopaque {
    const d = &custom_pool[custom_pool_idx];
    custom_pool_idx += 1;
    d.* = .{ .window_surface = .{ .focusable = focusable, .scale = scale, .anim_scale = anim_scale } };
    return d;
}

pub fn mkAnimatedShadow(roundness: f32, anim_scale: f32, intensity: f32) *anyopaque {
    const d = &custom_pool[custom_pool_idx];
    custom_pool_idx += 1;
    d.* = .{ .shadow = .{ .roundness = roundness, .animated = true, .anim_scale = anim_scale, .intensity = intensity } };
    return d;
}

pub fn mkGlassBlobRaw(centers: [16]f32, scales: [8]f32, widths: [8]f32, heights: [8]f32, radius: f32, morph_k: f32, shadow_x: f32, shadow_y: f32, shadow_w: f32, shadow_h: f32, shadow_r: f32, open_state: f32, mask_cx: f32, mask_cy: f32, mask_half_ex: f32, mask_half_ey: f32, mask_r: f32) *anyopaque {
    const d = &custom_pool[custom_pool_idx];
    custom_pool_idx += 1;
    d.* = .{ .glass_blob = .{ .centers = centers, .scales = scales, .widths = widths, .heights = heights, .radius = radius, .morph_k = morph_k, .shadow_x = shadow_x, .shadow_y = shadow_y, .shadow_w = shadow_w, .shadow_h = shadow_h, .shadow_r = shadow_r, .open_state = open_state, .mask_cx = mask_cx, .mask_cy = mask_cy, .mask_half_ex = mask_half_ex, .mask_half_ey = mask_half_ey, .mask_r = mask_r } };
    return d;
}

pub fn mkGlassBlob(t: f32, t1: f32, t2: f32, t3: f32, radius: f32, spread: f32, bx: f32, by: f32, scale0: f32, scale1: f32, scale2: f32, scale3: f32) *anyopaque {
    const diag: f32 = 0.7071067811865476;
    const cx0 = screen_width + bx - radius;
    const cy0 = screen_height - by - radius;
    const centers = [16]f32{
        cx0,                          cy0,
        cx0 - spread * t1,            cy0 + spread * 0.15 * t1,
        cx0 - spread * diag * t2,     cy0 - spread * diag * t2,
        cx0 + spread * 0.15 * t3,     cy0 - spread * t3,
        cx0, cy0, cx0, cy0, cx0, cy0, cx0, cy0,
    };
    const scales_arr = [8]f32{ scale0, scale1, scale2, scale3, 0, 0, 0, 0 };
    const widths_arr = [8]f32{ 0, 0, 0, 0, 0, 0, 0, 0 };
    const heights_arr = [8]f32{ 0, 0, 0, 0, 0, 0, 0, 0 };
    const btn_size = radius * 2.0;
    const bb_size = btn_size + spread * t;
    const shadow_x_clay = screen_width + bx - bb_size;
    const shadow_y_clay = by;
    return mkGlassBlobRaw(centers, scales_arr, widths_arr, heights_arr, radius, radius * 1.2 * @max(t1, @max(t2, t3)), shadow_x_clay, shadow_y_clay, bb_size, bb_size, radius, 0.0, 0, 0, 0, 0, 0);
}

pub fn textSize(text: []const u8, font_size: u16) zclay.Dimensions {
    return textSizeEx(text, font_size, false);
}

pub fn textSizeEx(text: []const u8, font_size: u16, bold: bool) zclay.Dimensions {
    const font = if (bold) &display_font else &glass_font;
    const scale: f32 = @floatFromInt(font_size);
    var w: f32 = 0;
    for (text) |ch| {
        if (ch == ' ') {
            w += 12.0 * scale / 32.0;
        } else if (font.glyphs[ch]) |g| {
            w += g.advance * scale;
        }
    }
    return .{ .w = w, .h = scale };
}

pub fn mkGlassText(text: []const u8, font_size: u16, bold: bool) *anyopaque {
    const d = &custom_pool[custom_pool_idx];
    custom_pool_idx += 1;
    d.* = .{ .glass_text = .{ .text = text, .font_size = font_size, .bold = bold } };
    return d;
}

pub fn mkGlassTextDark(text: []const u8, font_size: u16, bold: bool, dark_amount: f32) *anyopaque {
    const d = &custom_pool[custom_pool_idx];
    custom_pool_idx += 1;
    d.* = .{ .glass_text = .{ .text = text, .font_size = font_size, .bold = bold, .dark_amount = dark_amount } };
    return d;
}

pub fn mkSpinner(time: f32) *anyopaque {
    const d = &custom_pool[custom_pool_idx];
    custom_pool_idx += 1;
    d.* = .{ .spinner = .{ .time = time } };
    return d;
}

pub fn mkRect(roundness: f32, a: f32) *anyopaque {
    const d = &custom_pool[custom_pool_idx];
    custom_pool_idx += 1;
    d.* = .{ .rect = .{ .roundness = roundness, .a = a } };
    return d;
}

pub fn mkRectColor(roundness: f32, r: f32, g: f32, b: f32, a: f32) *anyopaque {
    const d = &custom_pool[custom_pool_idx];
    custom_pool_idx += 1;
    d.* = .{ .rect = .{ .roundness = roundness, .a = a, .r = r, .g = g, .b = b } };
    return d;
}

fn getIcon(allocator: std.mem.Allocator, name: []const u8, stroke: f32) ?Icon {
    const cache_key = if (stroke > 0.0) std.fmt.allocPrint(allocator, "{s}:s{d}", .{ name, stroke }) catch name else name;
    defer if (stroke > 0.0) allocator.free(cache_key);

    if (icon_cache.get(cache_key)) |cached| return cached;
    const path = (resolveIconPath(allocator, name) catch {
        if (icon_index_ready.load(.acquire)) {
            const key = allocator.dupe(u8, cache_key) catch return null;
            icon_cache.put(key, null) catch @panic("fuck");
        }
        return null;
    }) orelse {
        if (icon_index_ready.load(.acquire)) {
            const key = allocator.dupe(u8, cache_key) catch return null;
            icon_cache.put(key, null) catch @panic("fuck");
        }
        return null;
    };

    defer allocator.free(path);

    const cache_null = struct {
        fn do(alloc: std.mem.Allocator, n: []const u8) void {
            const k = alloc.dupe(u8, n) catch return;
            icon_cache.put(k, null) catch {};
        }
    }.do;

    const png: []u8 = if (std.mem.endsWith(u8, path, ".svg")) blk: {
        break :blk svgToPng(allocator, path, name, stroke) orelse {
            cache_null(allocator, cache_key);
            return null;
        };
    } else blk: {
        const file = std.fs.openFileAbsolute(path, .{}) catch {
            cache_null(allocator, cache_key);
            return null;
        };
        defer file.close();
        break :blk file.readToEndAlloc(allocator, 256 * 1024) catch {
            cache_null(allocator, cache_key);
            return null;
        };
    };
    defer allocator.free(png);

    const icon = loadIconFromPng(png);
    const key = allocator.dupe(u8, cache_key) catch return icon;
    icon_cache.put(key, @as(?Icon, icon)) catch {};
    return icon;
}

pub fn mkIcon(allocator: std.mem.Allocator, name: []const u8, alpha: f32) *anyopaque {
    return mkIconEx(allocator, name, alpha, 0.0);
}

pub fn mkIconEx(allocator: std.mem.Allocator, name: []const u8, alpha: f32, stroke: f32) *anyopaque {
    const d = &custom_pool[custom_pool_idx];
    custom_pool_idx += 1;
    d.* = .{ .icon = .{ .icon = getIcon(allocator, name, stroke) orelse default_icon, .alpha = alpha } };
    return d;
}

var clay_mem: []u8 = &.{};

fn measureText(text: []const u8, cfg: *zclay.TextElementConfig, _: void) zclay.Dimensions {
    const scale: f32 = @floatFromInt(cfg.font_size);
    var w: f32 = 0;
    for (text) |ch| {
        if (ch == ' ') {
            w += 12.0 * scale / 32.0;
        } else if (glass_font.glyphs[ch]) |g| {
            w += g.advance * scale;
        }
    }
    return .{ .w = w, .h = scale };
}

fn getDeltaSeconds() f32 {
    const now = std.time.nanoTimestamp();
    if (last_ns == 0) {
        last_ns = now;
        return 0;
    }
    const dt_ns = now - last_ns;
    last_ns = now;
    return @as(f32, @floatFromInt(dt_ns)) / 1_000_000_000.0;
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn ndc_x(x: f32, w: f32) f32 {
    return (x / w) * 2.0 - 1.0;
}

fn ndc_y(y: f32, h: f32) f32 {
    return 1.0 - (y / h) * 2.0;
}

fn glCompileShader(kind: c_uint, src: []const u8) c_uint {
    const sh = gl.glCreateShader(kind);

    var buf: [8048]u8 = undefined;
    if (src.len + 1 > buf.len) @panic("shader too long to compile");
    @memcpy(buf[0..src.len], src);
    buf[src.len] = 0;

    var p: [*c]const u8 = @ptrCast(&buf[0]);
    var len: c_int = @intCast(src.len);

    gl.glShaderSource(sh, 1, &p, &len);
    gl.glCompileShader(sh);

    var ok: c_int = 0;
    gl.glGetShaderiv(sh, gl.GL_COMPILE_STATUS, &ok);

    if (ok == 0) {
        var log_len: c_int = 0;
        gl.glGetShaderiv(sh, gl.GL_INFO_LOG_LENGTH, &log_len);
        if (log_len > 1) {
            var log: [1024]u8 = undefined;
            var out_len: c_int = 0;
            gl.glGetShaderInfoLog(sh, @min(log.len - 1, @as(usize, @intCast(log_len))), &out_len, @ptrCast(&log[0]));
            log[@intCast(out_len)] = 0;
            std.debug.print("shader compile log:\n{s}\n", .{log[0..@intCast(out_len)]});
        }
    }

    return sh;
}

fn glLinkProgram(vs: c_uint, fs: c_uint) c_uint {
    const prog = gl.glCreateProgram();
    gl.glAttachShader(prog, vs);
    gl.glAttachShader(prog, fs);
    gl.glLinkProgram(prog);

    var ok: c_int = 0;
    gl.glGetProgramiv(prog, gl.GL_LINK_STATUS, &ok);
    if (ok == 0) {
        var log_len: c_int = 0;
        gl.glGetProgramiv(prog, gl.GL_INFO_LOG_LENGTH, &log_len);
        if (log_len > 1) {
            var log: [1024]u8 = undefined;
            var out_len: c_int = 0;
            gl.glGetProgramInfoLog(prog, @min(log.len - 1, @as(usize, @intCast(log_len))), &out_len, @ptrCast(&log[0]));
            log[@intCast(out_len)] = 0;
            std.debug.print("program link log:\n{s}\n", .{log[0..@intCast(out_len)]});
        }
    }

    gl.glDeleteShader(vs);
    gl.glDeleteShader(fs);
    return prog;
}

pub fn toggleBeacon() void {
    if (open.beacon) beacon.beacon_buffer.clearRetainingCapacity();
    if (!open.menu and !(screenshot.state == .selecting)) {
        open.beacon = !open.beacon;
        if (open.beacon) main.resetCursorToDefault();
    }
}

pub fn ensurePrograms(out: *WinglessOutput) void {
    if (out.glass_background != null and out.glass_blob_prog != null) return;

    {
        const vs = glCompileShader(gl.GL_VERTEX_SHADER, glass_vert_src);
        const fs = glCompileShader(gl.GL_FRAGMENT_SHADER, glass_frag_src);
        const prog = glLinkProgram(vs, fs);
        out.glass_background = .{
            .prog = prog,
            .pos_loc = gl.glGetAttribLocation(prog, "pos"),
            .scene_loc = gl.glGetUniformLocation(prog, "scene"),
            .quad_pos_loc = gl.glGetUniformLocation(prog, "quadPos"),
            .size_loc = gl.glGetUniformLocation(prog, "size"),
            .roundness = gl.glGetUniformLocation(prog, "roundness"),
            .fill_amount_loc = gl.glGetUniformLocation(prog, "fillAmount"),
            .fill_direction_loc = gl.glGetUniformLocation(prog, "fillDirection"),
            .refraction_band_loc = gl.glGetUniformLocation(prog, "refractionBand"),
            .resolution_loc = gl.glGetUniformLocation(prog, "resolution"),
            .blur_amount_loc = gl.glGetUniformLocation(prog, "blurAmount"),
        };
        if (out.glass_background.?.pos_loc < 0) @panic("pos not found");
    }

    {
        const vs = glCompileShader(gl.GL_VERTEX_SHADER, @embedFile("shaders/glass_text.vert"));
        const fs = glCompileShader(gl.GL_FRAGMENT_SHADER, @embedFile("shaders/glass_text.frag"));
        const prog = glLinkProgram(vs, fs);
        out.glass_text = .{
            .prog = prog,
            .pos_loc = gl.glGetAttribLocation(prog, "pos"),
            .uv_loc = gl.glGetAttribLocation(prog, "uv"),
            .atlas_loc = gl.glGetUniformLocation(prog, "atlas"),
            .scene_loc = gl.glGetUniformLocation(prog, "scene"),
            .px_range_loc = gl.glGetUniformLocation(prog, "pxRange"),
            .thickness_loc = gl.glGetUniformLocation(prog, "thickness"),
            .glass_mode_loc = gl.glGetUniformLocation(prog, "glassMode"),
            .dark_amount_loc = gl.glGetUniformLocation(prog, "darkAmount"),
            .resolution_loc = gl.glGetUniformLocation(prog, "resolution"),
        };
    }

    {
        const vs = glCompileShader(gl.GL_VERTEX_SHADER, @embedFile("shaders/fill.vert"));
        const fs = glCompileShader(gl.GL_FRAGMENT_SHADER, @embedFile("shaders/fill.frag"));
        const prog = glLinkProgram(vs, fs);
        out.fill = .{
            .prog = prog,
            .pos_loc = gl.glGetAttribLocation(prog, "pos"),
            .color_loc = gl.glGetUniformLocation(prog, "color"),
        };
    }

    {
        const vs = glCompileShader(gl.GL_VERTEX_SHADER, glass_vert_src);
        const fs = glCompileShader(gl.GL_FRAGMENT_SHADER, @embedFile("shaders/fill_rounded.frag"));
        const prog = glLinkProgram(vs, fs);
        out.round_fill = .{
            .prog = prog,
            .pos_loc = gl.glGetAttribLocation(prog, "pos"),
            .color_loc = gl.glGetUniformLocation(prog, "color"),
            .quad_pos_loc = gl.glGetUniformLocation(prog, "quadPos"),
            .size_loc = gl.glGetUniformLocation(prog, "size"),
            .roundness_loc = gl.glGetUniformLocation(prog, "roundness"),
            .resolution_loc = gl.glGetUniformLocation(prog, "resolution"),
        };
    }

    {
        const vs = glCompileShader(gl.GL_VERTEX_SHADER, glass_vert_src);
        const fs = glCompileShader(gl.GL_FRAGMENT_SHADER, @embedFile("shaders/shadow.frag"));
        const prog = glLinkProgram(vs, fs);
        var sp: ShadowProgram = .{
            .prog = prog,
            .pos_loc = gl.glGetAttribLocation(prog, "pos"),
            .resolution_loc = gl.glGetUniformLocation(prog, "resolution"),
            .pos_locs = undefined,
            .size_locs = undefined,
            .roundness_locs = undefined,
            .intensity_locs = undefined,
            .blob_centers_loc = gl.glGetUniformLocation(prog, "blobCenters[0]"),
            .blob_scales_loc = gl.glGetUniformLocation(prog, "blobScales[0]"),
            .blob_widths_loc = gl.glGetUniformLocation(prog, "blobWidths[0]"),
            .blob_heights_loc = gl.glGetUniformLocation(prog, "blobHeights[0]"),
            .blob_radius_loc = gl.glGetUniformLocation(prog, "blobRadius[0]"),
            .blob_morph_k_loc = gl.glGetUniformLocation(prog, "blobMorphK[0]"),
            .blob_intensity_loc = gl.glGetUniformLocation(prog, "blobIntensity[0]"),
            .blob_mask_center_loc = gl.glGetUniformLocation(prog, "blobMaskCenter[0]"),
            .blob_mask_half_ex_loc = gl.glGetUniformLocation(prog, "blobMaskHalfEx[0]"),
            .blob_mask_half_ey_loc = gl.glGetUniformLocation(prog, "blobMaskHalfEy[0]"),
            .blob_mask_radius_loc = gl.glGetUniformLocation(prog, "blobMaskRadius[0]"),
        };
        var name_buf: [32]u8 = undefined;
        for (0..MAX_SHADOW_COUNT) |i| {
            sp.pos_locs[i] = gl.glGetUniformLocation(prog, (std.fmt.bufPrintZ(&name_buf, "shadowPos[{d}]", .{i}) catch unreachable).ptr);
            sp.size_locs[i] = gl.glGetUniformLocation(prog, (std.fmt.bufPrintZ(&name_buf, "shadowSize[{d}]", .{i}) catch unreachable).ptr);
            sp.roundness_locs[i] = gl.glGetUniformLocation(prog, (std.fmt.bufPrintZ(&name_buf, "shadowRoundness[{d}]", .{i}) catch unreachable).ptr);
            sp.intensity_locs[i] = gl.glGetUniformLocation(prog, (std.fmt.bufPrintZ(&name_buf, "shadowIntensity[{d}]", .{i}) catch unreachable).ptr);
        }
        out.shadow = sp;
    }

    {
        const vs = glCompileShader(gl.GL_VERTEX_SHADER, glass_vert_src);
        const fs = glCompileShader(gl.GL_FRAGMENT_SHADER, @embedFile("shaders/blur.frag"));
        const prog = glLinkProgram(vs, fs);
        out.blur = .{
            .prog = prog,
            .pos_loc = gl.glGetAttribLocation(prog, "pos"),
            .scene_loc = gl.glGetUniformLocation(prog, "scene"),
            .intensity_loc = gl.glGetUniformLocation(prog, "intensity"),
            .direction_loc = gl.glGetUniformLocation(prog, "direction"),
            .resolution_loc = gl.glGetUniformLocation(prog, "resolution"),
        };
    }

    {
        const vs = glCompileShader(gl.GL_VERTEX_SHADER, @embedFile("shaders/glass_text.vert"));
        const fs = glCompileShader(gl.GL_FRAGMENT_SHADER, @embedFile("shaders/text.frag"));
        const prog = glLinkProgram(vs, fs);
        out.text = .{
            .prog = prog,
            .pos_loc = gl.glGetAttribLocation(prog, "pos"),
            .uv_loc = gl.glGetAttribLocation(prog, "uv"),
            .atlas_loc = gl.glGetUniformLocation(prog, "atlas"),
            .px_range_loc = gl.glGetUniformLocation(prog, "pxRange"),
            .thickness_loc = gl.glGetUniformLocation(prog, "thickness"),
            .color_loc = gl.glGetUniformLocation(prog, "color"),
        };
    }

    {
        const vs = glCompileShader(gl.GL_VERTEX_SHADER, @embedFile("shaders/image.vert"));
        const fs = glCompileShader(gl.GL_FRAGMENT_SHADER, @embedFile("shaders/image.frag"));
        const prog = glLinkProgram(vs, fs);
        out.image = .{
            .prog = prog,
            .pos_loc = gl.glGetAttribLocation(prog, "pos"),
            .uv_loc = gl.glGetAttribLocation(prog, "uv"),
            .image_loc = gl.glGetUniformLocation(prog, "image"),
            .size_loc = gl.glGetUniformLocation(prog, "size"),
            .quad_pos_loc = gl.glGetUniformLocation(prog, "quadPos"),
            .roundness_loc = gl.glGetUniformLocation(prog, "roundness"),
            .alpha_loc = gl.glGetUniformLocation(prog, "alpha"),
        };
    }

    {
        const vs = glCompileShader(gl.GL_VERTEX_SHADER, @embedFile("shaders/image.vert"));
        const fs = glCompileShader(gl.GL_FRAGMENT_SHADER, @embedFile("shaders/window.frag"));
        const prog = glLinkProgram(vs, fs);
        out.window = .{
            .prog = prog,
            .pos_loc = gl.glGetAttribLocation(prog, "pos"),
            .uv_loc = gl.glGetAttribLocation(prog, "uv"),
            .image_loc = gl.glGetUniformLocation(prog, "image"),
            .size_loc = gl.glGetUniformLocation(prog, "size"),
            .quad_pos_loc = gl.glGetUniformLocation(prog, "quadPos"),
            .clip_pos_loc = gl.glGetUniformLocation(prog, "clipPos"),
            .clip_size_loc = gl.glGetUniformLocation(prog, "clipSize"),
            .roundness_loc = gl.glGetUniformLocation(prog, "roundness"),
            .border_width_loc = gl.glGetUniformLocation(prog, "borderWidth"),
            .border_color_loc = gl.glGetUniformLocation(prog, "borderColor"),
        };
    }

    {
        const vs = glCompileShader(gl.GL_VERTEX_SHADER, glass_vert_src);
        const fs = glCompileShader(gl.GL_FRAGMENT_SHADER, @embedFile("shaders/spinner.frag"));
        const prog = glLinkProgram(vs, fs);
        out.spinner = .{
            .prog = prog,
            .pos_loc = gl.glGetAttribLocation(prog, "pos"),
            .color_loc = gl.glGetUniformLocation(prog, "color"),
            .quad_pos_loc = gl.glGetUniformLocation(prog, "quadPos"),
            .size_loc = gl.glGetUniformLocation(prog, "size"),
            .resolution_loc = gl.glGetUniformLocation(prog, "resolution"),
            .time_loc = gl.glGetUniformLocation(prog, "time"),
        };
    }

    {
        const vs = glCompileShader(gl.GL_VERTEX_SHADER, glass_vert_src);
        const fs = glCompileShader(gl.GL_FRAGMENT_SHADER, glass_blob_frag_src);
        const prog = glLinkProgram(vs, fs);
        out.glass_blob_prog = .{
            .prog = prog,
            .pos_loc = gl.glGetAttribLocation(prog, "pos"),
            .scene_loc = gl.glGetUniformLocation(prog, "scene"),
            .resolution_loc = gl.glGetUniformLocation(prog, "resolution"),
            .centers_loc = gl.glGetUniformLocation(prog, "centers[0]"),
            .scales_loc = gl.glGetUniformLocation(prog, "scales[0]"),
            .widths_loc = gl.glGetUniformLocation(prog, "widths[0]"),
            .heights_loc = gl.glGetUniformLocation(prog, "heights[0]"),
            .radius_loc = gl.glGetUniformLocation(prog, "radius"),
            .morph_k_loc = gl.glGetUniformLocation(prog, "morphK"),
            .open_state_loc = gl.glGetUniformLocation(prog, "openState"),
            .mask_center_loc = gl.glGetUniformLocation(prog, "maskCenter"),
            .mask_half_ex_loc = gl.glGetUniformLocation(prog, "maskHalfEx"),
            .mask_half_ey_loc = gl.glGetUniformLocation(prog, "maskHalfEy"),
            .mask_radius_loc = gl.glGetUniformLocation(prog, "maskRadius"),
        };
    }
}

fn loadFont(allocator: std.mem.Allocator, json_bytes: []const u8, atlas_tex: c_uint) !Font {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    const root = parsed.value;
    const atlas = root.object.get("atlas").?.object;

    var font = Font{
        .atlas_tex = atlas_tex,
        .glyphs = [_]?Glyph{null} ** 256,
        .px_range = @floatFromInt(atlas.get("distanceRange").?.integer),
    };

    const aw: f32 = @floatFromInt(atlas.get("width").?.integer);
    const ah: f32 = @floatFromInt(atlas.get("height").?.integer);

    for (root.object.get("glyphs").?.array.items) |g| {
        const code = g.object.get("unicode").?.integer;
        if (code < 0 or code > 255) continue;

        const plane_val = g.object.get("planeBounds");
        if (plane_val == null) continue;

        const atlas_val = g.object.get("atlasBounds");
        if (atlas_val == null) continue;

        const plane = plane_val.?.object;
        const atlasb = atlas_val.?.object;

        const left: f32 = @floatCast(atlasb.get("left").?.float);
        const right: f32 = @floatCast(atlasb.get("right").?.float);
        const bottom: f32 = @floatCast(atlasb.get("bottom").?.float);
        const top: f32 = @floatCast(atlasb.get("top").?.float);

        const left_p: f32 = @floatCast(plane.get("left").?.float);
        const right_p: f32 = @floatCast(plane.get("right").?.float);
        const bottom_p: f32 = @floatCast(plane.get("bottom").?.float);
        const top_p: f32 = @floatCast(plane.get("top").?.float);

        font.glyphs[@intCast(code)] = Glyph{
            .w = right_p - left_p,
            .h = top_p - bottom_p,
            .x_off = left_p,
            .y_off = bottom_p,
            .advance = @floatCast(g.object.get("advance").?.float),
            .u0 = left / aw,
            .u1 = right / aw,
            .v0 = 1.0 - (top / ah),
            .v1 = 1.0 - (bottom / ah),
        };
    }

    return font;
}

fn loadIconFromPng(png: []const u8) Icon {
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;
    const pixels = c.stbi_load_from_memory(png.ptr, @intCast(png.len), &w, &h, &comp, 4) orelse @panic("bad icon png");
    defer c.stbi_image_free(pixels);
    var tex: c_uint = 0;
    gl.glGenTextures(1, &tex);
    gl.glBindTexture(gl.GL_TEXTURE_2D, tex);
    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, w, h, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, pixels);
    gl.glGenerateMipmap(gl.GL_TEXTURE_2D);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR_MIPMAP_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
    return Icon{ .tex = tex, .w = @intCast(w), .h = @intCast(h) };
}

fn loadTextureFromPng(png: []const u8) c_uint {
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;

    const pixels = c.stbi_load_from_memory(png.ptr, @intCast(png.len), &w, &h, &comp, 4) orelse @panic("no png");
    defer c.stbi_image_free(pixels);

    var tex: c_uint = 0;
    gl.glGenTextures(1, &tex);
    gl.glBindTexture(gl.GL_TEXTURE_2D, tex);

    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, w, h, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, pixels);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);

    return tex;
}

pub var initialized = false;

pub var bg_path: ?[]const u8 = null;
pub var bg_gl_tex: c_uint = 0;
pub var bg_gl_loaded: bool = false;

pub fn renderBackground(output: *WinglessOutput, screen_w: f32, screen_h: f32) void {
    if (!initialized) return;
    rendering.renderBackground(output, screen_w, screen_h);
}

pub fn drawWindowSurface(output: *WinglessOutput, tex: *c.wlr_texture, sx: f32, sy: f32, sw: f32, sh: f32, clip_x: f32, clip_y: f32, clip_w: f32, clip_h: f32, screen_w: f32, screen_h: f32, with_decorations: bool, is_focused: bool) void {
    rendering.drawWindowSurface(output, tex, sx, sy, sw, sh, clip_x, clip_y, clip_w, clip_h, screen_w, screen_h, with_decorations, is_focused);
}

const glass_proto = @import("protocols/glass.zig");
pub fn drawWindowGlassRegions(output: *WinglessOutput, regions: []*glass_proto.BlurRegion, sx: f32, sy: f32, screen_w: f32, screen_h: f32) void {
    rendering.drawWindowGlassRegions(output, regions, sx, sy, screen_w, screen_h);
}

pub fn initUI(allocator: std.mem.Allocator) !void {
    const font_json = @embedFile("assets/font-poppins.json");
    const font_png = @embedFile("assets/font-poppins.png");
    const display_font_json = @embedFile("assets/font-calsans.json");
    const display_font_png = @embedFile("assets/font-calsans.png");

    icon_cache = std.StringHashMap(?Icon).init(allocator);

    const atlas_tex = loadTextureFromPng(font_png);
    glass_font = try loadFont(allocator, font_json, atlas_tex);
    const display_atlas_tex = loadTextureFromPng(display_font_png);
    display_font = try loadFont(allocator, display_font_json, display_atlas_tex);

    volume_slider.init();

    {
        var tex: c_uint = 0;
        gl.glGenTextures(1, &tex);
        gl.glBindTexture(gl.GL_TEXTURE_2D, tex);
        const px = [_]u8{ 0, 0, 0, 0 };
        gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, 1, 1, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, &px);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
        default_icon = Icon{ .tex = tex, .w = 1, .h = 1 };
    }

    try beacon.initCommands(allocator);
    _ = std.Thread.spawn(.{}, preloadThread, .{}) catch |err| std.log.warn("preload thread failed: {}", .{err});

    const min_mem = zclay.minMemorySize();
    clay_mem = try allocator.alloc(u8, min_mem);
    const arena = zclay.createArenaWithCapacityAndMemory(clay_mem);
    _ = zclay.initialize(arena, .{ .w = 1920, .h = 1080 }, .{});
    zclay.setMeasureTextFunction(void, {}, measureText);
}

fn preloadThread() void {
    const alloc = std.heap.page_allocator;
    buildIconIndex(alloc);
    icon_index_ready.store(true, .release);
    var seen = std.StringHashMap(void).init(alloc);
    defer seen.deinit();
    for (beacon.beacon_commands) |cmd| {
        const name = cmd.icon orelse continue;
        if (seen.contains(name)) continue;
        seen.put(alloc.dupe(u8, name) catch continue, {}) catch continue;
        const path = (resolveIconPath(alloc, name) catch continue) orelse continue;
        defer alloc.free(path);
        const png: []u8 = if (std.mem.endsWith(u8, path, ".svg")) blk: {
            break :blk svgToPng(alloc, path, name, 0.0) orelse continue;
        } else blk: {
            const file = std.fs.openFileAbsolute(path, .{}) catch continue;
            defer file.close();
            break :blk file.readToEndAlloc(alloc, 256 * 1024) catch continue;
        };
        defer alloc.free(png);
        var w: c_int = 0;
        var h: c_int = 0;
        var comp: c_int = 0;
        const pixels = c.stbi_load_from_memory(png.ptr, @intCast(png.len), &w, &h, &comp, 4) orelse continue;
        const name_copy = alloc.dupe(u8, name) catch { c.stbi_image_free(pixels); continue; };
        pending_mutex.lock();
        pending_icons.append(alloc, .{ .name = name_copy, .pixels = pixels, .w = w, .h = h }) catch {
            c.stbi_image_free(pixels);
            alloc.free(name_copy);
        };
        pending_mutex.unlock();
    }
}

var default_icon_set: bool = false;

fn svgToPng(allocator: std.mem.Allocator, svg_path: []const u8, icon_name: []const u8, stroke: f32) ?[]u8 {
    const is_symbolic = std.mem.endsWith(u8, icon_name, "-symbolic") or
        std.mem.indexOf(u8, svg_path, "symbolic") != null;
    if (is_symbolic) {
        const css_path = std.fmt.allocPrint(allocator, "/tmp/wingless-symbolic-s{d}.css", .{stroke}) catch return null;
        defer allocator.free(css_path);
        const f = std.fs.createFileAbsolute(css_path, .{}) catch return null;
        if (stroke > 0.0) {
            const css = std.fmt.allocPrint(allocator, "* {{ fill: white !important; color: white !important; stroke: white; stroke-width: {d}px; }}", .{stroke}) catch {
                f.close();
                return null;
            };
            defer allocator.free(css);
            f.writeAll(css) catch {};
        } else {
            f.writeAll("* { fill: white !important; color: white !important; }") catch {};
        }
        f.close();
        const argv = &[_][]const u8{ "rsvg-convert", "-w", "512", "-h", "512", "--format", "png", "--stylesheet", css_path, svg_path };
        const result = std.process.Child.run(.{ .allocator = allocator, .argv = argv }) catch return null;
        allocator.free(result.stderr);
        return result.stdout;
    }
    const argv = &[_][]const u8{ "rsvg-convert", "-w", "512", "-h", "512", "--format", "png", svg_path };
    const result = std.process.Child.run(.{ .allocator = allocator, .argv = argv }) catch return null;
    allocator.free(result.stderr);
    return result.stdout;
}

pub fn flushPendingIcons() void {
    if (!default_icon_set and icon_index_ready.load(.acquire)) {
        if (getIcon(std.heap.page_allocator, "application-x-executable-symbolic", 0.0)) |ic| {
            default_icon = ic;
        }
        default_icon_set = true;
    }
    pending_mutex.lock();
    const to_flush = pending_icons;
    pending_icons = .empty;
    pending_mutex.unlock();
    for (to_flush.items) |item| {
        defer std.heap.page_allocator.free(item.name);
        defer c.stbi_image_free(item.pixels);
        if (icon_cache.contains(item.name)) continue;
        var tex: c_uint = 0;
        gl.glGenTextures(1, &tex);
        gl.glBindTexture(gl.GL_TEXTURE_2D, tex);
        gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, item.w, item.h, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, item.pixels);
        gl.glGenerateMipmap(gl.GL_TEXTURE_2D);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR_MIPMAP_LINEAR);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
        const icon = Icon{ .tex = tex, .w = @intCast(item.w), .h = @intCast(item.h) };
        const key = std.heap.page_allocator.dupe(u8, item.name) catch continue;
        icon_cache.put(key, @as(?Icon, icon)) catch std.heap.page_allocator.free(key);
    }
}

fn resolveIconPath(allocator: std.mem.Allocator, icon: []const u8) !?[]const u8 {
    if (std.fs.path.isAbsolute(icon)) {
        if (std.fs.openFileAbsolute(icon, .{}) catch null != null) return try allocator.dupe(u8, icon);
        return null;
    }
    if (!icon_index_ready.load(.acquire)) return null;
    if (icon_path_index.get(icon)) |path| return try allocator.dupe(u8, path);
    return null;
}

fn iconPathPriority(path: []const u8) u8 {
    if (std.mem.indexOf(u8, path, "scalable") != null) return 10;
    if (std.mem.indexOf(u8, path, "256") != null) return 8;
    if (std.mem.indexOf(u8, path, "128") != null) return 7;
    if (std.mem.indexOf(u8, path, "96") != null) return 6;
    if (std.mem.indexOf(u8, path, "64") != null) return 5;
    if (std.mem.indexOf(u8, path, "48") != null) return 4;
    if (std.mem.indexOf(u8, path, "32") != null) return 3;
    if (std.mem.indexOf(u8, path, "24") != null) return 2;
    if (std.mem.indexOf(u8, path, "16") != null) return 1;
    return 4;
}

fn indexIconDir(allocator: std.mem.Allocator, base: []const u8, fallback_only: bool) void {
    var dir = std.fs.openDirAbsolute(base, .{ .iterate = true }) catch return;
    defer dir.close();
    var walker = dir.walk(allocator) catch return;
    defer walker.deinit();
    while (walker.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.basename);
        const is_png = std.mem.eql(u8, ext, ".png");
        const is_svg = std.mem.eql(u8, ext, ".svg");
        if (!is_png and !is_svg) continue;
        const icon_name = entry.basename[0 .. entry.basename.len - ext.len];
        const full = std.fs.path.join(allocator, &.{ base, entry.path }) catch continue;
        if (icon_path_index.getPtr(icon_name)) |existing| {
            if (fallback_only) {
                allocator.free(full);
                continue;
            }
            const new_prio = iconPathPriority(full);
            const old_prio = iconPathPriority(existing.*);
            const upgrade = new_prio > old_prio or
                (new_prio == old_prio and is_png and std.mem.endsWith(u8, existing.*, ".svg"));
            if (upgrade) {
                existing.* = full;
            } else {
                allocator.free(full);
            }
            continue;
        }
        const key = allocator.dupe(u8, icon_name) catch { allocator.free(full); continue; };
        icon_path_index.put(key, full) catch { allocator.free(full); allocator.free(key); };
    }
}

fn buildIconIndex(allocator: std.mem.Allocator) void {
    icon_path_index = std.StringHashMap([]const u8).init(allocator);
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch "";
    defer if (home.len > 0) allocator.free(home);
    const whitesur_themes = [_][]const u8{ "WhiteSur-dark", "WhiteSur" };
    const fallback_themes = [_][]const u8{"hicolor"};
    const user_bases = if (home.len > 0) [_][]const u8{
        ".local/share/icons",
        ".icons",
        ".local/share/flatpak/exports/share/icons",
    } else [_][]const u8{ "", "", "" };
    const sys_dirs = [_][]const u8{
        "/usr/share/icons",
        "/var/lib/flatpak/exports/share/icons",
        "/usr/local/share/icons",
    };

    if (home.len > 0) {
        for (user_bases) |ub| {
            if (ub.len == 0) continue;
            for (whitesur_themes) |t| {
                const d = std.fs.path.join(allocator, &.{ home, ub, t }) catch continue;
                defer allocator.free(d);
                indexIconDir(allocator, d, false);
            }
        }
    }
    for (sys_dirs) |sd| {
        for (whitesur_themes) |t| {
            const d = std.fs.path.join(allocator, &.{ sd, t }) catch continue;
            defer allocator.free(d);
            indexIconDir(allocator, d, false);
        }
    }

    if (home.len > 0) {
        for (user_bases) |ub| {
            if (ub.len == 0) continue;
            for (fallback_themes) |t| {
                const d = std.fs.path.join(allocator, &.{ home, ub, t }) catch continue;
                defer allocator.free(d);
                indexIconDir(allocator, d, true);
            }
            const flat = std.fs.path.join(allocator, &.{ home, ub }) catch continue;
            defer allocator.free(flat);
            indexIconDir(allocator, flat, true);
        }
    }
    for (sys_dirs) |sd| {
        for (fallback_themes) |t| {
            const d = std.fs.path.join(allocator, &.{ sd, t }) catch continue;
            defer allocator.free(d);
            indexIconDir(allocator, d, true);
        }
        indexIconDir(allocator, sd, true);
    }
    indexIconDir(allocator, "/usr/share/pixmaps", true);
}

fn debugFill() void {
    zclay.UI()(.{
        .id = .ID("DebugFill"),
        .layout = .{
            .sizing = .{ .w = .grow, .h = .grow },
        },
        .custom = .{ .custom_data = mkRect(0.0, 1.0) },
    })({});
}

pub fn renderUI(server: *WinglessServer, output: *WinglessOutput, w: c_int, h: c_int, is_cursor_output: bool) !void {
    if (!initialized) {
        try initUI(std.heap.page_allocator);
        initialized = true;
    }

    if (is_cursor_output) flushPendingIcons();

    if (output.gl_vbo == 0) gl.glGenBuffers(1, &output.gl_vbo);
    if (output.gl_vao == 0) gl.glGenBuffers(1, &output.gl_vao);

    ensurePrograms(output);
    gl.glViewport(0, 0, w, h);

    screen_width = @floatFromInt(w);
    screen_height = @floatFromInt(h);
    ui_scale = output.output.scale;
    if (output.output.current_mode != null) {
        const hz: u32 = @intCast(@divTrunc(output.output.current_mode.*.refresh, 1000));
        if (hz > 0) output_refresh_hz = hz;
    }

    if (is_cursor_output) {
        const dt = @min(getDeltaSeconds(), 1.0 / 30.0);
        beacon.tick(dt);
        menu.tick(dt);
        volume_slider.tick(dt);
        screenshot.tick(dt);
    }

    gl.glDisable(c.GL_SCISSOR_TEST);
    gl.glDisable(c.GL_DEPTH_TEST);
    gl.glDisable(c.GL_CULL_FACE);
    gl.glEnable(c.GL_BLEND);
    gl.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

    const scene_tex = c.wlr_texture_from_buffer(server.renderer, output.scene_buffer.?);
    if (scene_tex == null) @panic("no tex");
    defer c.wlr_texture_destroy(scene_tex);

    if (is_cursor_output) {
        const focusables = if (server.focused_toplevel != null and menu.isActive())
            server.focused_toplevel.?.linkedToList(server.allocator) catch null
        else
            null;
        defer if (focusables) |f| server.allocator.free(f);
        const focused_toplevel = if (menu.isActive()) server.focused_toplevel else null;

        screenshot.renderBackground(w, h);

        cursor_screen_width = screen_width;
        cursor_screen_height = screen_height;

        custom_pool_idx = 0;
        zclay.setLayoutDimensions(.{ .w = screen_width, .h = screen_height });
        zclay.beginLayout();

        zclay.UI()(.{
            .id = .ID("Screen"),
            .layout = .{
                .sizing = .grow,
                .child_alignment = .{ .x = .center, .y = .center },
            },
        })({
            beacon.layout(server.allocator);
            menu.layout(focused_toplevel, focusables);
            menu.layoutPowerCluster();
            volume_slider.layout();
            screenshot.layoutToolbar();
        });

        rendering.render(.{
            .output = output,
            .screen_width = screen_width,
            .screen_height = screen_height,
            .scene_tex = @ptrCast(scene_tex.?),
            .font = &glass_font,
            .display_font = &display_font,
        });

        screenshot.onFrame(w, h);
        recording.onFrame(w, h);
    }
}
