const std = @import("std");
const g = @import("geometry");
const Texture = @import("texture.zig").Texture;
const Camera = @import("camera.zig");

const BG_COLOR = g.Color{ .r = 32, .g = 32, .b = 32 };
const RED_COLOR = g.Color{ .r = 255, .g = 0, .b = 0 };
const GREEN_COLOR = g.Color{ .r = 0, .g = 255, .b = 0 };
const BLUE_COLOR = g.Color{ .r = 0, .g = 0, .b = 255 };

const Rasterizer = @This();

// work phases for threads
const WorkPhase = enum(u32) {
    idle = 0,
    binning = 1,
    rasterizing = 2,
    shutdown = 3,
};

pub const ColorMode = enum {
    green,
    rainbow,
    texture,
};

zbuffer: []f32,
screen_width: u32,
screen_height: u32,
allocator: std.mem.Allocator,

threads: []std.Thread,
num_threads: u32,
global_bins: []std.ArrayList(usize), // One bin list per thread, storing indices of faces

// Cached projected vertices (reused each frame)
projected_vertices: []g.V3f,

// Pre-allocated local bins for binning phase (num_threads * num_threads)
// Each thread gets num_threads bins (one per stripe)
local_bins: []std.ArrayList(usize),

// Thread pool synchronization
work_phase: std.atomic.Value(u32),
threads_completed: std.atomic.Value(u32),
work_generation: std.atomic.Value(u32), // Incremented each time new work is available

// Shared work context
model: *const g.Model,
framebuffer: ?[*]u32,
vertex_colors: ?[]g.Color,
texture: ?*const Texture,

// Track if threads have been started
threads_started: bool,

pub fn init(allocator: std.mem.Allocator, screen_width: u32, screen_height: u32, num_threads: u32, model: *const g.Model, color_mode: ColorMode) !Rasterizer {
    const global_bins = try allocator.alloc(std.ArrayList(usize), num_threads);
    for (global_bins) |*bin| {
        bin.* = .empty;
    }

    // Pre-allocate local bins: each thread gets num_threads bins (one per stripe)
    const local_bins = try allocator.alloc(std.ArrayList(usize), num_threads * num_threads);
    for (local_bins) |*bin| {
        bin.* = .empty;
    }

    const threads = try allocator.alloc(std.Thread, num_threads);

    std.debug.print("Initializing rasterizer with model containing {d} vertices, {d} faces, and {d} texcoords\n", .{ model.vertices.len, model.faces.len, model.texcoords.len });

    var vertex_colors: ?[]g.Color = null;
    var texture: ?*const Texture = null;

    switch (color_mode) {
        .green, .rainbow => {
            vertex_colors = try allocator.alloc(g.Color, model.faces.len * 3);
            for (model.faces, 0..) |face, i| {
                if (color_mode == .green) {
                    const vertex_indices = face.vertex_indices;
                    const hash = (vertex_indices[0] *% 73) +% (vertex_indices[1] *% 151) +% (vertex_indices[2] *% 283);
                    const variation = @as(u8, @truncate(hash % 128));
                    const red: u8 = 0x20 + variation / 4;
                    const green: u8 = 0x80 + variation;
                    const blue: u8 = 0x20 + variation / 6;

                    const color = g.Color.fromU8(red, green, blue);
                    // All three vertices get the same color (flat shading)
                    vertex_colors.?[i * 3 + 0] = color;
                    vertex_colors.?[i * 3 + 1] = color;
                    vertex_colors.?[i * 3 + 2] = color;
                } else {
                    vertex_colors.?[i * 3 + 0] = RED_COLOR;
                    vertex_colors.?[i * 3 + 1] = GREEN_COLOR;
                    vertex_colors.?[i * 3 + 2] = BLUE_COLOR;
                }
            }
        },
        .texture => {
            if (model.texcoords.len == 0) {
                return error.TextureCoordinatesRequired;
            }
            texture = try Texture.initFromFilePinned(allocator, "assets/texture.jpeg");
        },
    }

    return Rasterizer{
        .allocator = allocator,
        .screen_width = screen_width,
        .screen_height = screen_height,
        .zbuffer = try allocator.alloc(f32, screen_width * screen_height),
        .threads = threads,
        .num_threads = num_threads,
        .global_bins = global_bins,
        .projected_vertices = try allocator.alloc(g.V3f, model.vertices.len),
        .local_bins = local_bins,
        .work_phase = std.atomic.Value(u32).init(@intFromEnum(WorkPhase.idle)),
        .threads_completed = std.atomic.Value(u32).init(0),
        .work_generation = std.atomic.Value(u32).init(0),
        .model = model,
        .vertex_colors = vertex_colors,
        .texture = texture,
        .framebuffer = null,
        .threads_started = false,
    };
}

