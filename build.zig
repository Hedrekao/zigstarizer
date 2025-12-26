const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const g_mod = b.addModule("geometry", .{
        .root_source_file = b.path("src/geometry.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Build obj2zig converter
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

    const model_names = [_][]const u8{ "xtree", "cow" };
    var model_modules: [model_names.len]*std.Build.Module = undefined;

    inline for (model_names, 0..) |model_name, i| {
        const obj_path = b.fmt("assets/{s}.obj", .{model_name});
        const zig_name = b.fmt("{s}.zig", .{model_name});

        const run_obj2zig = b.addRunArtifact(obj2zig_exe);
        run_obj2zig.addFileArg(b.path(obj_path));
        const generated_file = run_obj2zig.addOutputFileArg(zig_name);

        model_modules[i] = b.createModule(.{
            .root_source_file = generated_file,
            .imports = &.{
                .{ .name = "geometry", .module = g_mod },
            },
        });
    }

    // Manual obj2zig step (for custom conversions)
    const run_obj2zig_manual = b.addRunArtifact(obj2zig_exe);
    if (b.args) |args| {
        run_obj2zig_manual.addArgs(args);
    }
    const obj2zig_step = b.step("obj2zig", "Run tool manually: zig build obj2zig -- assets/in.obj src/out.zig");
    obj2zig_step.dependOn(&run_obj2zig_manual.step);

    // Build main executable with all model modules
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
        .imports = &.{
            .{ .name = "geometry", .module = g_mod },
            .{ .name = "xtree", .module = model_modules[0] },
            .{ .name = "cow", .module = model_modules[1] },
        },
    });

    root_module.linkSystemLibrary("sdl2", .{});

    const exe = b.addExecutable(.{
        .name = "main",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    // Run step (passes args to the executable)
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app (use: zig build run -- cow)");
    run_step.dependOn(&run_cmd.step);
}
