const std = @import("std");
const g = @import("geometry");
const Camera = @import("camera.zig");

const BG_COLOR = 0x00202020; // Dark gray background

const Rasterizer = @This();

zbuffer: []f32,
screen_width: u32,
screen_height: u32,
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator, screen_width: u32, screen_height: u32) !Rasterizer {
    return .{
        .allocator = allocator,
        .screen_width = screen_width,
        .screen_height = screen_height,
        .zbuffer = try allocator.alloc(f32, screen_width * screen_height),
    };
}

pub fn deinit(self: Rasterizer) void {
    self.allocator.free(self.zbuffer);
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
    v0: g.V3f,
    v1: g.V3f,
    v2: g.V3f,
    color_packed: u32,
) void {

    // Compute triangle area using edge function
    const area = (v2.x - v0.x) * (v1.y - v0.y) - (v2.y - v0.y) * (v1.x - v0.x);

    // Skip degenerate triangles only (render both front and back faces)
    if (@abs(area) <= 0.001) return;

    const inv_area = 1.0 / @abs(area);

    // Calculate bounding box of triangle
    const minX = @max(0, @as(i32, @intFromFloat(g.min3(v0.x, v1.x, v2.x))));
    const minY = @max(0, @as(i32, @intFromFloat(g.min3(v0.y, v1.y, v2.y))));
    const maxX = @min(@as(i32, @intCast(self.screen_width - 1)), @as(i32, @intFromFloat(g.max3(v0.x, v1.x, v2.x))));
    const maxY = @min(@as(i32, @intCast(self.screen_height - 1)), @as(i32, @intFromFloat(g.max3(v0.y, v1.y, v2.y))));

    // Early rejection: triangle completely outside screen
    const max_x_screen = @as(i32, @intCast(self.screen_width - 1));
    const max_y_screen = @as(i32, @intCast(self.screen_height - 1));
    if (minX > max_x_screen or maxX < 0 or minY > max_y_screen or maxY < 0) return;

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
    const start_x = @as(f32, @floatFromInt(minX)) + 0.5;
    const start_y = @as(f32, @floatFromInt(minY)) + 0.5;

    // edge function at starting point
    var w0_row = A0 * start_x + B0 * start_y + C0;
    var w1_row = A1 * start_x + B1 * start_y + C1;
    var w2_row = A2 * start_x + B2 * start_y + C2;

    // Loop through bounding box with incremental evaluation
    var y: i32 = minY;
    while (y <= maxY) : (y += 1) {
        // Reset edge values for this row
        var w0 = w0_row;
        var w1 = w1_row;
        var w2 = w2_row;

        var x: i32 = minX;
        while (x <= maxX) : (x += 1) {

            var edge0 = w0;
            var edge1 = w1;
            var edge2 = w2;

            // Flip signs for negative area triangles (to show both faces of model)
            if (area < 0) {
                edge0 = -edge0;
                edge1 = -edge1;
                edge2 = -edge2;
            }

            // Check if inside triangle
            if (edge0 >= 0 and edge1 >= 0 and edge2 >= 0) {

                // Barycentric coordinates
                const bc0 = edge0 * inv_area;
                const bc1 = edge1 * inv_area;
                const bc2 = edge2 * inv_area;

                // Interpolate depth
                const depth = bc0 * v0.z + bc1 * v1.z + bc2 * v2.z;

                const index = @as(usize, @intCast(@as(u32, @intCast(y)) * self.screen_width + @as(u32, @intCast(x))));

                if (depth < self.zbuffer[index]) {
                    self.zbuffer[index] = depth;
                    framebuffer[index] = color_packed;
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
    @memset(framebuffer[0..(self.screen_width * self.screen_height)], BG_COLOR);
    @memset(self.zbuffer, 999999.0);
}
