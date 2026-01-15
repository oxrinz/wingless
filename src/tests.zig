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
    shm: *c.wl_shm,
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
        ctx_ptr.*.compositor = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, 4).?);
    } else if (std.mem.eql(u8, iface_name, "xdg_wm_base")) {
        ctx_ptr.*.wm_base = @ptrCast(c.wl_registry_bind(registry, name, &c.xdg_wm_base_interface, 1).?);
    } else if (std.mem.eql(u8, iface_name, "wl_shm")) {
        ctx_ptr.*.shm = @ptrCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1).?);
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

pub const XdgSurfaceState = struct {
    configure_serial: u32 = 0,
};

fn xdg_surface_configure(
    data: ?*anyopaque,
    xdg_surface: ?*c.xdg_surface,
    serial: u32,
) callconv(.c) void {
    _ = xdg_surface;
    const state: *XdgSurfaceState = @ptrCast(@alignCast(data.?));
    state.configure_serial = serial;
}

pub const xdg_surface_listener = c.xdg_surface_listener{
    .configure = xdg_surface_configure,
};

pub fn createSurface(server: *WinglessServer, ctx: *TestContext, client: *c.wl_display) !void {
    const surface = c.wl_compositor_create_surface(ctx.compositor);
    const xdg_surface = c.xdg_wm_base_get_xdg_surface(ctx.wm_base, surface);
    _ = c.xdg_surface_get_toplevel(xdg_surface);

    var state = XdgSurfaceState{};
    _ = c.xdg_surface_add_listener(xdg_surface, &xdg_surface_listener, &state);

    c.wl_surface_commit(surface);
    testPump(server, client);

    c.xdg_surface_ack_configure(xdg_surface, state.configure_serial);

    // buffer attatchment
    const width = 1;
    const height = 1;
    const stride = width * 4;
    const size = stride * height;

    var file = try std.fs.cwd().createFile(
        ".wingless-test-shm",
        .{ .read = true, .truncate = true },
    );
    defer file.close();

    try file.setEndPos(size);

    const pool = c.wl_shm_create_pool(ctx.shm, file.handle, size);
    const buffer = c.wl_shm_pool_create_buffer(
        pool,
        0,
        width,
        height,
        stride,
        c.WL_SHM_FORMAT_XRGB8888,
    );

    c.wl_surface_attach(surface, buffer, 0, 0);
    c.wl_surface_damage_buffer(surface, 0, 0, width, height);

    c.wl_surface_commit(surface);

    testPump(server, client);
}
