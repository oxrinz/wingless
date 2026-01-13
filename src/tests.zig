const std = @import("std");
const c = @import("c.zig").c;
const main = @import("main.zig");

const WinglessServer = main.WinglessServer;

pub fn testPump(server: *WinglessServer, client: *c.wl_display) void {
    _ = c.wl_display_flush(client);

    _ = c.wl_event_loop_dispatch(c.wl_display_get_event_loop(server.display), 0);

    _ = c.wl_display_flush_clients(server.display);

    if (c.wl_display_prepare_read(client) == 0) {
        _ = c.wl_display_read_events(client);
    }

    _ = c.wl_display_dispatch_pending(client);
}

pub const TestContext = struct {
    compositor: *c.wl_compositor,
    wm_base: *c.xdg_wm_base,
    seat: *c.wl_seat,
};

fn cb(
    data: ?*anyopaque,
    registry: ?*c.wl_registry,
    name: u32,
    iface: [*c]const u8,
    version: u32,
) callconv(.c) void {
    _ = version;
    const ctx_ptr: **TestContext = @ptrCast(@alignCast(data.?));

    const iface_name = std.mem.span(iface);

    if (std.mem.eql(u8, iface_name, "wl_seat")) {
        ctx_ptr.*.seat = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, 1).?);
    } else if (std.mem.eql(u8, iface_name, "wl_compositor")) {
        ctx_ptr.*.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, 1).?);
    } else if (std.mem.eql(u8, iface_name, "xdg_wm_base")) {
        ctx_ptr.*.wm_base = @ptrCast(c.wl_registry_bind(registry, name, &c.xdg_wm_base_interface, 1).?);
    }
}

pub const registry_listener = c.wl_registry_listener{
    .global = cb,
    .global_remove = null,
};

pub fn getTestContext(allocator: std.mem.Allocator, client: *c.wl_display, server: *WinglessServer) !*TestContext {
    const registry = c.wl_display_get_registry(client);

    var ctx: *TestContext = try allocator.create(TestContext);

    _ = c.wl_registry_add_listener(registry, &registry_listener, @ptrCast(&ctx));
    testPump(server, client);

    return ctx;
}

pub const TestKeyboard = struct {
    last_key_id: ?u32 = null,

    pub fn key(
        data: ?*anyopaque,
        keyboard: ?*c.wl_keyboard,
        serial: u32,
        time: u32,
        key_id: u32,
        state: u32,
    ) callconv(.c) void {
        _ = keyboard;
        _ = serial;
        _ = time;
        _ = state;

        std.debug.print("KEY FIRED\n", .{});

        const self: *TestKeyboard = @ptrCast(@alignCast(data.?));
        self.last_key_id = key_id;
    }
};
