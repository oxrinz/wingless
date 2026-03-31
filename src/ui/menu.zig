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

// Top cluster blob state: BT+WiFi+Capture merge into one blob when any panel opens
var top_cluster_blob_h: f32 = 54.0; // animated bounding box height
var top_cluster_morph_k: f32 = 0.0; // smooth union parameter
var bt_circle_grow: f32 = 0.0;
var wifi_circle_grow: f32 = 0.0;
var cap_circle_grow: f32 = 0.0;
var rickroll_circle_grow: f32 = 0.0;

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

const max_audio_entries = 8;
const AudioEntry = struct {
    name: [128]u8 = [_]u8{0} ** 128,
    name_len: usize = 0,
    desc: [128]u8 = [_]u8{0} ** 128,
    desc_len: usize = 0,
    is_default: bool = false,
};

var speaker_entries: [max_audio_entries]AudioEntry = [_]AudioEntry{.{}} ** max_audio_entries;
var speaker_count: usize = 0;
var speaker_mutex: std.Thread.Mutex = .{};
var speaker_fetching: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var speaker_snapshot: [max_audio_entries]AudioEntry = [_]AudioEntry{.{}} ** max_audio_entries;
var speaker_snapshot_count: usize = 0;

var mic_entries: [max_audio_entries]AudioEntry = [_]AudioEntry{.{}} ** max_audio_entries;
var mic_count: usize = 0;
var mic_mutex: std.Thread.Mutex = .{};
var mic_fetching: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var mic_snapshot: [max_audio_entries]AudioEntry = [_]AudioEntry{.{}} ** max_audio_entries;
var mic_snapshot_count: usize = 0;

const AudioItemCb = struct { idx: usize, is_speaker: bool };
var speaker_item_cb: [max_net_hover]AudioItemCb = undefined;
var speaker_item_hover: [max_net_hover]bool = [_]bool{false} ** max_net_hover;
var speaker_item_hover_bright: [max_net_hover]f32 = [_]f32{0.0} ** max_net_hover;
var mic_item_cb: [max_net_hover]AudioItemCb = undefined;
var mic_item_hover: [max_net_hover]bool = [_]bool{false} ** max_net_hover;
var mic_item_hover_bright: [max_net_hover]f32 = [_]f32{0.0} ** max_net_hover;

var clock_buf: [16]u8 = undefined;
var clock_str: []u8 = clock_buf[0..0];

var date_buf: [32]u8 = undefined;
var date_str: []u8 = date_buf[0..0];

// this is public only because of the fullscreen blur
pub var menu_state: f32 = 0;
// btn_states[0]=Power, [1]=Reboot, [2]=BT, [3]=WiFi, [4]=Capture, [5]=Rickroll, [6]=Speaker, [7]=Mic (right to left)
var btn_states: [8]f32 = [_]f32{0} ** 8;

var capture_hover: bool = false;
var capture_hover_brightness: f32 = 0.05;
var capture_hover_scale: f32 = 1.0;

var rickroll_hover: bool = false;
var rickroll_hover_brightness: f32 = 0.05;
var rickroll_hover_scale: f32 = 1.0;

var speaker_open: bool = false;
var speaker_panel_state: f32 = 0.0;
var speaker_hover: bool = false;
var speaker_hover_brightness: f32 = 0.05;
var speaker_hover_scale: f32 = 1.0;
var speaker_circle_grow: f32 = 0.0;
var speaker_panel_full_h: f32 = 54.0;

var mic_open: bool = false;
var mic_panel_state: f32 = 0.0;
var mic_hover: bool = false;
var mic_hover_brightness: f32 = 0.05;
var mic_hover_scale: f32 = 1.0;
var mic_circle_grow: f32 = 0.0;
var mic_panel_full_h: f32 = 54.0;

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

fn fetchAudioThread(is_speaker: bool) void {
    const fetching = if (is_speaker) &speaker_fetching else &mic_fetching;
    defer fetching.store(false, .release);
    const alloc = std.heap.page_allocator;

    // Get default device name
    var def_buf: [256]u8 = [_]u8{0} ** 256;
    var def_name: []const u8 = "";
    {
        const cmd = if (is_speaker) &[_][]const u8{ "pactl", "get-default-sink" } else &[_][]const u8{ "pactl", "get-default-source" };
        var child = std.process.Child.init(cmd, alloc);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        child.spawn() catch {};
        if (child.stdout) |stdout| {
            const out = stdout.readToEndAlloc(alloc, 4096) catch "";
            defer alloc.free(out);
            const trimmed = std.mem.trim(u8, out, " \n\r\t");
            const l = @min(trimmed.len, def_buf.len - 1);
            @memcpy(def_buf[0..l], trimmed[0..l]);
            def_name = def_buf[0..l];
        }
        _ = child.wait() catch {};
    }

    const list_cmd = if (is_speaker)
        &[_][]const u8{ "pactl", "list", "sinks" }
    else
        &[_][]const u8{ "pactl", "list", "sources" };
    var child = std.process.Child.init(list_cmd, alloc);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return;
    const stdout_data = if (child.stdout) |s| s.readToEndAlloc(alloc, 128 * 1024) catch "" else "";
    defer alloc.free(stdout_data);
    _ = child.wait() catch {};

    var entries: [max_audio_entries]AudioEntry = [_]AudioEntry{.{}} ** max_audio_entries;
    var count: usize = 0;
    var cur_name_buf: [128]u8 = [_]u8{0} ** 128;
    var cur_desc_buf: [128]u8 = [_]u8{0} ** 128;
    var cur_name: []u8 = cur_name_buf[0..0];
    var cur_desc: []u8 = cur_desc_buf[0..0];
    var in_block = false;
    var is_monitor = false;

    const block_prefix = if (is_speaker) "Sink #" else "Source #";
    var lines = std.mem.splitScalar(u8, stdout_data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimLeft(u8, raw_line, " \t");
        if (std.mem.startsWith(u8, line, block_prefix)) {
            if (in_block and cur_name.len > 0 and !is_monitor and count < max_audio_entries) {
                entries[count].is_default = std.mem.eql(u8, cur_name, def_name);
                const nl = @min(cur_name.len, 127);
                @memcpy(entries[count].name[0..nl], cur_name[0..nl]);
                entries[count].name_len = nl;
                const dl = @min(cur_desc.len, 127);
                @memcpy(entries[count].desc[0..dl], cur_desc[0..dl]);
                entries[count].desc_len = dl;
                count += 1;
            }
            in_block = true;
            is_monitor = false;
            cur_name = cur_name_buf[0..0];
            cur_desc = cur_desc_buf[0..0];
        } else if (in_block and std.mem.startsWith(u8, line, "Name: ")) {
            const v = std.mem.trim(u8, line[6..], " \t\r");
            if (!is_speaker and std.mem.indexOf(u8, v, ".monitor") != null) is_monitor = true;
            const l = @min(v.len, cur_name_buf.len - 1);
            @memcpy(cur_name_buf[0..l], v[0..l]);
            cur_name = cur_name_buf[0..l];
        } else if (in_block and std.mem.startsWith(u8, line, "Description: ")) {
            const v = std.mem.trim(u8, line[13..], " \t\r");
            const l = @min(v.len, cur_desc_buf.len - 1);
            @memcpy(cur_desc_buf[0..l], v[0..l]);
            cur_desc = cur_desc_buf[0..l];
        }
    }
    if (in_block and cur_name.len > 0 and !is_monitor and count < max_audio_entries) {
        entries[count].is_default = std.mem.eql(u8, cur_name, def_name);
        const nl = @min(cur_name.len, 127);
        @memcpy(entries[count].name[0..nl], cur_name[0..nl]);
        entries[count].name_len = nl;
        const dl = @min(cur_desc.len, 127);
        @memcpy(entries[count].desc[0..dl], cur_desc[0..dl]);
        entries[count].desc_len = dl;
        count += 1;
    }

    if (is_speaker) {
        speaker_mutex.lock();
        @memcpy(speaker_entries[0..count], entries[0..count]);
        speaker_count = count;
        speaker_mutex.unlock();
    } else {
        mic_mutex.lock();
        @memcpy(mic_entries[0..count], entries[0..count]);
        mic_count = count;
        mic_mutex.unlock();
    }
}

