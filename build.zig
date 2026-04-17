const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "clicktrack",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    exe.root_module.strip = true;

    const os = target.result.os.tag;

    if (os == .windows) {
        exe.root_module.addCSourceFile(.{
            .file = b.path("src/platform_windows.c"),
            .flags = &.{"-O2"},
        });
        exe.root_module.linkSystemLibrary("user32", .{});
        exe.root_module.linkSystemLibrary("kernel32", .{});
    }

    if (os == .macos) {
        exe.root_module.addCSourceFile(.{
            .file = b.path("src/platform_macos.c"),
            .flags = &.{ "-O2", "-x", "objective-c" },
        });
        exe.root_module.linkFramework("CoreGraphics", .{});
        exe.root_module.linkFramework("CoreFoundation", .{});
        exe.root_module.linkFramework("ApplicationServices", .{});
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run clicktrack");
    run_step.dependOn(&run_cmd.step);
}
