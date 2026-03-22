const std = @import("std");
pub const zclay = @import("zclay");

const config = @import("config.zig");
const rendering = @import("ui/rendering.zig");
pub const beacon = @import("ui/beacon.zig");
pub const menu = @import("ui/menu.zig");
pub const volume_slider = @import("ui/volume_slider.zig");

const main = @import("main.zig");
const WinglessOutput = main.WinglessOutput;
const WinglessServer = main.WinglessServer;
const Focusable = main.Focusable;

const c = @import("c.zig").c;
const gl = @import("c.zig").gl;

const glass_vert_src = @embedFile("shaders/glass.vert");
const glass_frag_src = @embedFile("shaders/glass.frag");
const text_frag_src = @embedFile("shaders/glass_text.frag");

pub const AnimState = struct { elapsed: u64 };

var last_ns: i128 = 0;

pub var beacon_open = false;
pub var menu_open = false;
pub var pointer_down: bool = false;
pub var screen_height: f32 = 0;

var glass_font: Font = undefined;
var icon_cache: std.StringHashMap(Icon) = undefined;

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
    shadow_intensity_loc: c_int,
    roundness: c_int,
    fill_amount_loc: c_int,
    fill_direction_loc: c_int,
    refraction_band_loc: c_int,
    brightness_loc: c_int,
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
};

pub const FillProgram = struct {
    prog: c_uint,
    pos_loc: c_int,
    color_loc: c_int,
};

pub const ShadowProgram = struct {
    prog: c_uint,
    pos_loc: c_int,
    quad_pos_loc: c_int,
    size_loc: c_int,
    roundness_loc: c_int,
    intensity_loc: c_int,
};

pub const BlurProgram = struct {
    prog: c_uint,
    pos_loc: c_int,
    scene_loc: c_int,
    intensity_loc: c_int,
    direction_loc: c_int,
};

pub const ImageProgram = struct {
    prog: c_uint,
    pos_loc: c_int,
    uv_loc: c_int,
    image_loc: c_int,
    size_loc: c_int,
    quad_pos_loc: c_int,
    roundness_loc: c_int,
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
    glass: struct { roundness: f32, animated: bool = false, anim_scale: f32 = 1.0, fill_amount: f32 = 0.0, fill_dir: i32 = 0, refraction_band: f32 = 20.0, brightness: f32 = 0.05 },
    window_surface: struct { focusable: *Focusable, scale: f32, anim_scale: f32 = 1.0 },
    divider: struct { alpha: f32 },
    icon: struct { icon: ?Icon },
    shadow: struct { roundness: f32, animated: bool = false, anim_scale: f32 = 1.0, intensity: f32 },
};

pub const RenderContext = struct {
    output: *WinglessOutput,
    screen_width: f32,
    screen_height: f32,
    scene_tex: *c.wlr_texture,
    font: *const Font,
};

var custom_pool: [256]CustomData = undefined;
var custom_pool_idx: usize = 0;

pub fn mkGlass(roundness: f32) *anyopaque {
    const d = &custom_pool[custom_pool_idx];
    custom_pool_idx += 1;
    d.* = .{ .glass = .{ .roundness = roundness } };
    return d;
}

pub fn mkAnimatedGlass(roundness: f32, anim_scale: f32, refraction_band: f32, brightness: f32) *anyopaque {
    const d = &custom_pool[custom_pool_idx];
    custom_pool_idx += 1;
    d.* = .{ .glass = .{ .roundness = roundness, .animated = true, .anim_scale = anim_scale, .refraction_band = refraction_band, .brightness = brightness } };
    return d;
}

pub fn mkGlassFill(roundness: f32, fill_amount: f32, fill_dir: FillDir) *anyopaque {
    const d = &custom_pool[custom_pool_idx];
    custom_pool_idx += 1;
    d.* = .{ .glass = .{ .roundness = roundness, .fill_amount = fill_amount, .fill_dir = @intFromEnum(fill_dir) } };
    return d;
}

