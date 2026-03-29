const std = @import("std");
const zclay = @import("zclay");

const c = @import("../c.zig").c;
const gl = @import("../c.zig").gl;
const ui = @import("../ui.zig");
const main = @import("../main.zig");

const menu = @import("menu.zig");
const glass_proto = @import("../protocols/glass.zig");

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
    gl.glUniform1f(output.glass_background.?.roundness, roundness);
    gl.glUniform1f(output.glass_background.?.fill_amount_loc, fill_amount);
    gl.glUniform1i(output.glass_background.?.fill_direction_loc, fill_direction);
    gl.glUniform1f(output.glass_background.?.refraction_band_loc, refraction_band);
    gl.glUniform1f(output.glass_background.?.brightness_loc, brightness);
    gl.glUniform2f(output.glass_background.?.resolution_loc, screen_w, screen_h);
    gl.glUniform1f(output.glass_background.?.blur_amount_loc, 1.2);

    const glass_pad = 300 * ui.ui_scale;
    drawQuad(output, x - glass_pad, y - glass_pad, w + glass_pad * 2, h + glass_pad * 2, screen_w, screen_h, output.glass_background.?.pos_loc);
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

fn drawBlobQuad(output: *WinglessOutput, bb_x: f32, bb_y: f32, bb_w: f32, bb_h: f32, screen_w: f32, screen_h: f32, scene_tex: *c.wlr_texture, _: f32, t1: f32, t2: f32, t3: f32, radius: f32, spread: f32, bright0: f32, bright1: f32, bright2: f32, bright3: f32, scale0: f32, scale1: f32, scale2: f32, scale3: f32) void {
    const prog = output.glass_blob_prog orelse return;

    var attribs: c.wlr_gles2_texture_attribs = undefined;
    c.wlr_gles2_texture_get_attribs(scene_tex, &attribs);

    gl.glUseProgram(prog.prog);
    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(attribs.target, attribs.tex);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(attribs.target, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
    gl.glUniform1i(prog.scene_loc, 0);
    gl.glUniform2f(prog.resolution_loc, screen_w, screen_h);

    // Convert button centers: Clay coords (y from top) → GL screen coords (y from bottom)
    const diag: f32 = 0.7071067811865476;
    const cy_gl = screen_h - bb_y - radius;
    const cx0 = bb_x + bb_w - radius;

    // Pack 4 active circles into slots 0-3; slots 4-7 inactive (scale=0)
    const centers = [16]f32{
        cx0,                          cy_gl,
        cx0 - spread * t1,            cy_gl + spread * 0.15 * t1,
        cx0 - spread * diag * t2,     cy_gl - spread * diag * t2,
        cx0 + spread * 0.15 * t3,     cy_gl - spread * t3,
        cx0, cy_gl, cx0, cy_gl, cx0, cy_gl, cx0, cy_gl,
    };
    const scales = [8]f32{ scale0, scale1, scale2, scale3, 0.0, 0.0, 0.0, 0.0 };
    const brights = [8]f32{ bright0, bright1, bright2, bright3, 0.0, 0.0, 0.0, 0.0 };

    gl.glUniform2fv(prog.centers_loc, 8, &centers[0]);
    gl.glUniform1fv(prog.scales_loc, 8, &scales[0]);
    gl.glUniform1fv(prog.brights_loc, 8, &brights[0]);
    gl.glUniform1f(prog.radius_loc, radius);
    gl.glUniform1f(prog.morph_k_loc, radius * 1.2 * @max(t1, @max(t2, t3)));

    const pad = 300.0 * ui.ui_scale;
    drawQuad(output, bb_x - pad, bb_y - pad, bb_w + pad * 2.0, bb_h + pad * 2.0, screen_w, screen_h, prog.pos_loc);
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
    gl.glUniform2f(output.glass_text.?.resolution_loc, screen_w, screen_h);

    const gx = x + g.x_off;
    const gy = y + g.y_off * scale + 0.2 * scale;

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
    const gy = y + g.y_off * scale + 0.1 * scale;

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

// Called during Pass 1 (scene_buffer), before drawing a window that has blur regions.
// Snapshots the current FBO (background + windows below this one) then draws the glass
// shader over each region using that snapshot — so the window draws on top of glass bg.
// Uses drawQuadScene (y=0=top) and passes quadPos without y-flip, unlike the UI-overlay
// drawGlassQuad which runs in Pass 2 where y=0=bottom.
pub fn drawWindowGlassRegions(output: *WinglessOutput, regions: []*glass_proto.BlurRegion, sx: f32, sy: f32, screen_w: f32, screen_h: f32) void {
    if (regions.len == 0) return;
    const glass = output.glass_background orelse return;

    const iw: c_int = @intFromFloat(screen_w);
    const ih: c_int = @intFromFloat(screen_h);

    // lazily create snapshot texture (holds a copy of the FBO before this window is drawn)
    if (output.blur_snapshot_tex == 0) {
        gl.glGenTextures(1, &output.blur_snapshot_tex);
        gl.glBindTexture(gl.GL_TEXTURE_2D, output.blur_snapshot_tex);
        gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGB, iw, ih, 0, gl.GL_RGB, gl.GL_UNSIGNED_BYTE, null);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
    }

    // snapshot: copy scene_buffer FBO (background + windows below this one) into snapshot texture
    gl.glBindTexture(gl.GL_TEXTURE_2D, output.blur_snapshot_tex);
    gl.glCopyTexSubImage2D(gl.GL_TEXTURE_2D, 0, 0, 0, 0, 0, iw, ih);

    gl.glUseProgram(glass.prog);
    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
    gl.glUniform1i(glass.scene_loc, 0);
    gl.glUniform2f(glass.resolution_loc, screen_w, screen_h);
    gl.glUniform1f(glass.fill_amount_loc, 0.0);
    gl.glUniform1i(glass.fill_direction_loc, 0);
    gl.glUniform1f(glass.brightness_loc, 0.0);

    gl.glEnable(c.GL_BLEND);
    gl.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

    for (regions) |region| {
        const r = region.current;
        if (r.width <= 0 or r.height <= 0) continue;
        const rx: f32 = sx + @as(f32, @floatFromInt(r.x));
        const ry: f32 = sy + @as(f32, @floatFromInt(r.y));
        const rw: f32 = @floatFromInt(r.width);
        const rh: f32 = @floatFromInt(r.height);
        // quadPos: top-left in scene_buffer fragCoord space (y=0=top, no flip needed)
        gl.glUniform2f(glass.quad_pos_loc, rx, ry);
        gl.glUniform2f(glass.size_loc, rw, rh);
        gl.glUniform1f(glass.roundness, @as(f32, @floatFromInt(r.radius)) * ui.ui_scale);
        gl.glUniform1f(glass.refraction_band_loc, @as(f32, @floatFromInt(r.radius)) * @as(f32, @floatFromInt(r.refraction_band)) / 100.0 * ui.ui_scale);
        gl.glUniform1f(glass.blur_amount_loc, @as(f32, @floatFromInt(r.blur_amount)) / 100.0);
        const glass_pad = 300 * ui.ui_scale;
        drawQuadScene(output, rx - glass_pad, ry - glass_pad, rw + glass_pad * 2, rh + glass_pad * 2, screen_w, screen_h, glass.pos_loc);
    }

    gl.glBindTexture(gl.GL_TEXTURE_2D, 0);
}

const ShadowEntry = struct { x: f32, y: f32, w: f32, h: f32, roundness: f32, intensity: f32 };

fn uploadShadowUniforms(prog: ui.ShadowProgram, entries: []const ShadowEntry, screen_h: f32, y_flip: bool) void {
    for (0..ui.MAX_SHADOW_COUNT) |i| {
        if (i < entries.len) {
            const e = entries[i];
            const qy: f32 = if (y_flip) screen_h - e.y - e.h else e.y;
            gl.glUniform2f(prog.pos_locs[i], e.x, qy);
            gl.glUniform2f(prog.size_locs[i], e.w, e.h);
            gl.glUniform1f(prog.roundness_locs[i], e.roundness);
            gl.glUniform1f(prog.intensity_locs[i], e.intensity);
        } else {
            gl.glUniform2f(prog.pos_locs[i], 0, 0);
            gl.glUniform2f(prog.size_locs[i], 0, 0);
            gl.glUniform1f(prog.roundness_locs[i], 0);
            gl.glUniform1f(prog.intensity_locs[i], 0);
        }
    }
}

// Scene-buffer-pass: single window shadow (no y-flip, padded quad)
fn drawWindowShadowScene(output: *WinglessOutput, x: f32, y: f32, w: f32, h: f32, screen_w: f32, screen_h: f32, roundness: f32, intensity: f32) void {
    const prog = output.shadow orelse return;
    gl.glUseProgram(prog.prog);
    gl.glUniform2f(prog.resolution_loc, screen_w, screen_h);
    uploadShadowUniforms(prog, &.{.{ .x = x, .y = y, .w = w, .h = h, .roundness = roundness, .intensity = intensity }}, screen_h, false);
    const pad: f32 = 200 * ui.ui_scale;
    drawQuadScene(output, x - pad, y - pad, w + pad * 2, h + pad * 2, screen_w, screen_h, prog.pos_loc);
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
    gl.glUniform2f(output.blur.?.resolution_loc, screen_w, screen_h);
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
    gl.glUniform2f(output.blur.?.resolution_loc, screen_w, screen_h);
    drawQuad(output, 0, 0, screen_w, screen_h, screen_w, screen_h, pos_loc);
}

// sx, sy, sw, sh: this surface's screen bounds (top-left origin)
// clip_x, clip_y, clip_w, clip_h: rounded clip rect (parent window for subsurfaces, self for main)
// with_decorations: draw shadow + border only for the main surface
pub fn drawWindowSurface(output: *WinglessOutput, tex: *c.wlr_texture, sx: f32, sy: f32, sw: f32, sh: f32, clip_x: f32, clip_y: f32, clip_w: f32, clip_h: f32, screen_w: f32, screen_h: f32, with_decorations: bool, is_focused: bool) void {
    const roundness: f32 = 20.0 * ui.ui_scale;

    gl.glEnable(c.GL_BLEND);
    gl.glBlendFunc(c.GL_SRC_ALPHA, c.GL_ONE_MINUS_SRC_ALPHA);

    if (with_decorations) {
        const intensity: f32 = 0.01 * @min(50.0, @min(clip_w, clip_h));
        drawWindowShadowScene(output, clip_x, clip_y, clip_w, clip_h, screen_w, screen_h, roundness, intensity);
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

    // Pass 0: all shadows in a single draw, below everything
    {
        var entries: [ui.MAX_SHADOW_COUNT]ShadowEntry = undefined;
        var count: usize = 0;

        for (render_cmds) |cmd| {
            if (count >= ui.MAX_SHADOW_COUNT) break;
            if (cmd.command_type != .custom) continue;
            const cd: *ui.CustomData = @ptrCast(@alignCast(cmd.render_data.custom.custom_data));
            const bb = cmd.bounding_box;
            switch (cd.*) {
                .glass => |g| {
                    const x, const y, const w, const h = if (g.animated) blk: {
                        const cx = bb.x + bb.width * 0.5;
                        const cy = bb.y + bb.height * 0.5;
                        break :blk .{ cx - bb.width * g.anim_scale * 0.5, cy - bb.height * g.anim_scale * 0.5, bb.width * g.anim_scale, bb.height * g.anim_scale };
                    } else .{ bb.x, bb.y, bb.width, bb.height };
                    entries[count] = .{ .x = x, .y = y, .w = w, .h = h, .roundness = g.roundness, .intensity = 0.01 * @min(0.5 * 100.0, @min(w, h)) };
                    count += 1;
                },
                .shadow => |sh| {
                    const x, const y, const w, const h = if (sh.animated) blk: {
                        const cx = bb.x + bb.width * 0.5;
                        const cy = bb.y + bb.height * 0.5;
                        break :blk .{ cx - bb.width * sh.anim_scale * 0.5, cy - bb.height * sh.anim_scale * 0.5, bb.width * sh.anim_scale, bb.height * sh.anim_scale };
                    } else .{ bb.x, bb.y, bb.width, bb.height };
                    entries[count] = .{ .x = x, .y = y, .w = w, .h = h, .roundness = sh.roundness, .intensity = sh.intensity };
                    count += 1;
                },
                .glass_blob => |pcb| {
                    const btn_size = pcb.radius * 2.0;
                    const shadow_intensity = 0.01 * @min(0.5 * 100.0, btn_size);
                    const diag: f32 = 0.7071067811865476;
                    // cx/cy in Clay coords: center button anchored to right edge
                    const cx0 = bb.x + bb.width - pcb.radius;
                    const cy0 = bb.y + pcb.radius;
                    if (count < ui.MAX_SHADOW_COUNT) {
                        entries[count] = .{ .x = cx0 - pcb.radius, .y = cy0 - pcb.radius, .w = btn_size, .h = btn_size, .roundness = pcb.radius, .intensity = shadow_intensity };
                        count += 1;
                    }
                    if (pcb.t1 > 0.02 and count < ui.MAX_SHADOW_COUNT) {
                        const cx1 = cx0 - pcb.spread * pcb.t1;
                        const cy1 = cy0 - pcb.spread * 0.15 * pcb.t1;
                        entries[count] = .{ .x = cx1 - pcb.radius, .y = cy1 - pcb.radius, .w = btn_size, .h = btn_size, .roundness = pcb.radius, .intensity = shadow_intensity * pcb.t1 };
                        count += 1;
                    }
                    if (pcb.t2 > 0.02 and count < ui.MAX_SHADOW_COUNT) {
                        const cx2 = cx0 - pcb.spread * diag * pcb.t2;
                        const cy2 = cy0 + pcb.spread * diag * pcb.t2;
                        entries[count] = .{ .x = cx2 - pcb.radius, .y = cy2 - pcb.radius, .w = btn_size, .h = btn_size, .roundness = pcb.radius, .intensity = shadow_intensity * pcb.t2 };
                        count += 1;
                    }
                    if (pcb.t3 > 0.02 and count < ui.MAX_SHADOW_COUNT) {
                        const cx3 = cx0 + pcb.spread * 0.15 * pcb.t3;
                        const cy3 = cy0 + pcb.spread * pcb.t3;
                        entries[count] = .{ .x = cx3 - pcb.radius, .y = cy3 - pcb.radius, .w = btn_size, .h = btn_size, .roundness = pcb.radius, .intensity = shadow_intensity * pcb.t3 };
                        count += 1;
                    }
                },
                else => {},
            }
        }

        if (count > 0) {
            if (ctx.output.shadow) |prog| {
                gl.glUseProgram(prog.prog);
                gl.glUniform2f(prog.resolution_loc, ctx.screen_width, ctx.screen_height);
                uploadShadowUniforms(prog, entries[0..count], ctx.screen_height, true);
                drawQuad(ctx.output, 0, 0, ctx.screen_width, ctx.screen_height, ctx.screen_width, ctx.screen_height, prog.pos_loc);
            }
        }
    }

    // Pass 1: glass backgrounds — all before any other content
    var ci: usize = 0;
    while (ci < render_cmds.len) : (ci += 1) {
        const cmd = render_cmds[ci];
        if (cmd.command_type != .custom) continue;
        const cd: *ui.CustomData = @ptrCast(@alignCast(cmd.render_data.custom.custom_data));
        const bb = cmd.bounding_box;
        switch (cd.*) {
            .glass => |g| {
                if (g.animated) {
                    const cx = bb.x + bb.width * 0.5;
                    const cy = bb.y + bb.height * 0.5;
                    const aw = bb.width * g.anim_scale;
                    const ah = bb.height * g.anim_scale;
                    drawGlassQuad(ctx.output, cx - aw * 0.5, cy - ah * 0.5, aw, ah, ctx.screen_width, ctx.screen_height, ctx.scene_tex, g.roundness, g.fill_amount, g.fill_dir, g.refraction_band, g.brightness);
                } else {
                    drawGlassQuad(ctx.output, bb.x, bb.y, bb.width, bb.height, ctx.screen_width, ctx.screen_height, ctx.scene_tex, g.roundness, g.fill_amount, g.fill_dir, g.refraction_band, g.brightness);
                }
            },
            .glass_blob => |pcb| {
                drawBlobQuad(ctx.output, bb.x, bb.y, bb.width, bb.height, ctx.screen_width, ctx.screen_height, ctx.scene_tex, pcb.t, pcb.t1, pcb.t2, pcb.t3, pcb.radius, pcb.spread, pcb.bright0, pcb.bright1, pcb.bright2, pcb.bright3, pcb.scale0, pcb.scale1, pcb.scale2, pcb.scale3);
            },
            else => {},
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
                                gl.glUniform1f(id.output.image.?.roundness_loc, 12.0 * ui.ui_scale);
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
                    .rect => |rc| {
                        const rf = ctx.output.round_fill.?;
                        gl.glUseProgram(rf.prog);
                        gl.glUniform4f(rf.color_loc, rc.r, rc.g, rc.b, rc.a);
                        gl.glUniform2f(rf.quad_pos_loc, bb.x, ctx.screen_height - bb.y - bb.height);
                        gl.glUniform2f(rf.size_loc, bb.width, bb.height);
                        gl.glUniform1f(rf.roundness_loc, rc.roundness);
                        gl.glUniform2f(rf.resolution_loc, ctx.screen_width, ctx.screen_height);
                        drawQuad(ctx.output, bb.x, bb.y, bb.width, bb.height, ctx.screen_width, ctx.screen_height, rf.pos_loc);
                    },
                    .spinner => |sp| {
                        const spn = ctx.output.spinner.?;
                        gl.glUseProgram(spn.prog);
                        gl.glUniform4f(spn.color_loc, 1.0, 1.0, 1.0, 1.0);
                        gl.glUniform2f(spn.quad_pos_loc, bb.x, ctx.screen_height - bb.y - bb.height);
                        gl.glUniform2f(spn.size_loc, bb.width, bb.height);
                        gl.glUniform2f(spn.resolution_loc, ctx.screen_width, ctx.screen_height);
                        gl.glUniform1f(spn.time_loc, sp.time);
                        drawQuad(ctx.output, bb.x, bb.y, bb.width, bb.height, ctx.screen_width, ctx.screen_height, spn.pos_loc);
                    },
                    .shadow => {}, // handled in Pass 0
                    .glass_blob => {}, // handled in Pass 1
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
