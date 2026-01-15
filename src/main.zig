const std = @import("std");

const config = @import("config.zig");
const utils = @import("utils.zig");
const tests = @import("tests.zig");

const c = @import("c.zig").c;

pub const WinglessServer = struct {
    display: *c.wl_display = undefined,
    backend: *c.wlr_backend = undefined,
    renderer: *c.wlr_renderer = undefined,
    wlr_allocator: *c.wlr_allocator = undefined,

    scene: *c.wlr_scene = undefined,
    scene_layout: *c.wlr_scene_output_layout = undefined,

    output_layout: *c.wlr_output_layout = undefined,
    outputs: c.wl_list = undefined,
    new_output: c.wl_listener = undefined,

    on_client: c.wl_listener = undefined,

    xdg_shell: *c.wlr_xdg_shell = undefined,
    new_xdg_surface: c.wl_listener = undefined,
    new_xdg_toplevel: c.wl_listener = undefined,
    new_xdg_popup: c.wl_listener = undefined,
    focused_toplevel: ?*WinglessToplevel = null,

    cursor: *c.wlr_cursor = undefined,
    cursor_mgr: *c.wlr_xcursor_manager = undefined,
    cursor_motion: c.wl_listener = undefined,
    cursor_motion_absolute: c.wl_listener = undefined,
    cursor_button: c.wl_listener = undefined,
    cursor_axis: c.wl_listener = undefined,
    cursor_frame: c.wl_listener = undefined,

    keyboards: c.wl_list = undefined,
    new_input: c.wl_listener = undefined,
    seat: *c.wlr_seat = undefined,

    wingless_config: config.WinglessConfig = undefined,

    allocator: std.mem.Allocator = undefined,

    pub fn init(conf: config.WinglessConfig) !*WinglessServer {
        var allocator = std.heap.page_allocator;

        var server = try allocator.create(WinglessServer);
        server.* = .{};
        server.display = c.wl_display_create() orelse return error.DispayCreationFailed;
        server.backend = c.wlr_backend_autocreate(c.wl_display_get_event_loop(server.display), null);
        server.renderer = c.wlr_renderer_autocreate(server.backend);
        server.wlr_allocator = c.wlr_allocator_autocreate(server.backend, server.renderer);

        _ = c.wlr_renderer_init_wl_display(server.renderer, server.display);

        _ = c.wlr_compositor_create(server.display, 5, server.renderer);
        _ = c.wlr_subcompositor_create(server.display);
        _ = c.wlr_data_device_manager_create(server.display);

        server.output_layout = c.wlr_output_layout_create(server.display);

        c.wl_list_init(&server.outputs);
        server.new_output = .{ .link = undefined, .notify = server_new_output };
        c.wl_signal_add(&server.backend.*.events.new_output, &server.new_output);

        server.scene = c.wlr_scene_create();
        server.scene_layout = c.wlr_scene_attach_output_layout(server.scene, server.output_layout) orelse return error.SceneCreationFailed;

        server.xdg_shell = c.wlr_xdg_shell_create(server.display, 3) orelse @panic("Failed to create xdgshell");

        server.new_xdg_toplevel = .{ .link = undefined, .notify = server_new_xdg_toplevel };
        server.new_xdg_popup = .{ .link = undefined, .notify = server_new_xdg_popup };
        server.new_xdg_surface = .{ .link = undefined, .notify = server_new_xdg_surface };
        c.wl_signal_add(&server.xdg_shell.events.new_surface, &server.new_xdg_surface);
        c.wl_signal_add(&server.xdg_shell.events.new_toplevel, &server.new_xdg_toplevel);
        c.wl_signal_add(&server.xdg_shell.events.new_popup, &server.new_xdg_popup);

        server.cursor = c.wlr_cursor_create();
        c.wlr_cursor_attach_output_layout(server.cursor, server.output_layout);
        server.cursor_mgr = c.wlr_xcursor_manager_create(null, 24);

        c.wlr_cursor_set_xcursor(server.cursor, server.cursor_mgr, "default");

        server.cursor_motion = .{ .link = undefined, .notify = server_cursor_motion };

        server.cursor_motion_absolute = .{ .link = undefined, .notify = server_cursor_motion_absolute };
        server.cursor_button = .{ .link = undefined, .notify = server_cursor_button };
        server.cursor_axis = .{ .link = undefined, .notify = server_cursor_axis };
        server.cursor_frame = .{ .link = undefined, .notify = server_cursor_frame };

        c.wl_signal_add(&server.cursor.events.motion, &server.cursor_motion);
        c.wl_signal_add(&server.cursor.events.motion_absolute, &server.cursor_motion_absolute);
        c.wl_signal_add(&server.cursor.events.button, &server.cursor_button);
        c.wl_signal_add(&server.cursor.events.axis, &server.cursor_axis);
        c.wl_signal_add(&server.cursor.events.frame, &server.cursor_frame);

        server.on_client = .{ .link = undefined, .notify = on_client };
        c.wl_display_add_client_created_listener(server.display, &server.on_client);

        c.wl_list_init(&server.keyboards);
        server.new_input = .{ .link = undefined, .notify = server_new_input };
        c.wl_signal_add(&server.backend.*.events.new_input, &server.new_input);
        server.seat = c.wlr_seat_create(server.display, "seat0");

        server.wingless_config = conf;

        server.allocator = allocator;

        return server;
    }

    pub fn deinit(self: *WinglessServer) void {
        c.wl_list_remove(&self.new_xdg_toplevel.link);
        c.wl_list_remove(&self.new_xdg_popup.link);
        c.wl_list_remove(&self.new_xdg_surface.link);

        c.wl_list_remove(&self.cursor_motion.link);
        c.wl_list_remove(&self.cursor_motion_absolute.link);
        c.wl_list_remove(&self.cursor_button.link);
        c.wl_list_remove(&self.cursor_axis.link);
        c.wl_list_remove(&self.cursor_frame.link);

        c.wl_list_remove(&self.new_input.link);
        c.wl_list_remove(&self.new_output.link);

        c.wlr_scene_node_destroy(&self.scene.tree.node);
        c.wlr_xcursor_manager_destroy(self.cursor_mgr);
        c.wlr_cursor_destroy(self.cursor);
        c.wlr_allocator_destroy(self.wlr_allocator);
        c.wlr_renderer_destroy(self.renderer);
        c.wlr_backend_destroy(self.backend);
        c.wl_display_destroy(self.display);
    }
};

