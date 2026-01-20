const std = @import("std");

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

var glass_font: Font = undefined;

pub const BeaconBackgroundProgram = struct {
    prog: c_uint,

    pos_loc: c_int,

    scene_loc: c_int,
    state_loc: c_int,
};

pub const GlassTextProgram = struct {
    prog: c_uint,

    pos_loc: c_int,
    uv_loc: c_int,

    atlas_loc: c_int,
    // px_range_loc: c_int,
    // color_loc: c_int,
};

const Glyph = struct {
    w: f32,
    h: f32,

    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

const Font = struct {
    atlas_tex: c_uint,
    glyphs: [256]?Glyph,
};

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
    if (out.beacon_background != null) return;
    // beacon_background
    {
        const vs = glCompileShader(gl.GL_VERTEX_SHADER, ui_vert_src);
        const fs = glCompileShader(gl.GL_FRAGMENT_SHADER, ui_frag_src);

        const prog = glLinkProgram(vs, fs);

        out.beacon_background = .{
            .prog = prog,
            .pos_loc = gl.glGetAttribLocation(prog, "pos"),
            .scene_loc = gl.glGetUniformLocation(prog, "scene"),
            .state_loc = gl.glGetUniformLocation(prog, "state"),
        };
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
        };
    }
}

fn drawQuad(output: *WinglessOutput, x: f32, y: f32, w: f32, h: f32, screen_w: f32, screen_h: f32, gl_pos_loc: c_int) void {
    const x0 = ndc_x(x, screen_w);
    const y0 = ndc_y(y, screen_h);
    const x1 = ndc_x(x + w, screen_w);
    const y1 = ndc_y(y + h, screen_h);

    const verts = [_]f32{ x0, y0, x1, y0, x0, y1, x1, y0, x1, y1, x0, y1 };

    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, output.gl_vbo);
    gl.glBufferData(gl.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, gl.GL_STREAM_DRAW);

    gl.glEnableVertexAttribArray(@intCast(gl_pos_loc));
    gl.glVertexAttribPointer(@intCast(gl_pos_loc), 2, gl.GL_FLOAT, gl.GL_FALSE, 2 * @sizeOf(f32), @ptrFromInt(0));

    gl.glDrawArrays(gl.GL_TRIANGLES, 0, 6);

    gl.glDisableVertexAttribArray(@intCast(gl_pos_loc));
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
) void {
    const g = font.glyphs[ch] orelse return;

    gl.glUseProgram(output.glass_text.?.prog);

    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, font.atlas_tex);
    gl.glUniform1i(output.glass_text.?.atlas_loc, 0);

    const x0 = ndc_x(x, screen_w);
    const y0 = ndc_y(y, screen_h);
    const x1 = ndc_x(x + g.w, screen_w);
    const y1 = ndc_y(y + g.h, screen_h);

    const verts = [_]f32{
        x0, y0, g.u0, g.v0,
        x1, y0, g.u1, g.v0,
        x0, y1, g.u0, g.v1,
        x1, y0, g.u1, g.v0,
        x1, y1, g.u1, g.v1,
        x0, y1, g.u0, g.v1,
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
}

fn loadFont(allocator: std.mem.Allocator, json_bytes: []const u8, atlas_tex: c_uint) !Font {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    var font = Font{
        .atlas_tex = atlas_tex,
        .glyphs = [_]?Glyph{null} ** 256,
    };

    const root = parsed.value;
    const atlas = root.object.get("atlas").?.object;

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

        font.glyphs[@intCast(code)] = Glyph{
            .w = @floatCast(plane.get("right").?.float - plane.get("left").?.float),
            .h = @floatCast(plane.get("top").?.float - plane.get("bottom").?.float),

            .u0 = left / aw,
            .u1 = right / aw,
            .v1 = 1.0 - (bottom / ah),
            .v0 = 1.0 - (top / ah),
        };
    }

    return font;
}

fn loadTextureFromPng(png: []const u8) c_uint {
    var w: c_int = 0;
    var h: c_int = 0;
    var comp: c_int = 0;

    const pixels = c.stbi_load_from_memory(png.ptr, @intCast(png.len), &w, &h, &comp, 4);
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

pub fn initUI(allocator: std.mem.Allocator) !void {
    const font_json = @embedFile("assets/roboto-msdf.json");
    const font_png = @embedFile("assets/roboto-msdf.png");

    const atlas_tex = loadTextureFromPng(font_png);
    glass_font = try loadFont(allocator, font_json, atlas_tex);
}

pub fn renderUI(server: *WinglessServer, output: *WinglessOutput, w: c_int, h: c_int) !void {
    const dt = getDeltaSeconds();

    // update state
    const beacon_state_target: f32 = if (beacon_open) 1.0 else 0.0;
    beacon_state = lerp(beacon_state, beacon_state_target, dt * 10.0);

    // setup
    if (output.gl_vbo == 0)
        gl.glGenBuffers(1, &output.gl_vbo);
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

    var attribs: c.wlr_gles2_texture_attribs = undefined;
    c.wlr_gles2_texture_get_attribs(scene_tex, &attribs);

    gl.glUseProgram(output.beacon_background.?.prog);

    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(attribs.target, attribs.tex);

    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);

    gl.glUniform1i(output.beacon_background.?.scene_loc, 0);
    gl.glUniform1f(output.beacon_background.?.state_loc, beacon_state);

    const W: f32 = @floatFromInt(w);
    const H: f32 = @floatFromInt(h);

    drawQuad(output, W / 2 - 600, H / 2 - 600, 1200, 1200, W, H, output.beacon_background.?.pos_loc);

    // text pass
    var x: f32 = W / 2 - 200;
    const y: f32 = H / 2 - 40;

    drawGlassChar(output, &glass_font, 'H', x, y, W, H);
    x += 32;
    drawGlassChar(output, &glass_font, 'e', x, y, W, H);
    x += 28;
    drawGlassChar(output, &glass_font, 'l', x, y, W, H);
    x += 16;
    drawGlassChar(output, &glass_font, 'l', x, y, W, H);
    x += 16;
    drawGlassChar(output, &glass_font, 'o', x, y, W, H);
}