fn refreshSpeakers() void {
    if (speaker_fetching.swap(true, .acquire)) return;
    const t = std.Thread.spawn(.{}, fetchAudioThread, .{true}) catch {
        speaker_fetching.store(false, .release);
        return;
    };
    t.detach();
}

fn refreshMic() void {
    if (mic_fetching.swap(true, .acquire)) return;
    const t = std.Thread.spawn(.{}, fetchAudioThread, .{false}) catch {
        mic_fetching.store(false, .release);
        return;
    };
    t.detach();
}

pub fn toggleMenu() void {
    if (ui.beacon_open == false and !ui.screenshot.isActive()) {
        ui.menu_open = !ui.menu_open;
        if (ui.menu_open) main.resetCursorToDefault();
    }
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
        if (btn_states[4] > 0.3) btn_states[5] = @min(1.0, lerp(btn_states[5], 1.0, bs));
        if (btn_states[5] > 0.3) btn_states[6] = @min(1.0, lerp(btn_states[6], 1.0, bs));
        if (btn_states[6] > 0.3) btn_states[7] = @min(1.0, lerp(btn_states[7], 1.0, bs));
    } else {
        btn_states[0] = @max(0.0, lerp(btn_states[0], 0.0, bs));
        if (btn_states[0] < 0.7) btn_states[2] = @max(0.0, lerp(btn_states[2], 0.0, bs));
        if (btn_states[2] < 0.7) btn_states[3] = @max(0.0, lerp(btn_states[3], 0.0, bs));
        if (btn_states[3] < 0.7) btn_states[4] = @max(0.0, lerp(btn_states[4], 0.0, bs));
        if (btn_states[4] < 0.7) btn_states[5] = @max(0.0, lerp(btn_states[5], 0.0, bs));
        if (btn_states[5] < 0.7) btn_states[6] = @max(0.0, lerp(btn_states[6], 0.0, bs));
        if (btn_states[6] < 0.7) btn_states[7] = @max(0.0, lerp(btn_states[7], 0.0, bs));
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
    wifi_panel_state = lerp(wifi_panel_state, if (wifi_open) 1.0 else 0.0, dt * 8.0);
    bt_panel_state = lerp(bt_panel_state, if (bt_open) 1.0 else 0.0, dt * 8.0);
    speaker_panel_state = lerp(speaker_panel_state, if (speaker_open) 1.0 else 0.0, dt * 8.0);
    mic_panel_state = lerp(mic_panel_state, if (mic_open) 1.0 else 0.0, dt * 8.0);

    // Staggered per-circle grow: opened button leads, others follow proportional to distance.
    // Button positions (right-to-left): bt=0, wifi=1, cap=2, rickroll=3, speaker=4, mic=5
    {
        const open_state = @max(@max(bt_panel_state, wifi_panel_state), @max(speaker_panel_state, mic_panel_state));
        const stagger: f32 = 0.18;
        const spd = dt * 9.0;
        const sg = stagger;
        if (bt_open) {
            bt_circle_grow     = lerp(bt_circle_grow,       open_state,                        spd);
            wifi_circle_grow   = lerp(wifi_circle_grow,     @max(0.0, open_state - sg),        spd);
            cap_circle_grow    = lerp(cap_circle_grow,      @max(0.0, open_state - sg * 2.0),  spd);
            rickroll_circle_grow = lerp(rickroll_circle_grow, @max(0.0, open_state - sg * 3.0), spd);
            speaker_circle_grow = lerp(speaker_circle_grow, @max(0.0, open_state - sg * 4.0),  spd);
            mic_circle_grow    = lerp(mic_circle_grow,      @max(0.0, open_state - sg * 5.0),  spd);
        } else if (wifi_open) {
            // wifi pos=1: bt=1 right, cap=1 left, rickroll=2, speaker=3, mic=4
            wifi_circle_grow   = lerp(wifi_circle_grow,     open_state,                        spd);
            bt_circle_grow     = lerp(bt_circle_grow,       @max(0.0, open_state - sg),        spd);
            cap_circle_grow    = lerp(cap_circle_grow,      @max(0.0, open_state - sg),        spd);
            rickroll_circle_grow = lerp(rickroll_circle_grow, @max(0.0, open_state - sg * 2.0), spd);
            speaker_circle_grow = lerp(speaker_circle_grow, @max(0.0, open_state - sg * 3.0),  spd);
            mic_circle_grow    = lerp(mic_circle_grow,      @max(0.0, open_state - sg * 4.0),  spd);
        } else if (speaker_open) {
            // speaker pos=4: mic=1 left, rickroll=1 right, cap=2, wifi=3, bt=4
            speaker_circle_grow = lerp(speaker_circle_grow, open_state,                        spd);
            mic_circle_grow    = lerp(mic_circle_grow,      @max(0.0, open_state - sg),        spd);
            rickroll_circle_grow = lerp(rickroll_circle_grow, @max(0.0, open_state - sg),      spd);
            cap_circle_grow    = lerp(cap_circle_grow,      @max(0.0, open_state - sg * 2.0),  spd);
            wifi_circle_grow   = lerp(wifi_circle_grow,     @max(0.0, open_state - sg * 3.0),  spd);
            bt_circle_grow     = lerp(bt_circle_grow,       @max(0.0, open_state - sg * 4.0),  spd);
        } else if (mic_open) {
            // mic pos=5: speaker=1, rickroll=2, cap=3, wifi=4, bt=5
            mic_circle_grow    = lerp(mic_circle_grow,      open_state,                        spd);
            speaker_circle_grow = lerp(speaker_circle_grow, @max(0.0, open_state - sg),        spd);
            rickroll_circle_grow = lerp(rickroll_circle_grow, @max(0.0, open_state - sg * 2.0), spd);
            cap_circle_grow    = lerp(cap_circle_grow,      @max(0.0, open_state - sg * 3.0),  spd);
            wifi_circle_grow   = lerp(wifi_circle_grow,     @max(0.0, open_state - sg * 4.0),  spd);
            bt_circle_grow     = lerp(bt_circle_grow,       @max(0.0, open_state - sg * 5.0),  spd);
        } else {
            bt_circle_grow     = lerp(bt_circle_grow,       0.0, spd);
            wifi_circle_grow   = lerp(wifi_circle_grow,     0.0, spd);
            cap_circle_grow    = lerp(cap_circle_grow,      0.0, spd);
            rickroll_circle_grow = lerp(rickroll_circle_grow, 0.0, spd);
            speaker_circle_grow = lerp(speaker_circle_grow, 0.0, spd);
            mic_circle_grow    = lerp(mic_circle_grow,      0.0, spd);
        }
    }

    // Top cluster blob: animate morph_k and bounding box height
    const any_open_state = @max(@max(bt_panel_state, wifi_panel_state), @max(speaker_panel_state, mic_panel_state));
    top_cluster_morph_k = lerp(top_cluster_morph_k, @max(15.0, any_open_state * 80.0) * ui.ui_scale, dt * 10.0);
    {
        const s = ui.ui_scale;
        const item_h: f32 = 38 * s;
        const pad: f32 = 14 * s;
        const list_vis: usize = @min(wifi_snapshot_count, 6);
        const target_list_h: f32 = if (wifi_pw_mode) item_h + 24 * s else if (list_vis == 0) item_h else @as(f32, @floatFromInt(list_vis)) * item_h;
        wifi_panel_full_h = lerp(wifi_panel_full_h, pad * 2 + target_list_h, dt * 25.0);

        const dev_item_h: f32 = 54 * s;
        const bt_list_vis: usize = @min(bt_snapshot_count, 6);
        const bt_list_h: f32 = if (bt_list_vis == 0) dev_item_h else @as(f32, @floatFromInt(bt_list_vis)) * dev_item_h;
        const bt_full_h: f32 = pad * 2 + bt_list_h;

        const sp_list_vis: usize = @min(speaker_snapshot_count, 6);
        const sp_list_h: f32 = if (sp_list_vis == 0) dev_item_h else @as(f32, @floatFromInt(sp_list_vis)) * dev_item_h;
        speaker_panel_full_h = lerp(speaker_panel_full_h, pad * 2 + sp_list_h, dt * 25.0);

        const mc_list_vis: usize = @min(mic_snapshot_count, 6);
        const mc_list_h: f32 = if (mc_list_vis == 0) dev_item_h else @as(f32, @floatFromInt(mc_list_vis)) * dev_item_h;
        mic_panel_full_h = lerp(mic_panel_full_h, pad * 2 + mc_list_h, dt * 25.0);

        const target_blob_h: f32 = if (bt_open or bt_panel_state > 0.01) bt_full_h
            else if (wifi_open or wifi_panel_state > 0.01) wifi_panel_full_h
            else if (speaker_open or speaker_panel_state > 0.01) speaker_panel_full_h
            else if (mic_open or mic_panel_state > 0.01) mic_panel_full_h
            else 54 * s;
        top_cluster_blob_h = lerp(top_cluster_blob_h, target_blob_h, dt * 10.0);
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
    rickroll_hover_brightness = lerp(rickroll_hover_brightness, if (rickroll_hover) 0.18 else 0.05, speed);
    rickroll_hover_scale = lerp(rickroll_hover_scale, if (rickroll_hover) 1.06 else 1.0, speed);
    speaker_hover_brightness = lerp(speaker_hover_brightness, if (speaker_hover and speaker_panel_state < 0.05) 0.18 else 0.05, speed);
    speaker_hover_scale = lerp(speaker_hover_scale, if (speaker_hover and speaker_panel_state < 0.05) 1.06 else 1.0, speed);
    mic_hover_brightness = lerp(mic_hover_brightness, if (mic_hover and mic_panel_state < 0.05) 0.18 else 0.05, speed);
    mic_hover_scale = lerp(mic_hover_scale, if (mic_hover and mic_panel_state < 0.05) 1.06 else 1.0, speed);
    wifi_hover = false;
    bt_hover = false;
    capture_hover = false;
    rickroll_hover = false;
    speaker_hover = false;
    mic_hover = false;

    // close panel on click outside
    const pressed_this_frame = ui.pointer_down and !prev_pointer_down;
    if (pressed_this_frame) {
        if (wifi_open and !zclay.pointerOver(zclay.ElementId.ID("WifiBtn")) and !zclay.pointerOver(zclay.ElementId.ID("WifiPanel"))) {
            wifi_open = false;
            wifi_pw_mode = false;
            wifi_pw_len = 0;
            wifi_pw_show = false;
        }
        if (bt_open and !zclay.pointerOver(zclay.ElementId.ID("BtBtn")) and !zclay.pointerOver(zclay.ElementId.ID("BtPanel"))) bt_open = false;
        if (speaker_open and !zclay.pointerOver(zclay.ElementId.ID("SpeakerBtn")) and !zclay.pointerOver(zclay.ElementId.ID("SpeakerPanel"))) speaker_open = false;
        if (mic_open and !zclay.pointerOver(zclay.ElementId.ID("MicBtn")) and !zclay.pointerOver(zclay.ElementId.ID("MicPanel"))) mic_open = false;
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
        speaker_item_hover_bright[i] = lerp(speaker_item_hover_bright[i], if (speaker_item_hover[i]) 0.09 else 0.0, speed);
        speaker_item_hover[i] = false;
        mic_item_hover_bright[i] = lerp(mic_item_hover_bright[i], if (mic_item_hover[i]) 0.09 else 0.0, speed);
        mic_item_hover[i] = false;
    }
    if (!ui.menu_open and menu_state < 0.01) {
        wifi_open = false;
        wifi_pw_mode = false;
        wifi_pw_len = 0;
        bt_open = false;
        speaker_open = false;
        mic_open = false;
    }
}

pub fn isActive() bool {
    return ui.menu_open or menu_state > 0.0001 or btn_states[0] > 0.0001 or btn_states[2] > 0.0001 or btn_states[3] > 0.0001 or btn_states[4] > 0.0001 or btn_states[5] > 0.0001 or btn_states[6] > 0.0001 or btn_states[7] > 0.0001;
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
    const btn_y = [6]f32{
        lerp(ui.screen_height + 200.0 * s, top_y, btn_states[2]),
        lerp(ui.screen_height + 200.0 * s, top_y, btn_states[3]),
        lerp(ui.screen_height + 200.0 * s, top_y, btn_states[4]),
        lerp(ui.screen_height + 200.0 * s, top_y, btn_states[5]),
        lerp(ui.screen_height + 200.0 * s, top_y, btn_states[6]),
        lerp(ui.screen_height + 200.0 * s, top_y, btn_states[7]),
    };

    const open_state = @max(@max(bt_panel_state, wifi_panel_state), @max(speaker_panel_state, mic_panel_state));
    const icon_alpha = std.math.clamp(1.0 - open_state / 0.3, 0.0, 1.0);
    const mask_overhang = 10.0 * s;

    // --- Unified blob background for BT + WiFi + Capture ---
    {
        const radius = 27.0 * s;
        const panel_half_w = 150.0 * s; // half of 300px panel width
        // Panel heights for each button
        const bt_item_h: f32 = 54 * s;
        const bt_pad_f: f32 = 14 * s;
        const bt_list_vis: usize = @min(bt_snapshot_count, 6);
        const bt_list_h: f32 = if (bt_list_vis == 0) bt_item_h else @as(f32, @floatFromInt(bt_list_vis)) * bt_item_h;
        const bt_full_h: f32 = bt_pad_f * 2 + bt_list_h;

        // GL coords: y from bottom of screen — each button has its own animated Y
        const bt_cy_gl       = (ui.screen_height - btn_y[0]) + radius;
        const wifi_cy_gl     = (ui.screen_height - btn_y[1]) + radius;
        const cap_cy_gl      = (ui.screen_height - btn_y[2]) + radius;
        const rickroll_cy_gl = (ui.screen_height - btn_y[3]) + radius;
        const speaker_cy_gl  = (ui.screen_height - btn_y[4]) + radius;
        const mic_cy_gl      = (ui.screen_height - btn_y[5]) + radius;

        // Circles stay at their button centers and grow radially (scale) to fill the mask.
        // Each button is 54px wide with 12px gap: step = 66px per position.
        const bt_cx_gl       = ui.screen_width - 40.0 * s - radius;
        const wifi_cx_gl     = bt_cx_gl - 66.0 * s;
        const cap_cx_gl      = bt_cx_gl - 132.0 * s;
        const rickroll_cx_gl = bt_cx_gl - 198.0 * s;
        const speaker_cx_gl  = bt_cx_gl - 264.0 * s;
        const mic_cx_gl      = bt_cx_gl - 330.0 * s;

        const centers = [16]f32{
            bt_cx_gl,      bt_cy_gl,
            wifi_cx_gl,    wifi_cy_gl,
            cap_cx_gl,     cap_cy_gl,
            rickroll_cx_gl, rickroll_cy_gl,
            speaker_cx_gl, speaker_cy_gl,
            mic_cx_gl,     mic_cy_gl,
            0, 0, 0, 0,
        };

        // Mask: panel shape — picks tallest open panel height
        const opened_h_candidates = [4]f32{ bt_full_h, wifi_panel_full_h, speaker_panel_full_h, mic_panel_full_h };
        const opened_h_states = [4]f32{ bt_panel_state, wifi_panel_state, speaker_panel_state, mic_panel_state };
        var opened_h: f32 = bt_full_h;
        var max_ps: f32 = 0.0;
        for (opened_h_candidates, opened_h_states) |h, ps| {
            if (ps > max_ps) { max_ps = ps; opened_h = h; }
        }

        // Max scale: each circle's radius must reach the farthest mask corner at its peak grow value.
        // All circles calibrated for 0.82 peak (1-step follower). Leaders overshoot slightly — fine.
        // bt/wifi/cap/rickroll: farthest corner is the opposite horizontal edge of mask.
        // speaker/mic: farthest corner is the mask right edge (they're further left than panel center).
        const vert_dist = opened_h - mask_overhang - radius;
        const mask_right_dist = 40.0 * s - radius; // from mask right edge to bt center (small)
        const bt_diag        = @sqrt((273.0 * s) * (273.0 * s) + vert_dist * vert_dist);
        const wifi_diag      = @sqrt((207.0 * s) * (207.0 * s) + vert_dist * vert_dist);
        const cap_diag       = @sqrt((169.0 * s) * (169.0 * s) + vert_dist * vert_dist);
        const rickroll_diag  = @sqrt((235.0 * s) * (235.0 * s) + vert_dist * vert_dist);
        // speaker/mic are left of the panel; their farthest corner is the panel right edge
        const speaker_h_dist = (264.0 * s) - mask_right_dist; // horiz dist to right edge
        const mic_h_dist     = (330.0 * s) - mask_right_dist;
        const speaker_diag   = @sqrt(speaker_h_dist * speaker_h_dist + vert_dist * vert_dist);
        const mic_diag       = @sqrt(mic_h_dist * mic_h_dist + vert_dist * vert_dist);
        const bt_max_scale       = @max(1.5, (bt_diag       - radius) / (0.82 * radius) + 1.0);
        const wifi_max_scale     = @max(1.5, (wifi_diag     - radius) / (0.82 * radius) + 1.0);
        const cap_max_scale      = @max(1.5, (cap_diag      - radius) / (0.82 * radius) + 1.0);
        const rickroll_max_scale = @max(1.5, (rickroll_diag - radius) / (0.82 * radius) + 1.0);
        const speaker_max_scale  = @max(1.5, (speaker_diag  - radius) / (0.82 * radius) + 1.0);
        const mic_max_scale      = @max(1.5, (mic_diag      - radius) / (0.82 * radius) + 1.0);
        const bt_scale       = lerp(1.0, bt_max_scale,       bt_circle_grow);
        const wifi_scale     = lerp(1.0, wifi_max_scale,     wifi_circle_grow);
        const cap_scale      = lerp(1.0, cap_max_scale,      cap_circle_grow);
        const rickroll_scale = lerp(1.0, rickroll_max_scale, rickroll_circle_grow);
        const speaker_scale  = lerp(1.0, speaker_max_scale,  speaker_circle_grow);
        const mic_scale      = lerp(1.0, mic_max_scale,      mic_circle_grow);
        const scales_arr = [8]f32{
            bt_hover_scale * bt_scale,       wifi_hover_scale * wifi_scale,
            capture_hover_scale * cap_scale, rickroll_hover_scale * rickroll_scale,
            speaker_hover_scale * speaker_scale, mic_hover_scale * mic_scale,
            0, 0,
        };
        const brights_arr = [8]f32{ bt_hover_brightness, wifi_hover_brightness, capture_hover_brightness, rickroll_hover_brightness, speaker_hover_brightness, mic_hover_brightness, 0, 0 };
        const widths_arr  = [8]f32{ 0, 0, 0, 0, 0, 0, 0, 0 };
        const heights_arr = [8]f32{ 0, 0, 0, 0, 0, 0, 0, 0 };
        const mask_r  = radius;
        const mask_ex = panel_half_w - radius + mask_overhang / 2.0;
        const mask_ey = @max(opened_h / 2.0 - radius, 0.0);
        const mask_cx_gl = ui.screen_width - 40.0 * s - panel_half_w + mask_overhang / 2.0;
        const mask_cy_gl = (ui.screen_height - btn_y[0]) + radius + @max(opened_h / 2.0 - radius, 0.0) - mask_overhang;

        // Bounding box must cover all 6 buttons (mic is leftmost at ~357px from right edge)
        const blob_bb_w = 400.0 * s;
        const blob_bb_h = top_cluster_blob_h;

        zclay.UI()(.{
            .id = .ID("TopClusterBg"),
            .floating = .{
                .attach_to = .to_root,
                .attach_points = .{ .element = .right_bottom, .parent = .right_top },
                .offset = .{ .x = -40.0 * s + mask_overhang, .y = btn_y[0] + mask_overhang },
            },
            .layout = .{ .sizing = .{ .w = .fixed(blob_bb_w + mask_overhang), .h = .fixed(blob_bb_h) } },
            .custom = .{ .custom_data = ui.mkGlassBlobRaw(centers, scales_arr, brights_arr, widths_arr, heights_arr, radius, top_cluster_morph_k, 0, 0, 0, 0, 0, open_state, mask_cx_gl, mask_cy_gl, mask_ex, mask_ey, mask_r) },
        })({});
    }

    // Generic device-list panel renderer — used by BT, Speaker, Mic
    const GenericItem = struct { label: []const u8, is_active: bool };
    const ItemHoverFn = *const fn (zclay.ElementId, zclay.PointerData, ?*anyopaque) callconv(.c) void;
    const renderDeviceListPanel = struct {
        fn call(
            comptime panel_id: []const u8,
            panel_state: f32,
            full_h: f32,
            offset_x: f32,
            btn_y_val: f32,
            sc: f32,
            mo: f32,
            fetching: bool,
            empty_text: []const u8,
            vis: usize,
            item_hover_bright: []const f32,
            items: []const GenericItem,
            hover_cb: ItemHoverFn,
            cb_ptrs: [*]?*anyopaque,
        ) void {
            if (panel_state < 0.01) return;
            const item_h: f32 = 54 * sc;
            const pad: f32 = 14 * sc;
            const panel_pad: u16 = @intFromFloat(pad);
            zclay.UI()(.{
                .id = .ID(panel_id),
                .floating = .{
                    .attach_to = .to_root,
                    .attach_points = .{ .element = .right_bottom, .parent = .right_top },
                    .offset = .{ .x = offset_x + mo, .y = btn_y_val + mo },
                },
                .layout = .{
                    .direction = .top_to_bottom,
                    .sizing = .{ .w = .fixed(300 * sc + mo), .h = .fixed(full_h) },
                    .child_alignment = .{ .x = .left, .y = .top },
                    .padding = .{ .top = panel_pad, .bottom = panel_pad, .left = panel_pad, .right = panel_pad },
                },
            })({
                const alpha = std.math.clamp((panel_state - 0.25) / 0.35, 0.0, 1.0);
                if (alpha > 0.01) {
                    if (vis == 0) {
                        const label: []const u8 = if (fetching) "Scanning..." else empty_text;
                        const fsz: u16 = @intFromFloat(14 * sc);
                        zclay.text(label, .{ .font_size = fsz, .color = .{ 255, 255, 255, 140.0 * alpha } });
                    } else {
                        for (0..vis) |i| {
                            const item = &items[i];
                            const item_px: u16 = @intFromFloat(10 * sc);
                            zclay.UI()(.{
                                .id = .IDI(panel_id ++ "Item", @intCast(i)),
                                .layout = .{
                                    .direction = .left_to_right,
                                    .sizing = .{ .w = .grow, .h = .fixed(item_h) },
                                    .child_alignment = .{ .x = .left, .y = .center },
                                    .padding = .{ .left = item_px, .right = item_px },
                                    .child_gap = @as(u16, @intFromFloat(8 * sc)),
                                },
                                .custom = .{ .custom_data = ui.mkRect(8 * sc, item_hover_bright[i] * alpha) },
                            })({
                                zclay.cdefs.Clay_OnHover(hover_cb, cb_ptrs[i]);
                                const fsz: u16 = @intFromFloat(14 * sc);
                                zclay.text(item.label, .{ .font_size = fsz, .color = if (item.is_active) .{ 255, 255, 255, 255.0 * alpha } else .{ 255, 255, 255, 200.0 * alpha } });
                            });
                        }
                    }
                }
            });
        }
    }.call;

    // Bluetooth button (morphs into panel on click)
    // Bluetooth button: static 54x54 hit area, never moves
    if (open_state < 0.4) {
        zclay.UI()(.{
            .id = .ID("BtBtn"),
            .floating = .{
                .attach_to = .to_root,
                .attach_points = .{ .element = .right_bottom, .parent = .right_top },
                .offset = .{ .x = -40 * s, .y = btn_y[0] },
            },
            .layout = .{
                .sizing = .{ .w = .fixed(54 * s), .h = .fixed(54 * s) },
                .child_alignment = .{ .x = .center, .y = .center },
            },
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
            if (icon_alpha > 0.01) {
                zclay.UI()(.{
                    .id = .ID("BtIcon"),
                    .layout = .{ .sizing = .{ .w = .fixed(32 * s * bt_hover_scale), .h = .fixed(32 * s * bt_hover_scale) } },
                    .custom = .{ .custom_data = ui.mkIcon(std.heap.page_allocator, "bluetooth-symbolic", icon_alpha) },
                })({});
            }
        });
    }
    // Bluetooth panel content: fixed at panel position, rendered on top of blob
    if (bt_panel_state > 0.01) {
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
        const bt_h = full_h;
        const bt_pad: u16 = @intFromFloat(pad);
        zclay.UI()(.{
            .id = .ID("BtPanel"),
            .floating = .{
                .attach_to = .to_root,
                .attach_points = .{ .element = .right_bottom, .parent = .right_top },
                .offset = .{ .x = -40 * s + mask_overhang, .y = btn_y[0] + mask_overhang },
            },
            .layout = .{
                .direction = .top_to_bottom,
                .sizing = .{ .w = .fixed(300 * s + mask_overhang), .h = .fixed(bt_h) },
                .child_alignment = .{ .x = .left, .y = .top },
                .padding = .{ .top = bt_pad, .bottom = bt_pad, .left = bt_pad, .right = bt_pad },
            },
        })({
            const ba = std.math.clamp((bt_panel_state - 0.25) / 0.35, 0.0, 1.0);
            if (ba > 0.01) {
                if (bt_vis == 0) {
                    const label: []const u8 = if (bt_fetching.load(.acquire)) "Scanning..." else "No devices";
                    const fsz: u16 = @intFromFloat(14 * s);
                    zclay.text(label, .{ .font_size = fsz, .color = .{ 255, 255, 255, 140.0 * ba } });
                } else {
                    if (bt_status.len > 0) {
                        const sfsz: u16 = @intFromFloat(12 * s);
                        zclay.text(bt_status, .{ .font_size = sfsz, .color = .{ 255, 255, 255, 160.0 * ba } });
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
                            .custom = .{ .custom_data = ui.mkRect(8 * s, bt_item_hover_bright[i] * ba) },
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
                            zclay.text(e.name[0..e.name_len], .{ .font_size = fsz, .color = if (e.connected) .{ 255, 255, 255, 255.0 * ba } else .{ 255, 255, 255, 200.0 * ba } });
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
                                    zclay.text(sub_lbl, .{ .font_size = lfsz, .color = .{ 255, 255, 255, 150.0 * ba } });
                                }
                            }
                        });
                    }
                }
            }
        });
    }

    // WiFi button (morphs into panel on click)
    // WiFi button: static 54x54 hit area, never moves
    if (open_state < 0.4) {
        const wifi_offset_x = -40 * s - 54 * s - 12 * s;
        zclay.UI()(.{
            .id = .ID("WifiBtn"),
            .floating = .{
                .attach_to = .to_root,
                .attach_points = .{ .element = .right_bottom, .parent = .right_top },
                .offset = .{ .x = wifi_offset_x, .y = btn_y[1] },
            },
            .layout = .{
                .sizing = .{ .w = .fixed(54 * s), .h = .fixed(54 * s) },
                .child_alignment = .{ .x = .center, .y = .center },
            },
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
            if (icon_alpha > 0.01) {
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
                    .custom = .{ .custom_data = ui.mkIcon(std.heap.page_allocator, btn_sig_icon, icon_alpha) },
                })({});
            }
        });
    }
    // WiFi panel content: fixed at panel position, rendered on top of blob
    if (wifi_panel_state > 0.01) {
        if (wifi_panel_state > 0.005) {
            wifi_mutex.lock();
            wifi_snapshot_count = wifi_count;
            if (wifi_count > 0) @memcpy(wifi_snapshot[0..wifi_count], wifi_entries[0..wifi_count]);
            wifi_mutex.unlock();
        }
        const item_h: f32 = 38 * s;
        const pad: f32 = 14 * s;
        const wifi_vis: usize = if (wifi_pw_mode) 0 else @min(wifi_snapshot_count, 6);
        const wifi_h = wifi_panel_full_h;
        const wifi_pad: u16 = @intFromFloat(pad);
        zclay.UI()(.{
            .id = .ID("WifiPanel"),
            .floating = .{
                .attach_to = .to_root,
                .attach_points = .{ .element = .right_bottom, .parent = .right_top },
                .offset = .{ .x = -40 * s + mask_overhang, .y = btn_y[1] + mask_overhang },
            },
            .layout = .{
                .direction = .top_to_bottom,
                .sizing = .{ .w = .fixed(300 * s + mask_overhang), .h = .fixed(wifi_h) },
                .child_alignment = if (wifi_pw_mode) .{ .x = .left, .y = .center } else .{ .x = .left, .y = .top },
                .padding = .{ .top = wifi_pad, .bottom = wifi_pad, .left = wifi_pad, .right = wifi_pad },
            },
        })({
            const wa = std.math.clamp((wifi_panel_state - 0.25) / 0.35, 0.0, 1.0);
            if (wa > 0.01) {
                if (wifi_pw_mode) {
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
                    zclay.text(wifi_pw_label, .{ .font_size = lfsz, .color = .{ 255, 255, 255, 180.0 * wa } });

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
                        .custom = .{ .custom_data = ui.mkRect(8 * s, 0.13 * wa) },
                    })({
                        zclay.UI()(.{
                            .id = .ID("WifiPwText"),
                            .layout = .{
                                .sizing = .{ .w = .grow, .h = .grow },
                                .child_alignment = .{ .x = .left, .y = .center },
                            },
                        })({
                            if (disp_len == 0) {
                                zclay.text("Enter password...", .{ .font_size = ifsz, .color = .{ 255, 255, 255, 60.0 * wa } });
                            } else {
                                zclay.text(wifi_pw_disp_buf[0..disp_len], .{ .font_size = ifsz, .color = .{ 255, 255, 255, 230.0 * wa } });
                            }
                        });
                        zclay.UI()(.{
                            .id = .ID("WifiPwEyeBtn"),
                            .layout = .{
                                .sizing = .{ .w = .fixed(eye_w), .h = .grow },
                                .child_alignment = .{ .x = .center, .y = .center },
                            },
                            .custom = .{ .custom_data = ui.mkRect(6 * s, wifi_pw_show_hover_bright * wa) },
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
                                .custom = .{ .custom_data = ui.mkIcon(std.heap.page_allocator, icon_name, (if (wifi_pw_show_hover) @as(f32, 1.0) else @as(f32, 0.5)) * wa) },
                            })({});
                        });
                    });
                });
            } else {
                if (wifi_vis == 0) {
                    const label: []const u8 = if (wifi_fetching.load(.acquire)) "Scanning..." else "No networks";
                    const fsz: u16 = @intFromFloat(14 * s);
                    zclay.text(label, .{ .font_size = fsz, .color = .{ 255, 255, 255, 140.0 * wa } });
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
                            .custom = .{ .custom_data = ui.mkRect(8 * s, wifi_item_hover_bright[i] * wa) },
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
                                .custom = .{ .custom_data = ui.mkIcon(std.heap.page_allocator, sig_icon, 0.9 * wa) },
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
                                    .custom = .{ .custom_data = ui.mkIcon(std.heap.page_allocator, "object-select-symbolic", 0.9 * wa) },
                                })({});
                            }
                            const fsz: u16 = @intFromFloat(14 * s);
                            zclay.text(e.ssid[0..e.ssid_len], .{ .font_size = fsz, .color = if (e.connected) .{ 255, 255, 255, 255.0 * wa } else .{ 255, 255, 255, 200.0 * wa } });
                        });
                    }
                }
            }
            }
        });
    }

    // Capture button (screenshot / recording)
    if (open_state < 0.4) {
        const is_rec = recording.isRecording();
        const cap_r = 27 * s;
        const cap_btn_w: f32 = 54 * s;
        // Capture fixed: right edge always at screen_w - 40 - 54 - 12 - 54 - 12 (not pushed by BT/WiFi)
        const cap_offset_x: f32 = -40 * s - 54 * s - 12 * s - 54 * s - 12 * s;
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
            .custom = .{ .custom_data = if (is_rec) ui.mkRectColor(cap_r, 1.0, 0.45, 0.05, btn_states[4] * capture_hover_scale) else null },
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
            if (icon_alpha > 0.01) {
                zclay.UI()(.{
                    .id = .ID("CaptureIcon"),
                    .layout = .{ .sizing = .{ .w = .fixed(32 * s * capture_hover_scale), .h = .fixed(32 * s * capture_hover_scale) } },
                    .custom = .{ .custom_data = ui.mkIcon(std.heap.page_allocator, "media-record-symbolic", icon_alpha) },
                })({});
            }
        });
    }

    // Rickroll button (settings icon, opens browser)
    if (open_state < 0.4) {
        const rr_r = 27 * s;
        const rr_offset_x: f32 = -40 * s - 54 * s - 12 * s - 54 * s - 12 * s - 54 * s - 12 * s;
        zclay.UI()(.{
            .id = .ID("RickrollBtn"),
            .floating = .{
                .attach_to = .to_root,
                .attach_points = .{ .element = .right_bottom, .parent = .right_top },
                .offset = .{ .x = rr_offset_x, .y = btn_y[3] },
            },
            .layout = .{
                .sizing = .{ .w = .fixed(54 * s), .h = .fixed(54 * s) },
                .child_alignment = .{ .x = .center, .y = .center },
                .direction = .top_to_bottom,
                .child_gap = @intFromFloat(4 * s),
            },
            .custom = .{ .custom_data = ui.mkRect(rr_r, rickroll_hover_brightness) },
        })({
            zclay.cdefs.Clay_OnHover(struct {
                pub fn callback(_: zclay.ElementId, ptr_data: zclay.PointerData, _: ?*anyopaque) callconv(.c) void {
                    rickroll_hover = true;
                    if (ptr_data.state == .pressed_this_frame) {
                        const t = std.Thread.spawn(.{}, struct {
                            pub fn run() void {
                                var child = std.process.Child.init(
                                    &[_][]const u8{ "xdg-open", "https://www.youtube.com/watch?v=dQw4w9WgXcQ" },
                                    std.heap.page_allocator,
                                );
                                _ = child.spawnAndWait() catch {};
                            }
                        }.run, .{}) catch return;
                        t.detach();
                    }
                }
            }.callback, null);
            if (icon_alpha > 0.01) {
                zclay.UI()(.{
                    .id = .ID("RickrollIcon"),
                    .layout = .{ .sizing = .{ .w = .fixed(32 * s * rickroll_hover_scale), .h = .fixed(32 * s * rickroll_hover_scale) } },
                    .custom = .{ .custom_data = ui.mkIcon(std.heap.page_allocator, "preferences-system-symbolic", icon_alpha) },
                })({});
            }
        });
    }

    // Speaker button
    if (open_state < 0.4) {
        const speaker_r = 27 * s;
        const speaker_offset_x: f32 = -40 * s - 54 * s - 12 * s - 54 * s - 12 * s - 54 * s - 12 * s - 54 * s - 12 * s;
        zclay.UI()(.{
            .id = .ID("SpeakerBtn"),
            .floating = .{
                .attach_to = .to_root,
                .attach_points = .{ .element = .right_bottom, .parent = .right_top },
                .offset = .{ .x = speaker_offset_x, .y = btn_y[4] },
            },
            .layout = .{
                .sizing = .{ .w = .fixed(54 * s), .h = .fixed(54 * s) },
                .child_alignment = .{ .x = .center, .y = .center },
                .direction = .top_to_bottom,
                .child_gap = @intFromFloat(4 * s),
            },
            .custom = .{ .custom_data = ui.mkRect(speaker_r, speaker_hover_brightness) },
        })({
            zclay.cdefs.Clay_OnHover(struct {
                pub fn callback(_: zclay.ElementId, ptr_data: zclay.PointerData, _: ?*anyopaque) callconv(.c) void {
                    speaker_hover = true;
                    if (ptr_data.state == .pressed_this_frame) {
                        if (!speaker_open) {
                            speaker_open = true;
                            bt_open = false;
                            wifi_open = false;
                            mic_open = false;
                            refreshSpeakers();
                        } else {
                            speaker_open = false;
                        }
                    }
                }
            }.callback, null);
            if (icon_alpha > 0.01) {
                zclay.UI()(.{
                    .id = .ID("SpeakerIcon"),
                    .layout = .{ .sizing = .{ .w = .fixed(32 * s * speaker_hover_scale), .h = .fixed(32 * s * speaker_hover_scale) } },
                    .custom = .{ .custom_data = ui.mkIcon(std.heap.page_allocator, "audio-speakers-symbolic", icon_alpha) },
                })({});
            }
        });
    }
    // Speaker panel
    {
        if (speaker_panel_state > 0.005) {
            speaker_mutex.lock();
            speaker_snapshot_count = speaker_count;
            if (speaker_count > 0) @memcpy(speaker_snapshot[0..speaker_count], speaker_entries[0..speaker_count]);
            speaker_mutex.unlock();
        }
        const speaker_vis: usize = @min(speaker_snapshot_count, max_audio_entries);
        var speaker_items: [max_audio_entries]GenericItem = undefined;
        for (0..speaker_vis) |i| {
            const e = &speaker_snapshot[i];
            speaker_item_cb[i] = .{ .idx = i, .is_speaker = true };
            speaker_items[i] = .{ .label = e.desc[0..e.desc_len], .is_active = e.is_default };
        }
        var speaker_cb_ptrs: [max_audio_entries]?*anyopaque = undefined;
        for (0..speaker_vis) |i| speaker_cb_ptrs[i] = &speaker_item_cb[i];
        const speaker_offset_x: f32 = -40 * s - 54 * s - 12 * s - 54 * s - 12 * s - 54 * s - 12 * s - 54 * s - 12 * s;
        renderDeviceListPanel(
            "SpeakerPanel",
            speaker_panel_state,
            speaker_panel_full_h,
            speaker_offset_x + mask_overhang,
            btn_y[4] + mask_overhang,
            s,
            mask_overhang,
            speaker_fetching.load(.acquire),
            "No outputs",
            speaker_vis,
            &speaker_item_hover_bright,
            speaker_items[0..speaker_vis],
            struct {
                pub fn callback(_: zclay.ElementId, ptr_data: zclay.PointerData, user_data: ?*anyopaque) callconv(.c) void {
                    const d: *AudioItemCb = @ptrCast(@alignCast(user_data.?));
                    speaker_item_hover[d.idx] = true;
                    if (ptr_data.state == .pressed_this_frame) {
                        const e = &speaker_snapshot[d.idx];
                        main.spawnCmd(&[_][]const u8{ "pactl", "set-default-sink", e.name[0..e.name_len] });
                        for (0..speaker_snapshot_count) |k| speaker_snapshot[k].is_default = (k == d.idx);
                    }
                }
            }.callback,
            &speaker_cb_ptrs,
        );
    }

    // Mic button
    if (open_state < 0.4) {
        const mic_r = 27 * s;
        const mic_offset_x: f32 = -40 * s - 54 * s - 12 * s - 54 * s - 12 * s - 54 * s - 12 * s - 54 * s - 12 * s - 54 * s - 12 * s;
        zclay.UI()(.{
            .id = .ID("MicBtn"),
            .floating = .{
                .attach_to = .to_root,
                .attach_points = .{ .element = .right_bottom, .parent = .right_top },
                .offset = .{ .x = mic_offset_x, .y = btn_y[5] },
            },
            .layout = .{
                .sizing = .{ .w = .fixed(54 * s), .h = .fixed(54 * s) },
                .child_alignment = .{ .x = .center, .y = .center },
                .direction = .top_to_bottom,
                .child_gap = @intFromFloat(4 * s),
            },
            .custom = .{ .custom_data = ui.mkRect(mic_r, mic_hover_brightness) },
        })({
            zclay.cdefs.Clay_OnHover(struct {
                pub fn callback(_: zclay.ElementId, ptr_data: zclay.PointerData, _: ?*anyopaque) callconv(.c) void {
                    mic_hover = true;
                    if (ptr_data.state == .pressed_this_frame) {
                        if (!mic_open) {
                            mic_open = true;
                            bt_open = false;
                            wifi_open = false;
                            speaker_open = false;
                            refreshMic();
                        } else {
                            mic_open = false;
                        }
                    }
                }
            }.callback, null);
            if (icon_alpha > 0.01) {
                zclay.UI()(.{
                    .id = .ID("MicIcon"),
                    .layout = .{ .sizing = .{ .w = .fixed(32 * s * mic_hover_scale), .h = .fixed(32 * s * mic_hover_scale) } },
                    .custom = .{ .custom_data = ui.mkIcon(std.heap.page_allocator, "audio-input-microphone-symbolic", icon_alpha) },
                })({});
            }
        });
    }
    // Mic panel
    {
        if (mic_panel_state > 0.005) {
            mic_mutex.lock();
            mic_snapshot_count = mic_count;
            if (mic_count > 0) @memcpy(mic_snapshot[0..mic_count], mic_entries[0..mic_count]);
            mic_mutex.unlock();
        }
        const mic_vis: usize = @min(mic_snapshot_count, max_audio_entries);
        var mic_items: [max_audio_entries]GenericItem = undefined;
        for (0..mic_vis) |i| {
            const e = &mic_snapshot[i];
            mic_item_cb[i] = .{ .idx = i, .is_speaker = false };
            mic_items[i] = .{ .label = e.desc[0..e.desc_len], .is_active = e.is_default };
        }
        var mic_cb_ptrs: [max_audio_entries]?*anyopaque = undefined;
        for (0..mic_vis) |i| mic_cb_ptrs[i] = &mic_item_cb[i];
        const mic_offset_x: f32 = -40 * s - 54 * s - 12 * s - 54 * s - 12 * s - 54 * s - 12 * s - 54 * s - 12 * s - 54 * s - 12 * s;
        renderDeviceListPanel(
            "MicPanel",
            mic_panel_state,
            mic_panel_full_h,
            mic_offset_x + mask_overhang,
            btn_y[5] + mask_overhang,
            s,
            mask_overhang,
            mic_fetching.load(.acquire),
            "No inputs",
            mic_vis,
            &mic_item_hover_bright,
            mic_items[0..mic_vis],
            struct {
                pub fn callback(_: zclay.ElementId, ptr_data: zclay.PointerData, user_data: ?*anyopaque) callconv(.c) void {
                    const d: *AudioItemCb = @ptrCast(@alignCast(user_data.?));
                    mic_item_hover[d.idx] = true;
                    if (ptr_data.state == .pressed_this_frame) {
                        const e = &mic_snapshot[d.idx];
                        main.spawnCmd(&[_][]const u8{ "pactl", "set-default-source", e.name[0..e.name_len] });
                        for (0..mic_snapshot_count) |k| mic_snapshot[k].is_default = (k == d.idx);
                    }
                }
            }.callback,
            &mic_cb_ptrs,
        );
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
                                    const live = switch (d.focusable) {
                                        .xdg => |xdg| &xdg.focusable,
                                        .xwayland => |xwl| &xwl.focusable,
                                    };
                                    main.focus_toplevel(live);
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
        .custom = .{ .custom_data = ui.mkGlassBlob(t, cluster_sub_states[0], cluster_sub_states[1], cluster_sub_states[2], radius, spread, bx, by,
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
                .custom = .{ .custom_data = ui.mkIcon(std.heap.page_allocator, "system-shutdown-symbolic", tp) },
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
                .custom = .{ .custom_data = ui.mkIcon(std.heap.page_allocator, "system-suspend-symbolic", ts) },
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
                .custom = .{ .custom_data = ui.mkIcon(std.heap.page_allocator, "system-reboot-symbolic", tr) },
            })({});
        });
    }

    // Center button: laid out last so it always has top click priority over sub-buttons
    {
        const center_icon: []const u8 = if (t < 0.5) "system-shutdown-symbolic" else "window-close-symbolic";
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