const WinglessKeyboard = struct {
    link: c.wl_list,
    server: *WinglessServer,
    wlr_keyboard: *c.wlr_keyboard,

    modifiers: c.wl_listener,
    key: c.wl_listener,
    destroy: c.wl_listener,

    pub fn init(server: *WinglessServer, device: *c.wlr_input_device) !*WinglessKeyboard {
        const keyboard = try server.allocator.create(WinglessKeyboard);

        keyboard.* = .{
            .link = undefined,
            .server = server,
            .wlr_keyboard = c.wlr_keyboard_from_input_device(device),

            .modifiers = .{ .link = undefined, .notify = keyboard_handle_modifiers },
            .key = .{ .link = undefined, .notify = keyboard_handle_key },
            .destroy = .{ .link = undefined, .notify = keyboard_handle_destroy },
        };

        c.wl_list_init(@ptrCast(@constCast(&keyboard.link)));

        return keyboard;
    }
};

const WinglessOutput = struct {
    link: c.wl_list,
    server: *WinglessServer,
    output: *c.wlr_output,
    frame: c.wl_listener,
    request_state: c.wl_listener,
    destroy: c.wl_listener,

    pub fn init(server: *WinglessServer, wlr_output: *c.wlr_output) !*WinglessOutput {
        const output = try server.allocator.create(WinglessOutput);

        output.* = .{
            .link = undefined,
            .server = server,
            .output = wlr_output,
            .frame = .{ .link = undefined, .notify = output_frame },
            .request_state = .{ .link = undefined, .notify = output_request_state },
            .destroy = .{ .link = undefined, .notify = output_destroy },
        };

        c.wl_list_init(@ptrCast(@constCast(&output.link)));

        return output;
    }

    pub fn deinit(self: *WinglessOutput) void {
        c.wl_list_remove(&self.frame.link);
        c.wl_list_remove(&self.request_state.link);
        c.wl_list_remove(&self.destroy.link);
        c.wl_list_remove(&self.link);
    }
};

