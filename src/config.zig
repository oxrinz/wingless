const std = @import("std");
const c = @import("c.zig").c;

pub const WinglessFunction = enum {
    tab_next,
    tab_prev,
    close_focused,
    toggle_fullscreen,
    toggle_menu,
    toggle_beacon,
    launch_app,

    volume_up,
    volume_down,
    volume_set,
    volume_mute,

    shutdown,
    reboot,

    snap_left,
    snap_right,
    move_to_next_output,

    screenshot,
    screenshot_fullscreen,

    record,
    record_fullscreen,
};

pub const Modifier = enum {
    super,
    super_shift,
    none,
};

pub const Keybind = struct {
    function: WinglessFunction,
    key: c_int, // uses XKB
    modifier: Modifier = .super,
};

pub const WinglessConfig = struct {
    pointer_sensitivity: f64 = 1,
    background: ?[]const u8 = null,
    key_repeat_rate: i32 = 60,
    key_repeat_delay: i32 = 200,
    keybinds: []Keybind,
};

const Token = union(enum) { identifier: []const u8, number: i32, colon, new_line, space };

fn readNextToken(allocator: std.mem.Allocator, line: []const u8) !struct { token: Token, characters_read: u8 } {
    var current_token: std.ArrayList(u8) = .empty;
    var curr_type: enum {
        text,
        number,
    } = .text;

    for (line) |char| {
        switch (char) {
            '\n' => return .{ .token = .new_line, .characters_read = 1 },
            ' ' => {},
            ':' => if (current_token.items.len == 0) return .{ .token = .colon, .characters_read = 1 } else break,
            else => {
                if ((char >= 'a' and char <= 'z') or (char >= 'A' and char <= 'Z')) {
                    if (curr_type == .text) try current_token.append(allocator, char);
                } else if (char >= '0' and char <= '9') {
                    if (current_token.items.len == 0) {
                        curr_type = .number;
                    }
                    try current_token.append(allocator, char);
                } else return error.UnexpectedCharacter;
            },
        }
    }

    const chars_read: u8 = @intCast(current_token.items.len);

    return switch (curr_type) {
        .text => return .{ .token = .{ .identifier = try current_token.toOwnedSlice(allocator) }, .characters_read = chars_read },
        .number => return .{ .token = .{ .number = try std.fmt.parseInt(i32, try current_token.toOwnedSlice(allocator), 10) }, .characters_read = chars_read },
    };
}

