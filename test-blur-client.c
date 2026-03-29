#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/mman.h>
#include <fcntl.h>

#include <wayland-client.h>
#include "protocols/xdg-shell-client-protocol.h"
#include "protocols/wingless-blur-v1-client-protocol.h"

#define WIDTH  400
#define HEIGHT 300

static struct wl_display    *display;
static struct wl_registry   *registry;
static struct wl_compositor *compositor;
static struct wl_shm        *shm;
static struct xdg_wm_base   *xdg_wm_base;
static struct wingless_blur_manager_v1 *blur_manager;

static struct wl_surface    *surface;
static struct xdg_surface   *xdg_surface;
static struct xdg_toplevel  *xdg_toplevel;
static struct wingless_blur_region_v1 *blur_region;

static int running = 1;

static int create_shm_file(size_t size) {
    int fd = memfd_create("blur-test", MFD_CLOEXEC);
    if (fd < 0) { perror("memfd_create"); exit(1); }
    if (ftruncate(fd, size) < 0) { perror("ftruncate"); exit(1); }
    return fd;
}

static struct wl_buffer *create_buffer(void) {
    int stride = WIDTH * 4;
    int size = stride * HEIGHT;
    int fd = create_shm_file(size);

    void *data = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data == MAP_FAILED) { perror("mmap"); exit(1); }

    // semi-transparent dark overlay so we can see the glass beneath
    uint32_t *pixels = data;
    for (int i = 0; i < WIDTH * HEIGHT; i++)
        pixels[i] = 0x55000000; // argb: ~33% black

    munmap(data, size);

    struct wl_shm_pool *pool = wl_shm_create_pool(shm, fd, size);
    struct wl_buffer *buf = wl_shm_pool_create_buffer(pool, 0, WIDTH, HEIGHT, stride, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    return buf;
}

static void xdg_surface_configure(void *data, struct xdg_surface *s, uint32_t serial) {
    xdg_surface_ack_configure(s, serial);

    struct wl_buffer *buf = create_buffer();
    wl_surface_attach(surface, buf, 0, 0);
    wl_surface_damage(surface, 0, 0, WIDTH, HEIGHT);
    wl_surface_commit(surface);
}

static const struct xdg_surface_listener xdg_surface_listener = {
    .configure = xdg_surface_configure,
};

static void xdg_toplevel_configure(void *data, struct xdg_toplevel *t, int32_t w, int32_t h, struct wl_array *states) {}
static void xdg_toplevel_close(void *data, struct xdg_toplevel *t) { running = 0; }
static void xdg_toplevel_configure_bounds(void *data, struct xdg_toplevel *t, int32_t w, int32_t h) {}
static void xdg_toplevel_wm_capabilities(void *data, struct xdg_toplevel *t, struct wl_array *caps) {}

static const struct xdg_toplevel_listener xdg_toplevel_listener = {
    .configure = xdg_toplevel_configure,
    .close = xdg_toplevel_close,
    .configure_bounds = xdg_toplevel_configure_bounds,
    .wm_capabilities = xdg_toplevel_wm_capabilities,
};

static void xdg_wm_base_ping(void *data, struct xdg_wm_base *base, uint32_t serial) {
    xdg_wm_base_pong(base, serial);
}
static const struct xdg_wm_base_listener xdg_wm_base_listener = { .ping = xdg_wm_base_ping };

static void registry_global(void *data, struct wl_registry *reg, uint32_t name, const char *interface, uint32_t version) {
    if (strcmp(interface, wl_compositor_interface.name) == 0)
        compositor = wl_registry_bind(reg, name, &wl_compositor_interface, 4);
    else if (strcmp(interface, wl_shm_interface.name) == 0)
        shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
        xdg_wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, 1);
        xdg_wm_base_add_listener(xdg_wm_base, &xdg_wm_base_listener, NULL);
    } else if (strcmp(interface, wingless_blur_manager_v1_interface.name) == 0)
        blur_manager = wl_registry_bind(reg, name, &wingless_blur_manager_v1_interface, 1);
}

static void registry_global_remove(void *data, struct wl_registry *reg, uint32_t name) {}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

int main(void) {
    display = wl_display_connect(NULL);
    if (!display) { fprintf(stderr, "failed to connect to wayland display\n"); return 1; }

    registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    wl_display_roundtrip(display);

    if (!compositor || !shm || !xdg_wm_base) {
        fprintf(stderr, "missing required globals\n"); return 1;
    }
    if (!blur_manager) {
        fprintf(stderr, "wingless_blur_manager_v1 not available — is wingless running?\n"); return 1;
    }

    surface = wl_compositor_create_surface(compositor);
    xdg_surface = xdg_wm_base_get_xdg_surface(xdg_wm_base, surface);
    xdg_surface_add_listener(xdg_surface, &xdg_surface_listener, NULL);
    xdg_toplevel = xdg_surface_get_toplevel(xdg_surface);
    xdg_toplevel_add_listener(xdg_toplevel, &xdg_toplevel_listener, NULL);
    xdg_toplevel_set_title(xdg_toplevel, "blur test");

    // request a blur region covering the whole window
    blur_region = wingless_blur_manager_v1_get_blur_region(blur_manager, surface);
    wingless_blur_region_v1_set_region(blur_region, 0, 0, WIDTH, HEIGHT);
    wingless_blur_region_v1_set_radius(blur_region, 100);

    wl_surface_commit(surface);

    while (running && wl_display_dispatch(display) != -1) {}

    wingless_blur_region_v1_destroy(blur_region);
    wingless_blur_manager_v1_destroy(blur_manager);
    wl_display_disconnect(display);
    return 0;
}
