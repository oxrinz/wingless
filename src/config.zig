const std = @import("std");
const c = @import("c.zig").c;

pub const WinglessFunction = enum {
    tab_next,
    tab_prev,
    close_focused,
    toggle_beacon,
    launch_app,
};

pub const Keybind = struct {
    function: WinglessFunction,
    key: c_int, // uses XKB
};

pub const WinglessConfig = struct {
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

// fn readLine(line: []const u8) !Keybind {}

pub fn getConfig(allocator: std.mem.Allocator) !WinglessConfig {
    var keybinds = try allocator.alloc(Keybind, 4);
    keybinds[0] = .{ .key = c.XKB_KEY_n, .function = .tab_next };
    keybinds[1] = .{ .key = c.XKB_KEY_p, .function = .tab_prev };
    keybinds[2] = .{ .key = c.XKB_KEY_q, .function = .close_focused };
    keybinds[3] = .{ .key = c.XKB_KEY_space, .function = .toggle_beacon };
    return .{ .keybinds = keybinds };
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