const WinglessToplevel = struct {
    prev: *WinglessToplevel,
    next: *WinglessToplevel,

    server: *WinglessServer,
    xdg_toplevel: *c.wlr_xdg_toplevel,
    scene_tree: *c.wlr_scene_tree,

    map: c.wl_listener,
    unmap: c.wl_listener,
    commit: c.wl_listener,
    destroy: c.wl_listener,

    pub fn init(server: *WinglessServer, xdg_toplevel: *c.wlr_xdg_toplevel) !*WinglessToplevel {
        const toplevel = try server.allocator.create(WinglessToplevel);

        toplevel.* = .{
            .prev = toplevel,
            .next = toplevel,

            .server = server,
            .xdg_toplevel = xdg_toplevel,
            .scene_tree = c.wlr_scene_xdg_surface_create(&server.scene.tree, xdg_toplevel.base),

            .map = .{ .link = undefined, .notify = xdg_toplevel_map },
            .unmap = undefined,
            .commit = .{ .link = undefined, .notify = xdg_toplevel_commit },
            .destroy = .{ .link = undefined, .notify = xdg_toplevel_destroy },
        };

        {
            const xdg_surface: *c.wlr_xdg_surface = toplevel.xdg_toplevel.base;
            const surface: *c.wlr_surface = @ptrCast(xdg_surface.surface);

            c.wl_signal_add(&surface.events.map, &toplevel.map);
            c.wl_signal_add(&surface.events.commit, &toplevel.commit);
            c.wl_signal_add(&surface.events.destroy, &toplevel.destroy);
        }

        toplevel.scene_tree.node.data = toplevel;
        const surface: *c.wlr_xdg_surface = xdg_toplevel.base;
        surface.data = toplevel.scene_tree;

        return toplevel;
    }

    pub fn insert(self: *WinglessToplevel) void {
        if (self.server.focused_toplevel) |f| {
            f.prev.next = self;
            self.prev = f.prev;
            self.next = f;
            f.prev = self;
        }
    }

    pub fn remove(self: *WinglessToplevel) void {
        const server = self.server;

        if (self.next == self) server.focused_toplevel = null else {
            self.prev.next = self.next;
            self.next.prev = self.prev;
        }

        self.next = self;
        self.prev = self;
    }

    pub fn deinit(self: *WinglessToplevel) void {
        self.remove();
        c.wl_list_remove(&self.map.link);
        // c.wl_list_remove(&self.unmap.link);
        c.wl_list_remove(&self.commit.link);
        c.wl_list_remove(&self.destroy.link);
    }
};

fn on_client(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = listener;
    _ = data;
}

fn tab_next(server: *WinglessServer) void {
    if (server.focused_toplevel == null) return;

    const toplevel = server.focused_toplevel.?.next;

    focus_toplevel(toplevel);
}

fn tab_prev(server: *WinglessServer) void {
    if (server.focused_toplevel == null) return;

    const toplevel = server.focused_toplevel.?.prev;

    focus_toplevel(toplevel);
}

