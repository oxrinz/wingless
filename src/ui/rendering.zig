const std = @import("std");
const zclay = @import("zclay");

const c = @import("../c.zig").c;
const gl = @import("../c.zig").gl;
const ui = @import("../ui.zig");
const main = @import("../main.zig");

const menu = @import("menu.zig");

const WinglessOutput = main.WinglessOutput;
const Font = ui.Font;

fn ndc_x(x: f32, w: f32) f32 {
    return (x / w) * 2.0 - 1.0;
}

fn ndc_y(y: f32, h: f32) f32 {
    return 1.0 - (y / h) * 2.0;
}

// Scene-buffer version: DMA-BUF row 0 = top of image, GL y=0 maps to row 0,
// so NDC y=-1 = top of screen (opposite of EGL display surface convention).
fn ndc_y_scene(y: f32, h: f32) f32 {
    return (y / h) * 2.0 - 1.0;
}

fn drawGlassQuad(output: *WinglessOutput, x: f32, y: f32, w: f32, h: f32, screen_w: f32, screen_h: f32, scene_tex: *c.wlr_texture, roundness: f32, fill_amount: f32, fill_direction: i32, refraction_band: f32, brightness: f32) void {
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
    gl.glUniform2f(output.glass_background.?.quad_pos_loc, x, screen_h - y - h);
    gl.glUniform2f(output.glass_background.?.size_loc, w, h);
    gl.glUniform1f(output.glass_background.?.shadow_intensity_loc, 0.01 * @min(0.5 * 100, @min(w, h)));
    gl.glUniform1f(output.glass_background.?.roundness, roundness);
    gl.glUniform1f(output.glass_background.?.fill_amount_loc, fill_amount);
    gl.glUniform1i(output.glass_background.?.fill_direction_loc, fill_direction);
    gl.glUniform1f(output.glass_background.?.refraction_band_loc, refraction_band);
    gl.glUniform1f(output.glass_background.?.brightness_loc, brightness);

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

// Scene-buffer variants: use ndc_y_scene (y=0 at top) and UV v=0 at top.
fn drawQuadScene(output: *WinglessOutput, x: f32, y: f32, w: f32, h: f32, screen_w: f32, screen_h: f32, gl_pos_loc: c_int) void {
    const x0 = ndc_x(x, screen_w);
    const y0 = ndc_y_scene(y, screen_h);
    const x1 = ndc_x(x + w, screen_w);
    const y1 = ndc_y_scene(y + h, screen_h);

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

fn drawQuadWithUvScene(output: *WinglessOutput, x: f32, y: f32, w: f32, h: f32, screen_w: f32, screen_h: f32, gl_pos_loc: c_int, gl_uv_loc: c_int) void {
    const x0 = ndc_x(x, screen_w);
    const y0 = ndc_y_scene(y, screen_h);
    const x1 = ndc_x(x + w, screen_w);
    const y1 = ndc_y_scene(y + h, screen_h);

    // UV: v=0 at visual top, v=1 at visual bottom (Wayland DMA-BUF row 0 = top = GL tex v=0)
    const verts = [_]f32{
        x0, y0, 0, 0,
        x1, y0, 1, 0,
        x0, y1, 0, 1,
        x1, y0, 1, 0,
        x1, y1, 1, 1,
        x0, y1, 0, 1,
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

fn drawGlassChar(output: *WinglessOutput, font: *const Font, ch: u8, x: f32, y: f32, screen_w: f32, screen_h: f32, thickness: f32, scale: f32, scene_tex: *c.wlr_texture, glass_mode: c_int) f32 {
    if (ch == ' ') return 12.0 * scale / 32.0;
    const g = font.glyphs[ch] orelse return 0;

    gl.glUseProgram(output.glass_text.?.prog);

    var attribs: c.wlr_gles2_texture_attribs = undefined;
    c.wlr_gles2_texture_get_attribs(scene_tex, &attribs);

    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, font.atlas_tex);
    gl.glUniform1i(output.glass_text.?.atlas_loc, 0);

    gl.glActiveTexture(gl.GL_TEXTURE1);
    gl.glBindTexture(attribs.target, attribs.tex);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
    gl.glUniform1i(output.glass_text.?.scene_loc, 1);
    gl.glUniform1i(output.glass_text.?.glass_mode_loc, glass_mode);

    gl.glUniform1f(output.glass_text.?.px_range_loc, font.px_range);
    gl.glUniform1f(output.glass_text.?.thickness_loc, thickness);

    const gx = x + g.x_off;
    const gy = y + g.y_off * scale + 0.2 * 32;

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

    gl.glActiveTexture(gl.GL_TEXTURE0);

    return g.advance * scale;
}

fn drawGlassSentence(output: *WinglessOutput, font: *const Font, sentence: []const u8, x: f32, y: f32, screen_w: f32, screen_h: f32, thickness: f32, scale: f32, scene_tex: *c.wlr_texture, glass_mode: c_int) void {
    var real_x = x;
    for (sentence) |char| {
        real_x += drawGlassChar(output, font, char, real_x, y, screen_w, screen_h, thickness, scale, scene_tex, glass_mode);
    }
}

fn drawTextChar(output: *WinglessOutput, font: *const Font, ch: u8, x: f32, y: f32, screen_w: f32, screen_h: f32, thickness: f32, scale: f32, color: [4]f32) f32 {
    if (ch == ' ') return 12.0 * scale / 32.0;
    const g = font.glyphs[ch] orelse return 0;

    gl.glUseProgram(output.text.?.prog);

    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, font.atlas_tex);
    gl.glUniform1i(output.text.?.atlas_loc, 0);
    gl.glUniform1f(output.text.?.px_range_loc, font.px_range);
    gl.glUniform1f(output.text.?.thickness_loc, thickness);
    gl.glUniform4f(output.text.?.color_loc, color[0], color[1], color[2], color[3]);

    const gx = x + g.x_off;
    const gy = y + g.y_off * scale + 0.1 * 32;

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
    gl.glEnableVertexAttribArray(@intCast(output.text.?.pos_loc));
    gl.glVertexAttribPointer(@intCast(output.text.?.pos_loc), 2, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(0));
    gl.glEnableVertexAttribArray(@intCast(output.text.?.uv_loc));
    gl.glVertexAttribPointer(@intCast(output.text.?.uv_loc), 2, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(2 * @sizeOf(f32)));
    gl.glDrawArrays(gl.GL_TRIANGLES, 0, 6);
    gl.glDisableVertexAttribArray(@intCast(output.text.?.pos_loc));
    gl.glDisableVertexAttribArray(@intCast(output.text.?.uv_loc));
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, 0);

    return g.advance * scale;
}

pub fn drawText(output: *WinglessOutput, font: *const Font, sentence: []const u8, x: f32, y: f32, screen_w: f32, screen_h: f32, thickness: f32, scale: f32, r: f32, g_: f32, b: f32, a: f32) void {
    var real_x = x;
    for (sentence) |char| {
        real_x += drawTextChar(output, font, char, real_x, y, screen_w, screen_h, thickness, scale, .{ r, g_, b, a });
    }
}

fn ensureBlurFbo(output: *WinglessOutput, w: c_int, h: c_int) void {
    if (output.blur_fbo != 0) return;
    gl.glGenFramebuffers(1, &output.blur_fbo);
    gl.glGenTextures(1, &output.blur_tex);
    gl.glBindTexture(gl.GL_TEXTURE_2D, output.blur_tex);
    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGB, w, h, 0, gl.GL_RGB, gl.GL_UNSIGNED_BYTE, null);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, output.blur_fbo);
    gl.glFramebufferTexture2D(gl.GL_FRAMEBUFFER, gl.GL_COLOR_ATTACHMENT0, gl.GL_TEXTURE_2D, output.blur_tex, 0);
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, 0);
}

