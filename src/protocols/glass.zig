const std = @import("std");
const c = @import("../c.zig").c;

const alloc = std.heap.page_allocator;

pub const BlurState = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    radius: u32 = 0,
    tint_r: u32 = 0,
    tint_g: u32 = 0,
    tint_b: u32 = 0,
    tint_a: u32 = 0,
    refraction_band: u32 = 100,
    blur_amount: u32 = 120,
};

pub const BlurRegion = struct {
    pending: BlurState = .{},
    current: BlurState = .{},
    surface_data: ?*SurfaceBlurData = null,
    resource: ?*c.wl_resource = null,
};

pub const SurfaceBlurData = struct {
    regions: std.ArrayListUnmanaged(*BlurRegion) = .empty,
    addon: c.wlr_addon = undefined,
};

const blur_addon_owner: u8 = 0;
const blur_addon_impl: c.wlr_addon_interface = .{
    .name = "wingless_glass",
    .destroy = handle_addon_destroy,
};

pub fn fromSurface(surface: *c.wlr_surface) ?*SurfaceBlurData {
    const addon = c.wlr_addon_find(&surface.addons, &blur_addon_owner, &blur_addon_impl) orelse return null;
    return @ptrCast(@as(*allowzero SurfaceBlurData, @fieldParentPtr("addon", addon)));
}

pub fn commitSurface(surface: *c.wlr_surface) void {
    const surface_data = fromSurface(surface) orelse return;
    for (surface_data.regions.items) |region| {
        region.current = region.pending;
    }
}

const manager_impl: c.struct_wingless_glass_manager_v1_interface = .{
    .get_blur_region = handle_get_blur_region,
    .destroy = handle_manager_destroy,
};

pub fn register(display: *c.wl_display, server_data: ?*anyopaque) void {
    _ = c.wl_global_create(display, &c.wingless_glass_manager_v1_interface, 1, server_data, handle_bind);
}

fn handle_bind(client: ?*c.wl_client, data: ?*anyopaque, version: u32, id: u32) callconv(.c) void {
    _ = data;
    const resource = c.wl_resource_create(client, &c.wingless_glass_manager_v1_interface, @intCast(version), id);
    c.wl_resource_set_implementation(resource, &manager_impl, null, null);
}

fn handle_manager_destroy(client: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    _ = client;
    c.wl_resource_destroy(resource);
}

fn handle_get_blur_region(client: ?*c.wl_client, resource: ?*c.wl_resource, id: u32, surface_resource: ?*c.wl_resource) callconv(.c) void {
    _ = resource;
    const region_resource = c.wl_resource_create(client, &c.wingless_glass_region_v1_interface, 1, id);

    const blur_region = alloc.create(BlurRegion) catch {
        c.wl_client_post_no_memory(client);
        return;
    };
    blur_region.* = .{ .resource = region_resource };

    c.wl_resource_set_implementation(region_resource, &region_impl, blur_region, handle_region_destroy);

    const wlr_surface: *c.wlr_surface = @ptrCast(c.wlr_surface_from_resource(surface_resource) orelse {
        alloc.destroy(blur_region);
        return;
    });

    const surface_data = fromSurface(wlr_surface) orelse blk: {
        const sd = alloc.create(SurfaceBlurData) catch {
            c.wl_resource_post_no_memory(region_resource);
            alloc.destroy(blur_region);
            return;
        };
        sd.* = .{};
        c.wlr_addon_init(&sd.addon, &wlr_surface.addons, &blur_addon_owner, &blur_addon_impl);
        break :blk sd;
    };

    surface_data.regions.append(alloc, blur_region) catch {
        c.wl_resource_post_no_memory(region_resource);
        alloc.destroy(blur_region);
        return;
    };
    blur_region.surface_data = surface_data;
}

const region_impl: c.struct_wingless_glass_region_v1_interface = .{
    .set_region = handle_set_region,
    .set_radius = handle_set_radius,
    .set_tint = handle_set_tint,
    .set_refraction_band = handle_set_refraction_band,
    .set_blur_amount = handle_set_blur_amount,
    .destroy = handle_region_destroy_request,
};

fn handle_region_destroy_request(client: ?*c.wl_client, resource: ?*c.wl_resource) callconv(.c) void {
    _ = client;
    c.wl_resource_destroy(resource);
}

fn handle_region_destroy(resource: ?*c.wl_resource) callconv(.c) void {
    const blur_region: *BlurRegion = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    if (blur_region.surface_data) |sd| {
        for (sd.regions.items, 0..) |region, i| {
            if (region == blur_region) {
                _ = sd.regions.swapRemove(i);
                break;
            }
        }
    }
    blur_region.resource = null;
    alloc.destroy(blur_region);
}

fn handle_addon_destroy(addon: ?*c.wlr_addon) callconv(.c) void {
    const surface_data: *SurfaceBlurData = @ptrCast(@as(*allowzero SurfaceBlurData, @fieldParentPtr("addon", addon.?)));
    c.wlr_addon_finish(&surface_data.addon);
    for (surface_data.regions.items) |region| {
        region.surface_data = null;
        if (region.resource) |res| {
            c.wl_resource_destroy(res);
        }
    }
    surface_data.regions.deinit(alloc);
    alloc.destroy(surface_data);
}

fn handle_set_region(client: ?*c.wl_client, resource: ?*c.wl_resource, x: i32, y: i32, width: i32, height: i32) callconv(.c) void {
    _ = client;
    const blur_region: *BlurRegion = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    blur_region.pending.x = x;
    blur_region.pending.y = y;
    blur_region.pending.width = width;
    blur_region.pending.height = height;
}

fn handle_set_radius(client: ?*c.wl_client, resource: ?*c.wl_resource, radius: u32) callconv(.c) void {
    _ = client;
    const blur_region: *BlurRegion = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    blur_region.pending.radius = radius;
}

fn handle_set_tint(client: ?*c.wl_client, resource: ?*c.wl_resource, r: u32, g: u32, b: u32, a: u32) callconv(.c) void {
    _ = client;
    const blur_region: *BlurRegion = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    blur_region.pending.tint_r = r;
    blur_region.pending.tint_g = g;
    blur_region.pending.tint_b = b;
    blur_region.pending.tint_a = a;
}

fn handle_set_refraction_band(client: ?*c.wl_client, resource: ?*c.wl_resource, band: u32) callconv(.c) void {
    _ = client;
    const blur_region: *BlurRegion = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    blur_region.pending.refraction_band = @max(band, 100);
}

fn handle_set_blur_amount(client: ?*c.wl_client, resource: ?*c.wl_resource, amount: u32) callconv(.c) void {
    _ = client;
    const blur_region: *BlurRegion = @ptrCast(@alignCast(c.wl_resource_get_user_data(resource)));
    blur_region.pending.blur_amount = amount;
}
