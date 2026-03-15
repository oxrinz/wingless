const std = @import("std");

const zclay = @import("zclay");

const config = @import("config.zig");

const main = @import("main.zig");
const WinglessOutput = main.WinglessOutput;
const WinglessServer = main.WinglessServer;

const c = @import("c.zig").c;
const gl = @import("c.zig").gl;

const ui_vert_src = @embedFile("shaders/ui.vert");
const ui_frag_src = @embedFile("shaders/ui.frag");
const text_frag_src = @embedFile("shaders/glass_text.frag");

pub const AnimState = struct { elapsed: u64 };

var last_ns: i128 = 0;

pub var beacon_open = false;
pub var menu_open = false;

var beacon_state: f32 = 0;
var beacon_suggestion_state: f32 = 0;
var beacon_line_state: f32 = 0;
var menu_state: f32 = 0;

pub var beacon_buffer: std.ArrayList(u8) = .empty;
pub var beacon_suggestions: []*BeaconCommand = &.{};

var glass_font: Font = undefined;
var icon_cache: std.StringHashMap(Icon) = undefined;

const Icon = struct {
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
};

pub const GlassTextProgram = struct {
    prog: c_uint,
    pos_loc: c_int,
    uv_loc: c_int,
    atlas_loc: c_int,
    px_range_loc: c_int,
    thickness_loc: c_int,
};

pub const FillProgram = struct {
    prog: c_uint,
    pos_loc: c_int,
    color_loc: c_int,
};

