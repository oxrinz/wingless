pub const c = @cImport({
    @cInclude("stdlib.h");
    @cDefine("WLR_USE_UNSTABLE", "1");
    @cInclude("xdg-shell-protocol.h");
    @cInclude("xdg-shell-client-protocol.h");
    @cInclude("wlr/util/log.h");
    @cInclude("wlr/backend.h");
    @cInclude("wlr/backend/libinput.h");
    @cInclude("wlr/backend/wayland.h");
    @cInclude("wlr/backend/x11.h");
    @cInclude("wlr/interfaces/wlr_keyboard.h");
    @cInclude("wlr/render/wlr_renderer.h");
    @cInclude("wlr/render/swapchain.h");
    @cInclude("wlr/render/allocator.h");
    @cInclude("wlr/render/drm_format_set.h");
    @cInclude("wlr/render/gles2.h");
    @cInclude("wlr/types/wlr_virtual_keyboard_v1.h");
    @cInclude("wlr/types/wlr_cursor.h");
    @cInclude("wlr/types/wlr_compositor.h");
    @cInclude("wlr/types/wlr_input_device.h");
    @cInclude("wlr/types/wlr_keyboard.h");
    @cInclude("wlr/types/wlr_data_device.h");
    @cInclude("wlr/types/wlr_output_layout.h");
    @cInclude("wlr/types/wlr_scene.h");
    @cInclude("wlr/types/wlr_subcompositor.h");
    @cInclude("wlr/types/wlr_xcursor_manager.h");
    @cInclude("wlr/types/wlr_xdg_shell.h");
    @cInclude("wlr/util/log.h");
    @cInclude("wlr/xwayland.h");
    @cInclude("wayland-server-core.h");
    @cInclude("drm/drm_fourcc.h");
    @cInclude("stb/stb_image.h");
    @cInclude("xcb/xcb.h");
    @cInclude("libinput.h");
});

pub const gl = @cImport({
    @cInclude("GLES2/gl2.h");
});