pub fn startThreads(self: *Rasterizer) !void {
    if (self.threads_started) return;

    for (0..self.num_threads) |i| {
        self.threads[i] = std.Thread.spawn(.{}, workerThread, .{ self, i }) catch {
            std.debug.print("Failed to spawn worker thread {d}\n", .{i});
            return error.ThreadSpawnFailed;
        };
    }
    self.threads_started = true;
}

pub fn deinit(self: *Rasterizer) void {
    // Only shutdown threads if they were started
    if (self.threads_started) {
        self.work_phase.store(@intFromEnum(WorkPhase.shutdown), .release);

        _ = self.work_generation.fetchAdd(1, .release);

        // Join all threads
        for (self.threads) |thread| {
            thread.join();
        }
    }

    self.allocator.free(self.zbuffer);
    self.allocator.free(self.threads);
    self.allocator.free(self.projected_vertices);

    for (self.global_bins) |*bin| {
        bin.deinit(self.allocator);
    }
    self.allocator.free(self.global_bins);

    for (self.local_bins) |*bin| {
        bin.deinit(self.allocator);
    }
    self.allocator.free(self.local_bins);

    if (self.vertex_colors) |colors| {
        self.allocator.free(colors);
    }

    if (self.texture) |tex| {
        tex.deinit();
        self.allocator.destroy(tex);
    }
}

fn workerThread(self: *Rasterizer, thread_index: usize) void {
    var last_generation: u32 = 0;

    while (true) {
        var current_generation = self.work_generation.load(.acquire);
        while (current_generation == last_generation) {
            std.atomic.spinLoopHint();
            current_generation = self.work_generation.load(.acquire);
        }
        last_generation = current_generation;

        const phase: WorkPhase = @enumFromInt(self.work_phase.load(.acquire));

        switch (phase) {
            .shutdown => return,
            .binning => {
                self.binFacesWorker(thread_index);
            },
            .rasterizing => {
                self.rasterizeStripeWorker(thread_index);
            },
            .idle => {},
        }

        _ = self.threads_completed.fetchAdd(1, .release);
    }
}

pub fn projectAllVertices(self: *Rasterizer, camera: *const Camera) void {
    for (self.model.vertices, 0..) |vertex, i| {
        self.projected_vertices[i] = self.projectVertex(vertex, camera.*);
    }
}

fn waitForThreads(self: *Rasterizer) void {
    while (self.threads_completed.load(.acquire) < self.num_threads) {
        std.atomic.spinLoopHint();
    }
}

fn dispatchWork(self: *Rasterizer, phase: WorkPhase) void {
    self.threads_completed.store(0, .release);

    self.work_phase.store(@intFromEnum(phase), .release);

    // Increment generation to wake threads
    _ = self.work_generation.fetchAdd(1, .release);
}

pub fn binFacesParallel(self: *Rasterizer) !void {
    for (self.global_bins) |*bin| {
        bin.clearRetainingCapacity();
    }

    for (self.local_bins) |*bin| {
        bin.clearRetainingCapacity();
    }

    self.dispatchWork(.binning);

    self.waitForThreads();

    for (self.local_bins, 0..) |bin, i| {
        const global_idx: usize = @mod(i, self.num_threads);
        for (bin.items) |face_index| {
            try self.global_bins[global_idx].append(self.allocator, face_index);
        }
    }
}