pub const ImageProgram = struct {
    prog: c_uint,
    pos_loc: c_int,
    uv_loc: c_int,
    image_loc: c_int,
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

const Font = struct {
    atlas_tex: c_uint,
    glyphs: [256]?Glyph,
    px_range: f32,
};

pub const BeaconCommand = struct {
    name: []const u8,
    function: config.WinglessFunction,
    args: ?[]*anyopaque = null,
    icon: ?[]const u8,
};

pub var beacon_commands: []*BeaconCommand = &.{};

const CustomTag = enum { glass, glass_thumb, divider, icon };

const CustomData = struct {
    tag: CustomTag,
    beacon_command: ?*const BeaconCommand = null,
    thumb_index: usize = 0,
};

var custom_pool: [128]CustomData = undefined;
var custom_pool_idx: usize = 0;

fn mkCustom(tag: CustomTag, bc: ?*const BeaconCommand, idx: usize) *anyopaque {
    const d = &custom_pool[custom_pool_idx];
    custom_pool_idx += 1;
    d.* = .{ .tag = tag, .beacon_command = bc, .thumb_index = idx };
    return d;
}

var clay_mem: []u8 = &.{};

fn measureText(text: []const u8, _: *zclay.TextElementConfig, _: void) zclay.Dimensions {
    var w: f32 = 0;
    for (text) |ch| {
        if (ch == ' ') {
            w += 12.0;
        } else if (glass_font.glyphs[ch]) |g| {
            w += g.advance * 32.0;
        }
    }
    return .{ .w = w, .h = 32.0 };
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

    var buf: [4048]u8 = undefined;
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

fn ensurePrograms(out: *WinglessOutput) void {
    if (out.glass_background != null) return;

    {
        const vs = glCompileShader(gl.GL_VERTEX_SHADER, ui_vert_src);
        const fs = glCompileShader(gl.GL_FRAGMENT_SHADER, ui_frag_src);
        const prog = glLinkProgram(vs, fs);
        out.glass_background = .{
            .prog = prog,
            .pos_loc = gl.glGetAttribLocation(prog, "pos"),
            .scene_loc = gl.glGetUniformLocation(prog, "scene"),
            .quad_pos_loc = gl.glGetUniformLocation(prog, "quadPos"),
            .size_loc = gl.glGetUniformLocation(prog, "size"),
            .shadow_intensity_loc = gl.glGetUniformLocation(prog, "shadowIntensity"),
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
            .px_range_loc = gl.glGetUniformLocation(prog, "pxRange"),
            .thickness_loc = gl.glGetUniformLocation(prog, "thickness"),
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
        const vs = glCompileShader(gl.GL_VERTEX_SHADER, @embedFile("shaders/image.vert"));
        const fs = glCompileShader(gl.GL_FRAGMENT_SHADER, @embedFile("shaders/image.frag"));
        const prog = glLinkProgram(vs, fs);
        out.image = .{
            .prog = prog,
            .pos_loc = gl.glGetAttribLocation(prog, "pos"),
            .uv_loc = gl.glGetAttribLocation(prog, "uv"),
            .image_loc = gl.glGetUniformLocation(prog, "image"),
        };
    }
}

fn drawGlassQuad(output: *WinglessOutput, x: f32, y: f32, w: f32, h: f32, screen_w: f32, screen_h: f32, scene_tex: *c.wlr_texture) void {
    var attribs: c.wlr_gles2_texture_attribs = undefined;
    c.wlr_gles2_texture_get_attribs(scene_tex, &attribs);

    gl.glUseProgram(output.glass_background.?.prog);

    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(attribs.target, attribs.tex);

    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);

    gl.glUniform1i(output.glass_background.?.scene_loc, 0);
    gl.glUniform2f(output.glass_background.?.quad_pos_loc, x, y);
    gl.glUniform2f(output.glass_background.?.size_loc, w, h);
    gl.glUniform1f(output.glass_background.?.shadow_intensity_loc, 0.01 * @min(0.5 * 100, @min(w, h)));

    drawQuad(output, x - 300, y - 300, w + 600, h + 600, screen_w, screen_h, output.glass_background.?.pos_loc);
}

fn drawQuad(output: *WinglessOutput, x: f32, y: f32, w: f32, h: f32, screen_w: f32, screen_h: f32, gl_pos_loc: c_int) void {
    const x0 = ndc_x(x, screen_w);
    const y0 = ndc_y(y, screen_h);
    const x1 = ndc_x(x + w, screen_w);
    const y1 = ndc_y(y + h, screen_h);

    const verts = [_]f32{
        x0, y0,
        x1, y0,
        x0, y1,
        x1, y0,
        x1, y1,
        x0, y1,
    };

    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, output.gl_vbo);
    gl.glBufferData(gl.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, gl.GL_STREAM_DRAW);

    gl.glEnableVertexAttribArray(@intCast(gl_pos_loc));
    gl.glVertexAttribPointer(@intCast(gl_pos_loc), 2, gl.GL_FLOAT, gl.GL_FALSE, 2 * @sizeOf(f32), @ptrFromInt(0));
    gl.glDrawArrays(gl.GL_TRIANGLES, 0, 6);
    gl.glDisableVertexAttribArray(@intCast(gl_pos_loc));
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, 0);
}

fn drawQuadWithUv(output: *WinglessOutput, x: f32, y: f32, w: f32, h: f32, screen_w: f32, screen_h: f32, gl_pos_loc: c_int, gl_uv_loc: c_int) void {
    const x0 = ndc_x(x, screen_w);
    const y0 = ndc_y(y, screen_h);
    const x1 = ndc_x(x + w, screen_w);
    const y1 = ndc_y(y + h, screen_h);

    const verts = [_]f32{
        x0, y0, 0, 1,
        x1, y0, 1, 1,
        x0, y1, 0, 0,
        x1, y0, 1, 1,
        x1, y1, 1, 0,
        x0, y1, 0, 0,
    };

    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, output.gl_vbo);
    gl.glBufferData(gl.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, gl.GL_STREAM_DRAW);

    const stride = 4 * @sizeOf(f32);
    gl.glEnableVertexAttribArray(@intCast(gl_pos_loc));
    gl.glVertexAttribPointer(@intCast(gl_pos_loc), 2, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(0));
    gl.glEnableVertexAttribArray(@intCast(gl_uv_loc));
    gl.glVertexAttribPointer(@intCast(gl_uv_loc), 2, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(2 * @sizeOf(f32)));
    gl.glDrawArrays(gl.GL_TRIANGLES, 0, 6);
    gl.glDisableVertexAttribArray(@intCast(gl_pos_loc));
    gl.glDisableVertexAttribArray(@intCast(gl_uv_loc));
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, 0);
}

