const std = @import("std");

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

var beacon_state: f32 = 0;
var beacon_suggestion_state: f32 = 0;
var beacon_line_state: f32 = 0;

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
    // glass_background
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

    // glass_text
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

    // fill
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

    // image
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

/// Render a glass quad. Self explanatory. The position and size parameters are for the box itself, not the rendered surface.
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
    gl.glUniform1f(output.glass_background.?.shadow_intensity_loc, 0.5);

    const W = screen_w;
    const H = screen_h;

    drawQuad(
        output,
        x - 150,
        y - 150,
        w + 300,
        h + 300,
        W,
        H,
        output.glass_background.?.pos_loc,
    );
}

fn drawQuad(output: *WinglessOutput, x: f32, y: f32, w: f32, h: f32, screen_w: f32, screen_h: f32, gl_pos_loc: c_int) void {
    const x0 = ndc_x(x, screen_w);
    const y0 = ndc_y(y, screen_h);
    const x1 = ndc_x(x + w, screen_w);
    const y1 = ndc_y(y + h, screen_h);

    const verts = [_]f32{
        x0,
        y0,
        x1,
        y0,
        x0,
        y1,
        x1,
        y0,
        x1,
        y1,
        x0,
        y1,
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

fn drawGlassChar(
    output: *WinglessOutput,
    font: *const Font,
    ch: u8,
    x: f32,
    y: f32,
    screen_w: f32,
    screen_h: f32,
    thickness: f32,
) f32 {
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

fn drawGlassSentence(
    output: *WinglessOutput,
    font: *const Font,
    sentence: []const u8,
    x: f32,
    y: f32,
    screen_w: f32,
    screen_h: f32,
    thickness: f32,
) void {
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

    gl.glTexImage2D(
        gl.GL_TEXTURE_2D,
        0,
        gl.GL_RGBA,
        w,
        h,
        0,
        gl.GL_RGBA,
        gl.GL_UNSIGNED_BYTE,
        pixels,
    );

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

    // beacon commands
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

            // parse .desktop file
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

                // parse group
                const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
                const key = line[0..eq];
                const val = line[eq + 1 ..];

                if (std.mem.eql(u8, key, "Type")) {
                    // TODO: check type and only add applications too lazy to do that rn
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

// potentially merge with updateBeaconSuggestions
fn resolveIconPath(allocator: std.mem.Allocator, icon: []const u8) !?[]const u8 {
    if (std.fs.path.isAbsolute(icon)) {
        if (std.fs.openFileAbsolute(icon, .{}) catch null != null) return try allocator.dupe(u8, icon);
        return null;
    }

    const themes = [_][]const u8{ "Adwaita", "hicolor" };
    const sizes = [_][]const u8{
        "128x128",
        "64x64",
        "48x48",
        "32x32",
        "scalable", // for svg later
    };

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
                    &.{
                        dir, theme, size, "apps", try std.mem.concat(allocator, u8, &.{ icon, ".png" }),
                    },
                );

                if (std.fs.openFileAbsolute(path, .{}) catch null != null) return path;
                allocator.free(path);
            }
        }
    }

    // pixmaps
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

    const pixels = c.stbi_load_from_memory(
        png.ptr,
        @intCast(png.len),
        &w,
        &h,
        &comp,
        4,
    ) orelse return null;
    defer c.stbi_image_free(pixels);

    var tex: c_uint = 0;
    gl.glGenTextures(1, &tex);
    gl.glBindTexture(gl.GL_TEXTURE_2D, tex);

    gl.glTexImage2D(
        gl.GL_TEXTURE_2D,
        0,
        gl.GL_RGBA,
        w,
        h,
        0,
        gl.GL_RGBA,
        gl.GL_UNSIGNED_BYTE,
        pixels,
    );

    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);

    const icon = Icon{
        .tex = tex,
        .w = @intCast(w),
        .h = @intCast(h),
    };

    // TODO: fix this
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
        // levenstein fuzzy
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

                curr[j] = @min(
                    @min(curr[j - 1] + 1, prev[j] + 1),
                    prev[j - 1] + cost,
                );
            }
            std.mem.swap([]usize, &prev, &curr);
        }

        const dist = prev[m];

        var score: isize = @intCast(dist);

        // penalize short names and add prefix / substring bonus
        if (std.mem.startsWith(u8, a, b)) score -= 5 else if (std.mem.indexOf(u8, a, b) != null) score -= 3;

        score += @intCast(a.len / 10);
        // TODO: add score based on how many times the user has launched the app in the recent times

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
    if (initialized == false) {
        try initUI(std.heap.page_allocator);

        initialized = true;
    }
    const dt = getDeltaSeconds();

    // update state
    const beacon_state_target: f32 = if (beacon_open) 1.0 else 0.0;
    beacon_state = lerp(beacon_state, beacon_state_target, dt * 20.0);

    const beacon_suggestion_state_target: f32 = if (beacon_buffer.items.len >= 2)
        switch (beacon_suggestions.len) {
            0, 1 => 0.4,
            2 => 0.7,
            else => 1,
        }
    else
        0.0;
    beacon_suggestion_state = lerp(beacon_suggestion_state, beacon_suggestion_state_target, dt * 20.0);

    const beacon_line_state_target: f32 = if (beacon_state_target > 0.1) 1 else 0;
    beacon_line_state = lerp(beacon_line_state, beacon_line_state_target, dt * 20.0);

    // setup
    if (output.gl_vbo == 0)
        gl.glGenBuffers(1, &output.gl_vbo);

    if (output.gl_vao == 0)
        gl.glGenBuffers(1, &output.gl_vao);

    ensurePrograms(output);

    gl.glViewport(0, 0, w, h);

    // global state
    gl.glDisable(c.GL_SCISSOR_TEST);
    gl.glDisable(c.GL_DEPTH_TEST);
    gl.glDisable(c.GL_CULL_FACE);

    gl.glEnable(c.GL_BLEND);
    gl.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

    // draw ui
    // bind scene texture
    const scene_tex = c.wlr_texture_from_buffer(server.renderer, output.scene_buffer.?);
    if (scene_tex == null) @panic("no tex");
    defer c.wlr_texture_destroy(scene_tex);

    const W: f32 = @floatFromInt(w);
    const H: f32 = @floatFromInt(h);

    // draw beacon background
    {
        const width = 800 * beacon_state;
        const height = 80 + 200 * beacon_suggestion_state;

        const x = W / 2 - width / 2;
        const y = H / 2 - height / 2 + 50 * beacon_suggestion_state;

        drawGlassQuad(output, x, y, width, height, W, H, scene_tex);
    }

    // beacon overlay pass
    const x: f32 = W / 2 - 370;
    const y: f32 = H / 2 - 10 + beacon_suggestion_state * 50;

    const suggestion_offset: f32 = 60;
    var suggestion_y = y - 80;
    const empty_suggestion_text = "Unknown command !";

    if (beacon_open) {
        drawGlassSentence(output, &glass_font, beacon_buffer.items, x, y, W, H, 0.2);

        // draw suggestions
        if (beacon_suggestion_state_target > 0.1) {
            // draw dividing line
            gl.glUseProgram(output.fill.?.prog);

            gl.glUniform4f(
                output.fill.?.color_loc,
                1.0,
                1.0,
                1.0,
                beacon_line_state * 0.2,
            );

            const line_w: f32 = 740;
            const line_h: f32 = 2;

            const line_x: f32 = x;
            const line_y: f32 = y - 24;

            drawQuad(
                output,
                line_x,
                line_y,
                line_w,
                line_h,
                W,
                H,
                output.fill.?.pos_loc,
            );

            // draw text
            for (0..beacon_suggestions.len) |i| {
                if (i > 2) break;

                const suggestion = beacon_suggestions[i].name;
                drawGlassSentence(
                    output,
                    &glass_font,
                    suggestion,
                    x + 58,
                    suggestion_y,
                    W,
                    H,
                    0.0,
                );

                // draw icons
                if (beacon_suggestions[i].icon) |beacon_icon| {
                    if (getIcon(server.allocator, beacon_icon)) |icon| {
                        gl.glUseProgram(output.image.?.prog);

                        gl.glActiveTexture(gl.GL_TEXTURE0);
                        gl.glBindTexture(gl.GL_TEXTURE_2D, icon.tex);
                        gl.glUniform1i(output.image.?.image_loc, 0);

                        drawQuadWithUv(
                            output,
                            x,
                            suggestion_y - 9,
                            42,
                            42,
                            W,
                            H,
                            output.image.?.pos_loc,
                            output.image.?.uv_loc,
                        );
                    }
                }

                suggestion_y -= suggestion_offset;
            }

            if (beacon_suggestions.len == 0) {
                drawGlassSentence(output, &glass_font, empty_suggestion_text, x, suggestion_y, W, H, 0.0);
            }
        }
    }
}
