const std = @import("std");

const config = @import("config.zig");
const WinglessConfig = config.WinglessConfig;
const utils = @import("utils.zig");
const tests = @import("tests.zig");
const ui = @import("ui.zig");

const c = @import("c.zig").c;
const gl = @import("c.zig").gl;

const activeTag = std.meta.activeTag;

const Focusable = union(enum) {
    xdg: *WinglessToplevel,
    xwayland: *WinglessXwayland,

    fn getNext(self: *Focusable) *Focusable {
        switch (self.*) {
            .xdg => |xdg| return xdg.next.?,
            .xwayland => |xwl| return xwl.next.?,
        }
    }

    fn getPrev(self: *Focusable) *Focusable {
        switch (self.*) {
            .xdg => |xdg| return xdg.prev.?,
            .xwayland => |xwl| return xwl.prev.?,
        }
    }

    fn setNext(self: *Focusable, next: *Focusable) void {
        switch (self.*) {
            .xdg => |xdg| xdg.next = next,
            .xwayland => |xwl| xwl.next = next,
        }
    }

    fn setPrev(self: *Focusable, prev: *Focusable) void {
        switch (self.*) {
            .xdg => |xdg| xdg.prev = prev,
            .xwayland => |xwl| xwl.prev = prev,
        }
    }

    fn cmp(self: *const Focusable, other: *const Focusable) bool {
        if (activeTag(self.*) != activeTag(other.*)) return false;
        return switch (self.*) {
            .xdg => self.xdg == other.xdg,
            .xwayland => self.xwayland == other.xwayland,
        };
    }

    fn cmpXdg(self: *const Focusable, xdg: *WinglessToplevel) bool {
        switch (self.*) {
            .xdg => return xdg == self.xdg,
            .xwayland => return false,
        }
    }

    fn cmpXwl(self: *const Focusable, xwl: *WinglessXwayland) bool {
        switch (self.*) {
            .xdg => return false,
            .xwayland => return xwl == self.xwayland,
        }
    }

    fn server(self: *const Focusable) *WinglessServer {
        return switch (self.*) {
            .xdg => |xdg| xdg.server,
            .xwayland => |xwl| xwl.server,
        };
    }

    fn sceneTree(self: *const Focusable) *c.wlr_scene_tree {
        return switch (self.*) {
            .xdg => |xdg| xdg.scene_tree,
            .xwayland => |xwl| xwl.scene_tree.?,
        };
    }
};

pub const WinglessPointer = struct {
    device: *c.wlr_input_device,
    libinput: *c.libinput_device,
};

