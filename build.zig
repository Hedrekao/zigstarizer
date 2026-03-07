const std = @import("std");

fn generateModelRegistry(b: *std.Build, model_names: []const []const u8) []const u8 {
    // Build imports section
    var imports_buf: [4096]u8 = undefined;
    var imports_fbs = std.io.fixedBufferStream(&imports_buf);
    const imports_writer = imports_fbs.writer();
    for (model_names) |name| {
        imports_writer.print("const {s} = @import(\"{s}\");\n", .{ name, name }) catch unreachable;
    }

    // Build getModel function body
    var getmodel_buf: [4096]u8 = undefined;
    var getmodel_fbs = std.io.fixedBufferStream(&getmodel_buf);
    const getmodel_writer = getmodel_fbs.writer();
    for (model_names) |name| {
        getmodel_writer.print("    if (std.mem.eql(u8, name, \"{s}\"))\n", .{name}) catch unreachable;
        getmodel_writer.print("        return .{{ .vertices = &{s}.vertices, .faces = &{s}.faces }};\n", .{ name, name }) catch unreachable;
    }

    // Build available models list
    var available_buf: [1024]u8 = undefined;
    var available_fbs = std.io.fixedBufferStream(&available_buf);
    const available_writer = available_fbs.writer();
    for (model_names, 0..) |name, i| {
        if (i > 0) available_writer.writeAll(", ") catch unreachable;
        available_writer.writeAll(name) catch unreachable;
    }

    // Combine everything
    return b.fmt(
        \\// Auto-generated model registry - do not edit manually!
        \\// Edit the model_names array in build.zig to add/remove models.
        \\
        \\const std = @import("std");
        \\const g = @import("geometry");
        \\
        \\{s}
        \\pub fn getModel(name: []const u8) ?g.Model {{
        \\{s}    return null;
        \\}}
        \\
        \\pub const available = "{s}";
        \\
    , .{ imports_fbs.getWritten(), getmodel_fbs.getWritten(), available_fbs.getWritten() });
}

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

    const model_names = [_][]const u8{ "xtree", "cow", "pokeball" };
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

    // Generate model registry file
    const registry_content = generateModelRegistry(b, &model_names);
    const registry_file = b.addWriteFiles();
    const registry_source = registry_file.add("model_registry.zig", registry_content);

    const registry_module = b.createModule(.{
        .root_source_file = registry_source,
        .imports = &.{
            .{ .name = "geometry", .module = g_mod },
        },
    });

    // Add all model imports to registry module
    inline for (model_names, 0..) |model_name, i| {
        registry_module.addImport(model_name, model_modules[i]);
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
            .{ .name = "model_registry", .module = registry_module },
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
