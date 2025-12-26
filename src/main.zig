const std = @import("std");
const g = @import("geometry");
const xtree = @import("xtree");
const cow = @import("cow");
const Rasterizer = @import("rasterizer.zig");
const Camera = @import("camera.zig");
const c = @cImport(
    @cInclude("SDL.h"),
);

const SCREEN_WIDTH = 960;
const SCREEN_HEIGHT = 640;

const MOVE_SPEED = 15.0; // Units per second
const ROTATE_SPEED = 1.0; // Radians per second

const RED_COLOR = g.Color{.r = 255, .g = 0, .b = 0};
const GREEN_COLOR = g.Color{.r = 0, .g = 255, .b = 0};
const BLUE_COLOR = g.Color{.r = 0, .g = 0, .b = 255};

const Model = struct {
    vertices: []const g.V3f,
    faces: []const g.Face,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const model_name = if (args.len > 1) args[1] else "xtree";

    const model: Model = if (std.mem.eql(u8, model_name, "cow"))
        .{ .vertices = &cow.vertices, .faces = &cow.faces }
    else if (std.mem.eql(u8, model_name, "xtree"))
        .{ .vertices = &xtree.vertices, .faces = &xtree.faces }
    else {
        std.debug.print("Unknown model: {s}\nAvailable: xtree, cow\n", .{model_name});
        return error.InvalidModel;
    };

    std.debug.print("Loading model: {s} ({d} vertices, {d} faces)\n", .{
        model_name,
        model.vertices.len,
        model.faces.len,
    });

    const rainbow_mode = args.len > 2 and std.mem.eql(u8, args[2], "rainbow");

    _ = c.SDL_Init(c.SDL_INIT_VIDEO);
    defer c.SDL_Quit();

    var rasterizer = try Rasterizer.init(allocator, SCREEN_WIDTH, SCREEN_HEIGHT);
    defer rasterizer.deinit();

    var camera = Camera.init();
    camera.position = .{ .x = 0, .y = 10, .z = 40 };

    const window = c.SDL_CreateWindow("3D Tree Rasterizer", 0, 0, SCREEN_WIDTH, SCREEN_HEIGHT, 0);
    defer c.SDL_DestroyWindow(window);

    const screen = c.SDL_GetWindowSurface(window);

    var running = true;
    var event: c.SDL_Event = undefined;

    const keyboard_state = c.SDL_GetKeyboardState(null);

    var last_time = c.SDL_GetTicks();

    // FPS tracking
    var frame_count: u32 = 0;
    var fps_timer: u32 = 0;

    // Pre-compute vertex colors (3 colors per triangle)
    var vertex_colors = try allocator.alloc(g.Color, model.faces.len * 3);
    defer allocator.free(vertex_colors);

    for (model.faces, 0..) |face, i| {
        if (rainbow_mode) {
            vertex_colors[i * 3 + 0] = RED_COLOR;
            vertex_colors[i * 3 + 1] = GREEN_COLOR;
            vertex_colors[i * 3 + 2] = BLUE_COLOR;
        } else {
            const hash = (face.v1 *% 73) +% (face.v2 *% 151) +% (face.v3 *% 283);
            const variation = @as(u8, @truncate(hash % 128));
            const red: u8 = 0x20 + variation / 4;
            const green: u8 = 0x80 + variation;
            const blue: u8 = 0x20 + variation / 6;

            const color = g.Color.fromU8(red, green, blue);
            // All three vertices get the same color (flat shading)
            vertex_colors[i * 3 + 0] = color;
            vertex_colors[i * 3 + 1] = color;
            vertex_colors[i * 3 + 2] = color;
        }
    }

    while (running) {
        const current_time = c.SDL_GetTicks();
        const dt = @as(f32, @floatFromInt(current_time - last_time)) / 1000.0;
        last_time = current_time;

        // Calculate FPS
        frame_count += 1;
        fps_timer += @as(u32, @intFromFloat(dt * 1000.0));
        if (fps_timer >= 1000) {
            std.debug.print("FPS: {d:.2}\n", .{@as(f32, @floatFromInt(frame_count)) * 1000.0 / @as(f32, @floatFromInt(fps_timer))});
            frame_count = 0;
            fps_timer = 0;
        }

        // UPDATE PASS
        {
            // Event handling
            while (c.SDL_PollEvent(&event) != 0) {
                if (event.type == c.SDL_QUIT) running = false;
            }

            // Continuous movement based on key states
            const forward_vec = camera.forward().scale(MOVE_SPEED * dt);
            const right_vec = camera.right().scale(MOVE_SPEED * dt);

            // WASD movement
            if (keyboard_state[c.SDL_SCANCODE_W] != 0) {
                camera.position = camera.position.add(forward_vec);
            }
            if (keyboard_state[c.SDL_SCANCODE_S] != 0) {
                camera.position = camera.position.sub(forward_vec);
            }
            if (keyboard_state[c.SDL_SCANCODE_A] != 0) {
                camera.position = camera.position.sub(right_vec);
            }
            if (keyboard_state[c.SDL_SCANCODE_D] != 0) {
                camera.position = camera.position.add(right_vec);
            }
            if (keyboard_state[c.SDL_SCANCODE_Q] != 0) {
                camera.position.y += MOVE_SPEED * dt;
            }
            if (keyboard_state[c.SDL_SCANCODE_E] != 0) {
                camera.position.y -= MOVE_SPEED * dt;
            }

            // Arrow keys for camera rotation
            if (keyboard_state[c.SDL_SCANCODE_LEFT] != 0) {
                camera.yaw -= ROTATE_SPEED * dt;
            }
            if (keyboard_state[c.SDL_SCANCODE_RIGHT] != 0) {
                camera.yaw += ROTATE_SPEED * dt;
            }
            if (keyboard_state[c.SDL_SCANCODE_UP] != 0) {
                camera.pitch += ROTATE_SPEED * dt;
            }
            if (keyboard_state[c.SDL_SCANCODE_DOWN] != 0) {
                camera.pitch -= ROTATE_SPEED * dt;
            }

            // Clamp pitch to avoid gimbal lock
            camera.pitch = std.math.clamp(camera.pitch, -1.5, 1.5);
        }

        // RASTERIZATION PASS - RENDER LOOP
        {
            // Lock framebuffer and clear buffers
            _ = c.SDL_LockSurface(screen);
            const framebuffer: [*]u32 = @ptrCast(@alignCast(screen.*.pixels));

            rasterizer.clearBuffers(framebuffer);

            for (model.faces, 0..) |face, i| {
                const v0_w = model.vertices[face.v1];
                const v1_w = model.vertices[face.v2];
                const v2_w = model.vertices[face.v3];

                const v0_r = rasterizer.projectVertex(v0_w, camera);
                const v1_r = rasterizer.projectVertex(v1_w, camera);
                const v2_r = rasterizer.projectVertex(v2_w, camera);

                // Skip triangles behind camera
                if (v0_r.x < 0 or v1_r.x < 0 or v2_r.x < 0) continue;

                const c0 = vertex_colors[i * 3 + 0];
                const c1 = vertex_colors[i * 3 + 1];
                const c2 = vertex_colors[i * 3 + 2];

                rasterizer.rasterizeTriangle(framebuffer, v0_r, v1_r, v2_r, c0, c1, c2);
            }

            c.SDL_UnlockSurface(screen);
            _ = c.SDL_UpdateWindowSurface(window);
        }
    }
}
