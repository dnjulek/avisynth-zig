//! Planar format description decoded from `AVS_VideoInfo.pixel_type`.
//!
//! Pure functions (no host calls), so they are unit-tested without AviSynth.
//! Only planar Y / YUV(A) / RGB(A) are described; packed RGB, YUY2 and other
//! interleaved layouts are reported as `error.UnsupportedFormat` so they are
//! never fed into planar kernels by accident.

const std = @import("std");
const c = @import("avisynth_c");

pub const ColorFamily = enum { gray, yuv, rgb };

/// Storage type of one sample. 9..16-bit integers share the `u16` carrier,
/// so values above the nominal peak are possible.
pub const SampleType = enum {
    u8,
    u16,
    f32,

    pub fn Type(comptime self: SampleType) type {
        return switch (self) {
            .u8 => u8,
            .u16 => u16,
            .f32 => f32,
        };
    }

    pub fn bytes(self: SampleType) u8 {
        return switch (self) {
            .u8 => 1,
            .u16 => 2,
            .f32 => 4,
        };
    }

    pub fn isFloat(self: SampleType) bool {
        return self == .f32;
    }
};

pub const Error = error{UnsupportedFormat};

pub const Format = struct {
    family: ColorFamily,
    sample: SampleType,
    /// Bits per component: 8, 10, 12, 14, 16 or 32 (float).
    bits: u8,
    /// Color planes, excluding alpha: 1 (gray) or 3.
    color_planes: u8,
    has_alpha: bool,
    /// log2 chroma subsampling; 0 for gray/RGB.
    ssw: u2,
    ssh: u2,

    /// Decode a planar `pixel_type`.
    pub fn fromPixelType(pixel_type: c_int) Error!Format {
        const pt: u32 = @bitCast(pixel_type);
        const planar: u32 = @bitCast(c.AVS_CS_PLANAR);
        if (pt & planar == 0) return error.UnsupportedFormat;

        const bits: u8 = switch (pt & @as(u32, @intCast(c.AVS_CS_SAMPLE_BITS_MASK))) {
            c.AVS_CS_SAMPLE_BITS_8 => 8,
            c.AVS_CS_SAMPLE_BITS_10 => 10,
            c.AVS_CS_SAMPLE_BITS_12 => 12,
            c.AVS_CS_SAMPLE_BITS_14 => 14,
            c.AVS_CS_SAMPLE_BITS_16 => 16,
            c.AVS_CS_SAMPLE_BITS_32 => 32,
            else => return error.UnsupportedFormat,
        };
        const sample: SampleType = switch (bits) {
            8 => .u8,
            32 => .f32,
            else => .u16,
        };

        const yuv: u32 = c.AVS_CS_YUV;
        const yuva: u32 = c.AVS_CS_YUVA;
        const bgr: u32 = c.AVS_CS_BGR;
        const interleaved: u32 = c.AVS_CS_INTERLEAVED;

        var f: Format = .{
            .family = undefined,
            .sample = sample,
            .bits = bits,
            .color_planes = 3,
            .has_alpha = false,
            .ssw = 0,
            .ssh = 0,
        };

        if (pt & bgr != 0) {
            // Planar RGB / RGBA (RGB_TYPE / RGBA_TYPE live in the low bits).
            f.family = .rgb;
            if (pt & @as(u32, c.AVS_CS_RGBA_TYPE) != 0) {
                f.has_alpha = true;
            } else if (pt & @as(u32, c.AVS_CS_RGB_TYPE) == 0) {
                return error.UnsupportedFormat;
            }
            return f;
        }

        if (pt & interleaved != 0 and pt & yuv != 0) {
            // GENERIC_Y: planar + interleaved + yuv marks greyscale.
            f.family = .gray;
            f.color_planes = 1;
            return f;
        }

        if (pt & (yuv | yuva) == 0) return error.UnsupportedFormat;
        f.family = .yuv;
        f.has_alpha = pt & yuva != 0;
        f.ssw = try subsampling(pt >> @intCast(c.AVS_CS_SHIFT_SUB_WIDTH));
        f.ssh = try subsampling(pt >> @intCast(c.AVS_CS_SHIFT_SUB_HEIGHT));
        return f;
    }

    pub fn fromVideoInfo(vi: *const c.AVS_VideoInfo) Error!Format {
        if (vi.width == 0) return error.UnsupportedFormat;
        return fromPixelType(vi.pixel_type);
    }

    /// Logical planes including alpha (1..4).
    pub fn numPlanes(self: Format) u8 {
        return self.color_planes + @intFromBool(self.has_alpha);
    }

    pub fn isFloat(self: Format) bool {
        return self.sample == .f32;
    }

    /// AviSynth plane id for a logical plane index. Logical order matches
    /// VapourSynth: Y,U,V or R,G,B, then alpha (index 3, or 1 is never alpha:
    /// gray+alpha is not a pinned format).
    pub fn planeId(self: Format, logical: usize) c_int {
        std.debug.assert(logical < self.numPlanes());
        if (logical == self.color_planes) return c.AVS_PLANAR_A;
        return switch (self.family) {
            .gray => c.AVS_PLANAR_Y,
            .yuv => ([3]c_int{ c.AVS_PLANAR_Y, c.AVS_PLANAR_U, c.AVS_PLANAR_V })[logical],
            .rgb => ([3]c_int{ c.AVS_PLANAR_R, c.AVS_PLANAR_G, c.AVS_PLANAR_B })[logical],
        };
    }

    /// True for the U/V planes of YUV formats (zero-centered when float).
    pub fn isChroma(self: Format, logical: usize) bool {
        return self.family == .yuv and (logical == 1 or logical == 2);
    }

    pub fn planeWidth(self: Format, width: u32, logical: usize) u32 {
        return if (self.isChroma(logical)) width >> self.ssw else width;
    }

    pub fn planeHeight(self: Format, height: u32, logical: usize) u32 {
        return if (self.isChroma(logical)) height >> self.ssh else height;
    }

    /// Largest integer sample value (`2^bits - 1`); 1.0 for float.
    pub fn peak(self: Format) f64 {
        if (self.isFloat()) return 1.0;
        return @floatFromInt((@as(u64, 1) << @intCast(self.bits)) - 1);
    }

    /// Same family, subsampling and sample type (bit depth included).
    pub fn eql(a: Format, b: Format) bool {
        return std.meta.eql(a, b);
    }
};

