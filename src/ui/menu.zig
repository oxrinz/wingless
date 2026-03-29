const std = @import("std");
const zclay = @import("zclay");
const ui = @import("../ui.zig");
const main = @import("../main.zig");
const Focusable = main.Focusable;
const c = @import("../c.zig").c;
const screenshot = @import("screenshot.zig");
const recording = @import("recording.zig");
const sd = @cImport(@cInclude("systemd/sd-bus.h"));

const NM_DEST: [*c]const u8 = "org.freedesktop.NetworkManager";
const NM_PATH: [*c]const u8 = "/org/freedesktop/NetworkManager";
const NM_IFACE: [*c]const u8 = "org.freedesktop.NetworkManager";
const NM_DEV_IFACE: [*c]const u8 = "org.freedesktop.NetworkManager.Device";
const NM_DEV_WIFI: [*c]const u8 = "org.freedesktop.NetworkManager.Device.Wireless";
const NM_AP_IFACE: [*c]const u8 = "org.freedesktop.NetworkManager.AccessPoint";
const NM_SETTINGS_PATH: [*c]const u8 = "/org/freedesktop/NetworkManager/Settings";
const NM_SETTINGS_IFACE: [*c]const u8 = "org.freedesktop.NetworkManager.Settings";
const NM_SETTINGS_CONN: [*c]const u8 = "org.freedesktop.NetworkManager.Settings.Connection";


var cluster_open: bool = false;
var cluster_state: f32 = 0.0; // 0=collapsed, 1=expanded
var cluster_sub_states: [3]f32 = [_]f32{0} ** 3; // per-button: 0=power, 1=sleep, 2=restart
// 0=center(close), 1=power, 2=sleep, 3=restart
var cluster_hover: [4]bool = [_]bool{false} ** 4;
var cluster_hover_bright: [4]f32 = [_]f32{0.05} ** 4;
var cluster_hover_scale: [4]f32 = [_]f32{1.0} ** 4;

const max_wifi_entries = 12;
const max_bt_entries = 8;
const max_net_hover = 12;

const WifiEntry = struct {
    ssid: [64]u8 = [_]u8{0} ** 64,
    ssid_len: usize = 0,
    signal: i32 = 0,
    connected: bool = false,
    secured: bool = false,
    known: bool = false,
    sig_str: [24]u8 = [_]u8{0} ** 24,
    sig_str_len: usize = 0,
    ap_path: [256]u8 = [_]u8{0} ** 256,
    ap_path_len: usize = 0,
};

const BtEntry = struct {
    name: [64]u8 = [_]u8{0} ** 64,
    name_len: usize = 0,
    addr: [17]u8 = [_]u8{0} ** 17,
    connected: bool = false,
};

var wifi_entries: [max_wifi_entries]WifiEntry = undefined;
var wifi_count: usize = 0;
var wifi_mutex: std.Thread.Mutex = .{};
var wifi_fetching: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var wifi_snapshot: [max_wifi_entries]WifiEntry = undefined;
var wifi_snapshot_count: usize = 0;
var wifi_device_path: [256]u8 = [_]u8{0} ** 256;
var wifi_device_path_len: usize = 0;

var bt_entries: [max_bt_entries]BtEntry = undefined;
var bt_count: usize = 0;
var bt_mutex: std.Thread.Mutex = .{};
var bt_fetching: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var bt_snapshot: [max_bt_entries]BtEntry = undefined;
var bt_snapshot_count: usize = 0;

var wifi_open: bool = false;
var wifi_panel_state: f32 = 0.0;
var prev_pointer_down: bool = false;
var wifi_hover: bool = false;
var wifi_hover_brightness: f32 = 0.05;
var wifi_hover_scale: f32 = 1.0;

var bt_open: bool = false;
var bt_panel_state: f32 = 0.0;
var bt_hover: bool = false;
var bt_hover_brightness: f32 = 0.05;
var bt_hover_scale: f32 = 1.0;

const no_action: usize = std.math.maxInt(usize);
var wifi_action_idx: usize = no_action;
var wifi_action_timer: f32 = 0;
var wifi_status_buf: [64]u8 = undefined;
var wifi_status: []const u8 = "";

var bt_action_idx: usize = no_action;
var bt_action_timer: f32 = 0;
var bt_status_buf: [64]u8 = undefined;
var bt_status: []const u8 = "";

pub var wifi_pw_mode: bool = false;
var wifi_pw_buf: [128]u8 = [_]u8{0} ** 128;
var wifi_pw_len: usize = 0;
var wifi_pw_target: usize = 0;
var wifi_pw_show: bool = false;
var wifi_pw_show_hover: bool = false;
var wifi_pw_show_hover_bright: f32 = 0.0;
var wifi_panel_full_h: f32 = 54.0;
var wifi_pw_disp_buf: [130]u8 = [_]u8{0} ** 130;
var wifi_pw_label_buf: [80]u8 = [_]u8{0} ** 80;
var wifi_pw_label: []const u8 = "";

const WifiConnectArgs = struct {
    ssid: [64]u8 = [_]u8{0} ** 64,
    ssid_len: usize = 0,
    password: [129]u8 = [_]u8{0} ** 129,
    password_len: usize = 0,
    ap_path: [256]u8 = [_]u8{0} ** 256,
    ap_path_len: usize = 0,
    with_password: bool = false,
};
var wifi_connect_args: WifiConnectArgs = .{};

pub fn wifiPwAppend(chars: []const u8) void {
    const space = wifi_pw_buf.len - wifi_pw_len;
    const n = @min(chars.len, space);
    @memcpy(wifi_pw_buf[wifi_pw_len .. wifi_pw_len + n], chars[0..n]);
    wifi_pw_len += n;
}

pub fn wifiPwBackspace() void {
    if (wifi_pw_len > 0) wifi_pw_len -= 1;
}

pub fn wifiPwConfirm() void {
    if (wifi_pw_target >= wifi_snapshot_count) {
        wifi_pw_mode = false;
        wifi_pw_len = 0;
        return;
    }
    const entry = &wifi_snapshot[wifi_pw_target];
    wifi_connect_args = .{};
    @memcpy(wifi_connect_args.ssid[0..entry.ssid_len], entry.ssid[0..entry.ssid_len]);
    wifi_connect_args.ssid_len = entry.ssid_len;
    @memcpy(wifi_connect_args.ap_path[0..entry.ap_path_len], entry.ap_path[0..entry.ap_path_len]);
    wifi_connect_args.ap_path_len = entry.ap_path_len;
    @memcpy(wifi_connect_args.password[0..wifi_pw_len], wifi_pw_buf[0..wifi_pw_len]);
    wifi_connect_args.password[wifi_pw_len] = 0;
    wifi_connect_args.password_len = wifi_pw_len;
    wifi_connect_args.with_password = true;
    const ct = std.Thread.spawn(.{}, wifiConnectThread, .{}) catch {
        wifi_pw_mode = false;
        wifi_pw_len = 0;
        wifi_pw_show = false;
        return;
    };
    ct.detach();
    wifi_action_idx = wifi_pw_target;
    wifi_action_timer = 5.0;
    wifi_pw_mode = false;
    wifi_pw_len = 0;
    wifi_pw_show = false;
}

pub fn wifiPwCancel() void {
    wifi_pw_mode = false;
    wifi_pw_len = 0;
    wifi_pw_show = false;
}

pub fn handleKey(sym: c.xkb_keysym_t) bool {
    if (sym == c.XKB_KEY_Escape) {
        wifiPwCancel();
        return true;
    } else if (sym == c.XKB_KEY_BackSpace) {
        wifiPwBackspace();
        return true;
    } else if (sym == c.XKB_KEY_Return) {
        wifiPwConfirm();
        return true;
    }
    var buf: [8]u8 = undefined;
    const len = c.xkb_keysym_to_utf8(sym, &buf, buf.len);
    if (len > 1) {
        wifiPwAppend(buf[0..@intCast(len - 1)]);
    }
    return true;
}

pub var anim_time: f32 = 0;

const WifiItemCb = struct { idx: usize };
var wifi_item_cb: [max_net_hover]WifiItemCb = undefined;
var wifi_item_hover: [max_net_hover]bool = [_]bool{false} ** max_net_hover;
var wifi_item_hover_bright: [max_net_hover]f32 = [_]f32{0.0} ** max_net_hover;

const BtItemCb = struct { idx: usize };
var bt_item_cb: [max_net_hover]BtItemCb = undefined;
var bt_item_hover: [max_net_hover]bool = [_]bool{false} ** max_net_hover;
var bt_item_hover_bright: [max_net_hover]f32 = [_]f32{0.0} ** max_net_hover;

var clock_buf: [16]u8 = undefined;
var clock_str: []u8 = clock_buf[0..0];

var date_buf: [32]u8 = undefined;
var date_str: []u8 = date_buf[0..0];

// this is public only because of the fullscreen blur
pub var menu_state: f32 = 0;
// btn_states[0]=Power, [1]=Reboot, [2]=BT, [3]=WiFi, [4]=Capture (right to left)
var btn_states: [5]f32 = [_]f32{0} ** 5;

var capture_hover: bool = false;
var capture_hover_brightness: f32 = 0.05;
var capture_hover_scale: f32 = 1.0;

const max_thumbs = 16;
var thumb_hover: [max_thumbs]bool = [_]bool{false} ** max_thumbs;
var thumb_hover_scale: [max_thumbs]f32 = [_]f32{1.0} ** max_thumbs;
var thumb_hover_brightness: [max_thumbs]f32 = [_]f32{0.05} ** max_thumbs;

