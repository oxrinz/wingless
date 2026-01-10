const std = @import("std");

const utils = @import("utils.zig");

const c = @import("c.zig").c;

var allocator = std.heap.page_allocator;

const WinglessServer = struct {
    display: *c.wl_display = undefined,
    backend: *c.wlr_backend = undefined,
    renderer: *c.wlr_renderer = undefined,
    wlr_allocator: *c.wlr_allocator = undefined,

    scene: *c.wlr_scene = undefined,
    scene_layout: *c.wlr_scene_output_layout = undefined,

    output_layout: *c.wlr_output_layout = undefined,
    outputs: c.wl_list = undefined,
    new_output: c.wl_listener = undefined,

    xdg_shell: *c.wlr_xdg_shell = undefined,

    keyboards: c.wl_list = undefined,
    new_input: c.wl_listener = undefined,
    seat: *c.wlr_seat = undefined,

    allocator: std.mem.Allocator = undefined,

    pub fn init() !*WinglessServer {
        var server = try allocator.create(WinglessServer);
        server.* = .{};
        server.display = c.wl_display_create() orelse return error.DispayCreationFailed;
        server.backend = c.wlr_backend_autocreate(c.wl_display_get_event_loop(server.display), null);
        server.renderer = c.wlr_renderer_autocreate(server.backend);
        server.wlr_allocator = c.wlr_allocator_autocreate(server.backend, server.renderer);

        _ = c.wlr_compositor_create(server.display, 5, server.renderer);
        _ = c.wlr_data_device_manager_create(server.display);

        server.output_layout = c.wlr_output_layout_create(server.display);

        c.wl_list_init(&server.outputs);
        server.new_output = .{ .link = undefined, .notify = server_new_output };
        // c.wl_signal_add(&server.backend.*.events.new_output, &server.new_output);

        server.scene = c.wlr_scene_create();
        server.scene_layout = c.wlr_scene_attach_output_layout(server.scene, server.output_layout) orelse return error.SceneCreationFailed;

        // var toplevels: c.wl_list = undefined;
        // c.wl_list_init(&toplevels);
        // const xdg_shell = c.wlr_xdg_shell_create(display, 3);
        // TODO: add xdg toplevel / popup listeners
        // const new_xdg_toplevel: c.wl_listener = .{ .link = undefined, .notify = server_new_xdg_toplevel };

        // TODO: add cursor here

        c.wl_list_init(&server.keyboards);
        server.new_input = .{ .link = undefined, .notify = server_new_input };
        c.wl_signal_add(&server.backend.*.events.new_input, &server.new_input);
        server.seat = c.wlr_seat_create(server.display, "seat0");

        server.allocator = allocator;

        return server;
    }

    pub fn deinit(self: *WinglessServer) !void {
        std.debug.print("DEINIT\n", .{});

        //c.wl_list_remove(&self.new_input.link);
        //c.wl_list_remove(&self.new_output.link);

        c.wlr_allocator_destroy(self.wlr_allocator);
        c.wlr_renderer_destroy(self.renderer);
        c.wlr_backend_destroy(self.backend);
        c.wl_display_destroy(self.display);
    }
};

const WinglessKeyboard = struct {
    link: *c.wl_list,
    server: *WinglessServer,
    wlr_keyboard: *c.wlr_keyboard,

    modifiers: *c.wl_listener,
    key: *c.wl_listener,
    destroy: *c.wl_listener,

    pub fn init(server: *WinglessServer, device: *c.wlr_input_device) !*WinglessKeyboard {
        std.debug.print("check 1, alloc: {any}\n", .{allocator});
        const keyboard = try server.allocator.create(WinglessKeyboard);

        var link: c.wl_list = undefined;
        c.wl_list_init(@ptrCast(@constCast(&link)));

        std.debug.print("check 1", .{});

        keyboard.* = .{
            .link = &link,
            .server = server,
            .wlr_keyboard = c.wlr_keyboard_from_input_device(device),

            .modifiers = try utils.createListener(&server.allocator, keyboard_handle_modifiers),
            .key = try utils.createListener(&server.allocator, keyboard_handle_key),
            .destroy = try utils.createListener(&server.allocator, keyboard_handle_destroy),
        };

        return keyboard;
    }
};

fn keyboard_handle_modifiers(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = listener;
    _ = data;
}

fn keyboard_handle_key(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = listener;
    _ = data;
}

fn keyboard_handle_destroy(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = listener;
    _ = data;
}

fn server_new_input(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    std.debug.print("FOUND NEW INPUT\n", .{});

    const server: *WinglessServer = @ptrCast(@as(*allowzero WinglessServer, @fieldParentPtr("new_output", listener)));
    const device: *c.wlr_input_device = @ptrCast(@alignCast(data.?));

    std.debug.print("alloc: {any}\n", .{server.allocator});

    switch (device.type) {
        c.WLR_INPUT_DEVICE_KEYBOARD => {
            const keyboard = WinglessKeyboard.init(server, device) catch @panic("Failed to create keyboard");
            _ = keyboard;
        },
        else => std.debug.print("unrecognized new input\n", .{}),
    }

    std.debug.print("new INPUT FOUND!!: {any}\n", .{device});
}

fn server_new_output(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    std.debug.print("FOUND NEW OUTPUT\n", .{});
    const server: *WinglessServer = @ptrCast(@as(*allowzero WinglessServer, @fieldParentPtr("new_output", listener)));

    std.debug.print("new OUTPUT FOUND!!: {any}\n", .{server});
}

pub fn main() !void {
    c.wlr_log_init(c.WLR_DEBUG, null);

    var server = try WinglessServer.init();

    const socket = c.wl_display_add_socket_auto(server.display);
    _ = c.wlr_backend_start(server.backend);
    _ = c.setenv("WAYLAND_DISPLAY", socket, 1);
    c._wlr_log(c.WLR_INFO, "Running wayland compositor on");
    // c.wl_display_run(server.display);

    try server.deinit();
}
