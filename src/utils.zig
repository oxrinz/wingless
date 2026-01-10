const std = @import("std");

const c = @import("c.zig").c;

pub fn createListener(allocator: *std.mem.Allocator, notify: *const fn (listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void) !*c.wl_listener {
    const listener = try allocator.create(c.wl_listener);

    listener.* = .{
        .link = undefined,
        .notify = notify,
    };

    return listener;
}