var thumb_order: [max_thumbs]Focusable = undefined;
var thumb_order_count: usize = 0;
var thumb_states: [max_thumbs]f32 = [_]f32{0.0} ** max_thumbs;

const ThumbCbData = struct { idx: usize, focusable: Focusable };
var thumb_cb_data: [max_thumbs]ThumbCbData = undefined;

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn refreshWifi() void {
    if (wifi_fetching.swap(true, .acquire)) return;
    const t = std.Thread.spawn(.{}, fetchWifiThread, .{}) catch {
        wifi_fetching.store(false, .release);
        return;
    };
    t.detach();
}

fn nmPropU8(b: *sd.sd_bus, path: [*c]const u8, iface: [*c]const u8, prop: [*c]const u8) u8 {
    var msg: ?*sd.sd_bus_message = null;
    var err: sd.sd_bus_error = std.mem.zeroes(sd.sd_bus_error);
    defer sd.sd_bus_error_free(&err);
    if (sd.sd_bus_get_property(b, NM_DEST, path, iface, prop, &err, &msg, "y") < 0) return 0;
    defer _ = sd.sd_bus_message_unref(msg.?);
    var v: u8 = 0;
    _ = sd.sd_bus_message_read(msg, "y", &v);
    return v;
}

fn nmPropU32(b: *sd.sd_bus, path: [*c]const u8, iface: [*c]const u8, prop: [*c]const u8) u32 {
    var msg: ?*sd.sd_bus_message = null;
    var err: sd.sd_bus_error = std.mem.zeroes(sd.sd_bus_error);
    defer sd.sd_bus_error_free(&err);
    if (sd.sd_bus_get_property(b, NM_DEST, path, iface, prop, &err, &msg, "u") < 0) return 0;
    defer _ = sd.sd_bus_message_unref(msg.?);
    var v: u32 = 0;
    _ = sd.sd_bus_message_read(msg, "u", &v);
    return v;
}

fn nmPropBytes(b: *sd.sd_bus, path: [*c]const u8, iface: [*c]const u8, prop: [*c]const u8, buf: []u8) usize {
    var msg: ?*sd.sd_bus_message = null;
    var err: sd.sd_bus_error = std.mem.zeroes(sd.sd_bus_error);
    defer sd.sd_bus_error_free(&err);
    if (sd.sd_bus_get_property(b, NM_DEST, path, iface, prop, &err, &msg, "ay") < 0) return 0;
    defer _ = sd.sd_bus_message_unref(msg.?);
    var ptr: ?*const anyopaque = null;
    var sz: usize = 0;
    if (sd.sd_bus_message_read_array(msg, 'y', &ptr, &sz) < 0 or ptr == null) return 0;
    const n = @min(sz, buf.len);
    @memcpy(buf[0..n], @as([*]const u8, @ptrCast(ptr.?))[0..n]);
    return n;
}

fn nmPropPath(b: *sd.sd_bus, path: [*c]const u8, iface: [*c]const u8, prop: [*c]const u8, buf: []u8) usize {
    var msg: ?*sd.sd_bus_message = null;
    var err: sd.sd_bus_error = std.mem.zeroes(sd.sd_bus_error);
    defer sd.sd_bus_error_free(&err);
    if (sd.sd_bus_get_property(b, NM_DEST, path, iface, prop, &err, &msg, "o") < 0) return 0;
    defer _ = sd.sd_bus_message_unref(msg.?);
    var s: [*c]const u8 = null;
    if (sd.sd_bus_message_read(msg, "o", &s) < 0 or s == null) return 0;
    const str = std.mem.sliceTo(s, 0);
    const n = @min(str.len, buf.len - 1);
    @memcpy(buf[0..n], str[0..n]);
    buf[n] = 0;
    return n;
}

fn nmConnSsid(b: *sd.sd_bus, conn_path: [*c]const u8, buf: *[64]u8) usize {
    var msg: ?*sd.sd_bus_message = null;
    var err: sd.sd_bus_error = std.mem.zeroes(sd.sd_bus_error);
    defer sd.sd_bus_error_free(&err);
    if (sd.sd_bus_call_method(b, NM_DEST, conn_path, NM_SETTINGS_CONN, "GetSettings", &err, &msg, "") < 0) return 0;
    defer _ = sd.sd_bus_message_unref(msg.?);
    if (sd.sd_bus_message_enter_container(msg, 'a', "{sa{sv}}") < 0) return 0;
    defer _ = sd.sd_bus_message_exit_container(msg);
    while (true) {
        if (sd.sd_bus_message_enter_container(msg, 'e', "sa{sv}") <= 0) break;
        var section: [*c]const u8 = null;
        if (sd.sd_bus_message_read(msg, "s", &section) < 0) {
            _ = sd.sd_bus_message_exit_container(msg);
            break;
        }
        const is_wifi = section != null and std.mem.eql(u8, std.mem.sliceTo(section, 0), "802-11-wireless");
        if (!is_wifi) {
            _ = sd.sd_bus_message_skip(msg, "a{sv}");
            _ = sd.sd_bus_message_exit_container(msg);
            continue;
        }
        if (sd.sd_bus_message_enter_container(msg, 'a', "{sv}") < 0) {
            _ = sd.sd_bus_message_exit_container(msg);
            break;
        }
        var result: usize = 0;
        while (true) {
            if (sd.sd_bus_message_enter_container(msg, 'e', "sv") <= 0) break;
            var key: [*c]const u8 = null;
            if (sd.sd_bus_message_read(msg, "s", &key) < 0) {
                _ = sd.sd_bus_message_exit_container(msg);
                break;
            }
            const is_ssid = key != null and std.mem.eql(u8, std.mem.sliceTo(key, 0), "ssid");
            if (!is_ssid) {
                _ = sd.sd_bus_message_skip(msg, "v");
                _ = sd.sd_bus_message_exit_container(msg);
                continue;
            }
            if (sd.sd_bus_message_enter_container(msg, 'v', "ay") >= 0) {
                var ptr: ?*const anyopaque = null;
                var sz: usize = 0;
                if (sd.sd_bus_message_read_array(msg, 'y', &ptr, &sz) >= 0 and ptr != null) {
                    const n = @min(sz, buf.len);
                    @memcpy(buf[0..n], @as([*]const u8, @ptrCast(ptr.?))[0..n]);
                    result = n;
                }
                _ = sd.sd_bus_message_exit_container(msg);
            }
            _ = sd.sd_bus_message_exit_container(msg);
            break;
        }
        _ = sd.sd_bus_message_exit_container(msg);
        _ = sd.sd_bus_message_exit_container(msg);
        if (result > 0) return result;
    }
    return 0;
}