/// AviSynth stores subsampling as an encoded 3-bit field: 3 -> 1x, 0 -> 2x,
/// 1 -> 4x (see AVS_CS_SUB_WIDTH_*). log2 factor = (field + 1) & 3.
fn subsampling(field: u32) Error!u2 {
    const v = field & 7;
    if (v > 3) return error.UnsupportedFormat;
    return @intCast((v + 1) & 3);
}

/// Pixel type for a planar format (inverse of `fromPixelType`, ignoring the
/// V/U plane-order flag which AviSynth+ always sets to VPLANEFIRST).
pub fn pixelType(f: Format) Error!c_int {
    const bits: c_int = switch (f.bits) {
        8 => c.AVS_CS_SAMPLE_BITS_8,
        10 => c.AVS_CS_SAMPLE_BITS_10,
        12 => c.AVS_CS_SAMPLE_BITS_12,
        14 => c.AVS_CS_SAMPLE_BITS_14,
        16 => c.AVS_CS_SAMPLE_BITS_16,
        32 => c.AVS_CS_SAMPLE_BITS_32,
        else => return error.UnsupportedFormat,
    };
    switch (f.family) {
        .gray => {
            if (f.has_alpha) return error.UnsupportedFormat;
            return c.AVS_CS_GENERIC_Y | bits;
        },
        .rgb => return (if (f.has_alpha) c.AVS_CS_GENERIC_RGBAP else c.AVS_CS_GENERIC_RGBP) | bits,
        .yuv => {
            const enc = [3]c_int{ 3, 0, 1 }; // log2 factor -> AVS field
            if (f.ssw > 2 or f.ssh > 2) return error.UnsupportedFormat;
            const base: c_int = if (f.has_alpha) c.AVS_CS_PLANAR | c.AVS_CS_YUVA else c.AVS_CS_PLANAR | c.AVS_CS_YUV;
            return base | c.AVS_CS_VPLANEFIRST | bits |
                (enc[f.ssw] << @intCast(c.AVS_CS_SHIFT_SUB_WIDTH)) |
                (enc[f.ssh] << @intCast(c.AVS_CS_SHIFT_SUB_HEIGHT));
        },
    }
}