fn binFacesWorker(self: *Rasterizer, thread_index: usize) void {
    const stripe_height: f32 = @floatFromInt(self.screen_height / self.num_threads);
    const model = self.model;
    const local_bins = self.local_bins[thread_index * self.num_threads .. (thread_index + 1) * self.num_threads];

    const faces_per_thread = model.faces.len / self.num_threads;
    const start_face = thread_index * faces_per_thread;
    const end_face = if (thread_index == self.num_threads - 1) model.faces.len else (thread_index + 1) * faces_per_thread;
    const faces = model.faces[start_face..end_face];

    for (faces, 0..) |face, i| {
        const v0 = self.projected_vertices[face.vertex_indices[0]];
        const v1 = self.projected_vertices[face.vertex_indices[1]];
        const v2 = self.projected_vertices[face.vertex_indices[2]];

        if (v0.x < 0 or v1.x < 0 or v2.x < 0) continue;

        const min_y = g.min3(v0.y, v1.y, v2.y);
        const max_y = g.max3(v0.y, v1.y, v2.y);

        // Skip triangles completely off-screen or with invalid coordinates
        if (max_y < 0 or min_y >= @as(f32, @floatFromInt(self.screen_height))) continue;

        // Clamp to screen bounds to prevent out-of-bounds access
        const clamped_min_y = @max(0.0, min_y);
        const clamped_max_y = @min(@as(f32, @floatFromInt(self.screen_height - 1)), max_y);

        const min_stripe = @as(usize, @intFromFloat(@floor(clamped_min_y / stripe_height)));
        const max_stripe = @min(self.num_threads - 1, @as(usize, @intFromFloat(@floor(clamped_max_y / stripe_height))));

        for (min_stripe..max_stripe + 1) |stripe| {
            local_bins[stripe].append(self.allocator, start_face + i) catch continue;
        }
    }
}

pub fn rasterizeParallel(self: *Rasterizer, framebuffer: [*]u32) !void {
    self.framebuffer = framebuffer;

    self.dispatchWork(.rasterizing);

    self.waitForThreads();
}

fn rasterizeStripeWorker(self: *Rasterizer, thread_index: usize) void {
    const model = self.model;
    const framebuffer = self.framebuffer.?;
    const vertex_colors = self.vertex_colors;
    const bin = self.global_bins[thread_index];
    const stripe_height = self.screen_height / self.num_threads;
    const min_y = thread_index * stripe_height;
    const max_y = if (thread_index == self.num_threads - 1)
        self.screen_height
    else
        min_y + stripe_height;

    for (bin.items) |face_index| {
        const face = model.faces[face_index];

        var face_colors: ?[3]g.Color = null;

        if (vertex_colors) |colors| {
            face_colors = .{
                colors[face_index * 3 + 0],
                colors[face_index * 3 + 1],
                colors[face_index * 3 + 2],
            };
        }

        self.rasterizeTriangle(framebuffer, face, face_colors, min_y, max_y);
    }
}

pub inline fn projectVertex(self: Rasterizer, v: g.V3f, camera: Camera) g.V3f {
    // Step 1: Transform vertex from world space to camera space
    const v_cam = camera.worldToCamera(v);

    // Step 2: Check if behind camera
    // In camera space, -Z is forward, so v_cam.z > 0 means behind camera
    if (v_cam.z >= 0) {
        return .{ .x = -1, .y = -1, .z = 999999 }; // Invalid, far depth
    }

    // Step 3: Perspective projection
    // Divide by distance to get perspective
    const depth = -v_cam.z; // Convert to positive distance
    const inv_z = 1.0 / depth;

    var v_r: g.V3f = undefined;
    v_r.x = v_cam.x * inv_z;
    v_r.y = v_cam.y * inv_z;
    v_r.z = depth; // Store positive depth

    // Step 4: Convert from normalized device coordinates [-1, 1] to [0, 1]
    v_r.x = (v_r.x + 1.0) * 0.5;
    v_r.y = (v_r.y + 1.0) * 0.5;

    // Step 5: Flip y axis (screen y goes down)
    v_r.y = 1.0 - v_r.y;

    // Step 6: Scale to screen dimensions
    v_r.x = v_r.x * @as(f32, @floatFromInt(self.screen_width));
    v_r.y = v_r.y * @as(f32, @floatFromInt(self.screen_height));

    return v_r;
}