pub fn getConfig(allocator: std.mem.Allocator) !WinglessConfig {
    const cwd = std.fs.cwd();
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    const path = try std.fmt.allocPrint(allocator, "{s}/.wingless", .{home});
    const file = try cwd.openFile(path, .{});
    const data = try file.readToEndAlloc(allocator, 16 * 1024);
    file.close();

    var config = WinglessConfig{ .keybinds = &.{} };
    var custom_binds: std.ArrayListUnmanaged(Keybind) = .{};

    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "#")) continue;

        if (std.mem.startsWith(u8, line, "BACKGROUND")) {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfig;
            const semi = std.mem.indexOfScalar(u8, line, ';') orelse return error.InvalidConfig;
            config.background = try allocator.dupe(u8, std.mem.trim(u8, line[eq + 1 .. semi], " \t"));
        } else if (std.mem.startsWith(u8, line, "POINTER_SENSITIVITY")) {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfig;
            const semi = std.mem.indexOfScalar(u8, line, ';') orelse return error.InvalidConfig;
            config.pointer_sensitivity = try std.fmt.parseFloat(f64, std.mem.trim(u8, line[eq + 1 .. semi], " \t"));
        } else if (std.mem.startsWith(u8, line, "KEY_REPEAT_RATE")) {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfig;
            const semi = std.mem.indexOfScalar(u8, line, ';') orelse return error.InvalidConfig;
            config.key_repeat_rate = try std.fmt.parseInt(i32, std.mem.trim(u8, line[eq + 1 .. semi], " \t"), 10);
        } else if (std.mem.startsWith(u8, line, "KEY_REPEAT_DELAY")) {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfig;
            const semi = std.mem.indexOfScalar(u8, line, ';') orelse return error.InvalidConfig;
            config.key_repeat_delay = try std.fmt.parseInt(i32, std.mem.trim(u8, line[eq + 1 .. semi], " \t"), 10);
        } else if (std.mem.startsWith(u8, line, "BIND")) {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfig;
            const semi = std.mem.indexOfScalar(u8, line, ';') orelse return error.InvalidConfig;
            const value_str = std.mem.trim(u8, line[eq + 1 .. semi], " \t");

            // format: BIND = <modifier> <key> <function>;
            // modifier: super, super_shift, none
            // key: XKB key name e.g. n, Tab, XF86AudioRaiseVolume
            // function: tab_next, close_focused, etc.
            var parts = std.mem.tokenizeScalar(u8, value_str, ' ');
            const modifier_str = parts.next() orelse return error.InvalidConfig;
            const key_str = parts.next() orelse return error.InvalidConfig;
            const function_str = parts.next() orelse return error.InvalidConfig;

            const modifier = std.meta.stringToEnum(Modifier, modifier_str) orelse return error.InvalidConfig;
            const function = std.meta.stringToEnum(WinglessFunction, function_str) orelse return error.InvalidConfig;

            const key_str_z = try allocator.dupeZ(u8, key_str);
            const keysym = c.xkb_keysym_from_name(key_str_z, c.XKB_KEYSYM_NO_FLAGS);
            if (keysym == c.XKB_KEY_NoSymbol) return error.InvalidKeyName;

            try custom_binds.append(allocator, .{
                .function = function,
                .key = @intCast(keysym),
                .modifier = modifier,
            });
        }
    }

    try custom_binds.appendSlice(allocator, &.{
        .{ .key = c.XKB_KEY_n, .function = .tab_next },
        .{ .key = c.XKB_KEY_p, .function = .tab_prev },
        .{ .key = c.XKB_KEY_q, .function = .close_focused },
        .{ .key = c.XKB_KEY_space, .function = .toggle_beacon },
        .{ .key = c.XKB_KEY_XF86AudioRaiseVolume, .function = .volume_up, .modifier = .none },
        .{ .key = c.XKB_KEY_XF86AudioLowerVolume, .function = .volume_down, .modifier = .none },
        .{ .key = c.XKB_KEY_XF86AudioMute, .function = .volume_mute, .modifier = .none },
        .{ .key = c.XKB_KEY_Tab, .function = .toggle_menu },
        .{ .key = c.XKB_KEY_f, .function = .toggle_fullscreen },
        .{ .key = c.XKB_KEY_h, .function = .snap_left },
        .{ .key = c.XKB_KEY_l, .function = .snap_right },
        .{ .key = c.XKB_KEY_s, .function = .screenshot_fullscreen },
        .{ .key = c.XKB_KEY_s, .function = .screenshot, .modifier = .super_shift },
        .{ .key = c.XKB_KEY_r, .function = .record_fullscreen },
        .{ .key = c.XKB_KEY_r, .function = .record, .modifier = .super_shift },
        .{ .key = c.XKB_KEY_m, .function = .move_to_next_output, .modifier = .super_shift },
    });
    config.keybinds = try custom_binds.toOwnedSlice(allocator);

    return config;
}

test "one line lexer" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    const allocator = arena.allocator();

    const input = "252: tabSwitch";
    var chars_read: u8 = 0;

    const number = try readNextToken(allocator, input);
    try std.testing.expect(number.token.number == 252);
    chars_read += number.characters_read;

    const colon = try readNextToken(allocator, input[chars_read..14]);
    try std.testing.expect(colon.token == .colon);
    chars_read += colon.characters_read;

    const identifier = try readNextToken(allocator, input[chars_read..14]);
    try std.testing.expect(std.mem.eql(u8, identifier.token.identifier, "tabSwitch"));
}