pub fn mkAnimatedGlassFill(roundness: f32, anim_scale: f32, fill_amount: f32, fill_dir: FillDir, refraction_band: f32, brightness: f32) *anyopaque {
    const d = &custom_pool[custom_pool_idx];
    custom_pool_idx += 1;
    d.* = .{ .glass = .{ .roundness = roundness, .animated = true, .anim_scale = anim_scale, .fill_amount = fill_amount, .fill_dir = @intFromEnum(fill_dir), .refraction_band = refraction_band, .brightness = brightness } };
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

pub fn mkDivider(alpha: f32) *anyopaque {
    const d = &custom_pool[custom_pool_idx];
    custom_pool_idx += 1;
    d.* = .{ .divider = .{ .alpha = alpha } };
    return d;
}

pub fn mkIcon(allocator: std.mem.Allocator, cmd: *const beacon.BeaconCommand) *anyopaque {
    const d = &custom_pool[custom_pool_idx];
    custom_pool_idx += 1;
    const resolved = if (cmd.icon) |name| getIcon(allocator, name) else null;
    d.* = .{ .icon = .{ .icon = resolved } };
    return d;
}

pub fn mkIconByName(allocator: std.mem.Allocator, name: []const u8) *anyopaque {
    const d = &custom_pool[custom_pool_idx];
    custom_pool_idx += 1;
    d.* = .{ .icon = .{ .icon = getIcon(allocator, name) } };
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
    if (beacon_open == true) beacon.beacon_buffer.clearRetainingCapacity();
    if (menu_open == false) beacon_open = !beacon_open;
}

pub fn ensurePrograms(out: *WinglessOutput) void {
    if (out.glass_background != null) return;

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
            .shadow_intensity_loc = gl.glGetUniformLocation(prog, "shadowIntensity"),
            .roundness = gl.glGetUniformLocation(prog, "roundness"),
            .fill_amount_loc = gl.glGetUniformLocation(prog, "fillAmount"),
            .fill_direction_loc = gl.glGetUniformLocation(prog, "fillDirection"),
            .refraction_band_loc = gl.glGetUniformLocation(prog, "refractionBand"),
            .brightness_loc = gl.glGetUniformLocation(prog, "brightness"),
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
        const fs = glCompileShader(gl.GL_FRAGMENT_SHADER, @embedFile("shaders/shadow.frag"));
        const prog = glLinkProgram(vs, fs);
        out.shadow = .{
            .prog = prog,
            .pos_loc = gl.glGetAttribLocation(prog, "pos"),
            .quad_pos_loc = gl.glGetUniformLocation(prog, "quadPos"),
            .size_loc = gl.glGetUniformLocation(prog, "size"),
            .roundness_loc = gl.glGetUniformLocation(prog, "roundness"),
            .intensity_loc = gl.glGetUniformLocation(prog, "intensity"),
        };
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
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
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

const bundled_power_png = @embedFile("assets/power.png");
const bundled_restart_png = @embedFile("assets/restart.png");

pub fn initUI(allocator: std.mem.Allocator) !void {
    const font_json = @embedFile("assets/font.json");
    const font_png = @embedFile("assets/font.png");

    icon_cache = std.StringHashMap(Icon).init(allocator);

    const atlas_tex = loadTextureFromPng(font_png);
    glass_font = try loadFont(allocator, font_json, atlas_tex);

    try icon_cache.put("_power", loadIconFromPng(bundled_power_png));
    try icon_cache.put("_restart", loadIconFromPng(bundled_restart_png));

    try beacon.initCommands(allocator);

    const min_mem = zclay.minMemorySize();
    clay_mem = try allocator.alloc(u8, min_mem);
    const arena = zclay.createArenaWithCapacityAndMemory(clay_mem);
    _ = zclay.initialize(arena, .{ .w = 1920, .h = 1080 }, .{});
    zclay.setMeasureTextFunction(void, {}, measureText);
}

fn resolveIconPath(allocator: std.mem.Allocator, icon: []const u8) !?[]const u8 {
    if (std.fs.path.isAbsolute(icon)) {
        if (std.fs.openFileAbsolute(icon, .{}) catch null != null) return try allocator.dupe(u8, icon);
        return null;
    }

    const themes = [_][]const u8{ "Adwaita", "AdwaitaLegacy", "hicolor" };
    const sizes = [_][]const u8{ "128x128", "64x64", "48x48", "32x32", "scalable" };
    const subdirs = [_][]const u8{ "apps", "legacy", "actions", "status" };

    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    const dirs = [_][]const u8{
        try std.fs.path.join(allocator, &.{ home, ".local/share/icons" }),
        try std.fs.path.join(allocator, &.{ home, ".icons" }),
        "/usr/share/icons",
        "/usr/share/pixmaps",
    };
    defer allocator.free(dirs[0]);
    defer allocator.free(dirs[1]);

    for (dirs) |dir| {
        for (themes) |theme| {
            for (sizes) |size| {
                for (subdirs) |sub| {
                    const path = try std.fs.path.join(
                        allocator,
                        &.{ dir, theme, size, sub, try std.mem.concat(allocator, u8, &.{ icon, ".png" }) },
                    );
                    if (std.fs.openFileAbsolute(path, .{}) catch null != null) return path;
                    allocator.free(path);
                }
            }
        }
    }

    for (dirs) |base| {
        const path = try std.fs.path.join(allocator, &.{
            base,
            try std.mem.concat(allocator, u8, &.{ icon, ".png" }),
        });
        if (std.fs.openFileAbsolute(path, .{}) catch null != null) return path;
        allocator.free(path);
    }

    return null;
}

fn getIcon(allocator: std.mem.Allocator, icon_name: []const u8) ?Icon {
    if (icon_cache.get(icon_name)) |cached| return cached;
    const path = (resolveIconPath(allocator, icon_name) catch return null) orelse return null;
    defer allocator.free(path);

    if (icon_cache.get(path)) |cached| return cached;

    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const png = file.readToEndAlloc(allocator, 256 * 1024) catch return null;
    defer allocator.free(png);

    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;

    const pixels = c.stbi_load_from_memory(png.ptr, @intCast(png.len), &w, &h, &comp, 4) orelse return null;
    defer c.stbi_image_free(pixels);

    var tex: c_uint = 0;
    gl.glGenTextures(1, &tex);
    gl.glBindTexture(gl.GL_TEXTURE_2D, tex);
    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, w, h, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, pixels);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);

    const icon = Icon{ .tex = tex, .w = @intCast(w), .h = @intCast(h) };

    const key = allocator.dupe(u8, path) catch return icon;
    icon_cache.put(key, icon) catch {};
    return icon;
}