fn drawGlassChar(output: *WinglessOutput, font: *const Font, ch: u8, x: f32, y: f32, screen_w: f32, screen_h: f32, thickness: f32) f32 {
    if (ch == ' ') return 12;
    const g = font.glyphs[ch] orelse return 0;

    gl.glUseProgram(output.glass_text.?.prog);

    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, font.atlas_tex);
    gl.glUniform1i(output.glass_text.?.atlas_loc, 0);
    gl.glUniform1f(output.glass_text.?.px_range_loc, font.px_range);
    gl.glUniform1f(output.glass_text.?.thickness_loc, thickness);

    const scale: f32 = 32.0;
    const gx = x + g.x_off;
    const gy = y + g.y_off * scale;

    const x0 = ndc_x(gx, screen_w);
    const y0 = ndc_y(gy, screen_h);
    const x1 = ndc_x(gx + g.w * scale, screen_w);
    const y1 = ndc_y(gy + g.h * scale, screen_h);

    const verts = [_]f32{
        x0, y0, g.u0, g.v1,
        x1, y0, g.u1, g.v1,
        x0, y1, g.u0, g.v0,
        x1, y0, g.u1, g.v1,
        x1, y1, g.u1, g.v0,
        x0, y1, g.u0, g.v0,
    };

    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, output.gl_vbo);
    gl.glBufferData(gl.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, gl.GL_STREAM_DRAW);

    const stride = 4 * @sizeOf(f32);
    gl.glEnableVertexAttribArray(@intCast(output.glass_text.?.pos_loc));
    gl.glVertexAttribPointer(@intCast(output.glass_text.?.pos_loc), 2, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(0));
    gl.glEnableVertexAttribArray(@intCast(output.glass_text.?.uv_loc));
    gl.glVertexAttribPointer(@intCast(output.glass_text.?.uv_loc), 2, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(2 * @sizeOf(f32)));
    gl.glDrawArrays(gl.GL_TRIANGLES, 0, 6);
    gl.glDisableVertexAttribArray(@intCast(output.glass_text.?.pos_loc));
    gl.glDisableVertexAttribArray(@intCast(output.glass_text.?.uv_loc));
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, 0);

    return glass_font.glyphs[ch].?.advance * scale;
}

