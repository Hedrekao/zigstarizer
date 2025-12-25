const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const g_mod = b.addModule("geometry", .{
        .root_source_file = b.path("src/geometry.zig"),
        .target = target,
        .optimize = optimize,
    });

    const obj2zig_exe = b.addExecutable(.{
        .name = "obj2zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/obj2zig.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "geometry", .module = g_mod },
            },
        }),
    });

    const run_obj2zig_auto = b.addRunArtifact(obj2zig_exe);
    // Arg 1: Input file
    run_obj2zig_auto.addFileArg(b.path("assets/xtree.obj"));

    // Arg 2: Output file
    const generated_obj_path = run_obj2zig_auto.addOutputFileArg("xtree.zig");

    const run_obj2zig_manual = b.addRunArtifact(obj2zig_exe);
    if (b.args) |args| {
        run_obj2zig_manual.addArgs(args);
    }
    const obj2zig_step = b.step("obj2zig", "Run tool manually: zig build obj2zig -- assets/in.obj src/out.zig");
    obj2zig_step.dependOn(&run_obj2zig_manual.step);

    const xtree_mod = b.createModule(.{
        .root_source_file = generated_obj_path,
        .imports = &.{
            .{ .name = "geometry", .module = g_mod },
        },
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .imports = &.{
            .{ .name = "geometry", .module = g_mod },
            .{ .name = "xtree", .module = xtree_mod },
        },
    });

    root_module.linkSystemLibrary("sdl2", .{});

    const exe = b.addExecutable(.{
        .name = "main",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    // 4. Run Step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
