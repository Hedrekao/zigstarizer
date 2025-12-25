const g = @import("geometry");

const Camera = @This();

position: g.V3f,
yaw: f32, // Rotation around Y axis (left/right)
pitch: f32, // Rotation around X axis (up/down)

pub fn init() Camera {
    return .{
        .position = .{ .x = 0, .y = 0, .z = 0 },
        .yaw = 0,
        .pitch = 0,
    };
}

// Get the forward direction vector based on camera rotation
pub fn forward(self: Camera) g.V3f {
    const cos_pitch = @cos(self.pitch);
    const fwd = g.V3f{
        .x = @sin(self.yaw) * cos_pitch,
        .y = @sin(self.pitch),
        .z = -@cos(self.yaw) * cos_pitch,
    };
    return fwd.normalize();
}

// Get the right direction vector
pub fn right(self: Camera) g.V3f {
    const r = g.V3f{
        .x = @cos(self.yaw),
        .y = 0,
        .z = @sin(self.yaw),
    };
    return r.normalize();
}

// Get the up direction vector
pub fn up(self: Camera) g.V3f {
    const r = self.right();
    const f = self.forward();
    return r.cross(f).normalize();
}

// Transform vertex from world space to camera space with rotation
pub fn worldToCamera(self: Camera, v: g.V3f) g.V3f {
    // Translate to camera position
    const translated = v.sub(self.position);

    // Get camera basis vectors
    const cam_right = self.right();
    const cam_up = self.up();
    const cam_forward = self.forward();

    // Rotate into camera space
    return .{
        .x = translated.dot(cam_right),
        .y = translated.dot(cam_up),
        .z = -translated.dot(cam_forward), // Negative because we look down -Z
    };
}
