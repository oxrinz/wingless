const std = @import("std");
const config = @import("../config.zig");
const zclay = @import("zclay");
const ui = @import("../ui.zig");

pub const BeaconCommand = struct {
    name: []const u8,
    function: config.WinglessFunction,
    args: ?[]*anyopaque = null,
    icon: ?[]const u8,
};

var beacon_state: f32 = 0;
var beacon_suggestion_state: f32 = 0;
var beacon_line_state: f32 = 0;
var sugg_target: f32 = 0;
var placeholder_alpha: f32 = 0;

pub var beacon_buffer: std.ArrayList(u8) = .empty;
pub var beacon_suggestions: []*BeaconCommand = &.{};
pub var beacon_commands: []*BeaconCommand = &.{};

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

pub fn tick(dt: f32) void {
    const t20 = @min(dt * 20.0, 1.0);
    const t18 = @min(dt * 18.0, 1.0);

    beacon_state = lerp(beacon_state, if (ui.beacon_open) 1.0 else 0.0, t20);

    sugg_target = if (beacon_buffer.items.len >= 2)
        switch (beacon_suggestions.len) {
            0, 1 => 0.4,
            2 => 0.7,
            else => 1.0,
        }
    else
        0.0;
    beacon_suggestion_state = lerp(beacon_suggestion_state, sugg_target, t20);
    beacon_line_state = lerp(beacon_line_state, if (beacon_state > 0.1) 1.0 else 0.0, t20);
    if (beacon_buffer.items.len > 0) {
        placeholder_alpha = 0.0;
    } else {
        const placeholder_target: f32 = if (beacon_state > 0.85) 1.0 else 0.0;
        placeholder_alpha = lerp(placeholder_alpha, placeholder_target, t18);
    }
}

pub fn layout(allocator: std.mem.Allocator) void {
    if (beacon_state <= 0.0001) return;

    const s = ui.ui_scale;
    const bw = 600.0 * s * beacon_state;
    const bh = @min(bw, 80.0 * s) + 180.0 * s * beacon_suggestion_state;

    zclay.UI()(.{
        .id = .ID("Beacon"),
        .layout = .{
            .direction = .top_to_bottom,
            .padding = .{ .top = @intFromFloat(24 * s), .bottom = @intFromFloat(24 * s), .left = @intFromFloat(24 * s), .right = @intFromFloat(24 * s) },
            .child_gap = @intFromFloat(8 * s),
            .sizing = .{ .w = .fixed(bw), .h = .fixed(bh) },
        },
        .custom = .{ .custom_data = ui.mkGlass(80 * s) },
    })({
        // suggestions below input
        if (beacon_suggestion_state > 0.05) {
            const n_sugg = @min(beacon_suggestions.len, 3);

            zclay.UI()(.{
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .grow },
                    .direction = .top_to_bottom,
                    .child_gap = 6,
                },
            })({
                if (n_sugg > 0) {
                    for (0..n_sugg) |i| {
                        zclay.UI()(.{
                            .id = .IDI("SuggRow", @intCast(i)),
                            .layout = .{
                                .sizing = .{ .w = .grow, .h = .fixed(44 * s) },
                                .child_alignment = .{ .x = .left, .y = .center },
                                .child_gap = @intFromFloat(12 * s),
                            },
                        })({
                            // icon slot
                            zclay.UI()(.{
                                .id = .IDI("SuggIcon", @intCast(i)),
                                .layout = .{
                                    .sizing = .{ .w = .fixed(32 * s), .h = .fixed(32 * s) },
                                },
                                .custom = .{ .custom_data = ui.mkIcon(allocator, beacon_suggestions[i]) },
                            })({});
                            zclay.UI()(.{
                                .id = .IDI("SuggTextWrap", @intCast(i)),
                                .layout = .{
                                    .sizing = .{ .w = .grow, .h = .grow },
                                    .child_alignment = .{ .x = .left, .y = .center },
                                },
                            })({
                                zclay.text(beacon_suggestions[i].name, .{
                                    .font_size = 26,
                                    .color = .{ 255, 255, 255, 255 },
                                });
                            });
                        });
                    }
                } else {
                    zclay.text("Unknown command !", .{
                        .font_size = 26,
                        .color = .{ 255, 255, 255, 255 },
                    });
                }
            });
        }

        // divider between input and suggestions
        if (beacon_suggestion_state > 0.05) {
            zclay.UI()(.{
                .id = .ID("BeaconDivider"),
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fixed(2 * s) },
                },
                .custom = .{ .custom_data = ui.mkDivider(beacon_line_state * 0.2) },
            })({});
        }

        // input text row
        zclay.UI()(.{
            .id = .ID("BeaconInput"),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fixed(32 * s) },
                .child_alignment = .{ .y = .center },
                .child_gap = @intFromFloat(10 * s),
            },
        })({
            if (placeholder_alpha > 0.01) {
                zclay.UI()(.{
                    .id = .ID("BeaconSearchIcon"),
                    .layout = .{ .sizing = .{ .w = .fixed(34 * s), .h = .fixed(34 * s) } },
                    .custom = .{ .custom_data = ui.mkIconByNameAlpha(allocator, "system-search-symbolic", placeholder_alpha * 180.0 / 255.0) },
                })({});
                zclay.text("Search...", .{
                    .font_size = 26,
                    .color = .{ 255, 255, 255, placeholder_alpha * 180.0 },
                });
            }

            if (beacon_buffer.items.len > 0) {
                zclay.text(beacon_buffer.items, .{
                    .font_size = 26,
                    .color = .{ 255, 255, 255, 255 },
                });
            }
        });
    });
}

