const std = @import("std");
const g = @import("geometry");
const models = @import("model_registry");
const Rasterizer = @import("rasterizer.zig");
const Camera = @import("camera.zig");
const c = @import("c.zig").c;

const SCREEN_WIDTH = 960;
const SCREEN_HEIGHT = 640;

const NUM_THREADS = 8;

const MOVE_SPEED = 15.0; // Units per second
const ROTATE_SPEED = 1.0; // Radians per second

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var args_iter = try init.minimal.args.iterateAllocator(allocator);
    defer args_iter.deinit();

    _ = args_iter.skip();
    const model_name = args_iter.next() orelse "xtree";

    const model = models.getModel(model_name) orelse {
        std.debug.print("Unknown model: {s}\nAvailable models: {s}\n", .{ model_name, models.available });
        return error.InvalidModel;
    };

    var color_mode: Rasterizer.ColorMode = .green;

    if (args_iter.next()) |flag| {
        if (std.mem.eql(u8, flag, "--rainbow")) {
            color_mode = .rainbow;
        } else if (std.mem.eql(u8, flag, "--texture")) {
            color_mode = .texture;
        }
    }

    _ = c.SDL_Init(c.SDL_INIT_VIDEO);
    defer c.SDL_Quit();
    var camera = Camera.init();
    camera.position = .{ .x = 0, .y = 10, .z = 40 };

    var rasterizer = try Rasterizer.init(allocator, SCREEN_WIDTH, SCREEN_HEIGHT, NUM_THREADS, &model, color_mode);
    defer rasterizer.deinit();

    try rasterizer.startThreads();

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

            // Project all vertices once (cached for binning and rasterization)
            rasterizer.projectAllVertices(&camera);

            try rasterizer.binFacesParallel();
            try rasterizer.rasterizeParallel(framebuffer);

            c.SDL_UnlockSurface(screen);
            _ = c.SDL_UpdateWindowSurface(window);
        }
    }
}