// Output-pass shadow (glass.vert: fragCoord = v_uv * res, where v_uv.y = 1 - y/h, so quadPos.y = screen_h - y - h)
fn drawShadowQuad(output: *WinglessOutput, x: f32, y: f32, w: f32, h: f32, screen_w: f32, screen_h: f32, roundness: f32, intensity: f32) void {
    gl.glUseProgram(output.shadow.?.prog);
    gl.glUniform2f(output.shadow.?.quad_pos_loc, x, screen_h - y - h);
    gl.glUniform2f(output.shadow.?.size_loc, w, h);
    gl.glUniform1f(output.shadow.?.roundness_loc, roundness);
    gl.glUniform1f(output.shadow.?.intensity_loc, intensity);
    const pad: f32 = 200;
    drawQuad(output, x - pad, y - pad, w + pad * 2, h + pad * 2, screen_w, screen_h, output.shadow.?.pos_loc);
}

// Scene-buffer-pass shadow (fragCoord.y = y directly in screen coords, so quadPos.y = y)
fn drawShadowQuadScene(output: *WinglessOutput, x: f32, y: f32, w: f32, h: f32, screen_w: f32, screen_h: f32, roundness: f32, intensity: f32) void {
    gl.glUseProgram(output.shadow.?.prog);
    gl.glUniform2f(output.shadow.?.quad_pos_loc, x, y);
    gl.glUniform2f(output.shadow.?.size_loc, w, h);
    gl.glUniform1f(output.shadow.?.roundness_loc, roundness);
    gl.glUniform1f(output.shadow.?.intensity_loc, intensity);
    const pad: f32 = 200;
    drawQuadScene(output, x - pad, y - pad, w + pad * 2, h + pad * 2, screen_w, screen_h, output.shadow.?.pos_loc);
}