fn fetchWifiThread() void {
    defer wifi_fetching.store(false, .release);

    var bus: ?*sd.sd_bus = null;
    if (sd.sd_bus_open_system(&bus) < 0) return;
    defer _ = sd.sd_bus_unref(bus);
    const b = bus.?;

    // Find WiFi device path
    var dev_path_buf: [256]u8 = [_]u8{0} ** 256;
    var dev_path_len: usize = 0;
    {
        var msg: ?*sd.sd_bus_message = null;
        var err: sd.sd_bus_error = std.mem.zeroes(sd.sd_bus_error);
        defer sd.sd_bus_error_free(&err);
        if (sd.sd_bus_call_method(b, NM_DEST, NM_PATH, NM_IFACE, "GetDevices", &err, &msg, "") >= 0) {
            defer _ = sd.sd_bus_message_unref(msg.?);
            if (sd.sd_bus_message_enter_container(msg, 'a', "o") >= 0) {
                while (dev_path_len == 0) {
                    var p: [*c]const u8 = null;
                    if (sd.sd_bus_message_read(msg, "o", &p) <= 0) break;
                    if (p == null) continue;
                    if (nmPropU32(b, p, NM_DEV_IFACE, "DeviceType") == 2) {
                        const s = std.mem.sliceTo(p, 0);
                        dev_path_len = @min(s.len, dev_path_buf.len - 1);
                        @memcpy(dev_path_buf[0..dev_path_len], s[0..dev_path_len]);
                    }
                }
                _ = sd.sd_bus_message_exit_container(msg);
            }
        }
    }
    if (dev_path_len == 0) return;
    const dev_path: [*c]const u8 = @ptrCast(&dev_path_buf);

    @memcpy(wifi_device_path[0..dev_path_len + 1], dev_path_buf[0..dev_path_len + 1]);
    wifi_device_path_len = dev_path_len;

    // Get active AP path
    var active_ap_buf: [256]u8 = [_]u8{0} ** 256;
    const active_ap_len = nmPropPath(b, dev_path, NM_DEV_WIFI, "ActiveAccessPoint", &active_ap_buf);
    const active_ap = active_ap_buf[0..active_ap_len];

    // Get known SSIDs from saved connections
    var known_ssids: [max_wifi_entries][64]u8 = undefined;
    var known_ssid_lens: [max_wifi_entries]usize = [_]usize{0} ** max_wifi_entries;
    var known_count: usize = 0;
    {
        var msg: ?*sd.sd_bus_message = null;
        var err: sd.sd_bus_error = std.mem.zeroes(sd.sd_bus_error);
        defer sd.sd_bus_error_free(&err);
        if (sd.sd_bus_call_method(b, NM_DEST, NM_SETTINGS_PATH, NM_SETTINGS_IFACE, "ListConnections", &err, &msg, "") >= 0) {
            defer _ = sd.sd_bus_message_unref(msg.?);
            if (sd.sd_bus_message_enter_container(msg, 'a', "o") >= 0) {
                while (known_count < max_wifi_entries) {
                    var cp: [*c]const u8 = null;
                    if (sd.sd_bus_message_read(msg, "o", &cp) <= 0) break;
                    if (cp == null) continue;
                    const slen = nmConnSsid(b, cp, &known_ssids[known_count]);
                    if (slen > 0) {
                        known_ssid_lens[known_count] = slen;
                        known_count += 1;
                    }
                }
                _ = sd.sd_bus_message_exit_container(msg);
            }
        }
    }

    // Get all access points
    var apmsg: ?*sd.sd_bus_message = null;
    var aperr: sd.sd_bus_error = std.mem.zeroes(sd.sd_bus_error);
    defer sd.sd_bus_error_free(&aperr);
    if (sd.sd_bus_call_method(b, NM_DEST, dev_path, NM_DEV_WIFI, "GetAllAccessPoints", &aperr, &apmsg, "") < 0) return;
    defer _ = sd.sd_bus_message_unref(apmsg.?);

    wifi_mutex.lock();
    defer wifi_mutex.unlock();
    wifi_count = 0;

    if (sd.sd_bus_message_enter_container(apmsg, 'a', "o") < 0) return;
    while (wifi_count < max_wifi_entries) {
        var ap: [*c]const u8 = null;
        if (sd.sd_bus_message_read(apmsg, "o", &ap) <= 0) break;
        if (ap == null) continue;

        var ssid_buf: [64]u8 = [_]u8{0} ** 64;
        const ssid_len = nmPropBytes(b, ap, NM_AP_IFACE, "Ssid", &ssid_buf);
        if (ssid_len == 0) continue;

        var dup = false;
        for (0..wifi_count) |di| {
            if (wifi_entries[di].ssid_len == ssid_len and
                std.mem.eql(u8, wifi_entries[di].ssid[0..ssid_len], ssid_buf[0..ssid_len]))
            {
                dup = true;
                break;
            }
        }
        if (dup) continue;

        const strength = nmPropU8(b, ap, NM_AP_IFACE, "Strength");
        const signal: i32 = @intCast(strength);

        const ap_flags = nmPropU32(b, ap, NM_AP_IFACE, "Flags");
        const wpa_flags = nmPropU32(b, ap, NM_AP_IFACE, "WpaFlags");
        const rsn_flags = nmPropU32(b, ap, NM_AP_IFACE, "RsnFlags");
        const secured = (ap_flags & 1) != 0 or wpa_flags != 0 or rsn_flags != 0;

        const ap_str = std.mem.sliceTo(ap, 0);
        const connected = active_ap_len > 0 and std.mem.eql(u8, ap_str, active_ap);

        var known = false;
        for (0..known_count) |ki| {
            if (known_ssid_lens[ki] == ssid_len and
                std.mem.eql(u8, known_ssids[ki][0..ssid_len], ssid_buf[0..ssid_len]))
            {
                known = true;
                break;
            }
        }

        const e = &wifi_entries[wifi_count];
        e.* = .{};
        const n = @min(ssid_len, e.ssid.len);
        @memcpy(e.ssid[0..n], ssid_buf[0..n]);
        e.ssid_len = n;
        e.connected = connected;
        e.signal = signal;
        e.secured = secured;
        e.known = known;
        const ap_path_len = @min(ap_str.len, e.ap_path.len - 1);
        @memcpy(e.ap_path[0..ap_path_len], ap_str[0..ap_path_len]);
        e.ap_path[ap_path_len] = 0;
        e.ap_path_len = ap_path_len;
        const sig_str = if (e.connected)
            std.fmt.bufPrint(&e.sig_str, "Connected  {d}%", .{signal}) catch ""
        else if (secured)
            std.fmt.bufPrint(&e.sig_str, "{d}%  *", .{signal}) catch ""
        else
            std.fmt.bufPrint(&e.sig_str, "{d}%", .{signal}) catch "";
        e.sig_str_len = sig_str.len;
        wifi_count += 1;
    }
    _ = sd.sd_bus_message_exit_container(apmsg);
}

fn wifiDisconnectThread() void {
    var bus: ?*sd.sd_bus = null;
    if (sd.sd_bus_open_system(&bus) < 0) return;
    defer _ = sd.sd_bus_unref(bus);
    const b = bus.?;

    const dev_path: [*c]const u8 = @ptrCast(&wifi_device_path);
    var err: sd.sd_bus_error = std.mem.zeroes(sd.sd_bus_error);
    defer sd.sd_bus_error_free(&err);
    var reply: ?*sd.sd_bus_message = null;
    _ = sd.sd_bus_call_method(b, NM_DEST, dev_path, NM_DEV_IFACE, "Disconnect", &err, &reply, "");
    if (reply != null) _ = sd.sd_bus_message_unref(reply.?);
}

fn wifiConnectThread() void {
    const args = &wifi_connect_args;
    var bus: ?*sd.sd_bus = null;
    if (sd.sd_bus_open_system(&bus) < 0) return;
    defer _ = sd.sd_bus_unref(bus);
    const b = bus.?;

    const dev_path: [*c]const u8 = @ptrCast(&wifi_device_path);
    args.ap_path[args.ap_path_len] = 0;
    const ap_path: [*c]const u8 = @ptrCast(&args.ap_path);
    const ssid = args.ssid[0..args.ssid_len];

    if (!args.with_password) {
        // Find and activate existing saved connection
        var conn_path_buf: [256]u8 = [_]u8{0} ** 256;
        var conn_path_len: usize = 0;
        {
            var msg: ?*sd.sd_bus_message = null;
            var err: sd.sd_bus_error = std.mem.zeroes(sd.sd_bus_error);
            defer sd.sd_bus_error_free(&err);
            if (sd.sd_bus_call_method(b, NM_DEST, NM_SETTINGS_PATH, NM_SETTINGS_IFACE, "ListConnections", &err, &msg, "") >= 0) {
                defer _ = sd.sd_bus_message_unref(msg.?);
                if (sd.sd_bus_message_enter_container(msg, 'a', "o") >= 0) {
                    while (conn_path_len == 0) {
                        var cp: [*c]const u8 = null;
                        if (sd.sd_bus_message_read(msg, "o", &cp) <= 0) break;
                        if (cp == null) continue;
                        var sbuf: [64]u8 = [_]u8{0} ** 64;
                        const slen = nmConnSsid(b, cp, &sbuf);
                        if (slen == ssid.len and std.mem.eql(u8, sbuf[0..slen], ssid)) {
                            const cp_str = std.mem.sliceTo(cp, 0);
                            conn_path_len = @min(cp_str.len, conn_path_buf.len - 1);
                            @memcpy(conn_path_buf[0..conn_path_len], cp_str[0..conn_path_len]);
                            conn_path_buf[conn_path_len] = 0;
                        }
                    }
                    _ = sd.sd_bus_message_exit_container(msg);
                }
            }
        }
        if (conn_path_len > 0) {
            const conn_path: [*c]const u8 = @ptrCast(&conn_path_buf);
            var err: sd.sd_bus_error = std.mem.zeroes(sd.sd_bus_error);
            defer sd.sd_bus_error_free(&err);
            var reply: ?*sd.sd_bus_message = null;
            _ = sd.sd_bus_call_method(b, NM_DEST, NM_PATH, NM_IFACE, "ActivateConnection", &err, &reply, "ooo", conn_path, dev_path, ap_path);
            if (reply != null) _ = sd.sd_bus_message_unref(reply.?);
        }
    } else {
        // AddAndActivateConnection with password
        var call_msg: ?*sd.sd_bus_message = null;
        if (sd.sd_bus_message_new_method_call(bus, &call_msg, NM_DEST, NM_PATH, NM_IFACE, "AddAndActivateConnection") < 0) return;
        defer _ = sd.sd_bus_message_unref(call_msg.?);
        const m = call_msg.?;

        _ = sd.sd_bus_message_open_container(m, 'a', "{sa{sv}}");
        _ = sd.sd_bus_message_open_container(m, 'e', "sa{sv}");
        _ = sd.sd_bus_message_append(m, "s", @as([*c]const u8, "802-11-wireless"));
        _ = sd.sd_bus_message_open_container(m, 'a', "{sv}");
        _ = sd.sd_bus_message_open_container(m, 'e', "sv");
        _ = sd.sd_bus_message_append(m, "s", @as([*c]const u8, "ssid"));
        _ = sd.sd_bus_message_open_container(m, 'v', "ay");
        _ = sd.sd_bus_message_append_array(m, 'y', ssid.ptr, ssid.len);
        _ = sd.sd_bus_message_close_container(m);
        _ = sd.sd_bus_message_close_container(m);
        _ = sd.sd_bus_message_close_container(m);
        _ = sd.sd_bus_message_close_container(m);
        _ = sd.sd_bus_message_open_container(m, 'e', "sa{sv}");
        _ = sd.sd_bus_message_append(m, "s", @as([*c]const u8, "802-11-wireless-security"));
        _ = sd.sd_bus_message_open_container(m, 'a', "{sv}");
        _ = sd.sd_bus_message_open_container(m, 'e', "sv");
        _ = sd.sd_bus_message_append(m, "s", @as([*c]const u8, "key-mgmt"));
        _ = sd.sd_bus_message_open_container(m, 'v', "s");
        _ = sd.sd_bus_message_append(m, "s", @as([*c]const u8, "wpa-psk"));
        _ = sd.sd_bus_message_close_container(m);
        _ = sd.sd_bus_message_close_container(m);
        _ = sd.sd_bus_message_open_container(m, 'e', "sv");
        _ = sd.sd_bus_message_append(m, "s", @as([*c]const u8, "psk"));
        _ = sd.sd_bus_message_open_container(m, 'v', "s");
        _ = sd.sd_bus_message_append(m, "s", @as([*c]const u8, @ptrCast(&args.password)));
        _ = sd.sd_bus_message_close_container(m);
        _ = sd.sd_bus_message_close_container(m);
        _ = sd.sd_bus_message_close_container(m);
        _ = sd.sd_bus_message_close_container(m);
        _ = sd.sd_bus_message_close_container(m);
        _ = sd.sd_bus_message_append(m, "oo", dev_path, ap_path);

        var err: sd.sd_bus_error = std.mem.zeroes(sd.sd_bus_error);
        defer sd.sd_bus_error_free(&err);
        var reply: ?*sd.sd_bus_message = null;
        _ = sd.sd_bus_call(bus, m, 0, &err, &reply);
        if (reply != null) _ = sd.sd_bus_message_unref(reply.?);
    }
}

