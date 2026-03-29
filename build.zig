const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("wingless", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const zclay_dep = b.dependency("zclay", .{ .target = target, .optimize = optimize });
    const zclay_mod = zclay_dep.module("zclay");

    const exe = b.addExecutable(.{
        .name = "wingless",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wingless", .module = mod },
                .{ .name = "zclay", .module = zclay_mod },
            },
        }),
    });

    exe.addCSourceFile(.{ .file = .{ .cwd_relative = "protocols/xdg-shell-protocol.c" } });
    exe.addCSourceFile(.{ .file = .{ .cwd_relative = "protocols/pointer-constraints-unstable-v1-protocol.c" } });
    exe.addCSourceFile(.{ .file = .{ .cwd_relative = "protocols/wingless-glass-v1-protocol.c" } });

    exe.addCSourceFile(.{ .file = .{ .cwd_relative = "src/stb_impl.c" } });
    exe.linkSystemLibrary("libinput");
    exe.linkSystemLibrary("xcb");
    exe.linkSystemLibrary("GLESv2");
    exe.linkSystemLibrary("EGL");
    exe.linkSystemLibrary("wlroots-0.19");
    exe.linkSystemLibrary("wayland-client");
    exe.linkSystemLibrary("wayland-server");
    exe.linkSystemLibrary("xkbcommon");
    exe.linkSystemLibrary("pixman-1");
    exe.linkSystemLibrary("libsystemd");
    exe.linkLibC();

    exe.addIncludePath(.{ .cwd_relative = "protocols" });
    exe.addIncludePath(.{ .cwd_relative = "/usr/include" });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
        .filters = b.args orelse &.{},
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