fn drawFullscreenBlur(output: *WinglessOutput, screen_w: f32, screen_h: f32, scene_tex: *c.wlr_texture, intensity: f32) void {
    const iw: c_int = @intFromFloat(screen_w);
    const ih: c_int = @intFromFloat(screen_h);
    ensureBlurFbo(output, iw, ih);

    var attribs: c.wlr_gles2_texture_attribs = undefined;
    c.wlr_gles2_texture_get_attribs(scene_tex, &attribs);

    const prog = output.blur.?.prog;
    const pos_loc = output.blur.?.pos_loc;
    const scene_loc = output.blur.?.scene_loc;
    const intensity_loc = output.blur.?.intensity_loc;
    const dir_loc = output.blur.?.direction_loc;

    // save current fbo (wlroots uses its own, not 0)
    var prev_fbo: c_int = 0;
    gl.glGetIntegerv(gl.GL_FRAMEBUFFER_BINDING, &prev_fbo);

    // pass 1: horizontal, scene_tex -> blur_fbo
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, output.blur_fbo);
    gl.glViewport(0, 0, iw, ih);
    gl.glDisable(gl.GL_BLEND);
    gl.glUseProgram(prog);
    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(attribs.target, attribs.tex);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
    gl.glUniform1i(scene_loc, 0);
    gl.glUniform1f(intensity_loc, 1.0);
    gl.glUniform2f(dir_loc, 1.0, 0.0);
    drawQuad(output, 0, 0, screen_w, screen_h, screen_w, screen_h, pos_loc);

    // pass 2: vertical, blur_tex -> compositor fbo
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, @intCast(prev_fbo));
    gl.glViewport(0, 0, iw, ih);
    gl.glEnable(gl.GL_BLEND);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glUseProgram(prog);
    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, output.blur_tex);
    gl.glUniform1i(scene_loc, 0);
    gl.glUniform1f(intensity_loc, intensity);
    gl.glUniform2f(dir_loc, 0.0, 1.0);
    drawQuad(output, 0, 0, screen_w, screen_h, screen_w, screen_h, pos_loc);
}