fn refreshBt() void {
    if (bt_fetching.swap(true, .acquire)) return;
    const t = std.Thread.spawn(.{}, fetchBtThread, .{}) catch {
        bt_fetching.store(false, .release);
        return;
    };
    t.detach();
}

fn fetchBtThread() void {
    defer bt_fetching.store(false, .release);

    var paired = std.process.Child.init(
        &[_][]const u8{ "bluetoothctl", "--", "devices", "Paired" },
        std.heap.page_allocator,
    );
    paired.stdout_behavior = .Pipe;
    paired.stderr_behavior = .Ignore;
    paired.spawn() catch return;
    const paired_out = paired.stdout.?.readToEndAlloc(std.heap.page_allocator, 16384) catch {
        _ = paired.wait() catch {};
        return;
    };
    defer std.heap.page_allocator.free(paired_out);
    _ = paired.wait() catch {};

    var conn = std.process.Child.init(
        &[_][]const u8{ "bluetoothctl", "--", "devices", "Connected" },
        std.heap.page_allocator,
    );
    conn.stdout_behavior = .Pipe;
    conn.stderr_behavior = .Ignore;
    conn.spawn() catch return;
    const conn_out = conn.stdout.?.readToEndAlloc(std.heap.page_allocator, 16384) catch {
        _ = conn.wait() catch {};
        return;
    };
    defer std.heap.page_allocator.free(conn_out);
    _ = conn.wait() catch {};

    bt_mutex.lock();
    defer bt_mutex.unlock();
    bt_count = 0;
    var lines = std.mem.splitScalar(u8, paired_out, '\n');
    while (lines.next()) |line| {
        if (bt_count >= max_bt_entries) break;
        if (!std.mem.startsWith(u8, line, "Device ")) continue;
        const rest = line[7..];
        if (rest.len < 17) continue;
        const addr = rest[0..17];
        const raw_name = if (rest.len > 18) rest[18..] else addr;
        const name = std.mem.trimRight(u8, raw_name, " \r");
        const e = &bt_entries[bt_count];
        e.* = .{};
        @memcpy(&e.addr, addr);
        const n = @min(name.len, e.name.len);
        @memcpy(e.name[0..n], name[0..n]);
        e.name_len = n;
        e.connected = std.mem.indexOf(u8, conn_out, addr) != null;
        bt_count += 1;
    }
}

pub fn toggleMenu() void {
    if (ui.beacon_open == false and !ui.screenshot.isActive()) ui.menu_open = !ui.menu_open;
}

pub fn tick(dt: f32) void {
    menu_state = lerp(menu_state, if (ui.menu_open) 1.0 else 0.0, dt * 20.0);

    // Close cluster when menu closes
    if (!ui.menu_open) cluster_open = false;

    // Power cluster animation
    cluster_state = lerp(cluster_state, if (cluster_open) 1.0 else 0.0, dt * 16.0);
    const css = dt * 10.0;
    if (cluster_open) {
        cluster_sub_states[0] = @min(1.0, lerp(cluster_sub_states[0], 1.0, css));
        if (cluster_sub_states[0] > 0.5) cluster_sub_states[1] = @min(1.0, lerp(cluster_sub_states[1], 1.0, css));
        if (cluster_sub_states[1] > 0.5) cluster_sub_states[2] = @min(1.0, lerp(cluster_sub_states[2], 1.0, css));
    } else {
        cluster_sub_states[0] = @max(0.0, lerp(cluster_sub_states[0], 0.0, css));
        if (cluster_sub_states[0] < 0.5) cluster_sub_states[1] = @max(0.0, lerp(cluster_sub_states[1], 0.0, css));
        if (cluster_sub_states[1] < 0.5) cluster_sub_states[2] = @max(0.0, lerp(cluster_sub_states[2], 0.0, css));
    }

    // Stagger power cluster, BT, WiFi, Capture buttons
    const bs = dt * 12.0;
    if (ui.menu_open) {
        btn_states[0] = @min(1.0, lerp(btn_states[0], 1.0, bs));
        if (btn_states[0] > 0.3) btn_states[2] = @min(1.0, lerp(btn_states[2], 1.0, bs));
        if (btn_states[2] > 0.3) btn_states[3] = @min(1.0, lerp(btn_states[3], 1.0, bs));
        if (btn_states[3] > 0.3) btn_states[4] = @min(1.0, lerp(btn_states[4], 1.0, bs));
    } else {
        btn_states[0] = @max(0.0, lerp(btn_states[0], 0.0, bs));
        if (btn_states[0] < 0.7) btn_states[2] = @max(0.0, lerp(btn_states[2], 0.0, bs));
        if (btn_states[2] < 0.7) btn_states[3] = @max(0.0, lerp(btn_states[3], 0.0, bs));
        if (btn_states[3] < 0.7) btn_states[4] = @max(0.0, lerp(btn_states[4], 0.0, bs));
    }

    const ts = c.time(null);
    const tm = c.localtime(&ts);
    clock_str = std.fmt.bufPrint(&clock_buf, "{d:0>2}:{d:0>2}", .{
        @as(u32, @intCast(tm.*.tm_hour)),
        @as(u32, @intCast(tm.*.tm_min)),
    }) catch clock_buf[0..0];

    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const month_idx: usize = @intCast(tm.*.tm_mon);
    const day_idx: usize = @intCast(tm.*.tm_wday);
    date_str = std.fmt.bufPrint(&date_buf, "{s}, {d} {s}", .{
        day_names[day_idx],
        @as(u32, @intCast(tm.*.tm_mday)),
        month_names[month_idx],
    }) catch date_buf[0..0];

    // Stagger thumbnails: each one waits for the previous to nearly finish
    const ts2 = dt * 18.0;
    if (ui.menu_open) {
        for (0..thumb_order_count) |i| {
            if (i == 0 or thumb_states[i - 1] > 0.2) {
                thumb_states[i] = @min(1.0, lerp(thumb_states[i], 1.0, ts2));
            }
        }
    } else {
        for (0..thumb_order_count) |i| {
            if (i == 0 or thumb_states[i - 1] < 0.8) {
                thumb_states[i] = @max(0.0, lerp(thumb_states[i], 0.0, ts2));
            }
        }
    }

    // animate hover states
    const speed = dt * 14.0;
    for (0..max_thumbs) |i| {
        const target_scale: f32 = if (thumb_hover[i]) 1.06 else 1.0;
        const target_brightness: f32 = if (thumb_hover[i]) 0.14 else 0.05;
        thumb_hover_scale[i] = lerp(thumb_hover_scale[i], target_scale, speed);
        thumb_hover_brightness[i] = lerp(thumb_hover_brightness[i], target_brightness, speed);
        thumb_hover[i] = false; // reset each frame, set again by OnHover
    }
    // Cluster hover brightness per button
    for (0..4) |i| {
        cluster_hover_bright[i] = lerp(cluster_hover_bright[i], if (cluster_hover[i]) 0.18 else 0.05, speed);
        cluster_hover_scale[i] = lerp(cluster_hover_scale[i], if (cluster_hover[i]) 1.06 else 1.0, speed);
        cluster_hover[i] = false;
    }

    anim_time += dt;
    wifi_panel_state = lerp(wifi_panel_state, if (wifi_open) 1.0 else 0.0, dt * 20.0);
    bt_panel_state = lerp(bt_panel_state, if (bt_open) 1.0 else 0.0, dt * 20.0);
    {
        const s = ui.ui_scale;
        const item_h: f32 = 38 * s;
        const pad: f32 = 14 * s;
        const list_vis: usize = @min(wifi_snapshot_count, 6);
        // pw mode: label (16s) + gap (8s) + input (54s) = 78s
        const target_list_h: f32 = if (wifi_pw_mode) item_h + 24 * s else if (list_vis == 0) item_h else @as(f32, @floatFromInt(list_vis)) * item_h;
        wifi_panel_full_h = lerp(wifi_panel_full_h, pad * 2 + target_list_h, dt * 25.0);
    }

    if (wifi_action_idx != no_action) {
        wifi_action_timer -= dt;
        if (wifi_action_timer <= 0) {
            wifi_action_idx = no_action;
            wifi_status = "";
            refreshWifi();
        }
    }
    if (bt_action_idx != no_action) {
        bt_action_timer -= dt;
        if (bt_action_timer <= 0) {
            bt_action_idx = no_action;
            bt_status = "";
            refreshBt();
        }
    }
    wifi_hover_brightness = lerp(wifi_hover_brightness, if (wifi_hover and wifi_panel_state < 0.05) 0.18 else 0.05, speed);
    wifi_hover_scale = lerp(wifi_hover_scale, if (wifi_hover and wifi_panel_state < 0.05) 1.06 else 1.0, speed);
    bt_hover_brightness = lerp(bt_hover_brightness, if (bt_hover and bt_panel_state < 0.05) 0.18 else 0.05, speed);
    bt_hover_scale = lerp(bt_hover_scale, if (bt_hover and bt_panel_state < 0.05) 1.06 else 1.0, speed);
    capture_hover_brightness = lerp(capture_hover_brightness, if (capture_hover) 0.18 else 0.05, speed);
    capture_hover_scale = lerp(capture_hover_scale, if (capture_hover) 1.06 else 1.0, speed);
    wifi_hover = false;
    bt_hover = false;
    capture_hover = false;

    // close panel on click outside
    const pressed_this_frame = ui.pointer_down and !prev_pointer_down;
    if (pressed_this_frame) {
        if (wifi_open and !zclay.pointerOver(zclay.ElementId.ID("WifiBtn"))) {
            wifi_open = false;
            wifi_pw_mode = false;
            wifi_pw_len = 0;
            wifi_pw_show = false;
        }
        if (bt_open and !zclay.pointerOver(zclay.ElementId.ID("BtBtn"))) bt_open = false;
        // Close the power cluster if clicking outside all its buttons
        if (cluster_open and
            !zclay.pointerOver(zclay.ElementId.ID("ClusterBtnCenter")) and
            !zclay.pointerOver(zclay.ElementId.ID("ClusterBtnPower")) and
            !zclay.pointerOver(zclay.ElementId.ID("ClusterBtnSleep")) and
            !zclay.pointerOver(zclay.ElementId.ID("ClusterBtnRestart")))
        {
            cluster_open = false;
        }
    }
    prev_pointer_down = ui.pointer_down;

    wifi_pw_show_hover_bright = lerp(wifi_pw_show_hover_bright, if (wifi_pw_show_hover) 0.14 else 0.0, speed);
    wifi_pw_show_hover = false;

    for (0..max_net_hover) |i| {
        wifi_item_hover_bright[i] = lerp(wifi_item_hover_bright[i], if (wifi_item_hover[i]) 0.09 else 0.0, speed);
        wifi_item_hover[i] = false;
        bt_item_hover_bright[i] = lerp(bt_item_hover_bright[i], if (bt_item_hover[i]) 0.09 else 0.0, speed);
        bt_item_hover[i] = false;
    }
    if (!ui.menu_open and menu_state < 0.01) {
        wifi_open = false;
        wifi_pw_mode = false;
        wifi_pw_len = 0;
        bt_open = false;
    }
}