fn drawGlassSentence(output: *WinglessOutput, font: *const Font, sentence: []const u8, x: f32, y: f32, screen_w: f32, screen_h: f32, thickness: f32) void {
    var real_x = x;
    for (sentence) |char| {
        real_x += drawGlassChar(output, font, char, real_x, y, screen_w, screen_h, thickness);
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

var initialized = false;

pub fn initUI(allocator: std.mem.Allocator) !void {
    const font_json = @embedFile("assets/font.json");
    const font_png = @embedFile("assets/font.png");

    icon_cache = std.StringHashMap(Icon).init(allocator);

    const atlas_tex = loadTextureFromPng(font_png);
    glass_font = try loadFont(allocator, font_json, atlas_tex);

    // beacon commands from WinglessFunction enum
    var command_array: std.ArrayList(*BeaconCommand) = .empty;
    for (std.enums.values(config.WinglessFunction)) |function| {
        const object = allocator.create(BeaconCommand) catch return;
        object.* = .{
            .name = try allocator.dupe(u8, @constCast(@tagName(function))),
            .args = null,
            .function = function,
            .icon = null,
        };
        command_array.append(std.heap.page_allocator, object) catch @panic("fuck");
    }

    // desktop apps
    const paths = [_][]const u8{ "/usr/share/applications", try std.fs.path.join(allocator, &.{
        try std.process.getEnvVarOwned(allocator, "HOME"),
        ".local/share/applications",
    }) };

    for (paths) |path| {
        if (path.len == 0) continue;
        var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch continue;
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |e| {
            if (e.kind != .file and !std.mem.endsWith(u8, e.name, ".desktop")) continue;

            const full = try std.fs.path.join(allocator, &.{ path, e.name });
            defer allocator.free(full);

            const file = try std.fs.openFileAbsolute(full, .{});
            defer file.close();

            const data = try file.readToEndAlloc(allocator, 64 * 1024);
            defer allocator.free(data);

            var in_group = false;
            var line_it = std.mem.splitScalar(u8, data, '\n');

            var name: ?[]const u8 = null;
            var exec: ?[]const u8 = null;
            var icon: ?[]const u8 = null;

            while (line_it.next()) |raw_line| {
                const line = std.mem.trim(u8, raw_line, " \t\r");
                if (line.len == 0 or line[0] == '#') continue;

                if (line[0] == '[') {
                    in_group = std.mem.eql(u8, line, "[Desktop Entry]");
                }

                if (!in_group) continue;

                const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
                const key = line[0..eq];
                const val = line[eq + 1 ..];

                if (std.mem.eql(u8, key, "Type")) {
                    // TODO: filter non-Application types
                } else if (std.mem.eql(u8, key, "Name")) {
                    name = try allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "Exec")) {
                    exec = try allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "Icon")) {
                    icon = try allocator.dupe(u8, val);
                }
            }

            if (name != null and exec != null) {
                exec = std.mem.trimRight(u8, exec.?, " %uUfF");

                const name_ptr = allocator.create([]const u8) catch @panic("out of memory");
                name_ptr.* = exec.?;

                const args = allocator.alloc(*anyopaque, 1) catch @panic("out of memory");
                args[0] = @ptrCast(name_ptr);

                const object = allocator.create(BeaconCommand) catch return;
                object.* = .{
                    .function = .launch_app,
                    .name = name.?,
                    .icon = icon,
                    .args = args,
                };
                command_array.append(std.heap.page_allocator, object) catch @panic("fuck");
            }
        }
    }

    beacon_commands = command_array.toOwnedSlice(std.heap.page_allocator) catch @panic("oh no");

    const min_mem = zclay.minMemorySize();
    clay_mem = try allocator.alloc(u8, min_mem);
    const arena = zclay.createArenaWithCapacityAndMemory(clay_mem);
    _ = zclay.initialize(arena, .{ .w = 1920, .h = 1080 }, .{});
    zclay.setMeasureTextFunction(void, {}, measureText);
}