// sx, sy, sw, sh: this surface's screen bounds (top-left origin)
// clip_x, clip_y, clip_w, clip_h: rounded clip rect (parent window for subsurfaces, self for main)
// with_decorations: draw shadow + border only for the main surface
pub fn drawWindowSurface(output: *WinglessOutput, tex: *c.wlr_texture, sx: f32, sy: f32, sw: f32, sh: f32, clip_x: f32, clip_y: f32, clip_w: f32, clip_h: f32, screen_w: f32, screen_h: f32, with_decorations: bool, is_focused: bool) void {
    const roundness: f32 = 12.0;

    gl.glEnable(c.GL_BLEND);
    gl.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

    if (with_decorations) {
        const intensity: f32 = 0.01 * @min(50.0, @min(clip_w, clip_h));
        drawShadowQuadScene(output, clip_x, clip_y, clip_w, clip_h, screen_w, screen_h, roundness, intensity);
    }

    const prog = output.window orelse return;
    var attribs: c.wlr_gles2_texture_attribs = undefined;
    c.wlr_gles2_texture_get_attribs(tex, &attribs);

    gl.glUseProgram(prog.prog);
    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(attribs.target, attribs.tex);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);

    const bw: f32 = if (with_decorations) 2.0 else 0.0;
    // quadPos/size = texture buffer bounds for UV sampling
    // render quad expanded by bw so the outer border ring has pixels outside the clip rect
    gl.glUniform1i(prog.image_loc, 0);
    gl.glUniform2f(prog.size_loc, sw, sh);
    gl.glUniform2f(prog.quad_pos_loc, sx, sy);
    gl.glUniform2f(prog.clip_pos_loc, clip_x, clip_y);
    gl.glUniform2f(prog.clip_size_loc, clip_w, clip_h);
    gl.glUniform1f(prog.roundness_loc, roundness);
    gl.glUniform1f(prog.border_width_loc, bw);
    if (is_focused) {
        gl.glUniform4f(prog.border_color_loc, 1.0, 1.0, 1.0, 1.0);
    } else {
        gl.glUniform4f(prog.border_color_loc, 0.5, 0.5, 0.5, 1.0);
    }

    drawQuadScene(output, clip_x - bw, clip_y - bw, clip_w + bw * 2.0, clip_h + bw * 2.0, screen_w, screen_h, prog.pos_loc);
}

pub fn renderBackground(output: *WinglessOutput, screen_w: f32, screen_h: f32) void {
    if (!ui.bg_gl_loaded) {
        ui.bg_gl_loaded = true;
        if (ui.bg_path) |path| {
            const path_z = std.heap.page_allocator.dupeZ(u8, path) catch return;
            defer std.heap.page_allocator.free(path_z);
            var iw: c_int = 0;
            var ih: c_int = 0;
            var ic: c_int = 0;
            const pixels = c.stbi_load(path_z.ptr, &iw, &ih, &ic, 4);
            if (pixels != null) {
                defer c.stbi_image_free(pixels);
                gl.glGenTextures(1, &ui.bg_gl_tex);
                gl.glBindTexture(gl.GL_TEXTURE_2D, ui.bg_gl_tex);
                gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA, iw, ih, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, pixels);
                gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
                gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
                gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
                gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
            } else {
                std.debug.print("background: failed to load: {s}\n", .{path_z});
            }
        }
    }

    if (ui.bg_gl_tex == 0) return;
    const prog = output.image orelse return;

    gl.glUseProgram(prog.prog);
    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, ui.bg_gl_tex);
    gl.glUniform1i(prog.image_loc, 0);
    gl.glUniform2f(prog.size_loc, screen_w, screen_h);
    gl.glUniform2f(prog.quad_pos_loc, 0, 0);
    gl.glUniform1f(prog.roundness_loc, 0);
    gl.glUniform1f(prog.alpha_loc, 1.0);
    gl.glDisable(c.GL_BLEND);
    drawQuadWithUvScene(output, 0, 0, screen_w, screen_h, screen_w, screen_h, prog.pos_loc, prog.uv_loc);
    gl.glEnable(c.GL_BLEND);
}

