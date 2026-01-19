const std = @import("std");

const main = @import("main.zig");
const WinglessOutput = main.WinglessOutput;
const WinglessServer = main.WinglessServer;

const c = @import("c.zig").c;
const gl = @import("c.zig").gl;

fn ndc_x(x: f32, w: f32) f32 {
    return (x / w) * 2.0 - 1.0;
}

fn ndc_y(y: f32, h: f32) f32 {
    return 1.0 - (y / h) * 2.0;
}

fn glCompileShader(kind: c_uint, src: []const u8) c_uint {
    const sh = gl.glCreateShader(kind);

    var buf: [2048]u8 = undefined;
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

fn ensureSolidProgram(out: *WinglessOutput) void {
    if (out.gl_prog != 0) return;

    const vs_src =
        \\attribute vec2 pos;
        \\varying vec2 uv;
        \\void main() {
        \\  uv = (pos + 1.0) * 0.5;
        \\  gl_Position = vec4(pos, 0.0, 1.0);
        \\}
    ;
    const fs_src =
        \\precision highp float;
        \\uniform sampler2D scene;
        \\varying vec2 uv;
        \\void main() {
        \\  vec2 p = uv * 2.0 - 1.0;
        \\  float r = length(p);
        \\  float theta = atan(p.y, p.x);
        \\  r = pow(r, 1.1);
        \\  p = r * vec2(cos(theta), sin(theta));
        \\  p = p * 0.5 + 0.5;
        \\  gl_FragColor = texture2D(scene, p);
        \\  // gl_FragColor = vec4(p, 0.0, 1.0);
        \\}
    ;

    const vs = glCompileShader(gl.GL_VERTEX_SHADER, vs_src);
    const fs = glCompileShader(gl.GL_FRAGMENT_SHADER, fs_src);
    out.gl_prog = glLinkProgram(vs, fs);

    out.gl_pos_loc = gl.glGetAttribLocation(out.gl_prog, "pos");
    out.gl_scene_loc = gl.glGetUniformLocation(out.gl_prog, "scene");

    gl.glGenBuffers(1, &out.gl_vbo);
}

pub fn renderUI(server: *WinglessServer, output: *WinglessOutput, w: c_int, h: c_int) !void {
    ensureSolidProgram(output);

    gl.glViewport(0, 0, w, h);

    gl.glDisable(c.GL_SCISSOR_TEST);
    gl.glDisable(c.GL_DEPTH_TEST);
    gl.glDisable(c.GL_CULL_FACE);

    gl.glEnable(c.GL_BLEND);
    gl.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

    const fx: f32 = 0;
    const fy: f32 = 0;
    const fw: f32 = @floatFromInt(w);
    const fh: f32 = @floatFromInt(h);

    const W: f32 = @floatFromInt(w);
    const H: f32 = @floatFromInt(h);

    const verts = [_]f32{
        ndc_x(fx, W),
        ndc_y(fy, H),
        ndc_x(fx + fw, W),
        ndc_y(fy, H),
        ndc_x(fx, W),
        ndc_y(fy + fh, H),
        ndc_x(fx + fw, W),
        ndc_y(fy, H),
        ndc_x(fx + fw, W),
        ndc_y(fy + fh, H),
        ndc_x(fx, W),
        ndc_y(fy + fh, H),
    };

    const scene_tex = c.wlr_texture_from_buffer(server.renderer, output.scene_buffer.?);
    if (scene_tex == null) @panic("no tex");
    defer c.wlr_texture_destroy(scene_tex);

    var attribs: c.wlr_gles2_texture_attribs = undefined;
    c.wlr_gles2_texture_get_attribs(scene_tex, &attribs);

    gl.glUseProgram(output.gl_prog);

    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(attribs.target, attribs.tex);

    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);

    gl.glUniform1i(output.gl_scene_loc, 0);

    var px: [4]u8 = .{ 0, 0, 0, 0 };

    std.debug.print("target = 0x{x}\n", .{attribs.target});

    gl.glReadPixels(0, 0, 1, 1, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, &px);
    std.debug.print("offscreen buffah px: {d} {d} {d} {d}\n", .{ px[0], px[1], px[2], px[3] });

    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, output.gl_vbo);
    gl.glBufferData(gl.GL_ARRAY_BUFFER, @sizeOf(@TypeOf(verts)), &verts, gl.GL_STREAM_DRAW);

    gl.glEnableVertexAttribArray(@intCast(output.gl_pos_loc));
    gl.glVertexAttribPointer(@intCast(output.gl_pos_loc), 2, gl.GL_FLOAT, gl.GL_FALSE, 2 * @sizeOf(f32), @ptrFromInt(0));

    gl.glDrawArrays(gl.GL_TRIANGLES, 0, 6);

    gl.glDisableVertexAttribArray(@intCast(output.gl_pos_loc));
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, 0);
}
