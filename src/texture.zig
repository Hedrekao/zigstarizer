const g = @import("geometry");
const c = @import("c.zig").c;
const std = @import("std");

pub const Texture = @This();

width: u32,
height: u32,
data: []const u8, // RGB format (3 bytes per pixel)
raw_ptr: [*c]u8, // Original C pointer for freeing

pub fn initFromFilePinned(allocator: std.mem.Allocator, path: [*c]const u8) !*const Texture {
    var img_width: c_int = 0;
    var img_height: c_int = 0;
    var img_channels: c_int = 0;

    std.debug.print("Loading texture from: {s}\n", .{path});

    c.stbi_set_flip_vertically_on_load(1);
    const data = c.stbi_load(path, &img_width, &img_height, &img_channels, 3);
    if (data == null) {
        const reason = c.stbi_failure_reason();
        std.debug.print("Failed to load texture: {s}\n", .{reason});
        return error.LoadFailed;
    }

    const size = @as(usize, @intCast(img_width)) * @as(usize, @intCast(img_height)) * 3;
    std.debug.print("Texture loaded successfully: {}x{}, {} channels\n", .{ img_width, img_height, img_channels });

    const texture = try allocator.create(Texture);

    texture.* = .{
        .width = @intCast(img_width),
        .height = @intCast(img_height),
        .data = data[0..size],
        .raw_ptr = data,
    };

    return texture;
}

pub fn deinit(self: *const Texture) void {
    c.stbi_image_free(self.raw_ptr);
}

pub fn sample(self: Texture, u: f32, v: f32) g.Color {
    // Wrap UV coordinates to [0, 1] range
    const u_wrapped = u - @floor(u);
    const v_wrapped = v - @floor(v);

    // Convert to pixel coordinates
    const x = @min(@as(u32, @intFromFloat(u_wrapped * @as(f32, @floatFromInt(self.width)))), self.width - 1);
    const y = @min(@as(u32, @intFromFloat(v_wrapped * @as(f32, @floatFromInt(self.height)))), self.height - 1);

    const idx = (y * self.width + x) * 3;
    return g.Color{
        .r = @floatFromInt(self.data[idx + 0]),
        .g = @floatFromInt(self.data[idx + 1]),
        .b = @floatFromInt(self.data[idx + 2]),
    };
}