pub fn initCommands(allocator: std.mem.Allocator) !void {
    var command_array: std.ArrayList(*BeaconCommand) = .empty;
    for (std.enums.values(config.WinglessFunction)) |function| {
        const icon: ?[]const u8 = switch (function) {
            .shutdown => "_power",
            .reboot => "_restart",
            .toggle_beacon => "system-search-symbolic",
            .toggle_menu => "view-app-grid-symbolic",
            .close_focused => "application-exit-symbolic",
            .toggle_fullscreen => "view-fullscreen-symbolic",
            .tab_next => "go-next-symbolic",
            .tab_prev => "go-previous-symbolic",
            .volume_up => "audio-volume-high-symbolic",
            .volume_down => "audio-volume-low-symbolic",
            .volume_set => "audio-volume-medium-symbolic",
            .snap_left, .snap_right => "focus-windows-symbolic",
            .launch_app => null,
        };
        const object = allocator.create(BeaconCommand) catch return;
        object.* = .{
            .name = try allocator.dupe(u8, @constCast(@tagName(function))),
            .args = null,
            .function = function,
            .icon = icon,
        };
        command_array.append(std.heap.page_allocator, object) catch @panic("fuck");
    }

    const paths = [_][]const u8{ "/usr/share/applications", try std.fs.path.join(allocator, &.{
        try std.process.getEnvVarOwned(allocator, "HOME"),
        ".local/share/applications",
    }) };

    for (paths) |path| {
        if (path.len == 0) continue;
        var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch continue;
        defer dir.close();

        var it = dir.iterate();
        while (try it.next()) |e| {
            if (e.kind != .file and !std.mem.endsWith(u8, e.name, ".desktop")) continue;

            const full = try std.fs.path.join(allocator, &.{ path, e.name });
            defer allocator.free(full);

            const file = try std.fs.openFileAbsolute(full, .{});
            defer file.close();

            const data = try file.readToEndAlloc(allocator, 64 * 1024);
            defer allocator.free(data);

            var in_group = false;
            var line_it = std.mem.splitScalar(u8, data, '\n');

            var name: ?[]const u8 = null;
            var exec: ?[]const u8 = null;
            var icon: ?[]const u8 = null;

            while (line_it.next()) |raw_line| {
                const line = std.mem.trim(u8, raw_line, " \t\r");
                if (line.len == 0 or line[0] == '#') continue;

                if (line[0] == '[') {
                    in_group = std.mem.eql(u8, line, "[Desktop Entry]");
                }

                if (!in_group) continue;

                const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
                const key = line[0..eq];
                const val = line[eq + 1 ..];

                if (std.mem.eql(u8, key, "Type")) {
                    // TODO: filter non-application types
                } else if (std.mem.eql(u8, key, "Name")) {
                    name = try allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "Exec")) {
                    exec = try allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "Icon")) {
                    icon = try allocator.dupe(u8, val);
                }
            }

            if (name != null and exec != null) {
                exec = std.mem.trimRight(u8, exec.?, " %uUfFiIck");
                if (icon == null) icon = try allocator.dupe(u8, "application-x-executable");

                const name_ptr = allocator.create([]const u8) catch @panic("out of memory");
                name_ptr.* = exec.?;

                const args = allocator.alloc(*anyopaque, 1) catch @panic("out of memory");
                args[0] = @ptrCast(name_ptr);

                const object = allocator.create(BeaconCommand) catch return;
                object.* = .{
                    .function = .launch_app,
                    .name = name.?,
                    .icon = icon,
                    .args = args,
                };
                command_array.append(std.heap.page_allocator, object) catch @panic("fuck");
            }
        }
    }

    beacon_commands = command_array.toOwnedSlice(std.heap.page_allocator) catch @panic("oh no");
}

pub fn updateBeaconSuggestions(allocator: std.mem.Allocator) !void {
    const Match = struct {
        cmd: *BeaconCommand,
        score: isize,
    };

    var matches: std.ArrayList(Match) = .empty;
    defer matches.deinit(allocator);

    for (beacon_commands) |command| {
        const a = try normalizeString(command.name, allocator);
        const b = try normalizeString(beacon_buffer.items, allocator);

        const n = a.len;
        const m = b.len;

        var prev = try allocator.alloc(usize, m + 1);
        defer allocator.free(prev);
        var curr = try allocator.alloc(usize, m + 1);
        defer allocator.free(curr);

        for (0..m + 1) |j| prev[j] = j;

        for (1..n + 1) |i| {
            curr[0] = i;
            for (1..m + 1) |j| {
                const cost: usize = if (std.ascii.toLower(a[i - 1]) == std.ascii.toLower(b[j - 1])) 0 else 1;
                curr[j] = @min(@min(curr[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
            }
            std.mem.swap([]usize, &prev, &curr);
        }

        const dist = prev[m];
        var score: isize = @intCast(dist);

        if (std.mem.startsWith(u8, a, b)) score -= 5 else if (std.mem.indexOf(u8, a, b) != null) score -= 3;
        score += @intCast(a.len / 10);

        if (score <= 2) {
            try matches.append(allocator, .{ .cmd = @constCast(command), .score = score });
        }
    }

    const Less = struct {
        pub fn lessThan(_: void, a: Match, b: Match) bool {
            return a.score < b.score;
        }
    };

    std.sort.block(Match, matches.items, {}, Less.lessThan);

    var results = try allocator.alloc(*BeaconCommand, matches.items.len);
    for (matches.items, 0..) |m, i| results[i] = m.cmd;

    beacon_suggestions = results;
}

fn normalizeString(buf: []const u8, allocator: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    for (buf) |char| {
        if (char != ' ' and char != '-' and char != '_') {
            try out.append(allocator, std.ascii.toLower(char));
        }
    }
    return try out.toOwnedSlice(allocator);
}