pub fn render(ctx: ui.RenderContext) void {
    const blur_intensity = menu.menu_state;
    if (blur_intensity > 0.0001) {
        drawFullscreenBlur(ctx.output, ctx.screen_width, ctx.screen_height, ctx.scene_tex, blur_intensity);
    }

    const render_cmds = zclay.endLayout();

    // Pass 1: glass backgrounds (oversized quads with shadows) — all before any content
    var ci: usize = 0;
    while (ci < render_cmds.len) : (ci += 1) {
        const cmd = render_cmds[ci];
        if (cmd.command_type != .custom) continue;
        const cd: *ui.CustomData = @ptrCast(@alignCast(cmd.render_data.custom.custom_data));
        if (cd.* != .glass) continue;
        const bb = cmd.bounding_box;
        const g = cd.glass;
        if (g.animated) {
            const cx = bb.x + bb.width * 0.5;
            const cy = bb.y + bb.height * 0.5;
            const aw = bb.width * g.anim_scale;
            const ah = bb.height * g.anim_scale;
            drawGlassQuad(ctx.output, cx - aw * 0.5, cy - ah * 0.5, aw, ah, ctx.screen_width, ctx.screen_height, ctx.scene_tex, g.roundness, g.fill_amount, g.fill_dir, g.refraction_band, g.brightness);
        } else {
            drawGlassQuad(ctx.output, bb.x, bb.y, bb.width, bb.height, ctx.screen_width, ctx.screen_height, ctx.scene_tex, g.roundness, g.fill_amount, g.fill_dir, g.refraction_band, g.brightness);
        }
    }

    // Pass 2: everything else
    ci = 0;
    while (ci < render_cmds.len) : (ci += 1) {
        const cmd = render_cmds[ci];
        const bb = cmd.bounding_box;

        switch (cmd.command_type) {
            .custom => {
                const cd: *ui.CustomData = @ptrCast(@alignCast(cmd.render_data.custom.custom_data));
                switch (cd.*) {
                    .glass => {},
                    .window_surface => |ws| {
                        const IterData = struct {
                            output: *WinglessOutput,
                            base_x: f32,
                            base_y: f32,
                            sc: f32,
                            screen_w: f32,
                            screen_h: f32,
                        };
                        const cx = bb.x + bb.width * 0.5;
                        const cy = bb.y + bb.height * 0.5;
                        const animated_sc = ws.scale * ws.anim_scale;
                        const iter_data = IterData{
                            .output = ctx.output,
                            .base_x = cx - (bb.width * ws.anim_scale) * 0.5,
                            .base_y = cy - (bb.height * ws.anim_scale) * 0.5,
                            .sc = animated_sc,
                            .screen_w = ctx.screen_width,
                            .screen_h = ctx.screen_height,
                        };
                        const iterator = struct {
                            pub fn run(surface: [*c]c.wlr_surface, sx: c_int, sy: c_int, data: ?*anyopaque) callconv(.c) void {
                                const id: *IterData = @ptrCast(@alignCast(data.?));
                                const tex_opt = c.wlr_surface_get_texture(surface);
                                if (tex_opt == null) return;
                                const tex: *c.wlr_texture = @ptrCast(tex_opt);
                                const s: *c.wlr_surface = @ptrCast(surface);
                                const sw: f32 = @floatFromInt(s.current.width);
                                const sh: f32 = @floatFromInt(s.current.height);
                                if (sw <= 0 or sh <= 0) return;
                                var attribs: c.wlr_gles2_texture_attribs = undefined;
                                c.wlr_gles2_texture_get_attribs(tex, &attribs);
                                gl.glUseProgram(id.output.image.?.prog);
                                gl.glActiveTexture(gl.GL_TEXTURE0);
                                gl.glBindTexture(attribs.target, attribs.tex);
                                gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
                                gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
                                gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
                                gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
                                const qx = id.base_x + @as(f32, @floatFromInt(sx)) * id.sc;
                                const qy = id.base_y + @as(f32, @floatFromInt(sy)) * id.sc;
                                const qw = sw * id.sc;
                                const qh = sh * id.sc;
                                gl.glUniform1i(id.output.image.?.image_loc, 0);
                                gl.glUniform2f(id.output.image.?.size_loc, qw, qh);
                                gl.glUniform2f(id.output.image.?.quad_pos_loc, qx, qy);
                                gl.glUniform1f(id.output.image.?.roundness_loc, 12.0);
                                gl.glUniform1f(id.output.image.?.alpha_loc, 1.0);

                                drawQuadWithUv(
                                    id.output,
                                    qx,
                                    qy,
                                    qw,
                                    qh,
                                    id.screen_w,
                                    id.screen_h,
                                    id.output.image.?.pos_loc,
                                    id.output.image.?.uv_loc,
                                );
                            }
                        }.run;
                        c.wlr_surface_for_each_surface(
                            ws.focusable.surface(),
                            iterator,
                            @ptrCast(@alignCast(@constCast(&iter_data))),
                        );
                    },
                    .glass_text => |gt| {
                        const scale: f32 = @floatFromInt(gt.font_size);
                        const thickness: f32 = if (gt.bold) 0.2 else 0.0;
                        drawGlassSentence(ctx.output, ctx.font, gt.text, bb.x, bb.y, ctx.screen_width, ctx.screen_height, thickness, scale, ctx.scene_tex, 1);
                    },
                    .divider => |d| {
                        gl.glUseProgram(ctx.output.fill.?.prog);
                        gl.glUniform4f(ctx.output.fill.?.color_loc, 1.0, 1.0, 1.0, d.alpha);
                        drawQuad(ctx.output, bb.x, bb.y, bb.width, bb.height, ctx.screen_width, ctx.screen_height, ctx.output.fill.?.pos_loc);
                    },
                    .shadow => |sh| {
                        if (sh.animated) {
                            const cx = bb.x + bb.width * 0.5;
                            const cy = bb.y + bb.height * 0.5;
                            const aw = bb.width * sh.anim_scale;
                            const ah = bb.height * sh.anim_scale;
                            drawShadowQuad(ctx.output, cx - aw * 0.5, cy - ah * 0.5, aw, ah, ctx.screen_width, ctx.screen_height, sh.roundness, sh.intensity);
                        } else {
                            drawShadowQuad(ctx.output, bb.x, bb.y, bb.width, bb.height, ctx.screen_width, ctx.screen_height, sh.roundness, sh.intensity);
                        }
                    },
                    .icon => |ic| {
                        gl.glUseProgram(ctx.output.image.?.prog);
                        gl.glActiveTexture(gl.GL_TEXTURE0);
                        gl.glBindTexture(gl.GL_TEXTURE_2D, ic.icon.tex);
                        gl.glUniform1i(ctx.output.image.?.image_loc, 0);
                        gl.glUniform2f(ctx.output.image.?.size_loc, bb.width, bb.height);
                        gl.glUniform2f(ctx.output.image.?.quad_pos_loc, bb.x, bb.y);
                        gl.glUniform1f(ctx.output.image.?.roundness_loc, 0.0);
                        gl.glUniform1f(ctx.output.image.?.alpha_loc, ic.alpha);
                        drawQuadWithUv(
                            ctx.output,
                            bb.x,
                            bb.y,
                            bb.width,
                            bb.height,
                            ctx.screen_width,
                            ctx.screen_height,
                            ctx.output.image.?.pos_loc,
                            ctx.output.image.?.uv_loc,
                        );
                    },
                }
            },
            .text => {
                const td = cmd.render_data.text;
                const text = td.string_contents.chars[0..@intCast(td.string_contents.length)];
                const scale: f32 = @floatFromInt(td.font_size);
                const col = td.text_color;
                drawText(ctx.output, ctx.font, text, bb.x, bb.y, ctx.screen_width, ctx.screen_height, 0.0, scale, col[0] / 255.0, col[1] / 255.0, col[2] / 255.0, col[3] / 255.0);
            },
            else => {},
        }
    }
}