pub const WinglessServer = struct {
    display: *c.wl_display = undefined,
    backend: *c.wlr_backend = undefined,
    renderer: *c.wlr_renderer = undefined,
    compositor: *c.wlr_compositor = undefined,
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
    focused_toplevel: ?*Focusable = null,

    cursor: *c.wlr_cursor = undefined,
    cursor_mgr: *c.wlr_xcursor_manager = undefined,
    cursor_motion: c.wl_listener = undefined,
    cursor_motion_absolute: c.wl_listener = undefined,
    cursor_button: c.wl_listener = undefined,
    cursor_axis: c.wl_listener = undefined,
    cursor_frame: c.wl_listener = undefined,

    pointers: std.ArrayList(*WinglessPointer) = .empty,
    keyboards: c.wl_list = undefined,
    new_input: c.wl_listener = undefined,
    seat: *c.wlr_seat = undefined,

    xwayland: *c.wlr_xwayland = undefined,
    new_xwayland_surface: c.wl_listener = undefined,

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

        server.compositor = c.wlr_compositor_create(server.display, 5, server.renderer);
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

        server.xwayland = c.wlr_xwayland_create(server.display, server.compositor, false) orelse @panic("XWayland failed");
        c.wlr_xwayland_set_seat(server.xwayland, server.seat);

        server.new_xwayland_surface = .{ .notify = server_new_xwayland_surface, .link = undefined };

        // xsurface map, unmap, destroy are added in new_xwayland_surface
        c.wl_signal_add(&server.xwayland.events.new_surface, &server.new_xwayland_surface);

        _ = c.setenv("DISPLAY", server.xwayland.display_name, 1);
        _ = c.setenv("XDG_CURRENT_DESKTOP", "wingless", 1);
        _ = c.setenv("XDG_SESSION_TYPE", "wayland", 1);
        _ = c.setenv("XDG_SESSION_DESKTOP", "wingless", 1);

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

        c.wl_list_remove(&self.new_xwayland_surface.link);

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

pub const WinglessOutput = struct {
    link: c.wl_list,
    server: *WinglessServer,
    output: *c.wlr_output,

    image: ?ui.ImageProgram = null,
    fill: ?ui.FillProgram = null,
    beacon_background: ?ui.BeaconBackgroundProgram = null,
    glass_text: ?ui.GlassTextProgram = null,

    gl_vao: c_uint = 0,
    gl_vbo: c_uint = 0,

    scene_buffer: ?*c.wlr_buffer = null,

    ui_gl_fmt_set: c.wlr_drm_format_set = .{ .len = 0, .capacity = 0, .formats = null },
    ui_gl_fmt: *const c.wlr_drm_format = undefined,
    width: i32 = 0,
    height: i32 = 0,

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

        if (!c.wlr_drm_format_set_add(&output.ui_gl_fmt_set, c.DRM_FORMAT_ARGB8888, 0)) @panic("no fmt");
        output.ui_gl_fmt = @ptrCast(c.wlr_drm_format_set_get(&output.ui_gl_fmt_set, c.DRM_FORMAT_ARGB8888).?);

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

const WinglessXwayland = struct {
    focusable: Focusable,
    prev: ?*Focusable = null,
    next: ?*Focusable = null,

    server: *WinglessServer,
    xsurface: *c.wlr_xwayland_surface,
    scene_tree: ?*c.wlr_scene_tree,

    associate: c.wl_listener,
    request_configure: c.wl_listener,
    request_activate: c.wl_listener,
    map: c.wl_listener,
    commit: c.wl_listener,
    destroy: c.wl_listener,
    surface_destroy: c.wl_listener,

    pub fn init(server: *WinglessServer, xsurface: *c.wlr_xwayland_surface) !*WinglessXwayland {
        const toplevel = try server.allocator.create(WinglessXwayland);

        //const surface: *c.wlr_surface = @ptrCast(xsurface.surface);

        toplevel.focusable = .{ .xwayland = toplevel };

        toplevel.server = server;
        toplevel.xsurface = xsurface;
        toplevel.scene_tree = null;

        toplevel.associate = .{ .link = undefined, .notify = xwayland_surface_associate };
        toplevel.request_configure = .{ .link = undefined, .notify = xwayland_request_configure };
        toplevel.request_activate = .{ .link = undefined, .notify = xwayland_request_activate };

        toplevel.map = .{ .link = undefined, .notify = xwayland_surface_map };
        toplevel.commit = .{ .link = undefined, .notify = xdg_toplevel_commit };
        toplevel.destroy = .{ .link = undefined, .notify = xwayland_destroy };
        toplevel.surface_destroy = .{ .link = undefined, .notify = xwayland_surface_destroy };

        toplevel.prev = &toplevel.focusable;
        toplevel.next = &toplevel.focusable;

        c.wl_signal_add(&xsurface.events.associate, &toplevel.associate);
        c.wl_signal_add(&xsurface.events.request_configure, &toplevel.request_configure);
        c.wl_signal_add(&xsurface.events.request_activate, &toplevel.request_activate);
        c.wl_signal_add(&xsurface.events.destroy, &toplevel.destroy);

        return toplevel;
    }

    // TODO: merge with WinglessToplevel
    pub fn insert(self: *WinglessXwayland) void {
        const me: *Focusable = &self.focusable;

        if (self.server.focused_toplevel) |f| {
            const next = f.getNext();

            me.setPrev(f);
            me.setNext(next);

            f.setNext(me);
            next.setPrev(me);
        } else {
            self.prev = me;
            self.next = me;
        }
    }

    pub fn remove(self: *WinglessXwayland) void {
        if (self.next == null and self.prev == null) return;
        if (self.next == null or self.prev == null) @panic("one of topleve's prev or next is null and the other one isn't, this should never happen");

        const server = self.server;
        const me = &self.focusable;
        const prev = self.prev.?;
        const next = self.next.?;

        if (server.focused_toplevel) |f| {
            if (f.cmp(me)) {
                if (!prev.cmp(me)) {
                    server.focused_toplevel = prev;
                    focus_toplevel(prev);
                } else {
                    server.focused_toplevel = null;
                }
            }
        }

        prev.setNext(next);
        next.setPrev(prev);

        self.prev = null;
        self.next = null;
    }

    pub fn deinit(self: *WinglessXwayland) void {
        c.wl_list_remove(&self.destroy.link);
        c.wl_list_remove(&self.associate.link);
        c.wl_list_remove(&self.request_configure.link);
        c.wl_list_remove(&self.request_activate.link);

        self.remove();

        std.debug.print("deiniting\n", .{});
    }
};

const WinglessToplevel = struct {
    // these exist only if the toplevel if mapped, use as an indicator if the toplevel if mapped
    focusable: Focusable,
    prev: ?*Focusable,
    next: ?*Focusable,

    server: *WinglessServer,
    xdg_toplevel: ?*c.wlr_xdg_toplevel,
    scene_tree: *c.wlr_scene_tree,

    map: c.wl_listener,
    unmap: c.wl_listener,
    commit: c.wl_listener,
    destroy: c.wl_listener,
    surface_destroy: c.wl_listener,

    pub fn init(server: *WinglessServer, xdg_toplevel: *c.wlr_xdg_toplevel) !*WinglessToplevel {
        const toplevel = try server.allocator.create(WinglessToplevel);

        toplevel.* = .{
            .focusable = .{ .xdg = toplevel },
            .prev = &toplevel.focusable,
            .next = &toplevel.focusable,

            .server = server,
            .xdg_toplevel = xdg_toplevel,
            .scene_tree = c.wlr_scene_xdg_surface_create(&server.scene.tree, xdg_toplevel.base),

            .map = .{ .link = undefined, .notify = xdg_toplevel_map },
            .unmap = .{ .link = undefined, .notify = xdg_toplevel_unmap },
            .commit = .{ .link = undefined, .notify = xdg_toplevel_commit },
            .destroy = .{ .link = undefined, .notify = xdg_toplevel_destroy },
            .surface_destroy = .{ .link = undefined, .notify = xdg_toplevel_surface_destroy },
        };

        {
            const xdg_surface: *c.wlr_xdg_surface = toplevel.xdg_toplevel.?.base;
            const surface: *c.wlr_surface = @ptrCast(xdg_surface.surface);

            c.wl_signal_add(&surface.events.map, &toplevel.map);
            c.wl_signal_add(&surface.events.unmap, &toplevel.unmap);
            c.wl_signal_add(&surface.events.commit, &toplevel.commit);
            // toplevel's lifetime can be shorter than the surface's, so we separate the destroys into 2 to let commit listeners know the toplevel doesn't exist
            c.wl_signal_add(&surface.events.destroy, &toplevel.surface_destroy);
            c.wl_signal_add(&toplevel.xdg_toplevel.?.events.destroy, &toplevel.destroy);

            std.debug.print("initing bithcv\n", .{});
        }

        toplevel.scene_tree.node.data = toplevel;
        const surface: *c.wlr_xdg_surface = xdg_toplevel.base;
        surface.data = toplevel.scene_tree;

        return toplevel;
    }

    pub fn insert(self: *WinglessToplevel) void {
        const me: *Focusable = &self.focusable;

        if (self.server.focused_toplevel) |f| {
            const next = f.getNext();

            me.setPrev(f);
            me.setNext(next);

            f.setNext(me);
            next.setPrev(me);
        } else {
            self.prev = me;
            self.next = me;
        }
    }

    pub fn remove(self: *WinglessToplevel) void {
        if (self.next == null and self.prev == null) return;
        if (self.next == null or self.prev == null) @panic("one of topleve's prev or next is null and the other one isn't, this should never happen");

        const server = self.server;
        const me = &self.focusable;
        const prev = self.prev.?;
        const next = self.next.?;

        if (server.focused_toplevel) |f| {
            if (f.cmp(me)) {
                if (!prev.cmp(me)) {
                    server.focused_toplevel = prev;
                    focus_toplevel(prev);
                } else {
                    server.focused_toplevel = null;
                }
            }
        }

        prev.setNext(next);
        next.setPrev(prev);
    }

    pub fn destroyToplevelSurface(self: *WinglessToplevel) void {
        std.debug.print("deiniting but wayland not xwayland\n", .{});
        if (self.next != null or self.prev != null) {
            self.remove();
        }
        c.wl_list_remove(&self.map.link);
        c.wl_list_remove(&self.unmap.link);
        c.wl_list_remove(&self.commit.link);
        c.wl_list_remove(&self.destroy.link);
    }
};

const WinglessPopup = struct {
    xdg_popup: *c.wlr_xdg_popup,
    commit: c.wl_listener,
    destroy: c.wl_listener,

    pub fn init(allocator: std.mem.Allocator, xdg_popup: *c.wlr_xdg_popup) !*WinglessPopup {
        const popup = try allocator.create(WinglessPopup);

        popup.* = .{
            .xdg_popup = xdg_popup,
            .commit = .{ .link = undefined, .notify = xdg_popup_commit },
            .destroy = .{ .link = undefined, .notify = xdg_popup_destroy },
        };

        const base: *c.wlr_xdg_surface = xdg_popup.base.?;
        const surface: *c.wlr_surface = base.surface.?;
        c.wl_signal_add(&surface.events.commit, &popup.commit);
        c.wl_signal_add(&surface.events.destroy, &popup.destroy);

        return popup;
    }

    pub fn deinit(self: *WinglessPopup) void {
        c.wl_list_remove(&self.commit.link);
        c.wl_list_remove(&self.destroy.link);
    }
};

fn on_client(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = listener;
    _ = data;
}

fn close_focused_toplevel(server: *WinglessServer) void {
    switch (server.focused_toplevel.?.*) {
        .xdg => |xdg| c.wlr_xdg_toplevel_send_close(xdg.xdg_toplevel),
        .xwayland => |xwl| c.wlr_xwayland_surface_close(xwl.xsurface),
    }
}

fn tab_next(server: *WinglessServer) void {
    if (server.focused_toplevel == null) return;

    const toplevel = server.focused_toplevel.?.getNext();

    focus_toplevel(toplevel);
}

fn tab_prev(server: *WinglessServer) void {
    if (server.focused_toplevel == null) return;

    const toplevel = server.focused_toplevel.?.getPrev();

    focus_toplevel(toplevel);
}

fn focus_toplevel(focusable: *Focusable) void {
    const server = focusable.server();

    const seat = server.seat;

    if (server.focused_toplevel != null and server.focused_toplevel.?.cmp(focusable)) return;

    // deactivate old surfaces
    if (seat.keyboard_state.focused_surface != null) {
        if (server.focused_toplevel) |prev| {
            switch (prev.*) {
                .xdg => |xdg| {
                    _ = c.wlr_xdg_toplevel_set_activated(xdg.xdg_toplevel, false);
                },
                .xwayland => |xwl| {
                    c.wlr_xwayland_surface_activate(xwl.xsurface, false);
                },
            }
        }
    }

    server.focused_toplevel = focusable;

    // activate new surfaces
    c.wlr_scene_node_raise_to_top(&focusable.sceneTree().node);
    switch (focusable.*) {
        .xdg => |xdg| _ = c.wlr_xdg_toplevel_set_activated(xdg.xdg_toplevel, true),
        .xwayland => |xwl| c.wlr_xwayland_surface_activate(xwl.xsurface, true),
    }

    // set keyboard focus
    if (c.wlr_seat_get_keyboard(seat)) |kbd| {
        const wlr_kbd: *c.wlr_keyboard = kbd;

        var surface: *c.wlr_surface = undefined;

        switch (focusable.*) {
            .xdg => |xdg| {
                const base: *c.wlr_xdg_surface = xdg.xdg_toplevel.?.base;
                surface = base.surface;
            },
            .xwayland => |xwl| surface = xwl.xsurface.surface,
        }

        c.wlr_seat_keyboard_notify_enter(seat, surface, @ptrCast(&wlr_kbd.keycodes), wlr_kbd.num_keycodes, &wlr_kbd.modifiers);
    }
}

fn xwayland_surface_map(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;

    const xwl: *WinglessXwayland = @ptrCast(@as(*allowzero WinglessXwayland, @fieldParentPtr("map", listener)));

    xwl.scene_tree = c.wlr_scene_tree_create(&xwl.server.scene.tree);
    _ = c.wlr_scene_surface_create(xwl.scene_tree, xwl.xsurface.surface);

    if (!xwl.xsurface.override_redirect) {
        const o = c.wlr_output_layout_get_center_output(xwl.server.output_layout) orelse return;

        var w: c_int = 0;
        var h: c_int = 0;
        c.wlr_output_effective_resolution(o, &w, &h);

        c.wlr_xwayland_surface_configure(xwl.xsurface, 0, 0, @intCast(w), @intCast(h));

        c.wlr_xwayland_surface_set_fullscreen(xwl.xsurface, true);
    }

    c.wlr_scene_node_set_position(&xwl.scene_tree.?.node, xwl.xsurface.x, xwl.xsurface.y);

    if (xwl.xsurface.override_redirect) return;
    xwl.insert();
    focus_toplevel(&xwl.focusable);
}

fn xdg_toplevel_map(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    std.debug.print("map!\n", .{});
    _ = data;

    const toplevel: *WinglessToplevel = @ptrCast(@as(*allowzero WinglessToplevel, @fieldParentPtr("map", listener)));
    toplevel.insert();
    focus_toplevel(&toplevel.focusable);
}

fn xdg_toplevel_unmap(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;

    const toplevel: *WinglessToplevel = @ptrCast(@as(*allowzero WinglessToplevel, @fieldParentPtr("unmap", listener)));
    toplevel.remove();
}

fn xdg_toplevel_commit(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;

    const toplevel: *WinglessToplevel = @ptrCast(@as(*allowzero WinglessToplevel, @fieldParentPtr("commit", listener)));

    if (toplevel.xdg_toplevel) |xdg_toplevel| {
        const xdg_surface: *c.wlr_xdg_surface = xdg_toplevel.base;
        if (xdg_surface.initial_commit) {
            const wlr_surface: *c.wlr_xdg_surface = toplevel.xdg_toplevel.?.base;
            const surface: *c.wlr_surface = wlr_surface.surface;
            const sx = surface.current.dx;
            const sy = surface.current.dy;
            const o = c.wlr_output_layout_output_at(toplevel.server.output_layout, @floatFromInt(sx), @floatFromInt(sy)) orelse @panic("nope");

            var w: c_int = 0;
            var h: c_int = 0;

            c.wlr_output_effective_resolution(o, &w, &h);

            if (toplevel.xdg_toplevel.?.parent == null) {
                _ = c.wlr_xdg_toplevel_set_size(toplevel.xdg_toplevel, w, h);
                _ = c.wlr_xdg_toplevel_set_fullscreen(toplevel.xdg_toplevel, true);
            } else {
                _ = c.wlr_xdg_toplevel_set_size(toplevel.xdg_toplevel, 0, 0);
            }
        }
    }
}

// the wl surface must be destroyed after its role, this is defined by the protocol
fn xdg_toplevel_surface_destroy(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    std.debug.print("bruh destroying surface\n", .{});
    const toplevel: *WinglessToplevel = @ptrCast(@as(*allowzero WinglessToplevel, @fieldParentPtr("surface_destroy", listener)));

    c.wl_list_remove(&toplevel.surface_destroy.link);
    toplevel.server.allocator.destroy(toplevel);
}

fn xdg_toplevel_destroy(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    std.debug.print("bruh destroying just destroying\n", .{});
    const toplevel: *WinglessToplevel = @ptrCast(@as(*allowzero WinglessToplevel, @fieldParentPtr("destroy", listener)));
    toplevel.xdg_toplevel = null;
    toplevel.destroyToplevelSurface();
}

fn server_new_xwayland_surface(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server: *WinglessServer = @ptrCast(@as(*allowzero WinglessServer, @fieldParentPtr("new_xwayland_surface", listener)));
    const xsurface: *c.wlr_xwayland_surface = @ptrCast(@alignCast(data.?));

    xsurface.data = server;

    _ = WinglessXwayland.init(server, xsurface) catch @panic("out of memory");
}

fn xwayland_surface_associate(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;

    const xwl: *WinglessXwayland = @ptrCast(@as(*allowzero WinglessXwayland, @fieldParentPtr("associate", listener)));

    const surface: *c.wlr_surface = @ptrCast(xwl.xsurface.surface);

    c.wl_signal_add(&surface.events.map, &xwl.map);
    c.wl_signal_add(&surface.events.destroy, &xwl.surface_destroy);
}

fn xwayland_request_configure(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const xwl: *WinglessXwayland = @ptrCast(@as(*allowzero WinglessXwayland, @fieldParentPtr("request_configure", listener)));
    const ev: *c.wlr_xwayland_surface_configure_event = @ptrCast(@alignCast(data.?));

    const o = c.wlr_output_layout_get_center_output(xwl.server.output_layout) orelse return;

    if (!xwl.xsurface.override_redirect) {
        var w: c_int = 0;
        var h: c_int = 0;
        c.wlr_output_effective_resolution(o, &w, &h);

        c.wlr_xwayland_surface_configure(xwl.xsurface, 0, 0, @intCast(w), @intCast(h));
    } else {
        c.wlr_xwayland_surface_configure(xwl.xsurface, ev.x, ev.y, ev.width, ev.height);
    }

    if (xwl.scene_tree) |tree| {
        c.wlr_scene_node_set_position(&tree.node, ev.x, ev.y);
    }
}

fn xwayland_request_activate(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const xwl: *WinglessXwayland = @ptrCast(@as(*allowzero WinglessXwayland, @fieldParentPtr("request_configure", listener)));
    _ = xwl;
}

fn xwayland_destroy(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;

    const xwl: *WinglessXwayland = @ptrCast(@as(*allowzero WinglessXwayland, @fieldParentPtr("destroy", listener)));

    xwl.deinit();
}

fn xwayland_surface_destroy(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;

    const xwl: *WinglessXwayland = @ptrCast(@as(*allowzero WinglessXwayland, @fieldParentPtr("surface_destroy", listener)));

    c.wl_list_remove(&xwl.map.link);
    c.wl_list_remove(&xwl.surface_destroy.link);

    xwl.remove();
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

fn xdg_popup_destroy(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;

    std.debug.print("destroyed popup\n", .{});
    const popup: *WinglessPopup = @ptrCast(@as(*allowzero WinglessPopup, @fieldParentPtr("destroy", listener)));

    popup.deinit();
}

fn xdg_popup_commit(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    std.debug.print("popup commited\n", .{});

    const popup: *WinglessPopup = @ptrCast(@as(*allowzero WinglessPopup, @fieldParentPtr("commit", listener)));

    const base: *c.wlr_xdg_surface = popup.xdg_popup.base.?;
    _ = if (base.initial_commit) c.wlr_xdg_surface_schedule_configure(popup.xdg_popup.base);
}

fn server_new_xdg_popup(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    const server: *WinglessServer = @ptrCast(@as(*allowzero WinglessServer, @fieldParentPtr("new_xdg_popup", listener)));

    const xdg_popup: *c.wlr_xdg_popup = @ptrCast(@alignCast(data));
    _ = WinglessPopup.init(server.allocator, xdg_popup) catch @panic("Out of memory");

    const parent: *c.wlr_xdg_surface = c.wlr_xdg_surface_try_from_wlr_surface(xdg_popup.parent).?;
    const parent_tree: *c.wlr_scene_tree = @ptrCast(@alignCast(parent.data.?));
    const base: *c.wlr_xdg_surface = xdg_popup.base.?;
    base.data = c.wlr_scene_xdg_surface_create(parent_tree, xdg_popup.base);
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
    const seat = server.seat;

    if (seat.pointer_state.button_count > 0) {
        c.wlr_seat_pointer_notify_motion(
            seat,
            time,
            seat.pointer_state.sx,
            seat.pointer_state.sy,
        );
        return;
    }

    var sx: f64 = undefined;
    var sy: f64 = undefined;
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

fn spawnCmd(argv: []const []const u8) void {
    var child = std.process.Child.init(argv, std.heap.page_allocator);
    child.spawn() catch {};
}

fn applyConfig(server: *WinglessServer, conf: *const WinglessConfig) !void {
    std.debug.print("applying config\n", .{});
    for (server.pointers.items) |pointer| {
        std.debug.print("SETTING SENSITIVITY: {any}\n", .{conf.pointer_sensitivity});
        _ = c.libinput_device_config_accel_set_speed(pointer.libinput, conf.pointer_sensitivity);
    }
}

fn launchCommand(function: config.WinglessFunction, args: ?[]*anyopaque, server: *WinglessServer) void {
    switch (function) {
        .tab_next => tab_next(server),
        .tab_prev => tab_prev(server),
        .close_focused => close_focused_toplevel(server),
        .toggle_beacon => {
            if (ui.beacon_open == true) ui.beacon_buffer.clearRetainingCapacity();
            ui.beacon_open = !ui.beacon_open;
        },
        .launch_app => {
            const name: *[]const u8 = @ptrCast(@alignCast(args.?[0]));

            spawnCmd(&[_][]const u8{ "sh", "-c", name.* });
        },

        .volume_down => spawnCmd(&[_][]const u8{ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "5%-" }),
        .volume_up => spawnCmd(&[_][]const u8{ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", "5%+" }),
        .volume_set => {
            const percent: *u8 = @ptrCast(args.?[0]);
            const p: u8 = if (percent.* > 150) 150 else percent.*;

            var buf: [8]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}%", .{p}) catch return;
            spawnCmd(&[_][]const u8{ "wpctl", "set-volume", "@DEFAULT_AUDIO_SINK@", s });
        },
    }
}

//fn set_pointer_speed(server: *WinglessServer, speed: f64) void {
//var it = server.
////}

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

        // handle keybind
        if (0 < (modifiers & c.WLR_MODIFIER_LOGO)) {
            for (0..@intCast(nsyms)) |i| {
                const sym = syms[i];

                if (sym == c.XKB_KEY_Escape) c.wl_display_terminate(server.display);
                for (server.wingless_config.keybinds) |keybind| {
                    if (keybind.key == sym) {
                        launchCommand(keybind.function, null, server);
                        handled = true;
                    }
                }
            }
        }

        // handle beacon input
        if (ui.beacon_open == true and handled == false) {
            for (0..@intCast(nsyms)) |i| {
                const sym = syms[i];
                if (sym == c.XKB_KEY_BackSpace) {
                    _ = ui.beacon_buffer.pop();

                    ui.updateBeaconSuggestions(server.allocator) catch @panic("oops");
                    handled = true;
                    continue;
                } else if (sym == c.XKB_KEY_Return) {
                    // launch command
                    ui.beacon_open = false;
                    ui.beacon_buffer.clearRetainingCapacity();

                    const command = ui.beacon_suggestions[0];

                    launchCommand(command.function, command.args, server);

                    handled = true;
                    continue;
                }

                var buf: [8]u8 = undefined;

                const len = c.xkb_keysym_to_utf8(syms[i], &buf, buf.len);

                if (len > 1) {
                    ui.beacon_buffer.appendSlice(server.allocator, buf[0..@intCast(len - 1)]) catch {};
                }

                ui.updateBeaconSuggestions(server.allocator) catch @panic("oops");

                handled = true;
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

            const pointer = server.allocator.create(WinglessPointer) catch @panic("out of memory");
            pointer.* = .{
                .device = device,
                .libinput = c.wlr_libinput_get_device_handle(device) orelse return,
            };
            server.pointers.append(server.allocator, pointer) catch @panic("out of memory");
            std.debug.print("added a pointer!\n", .{});
        },
        else => std.debug.print("unrecognized new input\n", .{}),
    }

    var caps = c.WL_SEAT_CAPABILITY_POINTER;
    if (c.wl_list_empty(&server.keyboards) == 0) caps |= c.WL_SEAT_CAPABILITY_KEYBOARD;
    c.wlr_seat_set_capabilities(server.seat, @intCast(caps));
}

const SceneRenderCtx = struct {
    renderer: *c.wlr_renderer,
    pass: *c.wlr_render_pass,
};

fn render_scene_buffer_iter(
    scene_buf: [*c]c.wlr_scene_buffer,
    sx: c_int,
    sy: c_int,
    data: ?*anyopaque,
) callconv(.c) void {
    const ctx: *SceneRenderCtx = @ptrCast(@alignCast(data.?));
    const fixed_scene_buf: *c.wlr_scene_buffer = @ptrCast(@alignCast(scene_buf.?));

    const tex = c.wlr_texture_from_buffer(ctx.renderer, fixed_scene_buf.buffer) orelse return;

    const dst = c.wlr_box{
        .x = sx,
        .y = sy,
        .width = fixed_scene_buf.dst_width,
        .height = fixed_scene_buf.dst_height,
    };

    var opts = c.wlr_render_texture_options{
        .texture = tex,
        .src_box = fixed_scene_buf.src_box,
        .dst_box = dst,
        .alpha = if (fixed_scene_buf.opacity < 1.0) @ptrCast(&fixed_scene_buf.opacity) else null,
        .transform = fixed_scene_buf.transform,
        .filter_mode = fixed_scene_buf.filter_mode,
        .blend_mode = c.WLR_RENDER_BLEND_MODE_PREMULTIPLIED,
    };

    c.wlr_render_pass_add_texture(ctx.pass, &opts);
    c.wlr_texture_destroy(tex);
}

fn output_frame(listener: [*c]c.wl_listener, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const output: *WinglessOutput = @ptrCast(@as(*allowzero WinglessOutput, @fieldParentPtr("frame", listener)));
    const server = output.server;
    const scene = output.server.scene;
    const scene_output = c.wlr_scene_get_scene_output(scene, output.output);

    var state: c.wlr_output_state = undefined;
    c.wlr_output_state_init(&state);
    defer c.wlr_output_state_finish(&state);

    _ = c.wlr_scene_output_build_state(scene_output, &state, null);

    var w: c_int = 0;
    var h: c_int = 0;
    c.wlr_output_transformed_resolution(output.output, &w, &h);

    // reset buffer on resize
    if (output.scene_buffer == null or
        output.width != w or
        output.height != h)
    {
        output.width = w;
        output.height = h;
        output.scene_buffer = c.wlr_allocator_create_buffer(server.wlr_allocator, w, h, @ptrCast(output.ui_gl_fmt));
    }

    // render scene onto scene buffer
    const scene_pass = c.wlr_renderer_begin_buffer_pass(
        server.renderer,
        output.scene_buffer.?,
        null,
    ) orelse return;

    var ctx = SceneRenderCtx{
        .renderer = server.renderer,
        .pass = scene_pass,
    };

    c.wlr_scene_output_for_each_buffer(scene_output, render_scene_buffer_iter, &ctx);

    _ = c.wlr_render_pass_submit(scene_pass);

    // start output pass
    const out_pass = c.wlr_output_begin_render_pass(output.output, &state, null) orelse return;

    // render scene to output
    // TODO: reuse existing scene buffer
    var out_ctx = SceneRenderCtx{
        .renderer = server.renderer,
        .pass = out_pass,
    };

    c.wlr_scene_output_for_each_buffer(scene_output, render_scene_buffer_iter, &out_ctx);

    // render ui
    ui.renderUI(server, output, w, h) catch @panic("Failed to render ui");

    _ = c.wlr_render_pass_submit(out_pass);
    _ = c.wlr_output_commit_state(output.output, &state);

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

    try applyConfig(server, &conf);

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

test "map map unmap change focus" {
    const server = try testSetup();
    defer server.deinit();

    const client = c.wl_display_connect(null).?;
    defer c.wl_display_disconnect(client);

    tests.pump(server, client);

    const ctx = try tests.getTestContext(std.testing.allocator, client, server);

    const toplevel = try tests.createToplevel(server, ctx, client);

    const client_surface_id = c.wl_proxy_get_id(@ptrCast(toplevel.surface.?));
    const focused_id = tests.getServerFocusedSurfaceId(server);

    try std.testing.expect(client_surface_id == focused_id);

    c.wl_surface_attach(toplevel.surface, null, 0, 0);
    c.wl_surface_commit(toplevel.surface);
    tests.pump(server, client);

    try std.testing.expect(server.focused_toplevel == null);

    ctx.deinit();
    std.testing.allocator.destroy(ctx);
}

test "destroy focus" {
    const server = try testSetup();
    defer server.deinit();

    const client = c.wl_display_connect(null).?;
    defer c.wl_display_disconnect(client);

    tests.pump(server, client);

    const ctx = try tests.getTestContext(std.testing.allocator, client, server);

    const toplevel = try tests.createToplevel(server, ctx, client);

    const client_surface_id = c.wl_proxy_get_id(@ptrCast(toplevel.surface.?));
    const focused_id = tests.getServerFocusedSurfaceId(server);

    tests.pump(server, client);
    tests.pump(server, client);

    try std.testing.expect(client_surface_id == focused_id);

    c.wl_surface_destroy(toplevel.surface);

    tests.pump(server, client);

    try std.testing.expect(server.focused_toplevel == null);

    ctx.deinit();
    std.testing.allocator.destroy(ctx);
}

test "globals" {
    const server = try testSetup();
    defer server.deinit();

    const client = c.wl_display_connect(null).?;
    _ = client;
}