fn focus_toplevel(toplevel: *WinglessToplevel) void {
    const server = toplevel.server;

    const seat = server.seat;

    std.debug.print("focusing: {any}\n", .{server.focused_toplevel});
    if (server.focused_toplevel != null and server.focused_toplevel.? == toplevel) return;
    server.focused_toplevel = toplevel;

    std.debug.print("focus toplevel: {any}\n", .{@intFromPtr(toplevel)});
    std.debug.print("focus server: {any}\n", .{@intFromPtr(server)});
    std.debug.print("focus toplevel server: {any}\n", .{@intFromPtr(server)});

    std.debug.print("seat kb state: {any}\n", .{seat});

    if (seat.keyboard_state.focused_surface != null) {
        const prev = c.wlr_xdg_toplevel_try_from_wlr_surface(seat.keyboard_state.focused_surface);
        _ = if (prev != null) c.wlr_xdg_toplevel_set_activated(prev, false);
    }

    c.wlr_scene_node_raise_to_top(&toplevel.scene_tree.node);
    _ = c.wlr_xdg_toplevel_set_activated(toplevel.xdg_toplevel, false);

    if (c.wlr_seat_get_keyboard(seat)) |kbd| {
        const wlr_kbd: *c.wlr_keyboard = kbd;

        const surface: *c.wlr_xdg_surface = toplevel.xdg_toplevel.base;
        c.wlr_seat_keyboard_notify_enter(seat, surface.surface, @ptrCast(&wlr_kbd.keycodes), wlr_kbd.num_keycodes, &wlr_kbd.modifiers);
    }
}

fn xdg_toplevel_map(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    std.debug.print("mapper\n", .{});
    _ = data;

    const toplevel: *WinglessToplevel = @ptrCast(@as(*allowzero WinglessToplevel, @fieldParentPtr("map", listener)));

    toplevel.insert();

    focus_toplevel(toplevel);
}

fn xdg_toplevel_commit(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;

    const toplevel: *WinglessToplevel = @ptrCast(@as(*allowzero WinglessToplevel, @fieldParentPtr("commit", listener)));

    std.debug.print("commit toplevel: {any}\n", .{@intFromPtr(toplevel)});
    std.debug.print("commit server: {any}\n", .{@intFromPtr(toplevel.server)});

    const xdg_surface: *c.wlr_xdg_surface = toplevel.xdg_toplevel.base;
    if (xdg_surface.initial_commit) {
        const wlr_surface: *c.wlr_xdg_surface = toplevel.xdg_toplevel.base;
        const surface: *c.wlr_surface = wlr_surface.surface;
        const sx = surface.current.dx;
        const sy = surface.current.dy;
        const o = c.wlr_output_layout_output_at(toplevel.server.output_layout, @floatFromInt(sx), @floatFromInt(sy)) orelse @panic("nope");

        var w: c_int = 0;
        var h: c_int = 0;

        c.wlr_output_effective_resolution(o, &w, &h);
        _ = c.wlr_xdg_toplevel_set_size(toplevel.xdg_toplevel, w, h);

        _ = c.wlr_xdg_toplevel_set_fullscreen(toplevel.xdg_toplevel, true);
    }
}

fn xdg_toplevel_destroy(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const toplevel: *WinglessToplevel = @ptrCast(@as(*allowzero WinglessToplevel, @fieldParentPtr("destroy", listener)));

    toplevel.deinit();
}

fn server_new_xdg_surface(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    _ = listener;
}

fn server_new_xdg_toplevel(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server: *WinglessServer = @ptrCast(@as(*allowzero WinglessServer, @fieldParentPtr("new_xdg_toplevel", listener)));
    const xdg_toplevel: *c.wlr_xdg_toplevel = @ptrCast(@alignCast(data.?));

    const toplevel = WinglessToplevel.init(server, xdg_toplevel) catch @panic("Failed to create toplevel");
    _ = toplevel;
}

fn server_new_xdg_popup(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = listener;
    _ = data;
}

fn desktop_active_toplevel(server: *WinglessServer, lx: f64, ly: f64, surface: *[*c]c.wlr_surface, sx: *f64, sy: *f64) ?*WinglessToplevel {
    const wlr_node = c.wlr_scene_node_at(&server.scene.tree.node, lx, ly, sx, sy);
    if (wlr_node != null) {
        const node: *c.wlr_scene_node = wlr_node;
        if (node.type != c.WLR_SCENE_NODE_BUFFER) return null;
    } else return null;
    const node: *c.wlr_scene_node = wlr_node;

    const scene_buffer = c.wlr_scene_buffer_from_node(wlr_node);
    const wlr_scene_surface = c.wlr_scene_surface_try_from_buffer(scene_buffer);

    if (wlr_scene_surface == null) return null;

    const scene_surface: *c.wlr_scene_surface = wlr_scene_surface;
    surface.* = scene_surface.surface;

    const wlr_tree = node.parent;
    var tree: *c.wlr_scene_tree = wlr_tree;
    while (wlr_tree != null and tree.node.data != null) {
        tree = tree.node.parent;
    }
    return @ptrCast(@alignCast(tree.node.data));
}