pub fn isActive() bool {
    return ui.menu_open or menu_state > 0.0001 or btn_states[0] > 0.0001 or btn_states[2] > 0.0001 or btn_states[3] > 0.0001 or btn_states[4] > 0.0001;
}

pub fn layout(_: ?*Focusable, focusables: ?[]*Focusable) void {
    if (!isActive()) return;

    const s = ui.ui_scale;
    const clock_x_off: f32 = lerp(-300.0 * s, 40.0 * s, menu_state);
    // const shadow_x_off: f32 = lerp(-620.0, -320.0, menu_state);

    // TODO: add shadow behind clock text
    //    zclay.UI()(.{
    //        .id = .ID("ClockShadow"),
    //        .floating = .{
    //            .attach_to = .to_root,
    //            .attach_points = .{ .element = .left_bottom, .parent = .left_bottom },
    //            .offset = .{ .x = shadow_x_off, .y = -40 },
    //        },
    //        .layout = .{
    //            .sizing = .{ .w = .fixed(300), .h = .fixed(140) },
    //        },
    //        .custom = .{ .custom_data = ui.mkAnimatedShadow(120, menu_state, 1.00) },
    //    })({});

    // text element, 40px from left and bottom edges
    zclay.UI()(.{
        .id = .ID("ClockText"),
        .floating = .{
            .attach_to = .to_root,
            .attach_points = .{ .element = .left_bottom, .parent = .left_bottom },
            .offset = .{ .x = clock_x_off, .y = -40 * s },
        },
        .layout = .{
            .direction = .top_to_bottom,
            .sizing = .{ .w = .fit, .h = .fit },
            .padding = .{ .top = @intFromFloat(10 * s), .bottom = @intFromFloat(10 * s), .left = 0, .right = 0 },
            .child_gap = @intFromFloat(12 * s),
        },
    })({
        const date_font_size: u16 = @intFromFloat(24 * s);
        zclay.text(date_str, .{ .font_size = date_font_size, .color = .{ 255, 255, 255, 160 } });
        const clock_font_size: u16 = @intFromFloat(96 * s);
        const clock_sz = ui.textSize(clock_str, clock_font_size);
        zclay.UI()(.{
            .id = .ID("ClockText2"),
            .layout = .{ .sizing = .{ .w = .fixed(clock_sz.w), .h = .fixed(clock_sz.h) } },
            .custom = .{ .custom_data = ui.mkGlassText(clock_str, clock_font_size, true) },
        })({});
    });

    const top_y = ui.screen_height - 40.0 * s;
    const btn_y = [3]f32{
        lerp(ui.screen_height + 200.0 * s, top_y, btn_states[2]),
        lerp(ui.screen_height + 200.0 * s, top_y, btn_states[3]),
        lerp(ui.screen_height + 200.0 * s, top_y, btn_states[4]),
    };

    const bt_w = lerp(54 * s, 300 * s, bt_panel_state);

    // Bluetooth button (morphs into panel on click)
    {
        if (bt_panel_state > 0.005) {
            bt_mutex.lock();
            bt_snapshot_count = bt_count;
            if (bt_count > 0) @memcpy(bt_snapshot[0..bt_count], bt_entries[0..bt_count]);
            bt_mutex.unlock();
        }
        const item_h: f32 = 54 * s;
        const pad: f32 = 14 * s;
        const bt_vis: usize = @min(bt_snapshot_count, 6);
        const list_h: f32 = if (bt_vis == 0) item_h else @as(f32, @floatFromInt(bt_vis)) * item_h;
        const full_h: f32 = pad * 2 + list_h;
        const bt_h = lerp(54 * s, full_h, bt_panel_state);
        const bt_r = 27 * s;
        const bt_pad: u16 = @intFromFloat(@max(0.0, pad * bt_panel_state));
        zclay.UI()(.{
            .id = .ID("BtBtn"),
            .floating = .{
                .attach_to = .to_root,
                .attach_points = .{ .element = .right_bottom, .parent = .right_top },
                .offset = .{ .x = -40 * s, .y = btn_y[0] },
            },
            .layout = .{
                .direction = .top_to_bottom,
                .sizing = .{ .w = .fixed(bt_w), .h = .fixed(bt_h) },
                .child_alignment = if (bt_panel_state < 0.15) .{ .x = .center, .y = .center } else .{ .x = .left, .y = .top },
                .padding = .{ .top = bt_pad, .bottom = bt_pad, .left = bt_pad, .right = bt_pad },
            },
            .custom = .{ .custom_data = ui.mkAnimatedGlass(bt_r, btn_states[2] * bt_hover_scale, 10.0 * s, bt_hover_brightness) },
        })({
            zclay.cdefs.Clay_OnHover(struct {
                pub fn callback(_: zclay.ElementId, ptr_data: zclay.PointerData, _: ?*anyopaque) callconv(.c) void {
                    bt_hover = true;
                    if (ptr_data.state == .pressed_this_frame) {
                        if (!bt_open) {
                            bt_open = true;
                            wifi_open = false;
                            refreshBt();
                        }
                    }
                }
            }.callback, null);
            if (bt_panel_state < 0.15) {
                zclay.UI()(.{
                    .id = .ID("BtIcon"),
                    .layout = .{ .sizing = .{ .w = .fixed(32 * s * bt_hover_scale), .h = .fixed(32 * s * bt_hover_scale) } },
                    .custom = .{ .custom_data = ui.mkIcon(std.heap.page_allocator, "_bluetooth", 1.0) },
                })({});
            } else {
                if (bt_vis == 0) {
                    const label: []const u8 = if (bt_fetching.load(.acquire)) "Scanning..." else "No devices";
                    const fsz: u16 = @intFromFloat(14 * s);
                    zclay.text(label, .{ .font_size = fsz, .color = .{ 255, 255, 255, 140 } });
                } else {
                    if (bt_status.len > 0) {
                        const sfsz: u16 = @intFromFloat(12 * s);
                        zclay.text(bt_status, .{ .font_size = sfsz, .color = .{ 255, 255, 255, 160 } });
                    }
                    for (0..bt_vis) |i| {
                        const e = &bt_snapshot[i];
                        bt_item_cb[i] = .{ .idx = i };
                        const item_px: u16 = @intFromFloat(10 * s);
                        zclay.UI()(.{
                            .id = .IDI("BtItem", @intCast(i)),
                            .layout = .{
                                .direction = .left_to_right,
                                .sizing = .{ .w = .grow, .h = .fixed(item_h) },
                                .child_alignment = .{ .x = .left, .y = .center },
                                .padding = .{ .left = item_px, .right = item_px },
                                .child_gap = @as(u16, @intFromFloat(8 * s)),
                            },
                            .custom = .{ .custom_data = ui.mkRect(8 * s, bt_item_hover_bright[i]) },
                        })({
                            zclay.cdefs.Clay_OnHover(struct {
                                pub fn callback(_: zclay.ElementId, ptr_data: zclay.PointerData, user_data: ?*anyopaque) callconv(.c) void {
                                    const d: *BtItemCb = @ptrCast(@alignCast(user_data.?));
                                    bt_item_hover[d.idx] = true;
                                    if (ptr_data.state == .pressed_this_frame and bt_action_idx == no_action) {
                                        const entry = &bt_snapshot[d.idx];
                                        if (entry.connected) {
                                            main.spawnCmd(&[_][]const u8{ "bluetoothctl", "--", "disconnect", entry.addr[0..] });
                                            bt_status = std.fmt.bufPrint(&bt_status_buf, "Disconnecting...", .{}) catch "";
                                        } else {
                                            main.spawnCmd(&[_][]const u8{ "bluetoothctl", "--", "connect", entry.addr[0..] });
                                            bt_status = std.fmt.bufPrint(&bt_status_buf, "Connecting to {s}...", .{entry.name[0..entry.name_len]}) catch "";
                                        }
                                        bt_action_idx = d.idx;
                                        bt_action_timer = 5.0;
                                    }
                                }
                            }.callback, &bt_item_cb[i]);
                            const fsz: u16 = @intFromFloat(15 * s);
                            zclay.text(e.name[0..e.name_len], .{ .font_size = fsz, .color = if (e.connected) .{ 255, 255, 255, 255 } else .{ 255, 255, 255, 200 } });
                            {
                                const lfsz: u16 = @intFromFloat(12 * s);
                                const spinner_frames = [_][]const u8{ "|", "/", "-", "\\" };
                                const spin_idx: usize = @as(usize, @intFromFloat(anim_time * 8)) % spinner_frames.len;
                                const sub_lbl: []const u8 = if (bt_action_idx == i)
                                    spinner_frames[spin_idx]
                                else if (e.connected)
                                    "Connected"
                                else
                                    "";
                                if (sub_lbl.len > 0) {
                                    zclay.UI()(.{
                                        .id = .IDI("BtSpacer", @intCast(i)),
                                        .layout = .{ .sizing = .{ .w = .grow, .h = .fixed(1) } },
                                    })({});
                                    zclay.text(sub_lbl, .{ .font_size = lfsz, .color = .{ 255, 255, 255, 150 } });
                                }
                            }
                        });
                    }
                }
            }
        });
    }

    // WiFi button (morphs into panel on click)
    {
        if (wifi_panel_state > 0.005) {
            wifi_mutex.lock();
            wifi_snapshot_count = wifi_count;
            if (wifi_count > 0) @memcpy(wifi_snapshot[0..wifi_count], wifi_entries[0..wifi_count]);
            wifi_mutex.unlock();
        }
        const item_h: f32 = 38 * s;
        const pad: f32 = 14 * s;
        const wifi_vis: usize = if (wifi_pw_mode) 0 else @min(wifi_snapshot_count, 6);
        const wifi_w = lerp(54 * s, 300 * s, wifi_panel_state);
        const wifi_h = lerp(54 * s, wifi_panel_full_h, wifi_panel_state);
        const wifi_r = 27 * s;
        const wifi_pad: u16 = @intFromFloat(@max(0.0, pad * wifi_panel_state));
        const wifi_offset_x = -40 * s - bt_w - 12 * s;
        zclay.UI()(.{
            .id = .ID("WifiBtn"),
            .floating = .{
                .attach_to = .to_root,
                .attach_points = .{ .element = .right_bottom, .parent = .right_top },
                .offset = .{ .x = wifi_offset_x, .y = btn_y[1] },
            },
            .layout = .{
                .direction = .top_to_bottom,
                .sizing = .{ .w = .fixed(wifi_w), .h = .fixed(wifi_h) },
                .child_alignment = if (!wifi_open or wifi_panel_state < 0.15) .{ .x = .center, .y = .center } else if (wifi_pw_mode) .{ .x = .left, .y = .center } else .{ .x = .left, .y = .top },
                .padding = .{ .top = wifi_pad, .bottom = wifi_pad, .left = wifi_pad, .right = wifi_pad },
            },
            .custom = .{ .custom_data = ui.mkAnimatedGlass(wifi_r, btn_states[3] * wifi_hover_scale, 10.0 * s, wifi_hover_brightness) },
        })({
            zclay.cdefs.Clay_OnHover(struct {
                pub fn callback(_: zclay.ElementId, ptr_data: zclay.PointerData, _: ?*anyopaque) callconv(.c) void {
                    wifi_hover = true;
                    if (ptr_data.state == .pressed_this_frame) {
                        if (!wifi_open) {
                            wifi_open = true;
                            bt_open = false;
                            refreshWifi();
                        }
                    }
                }
            }.callback, null);
            if (!wifi_open or wifi_panel_state < 0.15) {
                var conn_signal: i32 = -1;
                for (wifi_snapshot[0..wifi_snapshot_count]) |we| {
                    if (we.connected) { conn_signal = we.signal; break; }
                }
                const btn_sig_icon: []const u8 = if (conn_signal >= 80)
                    "network-wireless-signal-excellent-symbolic"
                else if (conn_signal >= 60)
                    "network-wireless-signal-good-symbolic"
                else if (conn_signal >= 40)
                    "network-wireless-signal-ok-symbolic"
                else if (conn_signal >= 0)
                    "network-wireless-signal-weak-symbolic"
                else
                    "network-wireless-symbolic";
                zclay.UI()(.{
                    .id = .ID("WifiIcon"),
                    .layout = .{ .sizing = .{ .w = .fixed(32 * s * wifi_hover_scale), .h = .fixed(32 * s * wifi_hover_scale) } },
                    .custom = .{ .custom_data = ui.mkIcon(std.heap.page_allocator, btn_sig_icon, 1.0) },
                })({});
            } else if (wifi_pw_mode) {
                const target = &wifi_snapshot[wifi_pw_target];
                wifi_pw_label = std.fmt.bufPrint(&wifi_pw_label_buf, "Password for {s}", .{target.ssid[0..target.ssid_len]}) catch "Password";

                @memset(&wifi_pw_disp_buf, 0);
                if (wifi_pw_show) {
                    @memcpy(wifi_pw_disp_buf[0..wifi_pw_len], wifi_pw_buf[0..wifi_pw_len]);
                } else {
                    for (0..wifi_pw_len) |k| wifi_pw_disp_buf[k] = '*';
                }
                const cursor_on = @as(usize, @intFromFloat(anim_time * 2)) % 2 == 0;
                if (wifi_pw_len > 0 and cursor_on) wifi_pw_disp_buf[wifi_pw_len] = '|';
                const disp_len: usize = if (wifi_pw_len > 0) (if (cursor_on) wifi_pw_len + 1 else wifi_pw_len) else 0;

                zclay.UI()(.{
                    .id = .ID("WifiPwContainer"),
                    .layout = .{
                        .direction = .top_to_bottom,
                        .sizing = .{ .w = .grow, .h = .fit },
                        .child_alignment = .{ .x = .left, .y = .top },
                        .child_gap = @as(u16, @intFromFloat(8 * s)),
                    },
                })({
                    const lfsz: u16 = @intFromFloat(13 * s);
                    zclay.text(wifi_pw_label, .{ .font_size = lfsz, .color = .{ 255, 255, 255, 180 } });

                    const ifsz: u16 = @intFromFloat(16 * s);
                    const item_px: u16 = @intFromFloat(8 * s);
                    const eye_w: f32 = item_h * 0.65;
                    const icon_name: []const u8 = if (wifi_pw_show) "password-show-off" else "password-show-on";
                    zclay.UI()(.{
                        .id = .ID("WifiPwInput"),
                        .layout = .{
                            .direction = .left_to_right,
                            .sizing = .{ .w = .grow, .h = .fixed(item_h) },
                            .child_alignment = .{ .x = .left, .y = .center },
                            .padding = .{ .left = item_px, .right = @as(u16, @intFromFloat(4 * s)) },
                            .child_gap = @as(u16, @intFromFloat(4 * s)),
                        },
                        .custom = .{ .custom_data = ui.mkRect(8 * s, 0.13) },
                    })({
                        zclay.UI()(.{
                            .id = .ID("WifiPwText"),
                            .layout = .{
                                .sizing = .{ .w = .grow, .h = .grow },
                                .child_alignment = .{ .x = .left, .y = .center },
                            },
                        })({
                            if (disp_len == 0) {
                                zclay.text("Enter password...", .{ .font_size = ifsz, .color = .{ 255, 255, 255, 60 } });
                            } else {
                                zclay.text(wifi_pw_disp_buf[0..disp_len], .{ .font_size = ifsz, .color = .{ 255, 255, 255, 230 } });
                            }
                        });
                        zclay.UI()(.{
                            .id = .ID("WifiPwEyeBtn"),
                            .layout = .{
                                .sizing = .{ .w = .fixed(eye_w), .h = .grow },
                                .child_alignment = .{ .x = .center, .y = .center },
                            },
                            .custom = .{ .custom_data = ui.mkRect(6 * s, wifi_pw_show_hover_bright) },
                        })({
                            zclay.cdefs.Clay_OnHover(struct {
                                pub fn callback(_: zclay.ElementId, ptr_data: zclay.PointerData, _: ?*anyopaque) callconv(.c) void {
                                    wifi_pw_show_hover = true;
                                    if (ptr_data.state == .pressed_this_frame) {
                                        wifi_pw_show = !wifi_pw_show;
                                    }
                                }
                            }.callback, null);
                            const icon_sz: f32 = 18 * s;
                            zclay.UI()(.{
                                .id = .ID("WifiPwEyeIcon"),
                                .layout = .{ .sizing = .{ .w = .fixed(icon_sz), .h = .fixed(icon_sz) } },
                                .custom = .{ .custom_data = ui.mkIcon(std.heap.page_allocator, icon_name, if (wifi_pw_show_hover) 1.0 else 0.5) },
                            })({});
                        });
                    });
                });
            } else {
                if (wifi_vis == 0) {
                    const label: []const u8 = if (wifi_fetching.load(.acquire)) "Scanning..." else "No networks";
                    const fsz: u16 = @intFromFloat(14 * s);
                    zclay.text(label, .{ .font_size = fsz, .color = .{ 255, 255, 255, 140 } });
                } else {
                    for (0..wifi_vis) |i| {
                        const e = &wifi_snapshot[i];
                        wifi_item_cb[i] = .{ .idx = i };
                        const item_px: u16 = @intFromFloat(10 * s);
                        zclay.UI()(.{
                            .id = .IDI("WifiItem", @intCast(i)),
                            .layout = .{
                                .direction = .left_to_right,
                                .sizing = .{ .w = .grow, .h = .fixed(item_h) },
                                .child_alignment = .{ .x = .left, .y = .center },
                                .padding = .{ .left = item_px, .right = item_px },
                                .child_gap = @as(u16, @intFromFloat(8 * s)),
                            },
                            .custom = .{ .custom_data = ui.mkRect(8 * s, wifi_item_hover_bright[i]) },
                        })({
                            zclay.cdefs.Clay_OnHover(struct {
                                pub fn callback(_: zclay.ElementId, ptr_data: zclay.PointerData, user_data: ?*anyopaque) callconv(.c) void {
                                    const d: *WifiItemCb = @ptrCast(@alignCast(user_data.?));
                                    wifi_item_hover[d.idx] = true;
                                    if (ptr_data.state == .pressed_this_frame and wifi_action_idx == no_action) {
                                        const entry = &wifi_snapshot[d.idx];
                                        if (entry.connected) {
                                            const dt = std.Thread.spawn(.{}, wifiDisconnectThread, .{}) catch return;
                                            dt.detach();
                                            wifi_action_idx = d.idx;
                                            wifi_action_timer = 5.0;
                                        } else if (entry.secured and !entry.known) {
                                            wifi_pw_target = d.idx;
                                            wifi_pw_mode = true;
                                            wifi_pw_len = 0;
                                        } else {
                                            wifi_connect_args = .{};
                                            @memcpy(wifi_connect_args.ssid[0..entry.ssid_len], entry.ssid[0..entry.ssid_len]);
                                            wifi_connect_args.ssid_len = entry.ssid_len;
                                            @memcpy(wifi_connect_args.ap_path[0..entry.ap_path_len], entry.ap_path[0..entry.ap_path_len]);
                                            wifi_connect_args.ap_path_len = entry.ap_path_len;
                                            wifi_connect_args.with_password = false;
                                            const ct = std.Thread.spawn(.{}, wifiConnectThread, .{}) catch return;
                                            ct.detach();
                                            wifi_action_idx = d.idx;
                                            wifi_action_timer = 5.0;
                                        }
                                    }
                                }
                            }.callback, &wifi_item_cb[i]);
                            const loading = wifi_action_idx == i;
                            const icon_sz: f32 = 20 * s;
                            const sig_icon: []const u8 = if (e.secured)
                                "network-wireless-encrypted-symbolic"
                            else if (e.signal >= 80)
                                "network-wireless-signal-excellent-symbolic"
                            else if (e.signal >= 60)
                                "network-wireless-signal-good-symbolic"
                            else if (e.signal >= 40)
                                "network-wireless-signal-ok-symbolic"
                            else
                                "network-wireless-signal-weak-symbolic";
                            zclay.UI()(.{
                                .id = .IDI("WifiSigIcon", @intCast(i)),
                                .layout = .{ .sizing = .{ .w = .fixed(icon_sz), .h = .fixed(icon_sz) } },
                                .custom = .{ .custom_data = ui.mkIcon(std.heap.page_allocator, sig_icon, 0.9) },
                            })({});
                            if (loading) {
                                zclay.UI()(.{
                                    .id = .IDI("WifiSpinner", @intCast(i)),
                                    .layout = .{ .sizing = .{ .w = .fixed(icon_sz), .h = .fixed(icon_sz) } },
                                    .custom = .{ .custom_data = ui.mkSpinner(anim_time) },
                                })({});
                            } else if (e.connected) {
                                zclay.UI()(.{
                                    .id = .IDI("WifiCheck", @intCast(i)),
                                    .layout = .{ .sizing = .{ .w = .fixed(icon_sz), .h = .fixed(icon_sz) } },
                                    .custom = .{ .custom_data = ui.mkIcon(std.heap.page_allocator, "object-select-symbolic", 0.9) },
                                })({});
                            }
                            const fsz: u16 = @intFromFloat(14 * s);
                            zclay.text(e.ssid[0..e.ssid_len], .{ .font_size = fsz, .color = if (e.connected) .{ 255, 255, 255, 255 } else .{ 255, 255, 255, 200 } });
                        });
                    }
                }
            }
        });
    }

    // Capture button (screenshot / recording)
    {
        const is_rec = recording.isRecording();
        const cap_r = 27 * s;
        const cap_btn_w: f32 = 54 * s;
        const cap_offset_x: f32 = -40 * s - bt_w - 12 * s - lerp(54 * s, 300 * s, wifi_panel_state) - 12 * s;
        zclay.UI()(.{
            .id = .ID("CaptureBtn"),
            .floating = .{
                .attach_to = .to_root,
                .attach_points = .{ .element = .right_bottom, .parent = .right_top },
                .offset = .{ .x = cap_offset_x, .y = btn_y[2] },
            },
            .layout = .{
                .sizing = .{ .w = .fixed(cap_btn_w), .h = .fixed(54 * s) },
                .child_alignment = .{ .x = .center, .y = .center },
                .direction = .top_to_bottom,
                .child_gap = @intFromFloat(4 * s),
            },
            .custom = .{ .custom_data = if (is_rec)
                ui.mkRectColor(cap_r, 1.0, 0.45, 0.05, btn_states[4] * capture_hover_scale)
            else
                ui.mkAnimatedGlass(cap_r, btn_states[4] * capture_hover_scale, 10.0 * s, capture_hover_brightness) },
        })({
            zclay.cdefs.Clay_OnHover(struct {
                pub fn callback(_: zclay.ElementId, ptr_data: zclay.PointerData, _: ?*anyopaque) callconv(.c) void {
                    capture_hover = true;
                    if (ptr_data.state == .pressed_this_frame) {
                        if (recording.isRecording()) {
                            recording.stop();
                        } else {
                            screenshot.activate();
                        }
                    }
                }
            }.callback, null);
            zclay.UI()(.{
                .id = .ID("CaptureIcon"),
                .layout = .{ .sizing = .{ .w = .fixed(32 * s * capture_hover_scale), .h = .fixed(32 * s * capture_hover_scale) } },
                .custom = .{ .custom_data = ui.mkIcon(std.heap.page_allocator, "media-record-symbolic", 1.0) },
            })({});
        });
    }

    // focs = all windows except the currently focused one — exactly what we want to show
    const focs = focusables orelse return;
    if (focs.len == 0) return;

    // Reconcile: keep stable order, drop closed windows, append newly opened ones
    {
        var new_count: usize = 0;
        for (thumb_order[0..thumb_order_count]) |fo| {
            for (focs) |f| {
                if (f.cmp(&fo)) {
                    thumb_order[new_count] = fo;
                    new_count += 1;
                    break;
                }
            }
        }
        thumb_order_count = new_count;
        for (focs) |fo| {
            var found = false;
            for (thumb_order[0..thumb_order_count]) |existing| {
                if (existing.cmp(fo)) { found = true; break; }
            }
            if (!found and thumb_order_count < max_thumbs) {
                thumb_order[thumb_order_count] = fo.*;
                thumb_order_count += 1;
            }
        }
    }

    const n = thumb_order_count;
    if (n == 0) return;

    const padding: f32 = 16.0 * s;
    const gap: f32 = 32.0 * s;

    const avail_w = ui.screen_width * 0.6;
    const avail_h = ui.screen_height * 0.6;

    // Square grid: cols = ceil(sqrt(n))
    const n_f: f32 = @floatFromInt(n);
    const cols_f = @ceil(@sqrt(n_f));
    const cols: usize = @intFromFloat(@max(1.0, @min(cols_f, n_f)));
    const rows: usize = (n + cols - 1) / cols;

    const cols_f2: f32 = @floatFromInt(cols);
    const rows_f: f32 = @floatFromInt(rows);
    const cell_w = (avail_w - gap * (cols_f2 - 1.0)) / cols_f2;
    const cell_h = (avail_h - gap * (rows_f - 1.0)) / rows_f;

    zclay.UI()(.{
        .id = .ID("Menu"),
        .layout = .{
            .sizing = .grow,
            .direction = .top_to_bottom,
            .child_alignment = .{ .x = .center, .y = .center },
            .child_gap = @intFromFloat(gap),
        },
    })({
        var idx: usize = 0;
        for (0..rows) |row| {
            const row_cols = @min(cols, n - row * cols);
            zclay.UI()(.{
                .id = .IDI("MenuRow", @intCast(row)),
                .layout = .{
                    .direction = .left_to_right,
                    .sizing = .{ .w = .fit, .h = .fit },
                    .child_alignment = .{ .x = .center, .y = .center },
                    .child_gap = @intFromFloat(gap),
                },
            })({
                for (0..row_cols) |_| {
                    if (idx >= n) break;
                    const focusable = thumb_order[idx];
                    const surf = focusable.surface();
                    const surf_w: f32 = @floatFromInt(surf.current.width);
                    const surf_h: f32 = @floatFromInt(surf.current.height);
                    const scale = @min(
                        (cell_w - padding * 2.0) / surf_w,
                        (cell_h - padding * 2.0) / surf_h,
                    );
                    const thumb_w = surf_w * scale + padding * 2.0;
                    const thumb_h = surf_h * scale + padding * 2.0;
                    thumb_cb_data[idx] = .{ .idx = idx, .focusable = focusable };
                    const combined_scale = thumb_states[idx] * thumb_hover_scale[idx];
                    zclay.UI()(.{
                        .id = .IDI("Thumb", @intCast(idx)),
                        .layout = .{
                            .child_alignment = .{ .x = .center, .y = .center },
                            .sizing = .{ .w = .fixed(thumb_w), .h = .fixed(thumb_h) },
                        },
                        .custom = .{ .custom_data = ui.mkAnimatedGlass(18, combined_scale, 10.0, thumb_hover_brightness[idx]) },
                    })({
                        zclay.cdefs.Clay_OnHover(struct {
                            pub fn callback(_: zclay.ElementId, ptr_data: zclay.PointerData, user_data: ?*anyopaque) callconv(.c) void {
                                const d: *ThumbCbData = @ptrCast(@alignCast(user_data.?));
                                thumb_hover[d.idx] = true;
                                if (ptr_data.state == .pressed_this_frame and ui.menu_open) {
                                    // Place the old focused window at the clicked slot.
                                    // Reconciliation next frame will drop the newly-focused window.
                                    if (d.focusable.server().focused_toplevel) |cur_focused| {
                                        thumb_order[d.idx] = cur_focused.*;
                                    }
                                    main.focus_toplevel(&d.focusable);
                                    ui.menu_open = false;
                                }
                            }
                        }.callback, &thumb_cb_data[idx]);
                        zclay.UI()(.{
                            .id = .IDI("ThumbSurface", @intCast(idx)),
                            .layout = .{
                                .sizing = .{ .w = .fixed(surf_w * scale), .h = .fixed(surf_h * scale) },
                            },
                            .custom = .{ .custom_data = ui.mkWindowSurface(&thumb_order[idx], scale, combined_scale) },
                        })({});
                    });
                    idx += 1;
                }
            });
        }
    });
}