pub inline fn rasterizeTriangle(
    self: Rasterizer,
    framebuffer: [*]u32,
    face: g.Face,
    colors: ?[3]g.Color,
    min_y_stripe: usize,
    max_y_stripe: usize,
) void {
    const v0 = self.projected_vertices[face.vertex_indices[0]];
    const v1 = self.projected_vertices[face.vertex_indices[1]];
    const v2 = self.projected_vertices[face.vertex_indices[2]];

    // Skip triangles with very small or zero depth (too close to camera)
    const min_depth = 0.001;
    if (v0.z < min_depth or v1.z < min_depth or v2.z < min_depth) return;

    // Compute triangle area using edge function
    const area = (v2.x - v0.x) * (v1.y - v0.y) - (v2.y - v0.y) * (v1.x - v0.x);

    // Backface culling
    if (area <= 0) return;

    const inv_area = 1.0 / area;

    // Calculate bounding box of triangle
    const min_x = @max(0, @as(i32, @intFromFloat(g.min3(v0.x, v1.x, v2.x))));
    const min_y = @max(@as(i32, @intCast(min_y_stripe)), @max(0, @as(i32, @intFromFloat(g.min3(v0.y, v1.y, v2.y)))));
    const max_x = @min(@as(i32, @intCast(self.screen_width - 1)), @as(i32, @intFromFloat(g.max3(v0.x, v1.x, v2.x))));
    const max_y = @min(@as(i32, @intCast(max_y_stripe - 1)), @min(@as(i32, @intCast(self.screen_height - 1)), @as(i32, @intFromFloat(g.max3(v0.y, v1.y, v2.y)))));

    // Precompute edge equation coefficients for incremental evaluation
    // Edge equation: E(x,y) = (x - x0) * (y1 - y0) - (y - y0) * (x1 - x0)
    // Which expands to: E(x,y) = (y1-y0)x - (x1-x0)y - x0y1 + y0x1 = Ax + By + C
    // Where: A = (y1 - y0), B = -(x1 - x0), C = y0x1 - x0y1

    // Edge 0: v1 -> v2
    const A0 = v2.y - v1.y;
    const B0 = v1.x - v2.x;
    const C0 = v1.y * v2.x - v1.x * v2.y;

    // Edge 1: v2 -> v0
    const A1 = v0.y - v2.y;
    const B1 = v2.x - v0.x;
    const C1 = v2.y * v0.x - v2.x * v0.y;

    // Edge 2: v0 -> v1
    const A2 = v1.y - v0.y;
    const B2 = v0.x - v1.x;
    const C2 = v0.y * v1.x - v0.x * v1.y;

    // Starting point (top-left of bounding box, pixel center)
    const start_x = @as(f32, @floatFromInt(min_x)) + 0.5;
    const start_y = @as(f32, @floatFromInt(min_y)) + 0.5;

    // edge function at starting point
    var w0_row = A0 * start_x + B0 * start_y + C0;
    var w1_row = A1 * start_x + B1 * start_y + C1;
    var w2_row = A2 * start_x + B2 * start_y + C2;

    // We can also optimize calculating z
    // 1/z = bc0 * 1/v0.z + bc1 * 1/v1.z + bc2 * 1/v2.z
    // bc0 + bc1 + bc2 = 1
    // bc0 = 1 - bc1 - bc2
    // 1/z = (1 - bc1 - bc2) * 1/v0.z + bc1 * 1/v1.z + bc2 * 1/v2.z
    // 1/z = 1/v0.z + bc1 * (1/v1.z - 1/v0.z) + bc2 * (1/v2.z - 1/v0.z)
    // where A = 1/v1.z - 1/v0.z and B = 1/v2.z - 1/v0.z are constants for the triangle
    const inv_z0 = 1 / v0.z;
    const inv_z1 = 1 / v1.z;
    const inv_z2 = 1 / v2.z;

    const Az = inv_z1 - inv_z0;
    const Bz = inv_z2 - inv_z0;

    var c0_over_z: g.Color = undefined;
    var c1_over_z: g.Color = undefined;
    var c2_over_z: g.Color = undefined;

    // Perspective-correct attribute interpolation: multiply by 1/z before interpolating

    if (colors) |face_colors| {
        const c0 = face_colors[0];
        const c1 = face_colors[1];
        const c2 = face_colors[2];
        c0_over_z = g.Color{ .r = c0.r * inv_z0, .g = c0.g * inv_z0, .b = c0.b * inv_z0 };
        c1_over_z = g.Color{ .r = c1.r * inv_z1, .g = c1.g * inv_z1, .b = c1.b * inv_z1 };
        c2_over_z = g.Color{ .r = c2.r * inv_z2, .g = c2.g * inv_z2, .b = c2.b * inv_z2 };
    }

    var uv0_over_z: g.V2f = undefined;
    var uv1_over_z: g.V2f = undefined;
    var uv2_over_z: g.V2f = undefined;

    var uv0: ?g.V2f = null;
    var uv1: ?g.V2f = null;
    var uv2: ?g.V2f = null;

    if (face.texcoord_indices) |t_idx| {
        const texcoords = self.model.texcoords;
        uv0 = texcoords[t_idx[0]];
        uv1 = texcoords[t_idx[1]];
        uv2 = texcoords[t_idx[2]];
    }

    const has_uvs = uv0 != null and uv1 != null and uv2 != null;

    if (has_uvs) {
        uv0_over_z = g.V2f{ .x = uv0.?.x * inv_z0, .y = uv0.?.y * inv_z0 };
        uv1_over_z = g.V2f{ .x = uv1.?.x * inv_z1, .y = uv1.?.y * inv_z1 };
        uv2_over_z = g.V2f{ .x = uv2.?.x * inv_z2, .y = uv2.?.y * inv_z2 };
    }

    // Loop through bounding box with incremental evaluation
    var y: i32 = min_y;
    while (y <= max_y) : (y += 1) {
        // Reset edge values for this row
        var w0 = w0_row;
        var w1 = w1_row;
        var w2 = w2_row;

        var x: i32 = min_x;
        while (x <= max_x) : (x += 1) {

            // Check if inside triangle
            if (w0 >= 0 and w1 >= 0 and w2 >= 0) {

                // Barycentric coordinates
                const bc0 = w0 * inv_area;
                const bc1 = w1 * inv_area;
                const bc2 = w2 * inv_area;

                // Interpolate depth
                const inv_z = inv_z0 + bc1 * Az + bc2 * Bz;
                const z = 1.0 / inv_z;

                const index = @as(usize, @intCast(@as(u32, @intCast(y)) * self.screen_width + @as(u32, @intCast(x))));

                if (z < self.zbuffer[index]) {
                    self.zbuffer[index] = z;

                    var final_color: g.Color = undefined;

                    // Use texture if available and UVs are provided
                    if (has_uvs and self.texture != null) {
                        // Interpolate UV coordinates with perspective correction
                        const u = (uv0_over_z.x * bc0 + uv1_over_z.x * bc1 + uv2_over_z.x * bc2) * z;
                        const v = (uv0_over_z.y * bc0 + uv1_over_z.y * bc1 + uv2_over_z.y * bc2) * z;

                        final_color = self.texture.?.sample(u, v);
                    } else {
                        final_color = g.Color{
                            .r = (c0_over_z.r * bc0 + c1_over_z.r * bc1 + c2_over_z.r * bc2) * z,
                            .g = (c0_over_z.g * bc0 + c1_over_z.g * bc1 + c2_over_z.g * bc2) * z,
                            .b = (c0_over_z.b * bc0 + c1_over_z.b * bc1 + c2_over_z.b * bc2) * z,
                        };
                    }

                    framebuffer[index] = final_color.toPacked();
                }
            }

            // Increment edge values for next pixel (edge function value is now A(x+1) instead of A)
            w0 += A0;
            w1 += A1;
            w2 += A2;
        }

        // Move to next row (edge function value is now B(y+1) instead of B)
        w0_row += B0;
        w1_row += B1;
        w2_row += B2;
    }
}

pub fn clearBuffers(self: Rasterizer, framebuffer: [*]u32) void {
    @memset(framebuffer[0..(self.screen_width * self.screen_height)], BG_COLOR.toPacked());
    @memset(self.zbuffer, 999999.0);
}