fn process_cursor_motion(server: *WinglessServer, time: c_uint) void {
    var sx: f64 = undefined;
    var sy: f64 = undefined;
    const seat = server.seat;
    var surface: [*c]c.wlr_surface = null;
    const toplevel = desktop_active_toplevel(server, server.cursor.x, server.cursor.y, &surface, &sx, &sy);

    if (toplevel == null) c.wlr_cursor_set_xcursor(server.cursor, server.cursor_mgr, "default");

    if (surface != null) {
        c.wlr_seat_pointer_notify_enter(seat, surface, sx, sy);
        c.wlr_seat_pointer_notify_motion(seat, time, sx, sy);
    } else c.wlr_seat_pointer_clear_focus(seat);
}

fn server_cursor_motion(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server: *WinglessServer = @ptrCast(@as(*allowzero WinglessServer, @fieldParentPtr("cursor_motion", listener)));
    const event: *c.wlr_pointer_motion_event = @ptrCast(@alignCast(data.?));
    const pointer: *c.wlr_pointer = event.pointer;

    c.wlr_cursor_move(server.cursor, &pointer.base, event.delta_x, event.delta_y);

    process_cursor_motion(server, event.time_msec);
}

fn server_cursor_motion_absolute(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server: *WinglessServer = @ptrCast(@as(*allowzero WinglessServer, @fieldParentPtr("cursor_motion_absolute", listener)));
    const event: *c.wlr_pointer_motion_absolute_event = @ptrCast(@alignCast(data.?));
    const pointer: *c.wlr_pointer = event.pointer;

    c.wlr_cursor_warp_absolute(server.cursor, &pointer.base, event.x, event.y);
    process_cursor_motion(server, event.time_msec);
}

fn server_cursor_button(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server: *WinglessServer = @ptrCast(@as(*allowzero WinglessServer, @fieldParentPtr("cursor_button", listener)));
    const event: *c.wlr_pointer_button_event = @ptrCast(@alignCast(data.?));

    _ = c.wlr_seat_pointer_notify_button(server.seat, event.time_msec, event.button, event.state);
}

fn server_cursor_axis(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server: *WinglessServer = @ptrCast(@as(*allowzero WinglessServer, @fieldParentPtr("cursor_axis", listener)));
    const event: *c.wlr_pointer_axis_event = @ptrCast(@alignCast(data.?));

    c.wlr_seat_pointer_notify_axis(server.seat, event.time_msec, event.orientation, event.delta, event.delta_discrete, event.source, event.relative_direction);
}

fn server_cursor_frame(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const server: *WinglessServer = @ptrCast(@as(*allowzero WinglessServer, @fieldParentPtr("cursor_frame", listener)));
    c.wlr_seat_pointer_notify_frame(server.seat);
}