fn debugFill() void {
    zclay.UI()(.{
        .id = .ID("DebugFill"),
        .layout = .{
            .sizing = .{ .w = .grow, .h = .grow },
        },
        .custom = .{ .custom_data = mkDivider(1.0) },
    })({});
}

pub fn renderUI(server: *WinglessServer, output: *WinglessOutput, w: c_int, h: c_int) !void {
    if (!initialized) {
        try initUI(std.heap.page_allocator);
        initialized = true;
    }

    const dt = getDeltaSeconds();

    if (output.gl_vbo == 0) gl.glGenBuffers(1, &output.gl_vbo);
    if (output.gl_vao == 0) gl.glGenBuffers(1, &output.gl_vao);

    // TODO: move this into some nicer init function on output detect
    ensurePrograms(output);
    gl.glViewport(0, 0, w, h);

    const screen_width: f32 = @floatFromInt(w);
    screen_height = @floatFromInt(h);

    // animate state
    beacon.tick(dt);
    menu.tick(dt);
    volume_slider.tick(dt);

    // gl state
    gl.glDisable(c.GL_SCISSOR_TEST);
    gl.glDisable(c.GL_DEPTH_TEST);
    gl.glDisable(c.GL_CULL_FACE);
    gl.glEnable(c.GL_BLEND);
    gl.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

    const scene_tex = c.wlr_texture_from_buffer(server.renderer, output.scene_buffer.?);
    if (scene_tex == null) @panic("no tex");
    defer c.wlr_texture_destroy(scene_tex);

    // these are for the menu
    // collect focusables before the clay layout block
    // the layout blocks, so any fallible work must happen here.
    const focusables = if (server.focused_toplevel != null and menu.isActive())
        server.focused_toplevel.?.linkedToList(server.allocator) catch null
    else
        null;

    // layout
    custom_pool_idx = 0;
    zclay.setLayoutDimensions(.{ .w = screen_width, .h = screen_height });
    zclay.beginLayout();

    // root container
    zclay.UI()(.{
        .id = .ID("Screen"),
        .layout = .{
            .sizing = .grow,
            .child_alignment = .{ .x = .center, .y = .center },
        },
    })({
        beacon.layout(server.allocator);
        menu.layout(focusables);
        volume_slider.layout();
    });

    rendering.render(.{
        .output = output,
        .screen_width = screen_width,
        .screen_height = screen_height,
        .scene_tex = @ptrCast(scene_tex.?),
        .font = &glass_font,
    });
}
