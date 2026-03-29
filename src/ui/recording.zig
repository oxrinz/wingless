const std = @import("std");
const gl = @import("../c.zig").gl;
const ui = @import("../ui.zig");

const State = enum { idle, recording };
var state: State = .idle;

// screen dimensions when recording started
var rec_w: c_int = 0;
var rec_h: c_int = 0;

// region in screen coords (y=0 at top); zero means fullscreen
var reg_x: c_int = 0;
var reg_y: c_int = 0;
var reg_w: c_int = 0;
var reg_h: c_int = 0;
var is_region: bool = false;

// full-screen pixel buffer (RGBA, GL order: row 0 = bottom)
var frame_buf: []u8 = &.{};

// ffmpeg child process
var ffmpeg_child: ?std.process.Child = null;

// worker thread state
var worker_thread: ?std.Thread = null;
var worker_mutex: std.Thread.Mutex = .{};
var worker_cond: std.Thread.Condition = .{};
var pending_buf: []u8 = &.{}; // pending frame to write (alloc'd, owned by main)
var pending_w: c_int = 0;
var pending_h: c_int = 0;
var pending_ready: bool = false;
var worker_stop: bool = false;

pub fn isRecording() bool {
    return state == .recording;
}

pub fn startFullscreen(w: c_int, h: c_int) void {
    startImpl(w, h, 0, 0, 0, 0, false);
}

pub fn startRegion(w: c_int, h: c_int, rx: c_int, ry: c_int, rw: c_int, rh: c_int) void {
    startImpl(w, h, rx, ry, rw, rh, true);
}

fn startImpl(w: c_int, h: c_int, rx: c_int, ry: c_int, rw: c_int, rh: c_int, region: bool) void {
    if (state != .idle) return;

    rec_w = w;
    rec_h = h;
    is_region = region;
    reg_x = rx;
    reg_y = ry;
    // round to even so they match the even-clamped ffmpeg video_size
    reg_w = rw & ~@as(c_int, 1);
    reg_h = rh & ~@as(c_int, 1);

    // H.264 requires even dimensions — round down
    const out_w: c_int = ((if (region) rw else w)) & ~@as(c_int, 1);
    const out_h: c_int = ((if (region) rh else h)) & ~@as(c_int, 1);

    // allocate full-screen read buffer
    const pixel_count: usize = @intCast(w * h * 4);
    frame_buf = std.heap.page_allocator.alloc(u8, pixel_count) catch return;

    // build output path: $HOME/wingless-TIMESTAMP.mp4
    const home = std.process.getEnvVarOwned(std.heap.page_allocator, "HOME") catch "/tmp";
    defer std.heap.page_allocator.free(home);

    const ts = std.time.timestamp();
    const out_path = std.fmt.allocPrint(std.heap.page_allocator, "{s}/wingless-{d}.mp4", .{ home, ts }) catch {
        std.heap.page_allocator.free(frame_buf);
        frame_buf = &.{};
        return;
    };
    defer std.heap.page_allocator.free(out_path);

    var size_buf: [32]u8 = undefined;
    const size_str = std.fmt.bufPrint(&size_buf, "{d}x{d}", .{ out_w, out_h }) catch return;

    var fps_buf: [16]u8 = undefined;
    const fps_str = std.fmt.bufPrint(&fps_buf, "{d}", .{ui.output_refresh_hz}) catch return;

    var child = std.process.Child.init(
        &[_][]const u8{
            "ffmpeg", "-y",
            "-f",            "rawvideo",
            "-pixel_format", "rgba",
            "-video_size",   size_str,
            "-framerate",    fps_str,
            "-i",            "pipe:0",
            "-c:v",          "libx264",
            "-preset",       "ultrafast",
            "-pix_fmt",      "yuv420p",
            out_path,
        },
        std.heap.page_allocator,
    );
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    child.spawn() catch {
        std.heap.page_allocator.free(frame_buf);
        frame_buf = &.{};
        return;
    };
    ffmpeg_child = child;

    // start writer worker
    worker_stop = false;
    pending_ready = false;
    worker_thread = std.Thread.spawn(.{}, workerFn, .{}) catch {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        ffmpeg_child = null;
        std.heap.page_allocator.free(frame_buf);
        frame_buf = &.{};
        return;
    };

    state = .recording;
}