pub fn layoutPowerCluster() void {
    if (menu_state <= 0.001 and !ui.menu_open and btn_states[0] <= 0.001) return;

    const s = ui.ui_scale;
    const radius = 27.0 * s;
    const spread = 88.0 * s;
    const btn_size = radius * 2.0;
    const icon_size = 32.0 * s;
    const t = cluster_state;
    const diag: f32 = 0.7071067811865476;

    // All floating elements use right_top anchor from root.
    // root.right_top = (screen_w, 0) in Clay (y=0 is visual bottom in this renderer).
    const bx = lerp(200.0 * s, -(40.0 * s), btn_states[0]);
    const by = 40.0 * s;

    // Single bounding box covers all 4 button positions (square that grows with t).
    // bb right_top stays fixed at (screen_w-40, 40); width/height grow as buttons spread.
    const bb_size = btn_size + spread * t;

    // --- One-pass SDF morph background for all 4 buttons ---
    zclay.UI()(.{
        .id = .ID("PowerClusterBg"),
        .floating = .{
            .attach_to = .to_root,
            .attach_points = .{ .element = .right_top, .parent = .right_top },
            .offset = .{ .x = bx, .y = by },
        },
        .layout = .{ .sizing = .{ .w = .fixed(bb_size), .h = .fixed(bb_size) } },
        .custom = .{ .custom_data = ui.mkGlassBlob(t, cluster_sub_states[0], cluster_sub_states[1], cluster_sub_states[2], radius, spread,
            cluster_hover_bright[0], cluster_hover_bright[1],
            cluster_hover_bright[2], cluster_hover_bright[3],
            cluster_hover_scale[0], cluster_hover_scale[1],
            cluster_hover_scale[2], cluster_hover_scale[3]) },
    })({});

    // --- Transparent overlay hitboxes (each has OnHover + icon child, no background) ---

    if (t > 0.05) {
        // Power (shutdown) — left
        const tp = cluster_sub_states[0];
        zclay.UI()(.{
            .id = .ID("ClusterBtnPower"),
            .floating = .{
                .attach_to = .to_root,
                .attach_points = .{ .element = .right_top, .parent = .right_top },
                .offset = .{ .x = bx - spread * tp, .y = by - spread * 0.15 * tp },
            },
            .layout = .{
                .sizing = .{ .w = .fixed(btn_size), .h = .fixed(btn_size) },
                .child_alignment = .{ .x = .center, .y = .center },
            },
        })({
            zclay.cdefs.Clay_OnHover(struct {
                pub fn callback(_: zclay.ElementId, ptr_data: zclay.PointerData, _: ?*anyopaque) callconv(.c) void {
                    cluster_hover[1] = true;
                    if (ptr_data.state == .pressed_this_frame)
                        main.spawnCmd(&[_][]const u8{ "systemctl", "poweroff" });
                }
            }.callback, null);
            zclay.UI()(.{
                .id = .ID("ClusterIconPower"),
                .layout = .{ .sizing = .{ .w = .fixed(icon_size * cluster_hover_scale[1]), .h = .fixed(icon_size * cluster_hover_scale[1]) } },
                .custom = .{ .custom_data = ui.mkIcon(std.heap.page_allocator, "_power", tp) },
            })({});
        });

        // Sleep (suspend) — upper-left diagonal
        const ts = cluster_sub_states[1];
        zclay.UI()(.{
            .id = .ID("ClusterBtnSleep"),
            .floating = .{
                .attach_to = .to_root,
                .attach_points = .{ .element = .right_top, .parent = .right_top },
                .offset = .{ .x = bx - spread * diag * ts, .y = by + spread * diag * ts },
            },
            .layout = .{
                .sizing = .{ .w = .fixed(btn_size), .h = .fixed(btn_size) },
                .child_alignment = .{ .x = .center, .y = .center },
            },
        })({
            zclay.cdefs.Clay_OnHover(struct {
                pub fn callback(_: zclay.ElementId, ptr_data: zclay.PointerData, _: ?*anyopaque) callconv(.c) void {
                    cluster_hover[2] = true;
                    if (ptr_data.state == .pressed_this_frame)
                        main.spawnCmd(&[_][]const u8{ "systemctl", "suspend" });
                }
            }.callback, null);
            zclay.UI()(.{
                .id = .ID("ClusterIconSleep"),
                .layout = .{ .sizing = .{ .w = .fixed(icon_size * cluster_hover_scale[2]), .h = .fixed(icon_size * cluster_hover_scale[2]) } },
                .custom = .{ .custom_data = ui.mkIcon(std.heap.page_allocator, "_sleep", ts) },
            })({});
        });

        // Restart (reboot) — up
        const tr = cluster_sub_states[2];
        zclay.UI()(.{
            .id = .ID("ClusterBtnRestart"),
            .floating = .{
                .attach_to = .to_root,
                .attach_points = .{ .element = .right_top, .parent = .right_top },
                .offset = .{ .x = bx + spread * 0.15 * tr, .y = by + spread * tr },
            },
            .layout = .{
                .sizing = .{ .w = .fixed(btn_size), .h = .fixed(btn_size) },
                .child_alignment = .{ .x = .center, .y = .center },
            },
        })({
            zclay.cdefs.Clay_OnHover(struct {
                pub fn callback(_: zclay.ElementId, ptr_data: zclay.PointerData, _: ?*anyopaque) callconv(.c) void {
                    cluster_hover[3] = true;
                    if (ptr_data.state == .pressed_this_frame)
                        main.spawnCmd(&[_][]const u8{ "systemctl", "reboot" });
                }
            }.callback, null);
            zclay.UI()(.{
                .id = .ID("ClusterIconRestart"),
                .layout = .{ .sizing = .{ .w = .fixed(icon_size * cluster_hover_scale[3]), .h = .fixed(icon_size * cluster_hover_scale[3]) } },
                .custom = .{ .custom_data = ui.mkIcon(std.heap.page_allocator, "_restart", tr) },
            })({});
        });
    }

    // Center button: laid out last so it always has top click priority over sub-buttons
    {
        const center_icon: []const u8 = if (t < 0.5) "_power" else "window-close-symbolic";
        zclay.UI()(.{
            .id = .ID("ClusterBtnCenter"),
            .floating = .{
                .attach_to = .to_root,
                .attach_points = .{ .element = .right_top, .parent = .right_top },
                .offset = .{ .x = bx, .y = by },
            },
            .layout = .{
                .sizing = .{ .w = .fixed(btn_size), .h = .fixed(btn_size) },
                .child_alignment = .{ .x = .center, .y = .center },
            },
        })({
            zclay.cdefs.Clay_OnHover(struct {
                pub fn callback(_: zclay.ElementId, ptr_data: zclay.PointerData, _: ?*anyopaque) callconv(.c) void {
                    cluster_hover[0] = true;
                    if (ptr_data.state == .pressed_this_frame)
                        cluster_open = !cluster_open;
                }
            }.callback, null);
            zclay.UI()(.{
                .id = .ID("ClusterIconCenter"),
                .layout = .{ .sizing = .{ .w = .fixed(icon_size * cluster_hover_scale[0]), .h = .fixed(icon_size * cluster_hover_scale[0]) } },
                .custom = .{ .custom_data = ui.mkIcon(std.heap.page_allocator, center_icon, 1.0) },
            })({});
        });
    }
}