test "decode pinned planar formats" {
    const t = std.testing;
    const yv12 = try Format.fromPixelType(c.AVS_CS_YV12);
    try t.expectEqual(ColorFamily.yuv, yv12.family);
    try t.expectEqual(SampleType.u8, yv12.sample);
    try t.expectEqual(@as(u2, 1), yv12.ssw);
    try t.expectEqual(@as(u2, 1), yv12.ssh);
    try t.expectEqual(@as(u8, 3), yv12.numPlanes());

    const yv24 = try Format.fromPixelType(c.AVS_CS_YV24);
    try t.expectEqual(@as(u2, 0), yv24.ssw);
    try t.expectEqual(@as(u2, 0), yv24.ssh);

    const yv16 = try Format.fromPixelType(c.AVS_CS_YUV422P10);
    try t.expectEqual(@as(u2, 1), yv16.ssw);
    try t.expectEqual(@as(u2, 0), yv16.ssh);
    try t.expectEqual(@as(u8, 10), yv16.bits);
    try t.expectEqual(SampleType.u16, yv16.sample);

    const yv411 = try Format.fromPixelType(c.AVS_CS_YV411);
    try t.expectEqual(@as(u2, 2), yv411.ssw);
    try t.expectEqual(@as(u2, 0), yv411.ssh);

    const y32 = try Format.fromPixelType(c.AVS_CS_Y32);
    try t.expectEqual(ColorFamily.gray, y32.family);
    try t.expectEqual(SampleType.f32, y32.sample);
    try t.expectEqual(@as(u8, 1), y32.numPlanes());
    try t.expectEqual(c.AVS_PLANAR_Y, y32.planeId(0));

    const rgbap = try Format.fromPixelType(c.AVS_CS_RGBAP16);
    try t.expectEqual(ColorFamily.rgb, rgbap.family);
    try t.expect(rgbap.has_alpha);
    try t.expectEqual(@as(u8, 4), rgbap.numPlanes());
    try t.expectEqual(c.AVS_PLANAR_R, rgbap.planeId(0));
    try t.expectEqual(c.AVS_PLANAR_G, rgbap.planeId(1));
    try t.expectEqual(c.AVS_PLANAR_B, rgbap.planeId(2));
    try t.expectEqual(c.AVS_PLANAR_A, rgbap.planeId(3));
    try t.expect(!rgbap.isChroma(1));

    const yuva = try Format.fromPixelType(c.AVS_CS_YUVA420PS);
    try t.expect(yuva.has_alpha);
    try t.expect(yuva.isChroma(2));
    try t.expect(!yuva.isChroma(3));
    try t.expectEqual(c.AVS_PLANAR_A, yuva.planeId(3));
    try t.expectEqual(@as(u32, 960), yuva.planeWidth(1920, 1));
    try t.expectEqual(@as(u32, 1920), yuva.planeWidth(1920, 3));
}

test "reject packed and interleaved formats" {
    const t = std.testing;
    for ([_]c_int{ c.AVS_CS_BGR24, c.AVS_CS_BGR32, c.AVS_CS_BGR48, c.AVS_CS_BGR64, c.AVS_CS_YUY2, c.AVS_CS_RAW32, c.AVS_CS_UNKNOWN }) |pt| {
        try t.expectError(error.UnsupportedFormat, Format.fromPixelType(pt));
    }
}

test "pixelType round-trips every pinned planar constant" {
    const all = [_]c_int{
        c.AVS_CS_YV24,      c.AVS_CS_YV16,      c.AVS_CS_YV12,      c.AVS_CS_YV411,     c.AVS_CS_YUV9,
        c.AVS_CS_Y8,        c.AVS_CS_Y10,       c.AVS_CS_Y12,       c.AVS_CS_Y14,       c.AVS_CS_Y16,
        c.AVS_CS_Y32,       c.AVS_CS_YUV444P10, c.AVS_CS_YUV422P12, c.AVS_CS_YUV420P14, c.AVS_CS_YUV420P16,
        c.AVS_CS_YUV444PS,  c.AVS_CS_YUV420PS,  c.AVS_CS_RGBP,      c.AVS_CS_RGBP10,    c.AVS_CS_RGBPS,
        c.AVS_CS_RGBAP,     c.AVS_CS_RGBAP16,   c.AVS_CS_RGBAPS,    c.AVS_CS_YUVA444,   c.AVS_CS_YUVA420P10,
        c.AVS_CS_YUVA422PS,
    };
    for (all) |pt| {
        const f = try Format.fromPixelType(pt);
        try std.testing.expectEqual(pt, try pixelType(f));
    }
}
