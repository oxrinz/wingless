const std = @import("std");
const c = @import("c.zig").c;

pub const WinglessFunction = enum {
    tab_next,
    tab_prev,
    close_focused,
    toggle_beacon,
    launch_app,

    volume_up,
    volume_down,
    volume_set,
};

pub const Keybind = struct {
    function: WinglessFunction,
    key: c_int, // uses XKB
};

pub const WinglessConfig = struct {
    pointer_sensitivity: f64 = 1,
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

    // read config file
    const cwd = std.fs.cwd();
    //const file = try cwd.openFile("~/.config/wingless/config", .{});
    const home = try std.process.getEnvVarOwned(allocator, "HOME");
    const path = try std.fmt.allocPrint(allocator, "{s}/.wingless", .{home});
    const file = try cwd.openFile(path, .{});
    const data = try file.readToEndAlloc(allocator, 16 * 1024);
    file.close();

    var config = try allocator.create(WinglessConfig);

    // parse config
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;

        if (std.mem.startsWith(u8, line, "POINTER_SENSITIVITY")) {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfig;
            const semi = std.mem.indexOfScalar(u8, line, ';') orelse return error.InvalidConfig;

            const value_str = std.mem.trim(
                u8,
                line[eq + 1 .. semi],
                " \t",
            );

            config.pointer_sensitivity = try std.fmt.parseFloat(f64, value_str);
        }
    }

    // keybinds
    var keybinds = try allocator.alloc(Keybind, 6);
    keybinds[0] = .{ .key = c.XKB_KEY_n, .function = .tab_next };
    keybinds[1] = .{ .key = c.XKB_KEY_p, .function = .tab_prev };
    keybinds[2] = .{ .key = c.XKB_KEY_q, .function = .close_focused };
    keybinds[3] = .{ .key = c.XKB_KEY_space, .function = .toggle_beacon };
    keybinds[4] = .{ .key = c.XKB_KEY_XF86AudioRaiseVolume, .function = .volume_up };
    keybinds[5] = .{ .key = c.XKB_KEY_XF86AudioLowerVolume, .function = .volume_down };

    config.keybinds = keybinds;

    return config.*;
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