fn normalizeString(buf: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (buf) |char| {
        if (char != ' ' and char != '-' and char != '_') {
            try out.append(allocator, std.ascii.toLower(char));
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn resolveIconPath(allocator: std.mem.Allocator, icon: []const u8) !?[]const u8 {
    if (std.fs.path.isAbsolute(icon)) {
        if (std.fs.openFileAbsolute(icon, .{}) catch null != null) return try allocator.dupe(u8, icon);
        return null;
    }

    const themes = [_][]const u8{ "Adwaita", "hicolor" };
    const sizes = [_][]const u8{ "128x128", "64x64", "48x48", "32x32", "scalable" };

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
                const path = try std.fs.path.join(
                    allocator,
                    &.{ dir, theme, size, "apps", try std.mem.concat(allocator, u8, &.{ icon, ".png" }) },
                );
                if (std.fs.openFileAbsolute(path, .{}) catch null != null) return path;
                allocator.free(path);
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

pub fn updateBeaconSuggestions(allocator: std.mem.Allocator) !void {
    const Match = struct {
        cmd: *BeaconCommand,
        score: isize,
    };

    var matches: std.ArrayList(Match) = .empty;
    defer matches.deinit(allocator);

    for (beacon_commands) |command| {
        const a = try normalizeString(command.name, allocator);
        const b = try normalizeString(beacon_buffer.items, allocator);

        const n = a.len;
        const m = b.len;

        var prev = try allocator.alloc(usize, m + 1);
        defer allocator.free(prev);
        var curr = try allocator.alloc(usize, m + 1);
        defer allocator.free(curr);

        for (0..m + 1) |j| prev[j] = j;

        for (1..n + 1) |i| {
            curr[0] = i;
            for (1..m + 1) |j| {
                const cost: usize = if (std.ascii.toLower(a[i - 1]) == std.ascii.toLower(b[j - 1])) 0 else 1;
                curr[j] = @min(@min(curr[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
            }
            std.mem.swap([]usize, &prev, &curr);
        }

        const dist = prev[m];
        var score: isize = @intCast(dist);

        if (std.mem.startsWith(u8, a, b)) score -= 5 else if (std.mem.indexOf(u8, a, b) != null) score -= 3;
        score += @intCast(a.len / 10);

        if (score <= 2) {
            try matches.append(allocator, .{ .cmd = @constCast(command), .score = score });
        }
    }

    const Less = struct {
        pub fn lessThan(_: void, a: Match, b: Match) bool {
            return a.score < b.score;
        }
    };

    std.sort.block(Match, matches.items, {}, Less.lessThan);

    var results = try allocator.alloc(*BeaconCommand, matches.items.len);
    for (matches.items, 0..) |m, i| results[i] = m.cmd;

    beacon_suggestions = results;
}

pub fn renderUI(server: *WinglessServer, output: *WinglessOutput, w: c_int, h: c_int) !void {
    if (!initialized) {
        try initUI(std.heap.page_allocator);
        initialized = true;
    }

    const dt = getDeltaSeconds();

    if (output.gl_vbo == 0) gl.glGenBuffers(1, &output.gl_vbo);
    if (output.gl_vao == 0) gl.glGenBuffers(1, &output.gl_vao);

    ensurePrograms(output);
    gl.glViewport(0, 0, w, h);

    const screen_width: f32 = @floatFromInt(w);
    const screen_height: f32 = @floatFromInt(h);

    // animate state
    beacon_state = lerp(beacon_state, if (beacon_open) 1.0 else 0.0, dt * 20.0);
    menu_state = lerp(menu_state, if (menu_open) 1.0 else 0.0, dt * 20.0);

    const sugg_target: f32 = if (beacon_buffer.items.len >= 2)
        switch (beacon_suggestions.len) {
            0, 1 => 0.4,
            2 => 0.7,
            else => 1.0,
        }
    else
        0.0;
    beacon_suggestion_state = lerp(beacon_suggestion_state, sugg_target, dt * 20.0);
    beacon_line_state = lerp(beacon_line_state, if (beacon_state > 0.1) 1.0 else 0.0, dt * 20.0);

    // gl state
    gl.glDisable(c.GL_SCISSOR_TEST);
    gl.glDisable(c.GL_DEPTH_TEST);
    gl.glDisable(c.GL_CULL_FACE);
    gl.glEnable(c.GL_BLEND);
    gl.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

    const scene_tex = c.wlr_texture_from_buffer(server.renderer, output.scene_buffer.?);
    if (scene_tex == null) @panic("no tex");
    defer c.wlr_texture_destroy(scene_tex);

    // collect focusables before the clay layout block
    // the layout blocks, so any fallible work must happen here.
    const focusables = if (server.focused_toplevel != null and menu_open)
        server.focused_toplevel.?.linkedToList(server.allocator) catch null
    else
        null;
    const n_focusables: usize = if (focusables) |f| f.len else 0;

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
        // beacon
        if (beacon_state > 0.01) {
            // background
            const bw = 800.0 * beacon_state;
            const bh = @min(bw, 80.0) + 100.0 * beacon_suggestion_state;

            zclay.UI()(.{
                .id = .ID("Beacon"),
                .layout = .{
                    .sizing = .{ .w = .fixed(bw), .h = .fixed(bh) },
                    .direction = .top_to_bottom,
                    .padding = .all(0),
                    .child_gap = 6,
                },
                .custom = .{ .custom_data = mkCustom(.glass, null, 0) },
            })({
                // suggestions
                if (beacon_suggestion_state > 0.01) {
                    const n_sugg = @min(beacon_suggestions.len, 3);

                    if (n_sugg > 0) {
                        for (0..n_sugg) |i| {
                            zclay.UI()(.{
                                .id = .IDI("SuggRow", @intCast(i)),
                                .layout = .{
                                    .sizing = .{ .w = .grow, .h = .fixed(50) },
                                    .child_alignment = .{ .x = .left, .y = .center },
                                    .child_gap = 14,
                                },
                            })({
                                // icon slot
                                if (beacon_suggestions[i].icon != null) {
                                    zclay.UI()(.{
                                        .id = .IDI("SuggIcon", @intCast(i)),
                                        .layout = .{
                                            .sizing = .{ .w = .fixed(42), .h = .fixed(42) },
                                        },
                                        .custom = .{ .custom_data = mkCustom(.icon, beacon_suggestions[i], i) },
                                    })({});
                                }
                                zclay.text(beacon_suggestions[i].name, .{
                                    .font_id = 0,
                                    .font_size = 26,
                                    .color = .{ 255, 255, 255, 255 },
                                });
                            });
                        }
                    } else {
                        zclay.text("Unknown command !", .{
                            .font_id = 0,
                            .font_size = 26,
                            .color = .{ 255, 255, 255, 255 },
                        });
                    }

                    // divider
                    zclay.UI()(.{
                        .id = .ID("BeaconDivider"),
                        .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(2) } },
                        .custom = .{ .custom_data = mkCustom(.divider, null, 0) },
                    })({});
                }

                // input text row
                zclay.UI()(.{
                    .id = .ID("BeaconInput"),
                    .layout = .{
                        .sizing = .{ .w = .grow, .h = .fixed(32) },
                        .child_alignment = .{ .y = .center },
                    },
                })({
                    zclay.text(beacon_buffer.items, .{
                        .font_id = 1,
                        .font_size = 26,
                        .color = .{ 255, 255, 255, 255 },
                    });
                });
            });
        }

        // menu thumbnails
        if (n_focusables > 0) {
            const scale: f32 = 0.2;
            const gap: f32 = 80.0;
            const thumb_w = 2540.0 * scale + gap - 20.0;
            const thumb_h = 1440.0 * scale + gap - 20.0;

            zclay.UI()(.{
                .id = .ID("Menu"),
                .layout = .{
                    .sizing = .grow,
                    .child_alignment = .{ .x = .center, .y = .center },
                    .child_gap = gap,
                },
            })({
                for (0..n_focusables) |i| {
                    zclay.UI()(.{
                        .id = .IDI("Thumb", @intCast(i)),
                        .layout = .{
                            .sizing = .{ .w = .fixed(thumb_w), .h = .fixed(thumb_h) },
                        },
                        .custom = .{ .custom_data = mkCustom(.glass_thumb, null, i) },
                    })({});
                }
            });
        }
    });

    // process render commands
    const render_cmds = zclay.endLayout();

    const ThumbRect = struct { x: f32, y: f32, w: f32, h: f32 };
    var thumb_rects: [32]ThumbRect = undefined;
    var thumb_count: usize = 0;

    var ci: usize = 0;
    while (ci < render_cmds.len) : (ci += 1) {
        const cmd = render_cmds[ci];
        const bb = cmd.bounding_box;

        switch (cmd.command_type) {
            .custom => {
                const cd: *CustomData = @ptrCast(@alignCast(cmd.render_data.custom.custom_data));
                switch (cd.tag) {
                    .glass => {
                        drawGlassQuad(output, bb.x, bb.y, bb.width, bb.height, screen_width, screen_height, scene_tex);
                    },
                    .glass_thumb => {
                        drawGlassQuad(output, bb.x, bb.y, bb.width, bb.height, screen_width, screen_height, scene_tex);
                        if (thumb_count < thumb_rects.len) {
                            thumb_rects[thumb_count] = .{ .x = bb.x, .y = bb.y, .w = bb.width, .h = bb.height };
                            thumb_count += 1;
                        }
                    },
                    .divider => {
                        gl.glUseProgram(output.fill.?.prog);
                        gl.glUniform4f(output.fill.?.color_loc, 1.0, 1.0, 1.0, beacon_line_state * 0.2);
                        drawQuad(output, bb.x, bb.y, bb.width, bb.height, screen_width, screen_height, output.fill.?.pos_loc);
                    },
                    .icon => {
                        if (cd.beacon_command) |bc| {
                            if (bc.icon) |icon_name| {
                                if (getIcon(server.allocator, icon_name)) |icon| {
                                    gl.glUseProgram(output.image.?.prog);
                                    gl.glActiveTexture(gl.GL_TEXTURE0);
                                    gl.glBindTexture(gl.GL_TEXTURE_2D, icon.tex);
                                    gl.glUniform1i(output.image.?.image_loc, 0);
                                    drawQuadWithUv(
                                        output,
                                        bb.x,
                                        bb.y,
                                        bb.width,
                                        bb.height,
                                        screen_width,
                                        screen_height,
                                        output.image.?.pos_loc,
                                        output.image.?.uv_loc,
                                    );
                                }
                            }
                        }
                    },
                }
            },
            .text => {
                const td = cmd.render_data.text;
                const text = td.string_contents.chars[0..@intCast(td.string_contents.length)];
                const thickness: f32 = if (td.font_id == 1) 0.2 else 0.0;
                drawGlassSentence(output, &glass_font, text, bb.x, bb.y, screen_width, screen_height, thickness);
            },
            else => {},
        }
    }

    // TODO: port to clay
    // menu surface pass
    if (focusables) |focs| {
        const scale: f32 = 0.2;

        const SurfaceItem = struct {
            texture: *c.wlr_texture,
            x: f32,
            y: f32,
            w: f32,
            h: f32,
        };

        const IteratorData = struct {
            tex_list: *std.ArrayList(*SurfaceItem),
            server: *WinglessServer,
            base_x: f32,
            base_y: f32,
            sc: f32,
        };

        var surface_textures: std.ArrayList(*SurfaceItem) = .empty;

        for (focs, 0..) |focusable, i| {
            if (i >= thumb_count) break;
            const tr = thumb_rects[i];

            const iterator = struct {
                pub fn run(surface: [*c]c.wlr_surface, sx: c_int, sy: c_int, data: ?*anyopaque) callconv(.c) void {
                    const id: *IteratorData = @ptrCast(@alignCast(data.?));
                    const tex_opt = c.wlr_surface_get_texture(surface);
                    if (tex_opt == null) return;
                    const tex: *c.wlr_texture = @ptrCast(tex_opt);
                    const s: *c.wlr_surface = @ptrCast(surface);
                    const sw: f32 = @floatFromInt(s.current.width);
                    const sh: f32 = @floatFromInt(s.current.height);
                    if (sw <= 0 or sh <= 0) return;
                    const it = id.server.allocator.create(SurfaceItem) catch @panic("oom");
                    it.* = .{
                        .texture = tex,
                        .x = id.base_x + @as(f32, @floatFromInt(sx)) * id.sc,
                        .y = id.base_y + @as(f32, @floatFromInt(sy)) * id.sc,
                        .w = sw * id.sc,
                        .h = sh * id.sc,
                    };
                    id.tex_list.append(id.server.allocator, it) catch @panic("oom");
                }
            }.run;

            const iter_data = IteratorData{
                .tex_list = &surface_textures,
                .server = server,
                .base_x = tr.x + 10,
                .base_y = tr.y + 10,
                .sc = scale,
            };

            c.wlr_surface_for_each_surface(
                focusable.surface(),
                iterator,
                @ptrCast(@alignCast(@constCast(&iter_data))),
            );
        }

        for (surface_textures.items) |it| {
            var attribs: c.wlr_gles2_texture_attribs = undefined;
            c.wlr_gles2_texture_get_attribs(it.texture, &attribs);

            gl.glUseProgram(output.image.?.prog);
            gl.glActiveTexture(gl.GL_TEXTURE0);
            gl.glBindTexture(attribs.target, attribs.tex);
            gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
            gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
            gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
            gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
            gl.glUniform1i(output.image.?.image_loc, 0);

            drawQuadWithUv(
                output,
                it.x,
                it.y,
                it.w,
                it.h,
                screen_width,
                screen_height,
                output.image.?.pos_loc,
                output.image.?.uv_loc,
            );
        }
    }
}
