const std = @import("std");

const main = @import("main.zig");
const WinglessServer = main.WinglessServer;
const c = @import("c.zig").c;

pub fn create_beacon(server: *WinglessServer) void {
    if (server.beacon_tree != null) return;

    const width: u32 = 400;
    const height: u32 = 200;

    const tree: *c.wlr_scene_tree = c.wlr_scene_tree_create(&server.scene.tree).?;

    var mods = [_]u64{
        c.DRM_FORMAT_MOD_NONE,
        c.DRM_FORMAT_MOD_NONE,
    };

    var fmt: c.wlr_drm_format = .{
        .format = c.DRM_FORMAT_ARGB8888,
        .len = mods.len,
        .capacity = mods.len,
        .modifiers = &mods,
    };

    const buf = c.wlr_allocator_create_buffer(server.wlr_allocator, width, height, &fmt) orelse @panic("buffer allocation failed");

    var data: ?*anyopaque = null;
    var stride: usize = 0;
    var format: u32 = 0;

    // std.debug.print("renderer: {any}\n", .{c.wlr_renderer_get_

    if (!c.wlr_buffer_begin_data_ptr_access(buf, c.WLR_BUFFER_DATA_PTR_ACCESS_WRITE, &data, &format, &stride)) @panic("buffer not cpu-mappable");
    defer c.wlr_buffer_end_data_ptr_access(buf);

    const bytes: [*]u8 = @ptrCast(data.?);

    for (0..@intCast(height)) |y| {
        const row = @as([*]u32, @ptrCast(@alignCast(bytes + y * stride)));
        for (0..@intCast(width)) |x| {
            row[x] = 0xE0202020;
        }
    }

    const scene_buf = c.wlr_scene_buffer_create(tree, buf);

    c.wlr_scene_node_set_position(&tree.node, 200, 200);
    c.wlr_scene_node_raise_to_top(&tree.node);

    server.beacon_tree = tree;
    server.beacon_scene_buffer = scene_buf;
    server.beacon_buffer = buf;
}
