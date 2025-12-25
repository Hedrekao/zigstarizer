pub const Face = struct {
    v1: u32,
    v2: u32,
    v3: u32,
};

pub const V3f = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn add(self: V3f, other: V3f) V3f {
        return .{ .x = self.x + other.x, .y = self.y + other.y, .z = self.z + other.z };
    }

    pub fn sub(self: V3f, other: V3f) V3f {
        return .{ .x = self.x - other.x, .y = self.y - other.y, .z = self.z - other.z };
    }

    pub fn scale(self: V3f, s: f32) V3f {
        return .{ .x = self.x * s, .y = self.y * s, .z = self.z * s };
    }

    pub fn dot(self: V3f, other: V3f) f32 {
        return self.x * other.x + self.y * other.y + self.z * other.z;
    }

    pub fn cross(self: V3f, other: V3f) V3f {
        return .{
            .x = self.y * other.z - self.z * other.y,
            .y = self.z * other.x - self.x * other.z,
            .z = self.x * other.y - self.y * other.x,
        };
    }

    pub fn length(self: V3f) f32 {
        return @sqrt(self.x * self.x + self.y * self.y + self.z * self.z);
    }

    pub fn normalize(self: V3f) V3f {
        const len = self.length();
        if (len == 0) return .{ .x = 0, .y = 0, .z = 0 };
        return self.scale(1.0 / len);
    }
};

pub const V2f = struct {
    x: f32,
    y: f32,
};

pub fn min3(a: f32, b: f32, c: f32) f32 {
    return @min(@min(a, b), c);
}

pub fn max3(a: f32, b: f32, c: f32) f32 {
    return @max(@max(a, b), c);
}