fn keyboard_handle_key(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const keyboard: *WinglessKeyboard = @ptrCast(@as(*allowzero WinglessKeyboard, @fieldParentPtr("key", listener)));
    const server = keyboard.server;
    const event: *c.wlr_keyboard_key_event = @ptrCast(@alignCast(data.?));
    const seat = server.seat;

    const keycode = event.keycode + 8;
    var syms: [*c]c.xkb_keysym_t = undefined;
    const nsyms = c.xkb_state_key_get_syms(keyboard.wlr_keyboard.xkb_state, keycode, @ptrCast(&syms));

    var handled = false;

    if (event.state == c.WL_KEYBOARD_KEY_STATE_PRESSED) {
        const modifiers = c.wlr_keyboard_get_modifiers(keyboard.wlr_keyboard);
        if (0 < (modifiers & c.WLR_MODIFIER_ALT)) {
            for (0..@intCast(nsyms)) |i| {
                const sym = syms[i];

                if (sym == c.XKB_KEY_Escape) c.wl_display_terminate(server.display);
                if (sym == c.XKB_KEY_k) {
                    var child = std.process.Child.init(
                        &[_][]const u8{"kitty"},
                        std.heap.page_allocator,
                    );

                    var env = std.process.getEnvMap(std.heap.page_allocator) catch @panic("bruh");
                    // env.put("WAYLAND_DEBUG", "1") catch @panic("bruh");
                    child.env_map = @constCast(&env);

                    child.spawn() catch @panic("Kitty failed");

                    handled = true;
                }

                for (server.wingless_config.keybinds) |keybind| {
                    if (keybind.key == sym) {
                        switch (keybind.function) {
                            .tab_next => tab_next(server),
                            .tab_prev => tab_prev(server),
                        }
                        handled = true;
                    }
                }
            }
        }
    }

    if (handled == false) {
        c.wlr_seat_set_keyboard(seat, keyboard.wlr_keyboard);
        c.wlr_seat_keyboard_notify_key(seat, event.time_msec, event.keycode, event.state);
    }
}

fn keyboard_handle_modifiers(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const keyboard: *WinglessKeyboard = @ptrCast(@as(*allowzero WinglessKeyboard, @fieldParentPtr("modifiers", listener)));

    c.wlr_seat_set_keyboard(keyboard.server.seat, keyboard.wlr_keyboard);
    c.wlr_seat_keyboard_notify_modifiers(keyboard.server.seat, &keyboard.wlr_keyboard.modifiers);
}

fn keyboard_handle_destroy(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const keyboard: *WinglessKeyboard = @ptrCast(@as(*allowzero WinglessKeyboard, @fieldParentPtr("destroy", listener)));

    c.wl_list_remove(&keyboard.modifiers.link);
    c.wl_list_remove(&keyboard.key.link);
    c.wl_list_remove(&keyboard.destroy.link);
    c.wl_list_remove(&keyboard.link);
}

fn server_new_input(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server: *WinglessServer = @ptrCast(@as(*allowzero WinglessServer, @fieldParentPtr("new_input", listener)));
    const device: *c.wlr_input_device = @ptrCast(@alignCast(data.?));

    switch (device.type) {
        c.WLR_INPUT_DEVICE_KEYBOARD => {
            const keyboard = WinglessKeyboard.init(server, device) catch @panic("Failed to create keyboard");

            const context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
            const keymap = c.xkb_keymap_new_from_names(context, null, c.XKB_KEYMAP_COMPILE_NO_FLAGS);

            _ = c.wlr_keyboard_set_keymap(keyboard.wlr_keyboard, keymap);
            c.xkb_keymap_unref(keymap);
            c.xkb_context_unref(context);
            c.wlr_keyboard_set_repeat_info(keyboard.wlr_keyboard, 25, 600);

            c.wl_signal_add(&keyboard.wlr_keyboard.events.modifiers, &keyboard.modifiers);
            c.wl_signal_add(&keyboard.wlr_keyboard.events.key, &keyboard.key);
            c.wl_signal_add(&device.events.destroy, &keyboard.destroy);

            c.wlr_seat_set_keyboard(server.seat, keyboard.wlr_keyboard);

            c.wl_list_insert(&server.keyboards, @ptrCast(&keyboard.link));
        },
        c.WLR_INPUT_DEVICE_POINTER => {
            c.wlr_cursor_attach_input_device(server.cursor, device);
        },
        else => std.debug.print("unrecognized new input\n", .{}),
    }

    var caps = c.WL_SEAT_CAPABILITY_POINTER;
    if (c.wl_list_empty(&server.keyboards) == 0) caps |= c.WL_SEAT_CAPABILITY_KEYBOARD;
    c.wlr_seat_set_capabilities(server.seat, @intCast(caps));
}

fn output_frame(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const output: *WinglessOutput = @ptrCast(@as(*allowzero WinglessOutput, @fieldParentPtr("frame", listener)));
    const scene = output.server.scene;

    const scene_output = c.wlr_scene_get_scene_output(scene, output.output);

    _ = c.wlr_scene_output_commit(scene_output, null);

    var now: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, @ptrCast(&now));
    c.wlr_scene_output_send_frame_done(scene_output, &now);
}