pub fn stop() void {
    if (state != .recording) return;
    state = .idle;

    // signal worker to stop
    {
        worker_mutex.lock();
        defer worker_mutex.unlock();
        worker_stop = true;
        worker_cond.signal();
    }
    if (worker_thread) |t| {
        t.join();
        worker_thread = null;
    }

    // close ffmpeg stdin and wait
    if (ffmpeg_child) |*ch| {
        if (ch.stdin) |stdin| {
            stdin.close();
            ch.stdin = null;
        }
        _ = ch.wait() catch {};
        ffmpeg_child = null;
    }

    // free pending buf if any
    if (pending_buf.len > 0) {
        std.heap.page_allocator.free(pending_buf);
        pending_buf = &.{};
    }

    if (frame_buf.len > 0) {
        std.heap.page_allocator.free(frame_buf);
        frame_buf = &.{};
    }
}

fn workerFn() void {
    while (true) {
        var local_buf: []u8 = &.{};
        var local_w: c_int = 0;
        var local_h: c_int = 0;

        {
            worker_mutex.lock();
            defer worker_mutex.unlock();
            while (!pending_ready and !worker_stop) {
                worker_cond.wait(&worker_mutex);
            }
            if (worker_stop and !pending_ready) return;
            local_buf = pending_buf;
            local_w = pending_w;
            local_h = pending_h;
            pending_buf = &.{};
            pending_ready = false;
        }

        defer std.heap.page_allocator.free(local_buf);

        const ch = &(ffmpeg_child orelse continue);
        const stdin = ch.stdin orelse continue;

        // write rows one at a time to handle striding for region crops
        const row_bytes: usize = @intCast(local_w * 4);
        var row: usize = 0;
        while (row < @as(usize, @intCast(local_h))) : (row += 1) {
            const off = row * row_bytes;
            stdin.writeAll(local_buf[off .. off + row_bytes]) catch {
                break;
            };
        }
    }
}

pub fn onFrame(w: c_int, h: c_int) void {
    if (state != .recording) return;
    if (frame_buf.len == 0) return;

    // dimensions changed mid-recording — stop cleanly
    if (w != rec_w or h != rec_h) {
        stop();
        return;
    }

    // read full framebuffer (GL row 0 = bottom of screen)
    gl.glReadPixels(0, 0, w, h, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, frame_buf.ptr);

    // build the frame that will be sent to ffmpeg
    // for fullscreen: the whole buffer; for region: crop out the rows/columns
    const out_w: c_int = if (is_region) reg_w else w;
    const out_h: c_int = if (is_region) reg_h else h;
    const out_bytes: usize = @intCast(out_w * out_h * 4);

    const send_buf = std.heap.page_allocator.alloc(u8, out_bytes) catch return;

    if (!is_region) {
        @memcpy(send_buf, frame_buf);
    } else {
        // glReadPixels returns the framebuffer top-to-bottom (row 0 = screen top).
        // Region in screen coords: rows [reg_y, reg_y + reg_h).
        var dst_off: usize = 0;
        var row: c_int = reg_y;
        while (row < reg_y + reg_h) : (row += 1) {
            if (row < 0 or row >= h) {
                dst_off += @intCast(reg_w * 4);
                continue;
            }
            const src_off: usize = @intCast(row * w * 4 + reg_x * 4);
            const copy_bytes: usize = @intCast(reg_w * 4);
            @memcpy(send_buf[dst_off .. dst_off + copy_bytes], frame_buf[src_off .. src_off + copy_bytes]);
            dst_off += copy_bytes;
        }
    }

    // hand off to worker, drop frame if worker is still busy
    worker_mutex.lock();
    defer worker_mutex.unlock();
    if (pending_ready) {
        // worker hasn't consumed last frame yet — drop this one
        std.heap.page_allocator.free(send_buf);
        return;
    }
    if (pending_buf.len > 0) std.heap.page_allocator.free(pending_buf);
    pending_buf = send_buf;
    pending_w = out_w;
    pending_h = out_h;
    pending_ready = true;
    worker_cond.signal();
}
