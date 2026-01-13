const std = @import("std");
const c = @import("c.zig").c;

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

        const self: *TestKeyboard = @ptrCast(@alignCast(data.?));
        self.last_key_id = key_id;
    }
};