fn output_request_state(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = listener;
    _ = data;
}

fn output_destroy(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const output: *WinglessOutput = @ptrCast(@as(*allowzero WinglessOutput, @fieldParentPtr("destroy", listener)));

    output.deinit();
}

fn server_new_output(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server: *WinglessServer = @ptrCast(@as(*allowzero WinglessServer, @fieldParentPtr("new_output", listener)));
    const wlr_output: *c.wlr_output = @ptrCast(@alignCast(data.?));

    _ = c.wlr_output_init_render(wlr_output, server.wlr_allocator, server.renderer);

    var state: c.wlr_output_state = undefined;
    c.wlr_output_state_init(@ptrCast(&state));
    c.wlr_output_state_set_enabled(@ptrCast(@constCast(&state)), true);

    const mode = c.wlr_output_preferred_mode(wlr_output);
    if (mode != null) {
        c.wlr_output_state_set_mode(@ptrCast(@constCast(&state)), mode);
    }

    _ = c.wlr_output_commit_state(wlr_output, &state);
    c.wlr_output_state_finish(@ptrCast(@constCast(&state)));

    const output = WinglessOutput.init(server, wlr_output) catch @panic("Failed to create output");

    c.wl_signal_add(&wlr_output.events.frame, &output.frame);
    c.wl_signal_add(&wlr_output.events.request_state, &output.request_state);
    c.wl_signal_add(&wlr_output.events.destroy, &output.destroy);

    c.wl_list_insert(&server.outputs, &output.link);

    const l_output = c.wlr_output_layout_add_auto(server.output_layout, wlr_output);
    const scene_output = c.wlr_scene_output_create(server.scene, wlr_output);
    c.wlr_scene_output_layout_add_output(server.scene_layout, l_output, scene_output);
}

pub fn main() !void {
    // c.wlr_log_init(c.WLR_DEBUG, null);
    const allocator = std.heap.page_allocator;
    const conf = try config.getConfig(allocator);

    var server = try WinglessServer.init(conf);

    const socket = c.wl_display_add_socket_auto(server.display);
    _ = c.wlr_backend_start(server.backend);
    _ = c.setenv("WAYLAND_DISPLAY", socket, 1);
    std.debug.print("Running wayland compositor on {s}\n", .{socket});

    c.wl_display_run(server.display);

    server.deinit();
}

comptime {
    _ = @import("config.zig");
}

fn testSetup() !*WinglessServer {
    _ = c.setenv("WLR_BACKENDS", "headless", 1);
    _ = c.setenv("WLR_LIBINPUT_NO_DEVICES", "1", 1);

    const allocator = std.heap.page_allocator;
    const conf = try config.getConfig(allocator);

    const server = try WinglessServer.init(conf);

    const socket = c.wl_display_add_socket_auto(server.display);
    _ = c.wlr_backend_start(server.backend);
    _ = c.setenv("WAYLAND_DISPLAY", socket, 1);

    return server;
}

test "init/deinit leak" {
    const server = try testSetup();

    c.wl_display_flush_clients(server.display);
    _ = c.wl_event_loop_dispatch(c.wl_display_get_event_loop(server.display), 0);

    server.deinit();
}

test "client open and close" {
    const server = try testSetup();

    const client_display = c.wl_display_connect(null);
    try std.testing.expect(client_display != null);

    c.wl_display_flush_clients(server.display);
    _ = c.wl_event_loop_dispatch(c.wl_display_get_event_loop(server.display), 0);

    c.wl_display_disconnect(client_display);

    server.deinit();
}

test "tab switching between two toplevels" {
    const server = try testSetup();
    defer server.deinit();

    const client = c.wl_display_connect(null).?;
    defer c.wl_display_disconnect(client);

    tests.testPump(server, client);

    const ctx = try tests.getTestContext(std.testing.allocator, client, server);

    try tests.createSurface(server, ctx, client);

    tab_prev(server);
}
