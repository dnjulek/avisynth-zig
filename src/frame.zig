//! `Frame`: an owned `AVS_VideoFrame*` reference, plus typed plane views.
//!
//! A `Frame` from `Clip.getFrame`, `Env.newFrame` or `Frame.retain` is owned:
//! release it exactly once, or hand it to the host by returning `frame.ptr`
//! from a get_frame callback (that transfers the reference). Plain assignment
//! copies the handle without adding a reference.
//!
//! `Plane`/`PlaneMut` views borrow the frame: they are valid while the frame
//! is alive and its pointer unchanged. `makeWritable` / `makePropertyWritable`
//! may replace `ptr`, which invalidates every view taken before.
//!
//! Geometry contract: `pitch` (bytes between row starts) and `width` (active
//! samples per row) are independent; two frames of the same format may have
//! different pitches (crops, subframes, other allocators). Nothing after the
//! last row's active samples is assumed accessible, so `span()` ends there.

const std = @import("std");
const c = @import("avisynth_c");
const api = @import("api.zig");
const Env = @import("env.zig").Env;
const props = @import("props.zig");

pub fn Plane(comptime T: type) type {
    return PlaneImpl(T, false);
}

pub fn PlaneMut(comptime T: type) type {
    return PlaneImpl(T, true);
}

fn PlaneImpl(comptime T: type, comptime mutable: bool) type {
    return struct {
        const Self = @This();
        pub const Elem = T;
        const Ptr = if (mutable) [*]align(@alignOf(T)) u8 else [*]align(@alignOf(T)) const u8;
        const Row = if (mutable) []T else []const T;

        ptr: Ptr,
        /// Bytes between row starts (a multiple of @sizeOf(T)).
        pitch: usize,
        /// Active samples per row.
        width: u32,
        height: u32,

        /// Build from raw geometry, validating the host's signed values.
        pub fn fromRaw(ptr: ?[*]const u8, pitch: c_int, row_size: c_int, height: c_int) Self {
            std.debug.assert(ptr != null);
            std.debug.assert(pitch > 0 and row_size >= 0 and height >= 0);
            const upitch: usize = @intCast(pitch);
            const urow: usize = @intCast(row_size);
            std.debug.assert(urow % @sizeOf(T) == 0);
            std.debug.assert(upitch % @sizeOf(T) == 0);
            std.debug.assert(height <= 1 or upitch >= urow);
            const p: Ptr = @ptrCast(@alignCast(@constCast(ptr.?)));
            return .{
                .ptr = p,
                .pitch = upitch,
                .width = @intCast(urow / @sizeOf(T)),
                .height = @intCast(height),
            };
        }

        /// Pitch in elements of T.
        pub fn stride(self: Self) usize {
            return self.pitch / @sizeOf(T);
        }

        /// Active bytes per row.
        pub fn rowBytes(self: Self) usize {
            return @as(usize, self.width) * @sizeOf(T);
        }

        /// Active samples of row `y`.
        pub fn row(self: Self, y: usize) Row {
            std.debug.assert(y < self.height);
            // pitch is a multiple of @sizeOf(T) (checked in fromRaw), so every
            // row start keeps the plane's sample alignment.
            const r: [*]T = @ptrCast(@alignCast(@constCast(self.ptr + y * self.pitch)));
            return r[0..self.width];
        }

        /// Every row as one slice: element (x, y) is `span()[y * stride() + x]`.
        /// Ends after the last row's active samples (padding between rows is
        /// included and may be read; written only for owned output frames).
        pub fn span(self: Self) Row {
            if (self.height == 0) return &.{};
            const base: [*]T = @ptrCast(@constCast(self.ptr));
            return base[0 .. (self.height - 1) * self.stride() + self.width];
        }

        /// `height * stride()` elements: the VapourSynth-style plane slice that
        /// kernels stepping rows with `rows = rows[stride..]` expect. Only the
        /// active samples of each row (and inter-row padding) are guaranteed
        /// accessible; the tail after the last row's active samples is not, so
        /// use this only on frames you allocated (`Env.newFrame`) or on a
        /// canonical copy, never on an arbitrary (cropped) upstream frame.
        pub fn fullSlice(self: Self) Row {
            const base: [*]T = @ptrCast(@constCast(self.ptr));
            return base[0 .. @as(usize, self.height) * self.stride()];
        }

        /// True when the plane starts on an `alignment`-byte boundary.
        pub fn isAligned(self: Self, alignment: usize) bool {
            return @intFromPtr(self.ptr) % alignment == 0;
        }

        /// Read-only view of the same plane.
        pub fn constView(self: Self) Plane(T) {
            return .{ .ptr = self.ptr, .pitch = self.pitch, .width = self.width, .height = self.height };
        }
    };
}

pub const Frame = struct {
    ptr: *c.AVS_VideoFrame,

    /// Release an owned reference. [core]
    pub fn release(self: Frame) void {
        api.fnPtr("avs_release_video_frame")(self.ptr);
    }

    /// New owned reference to the same frame (shares pixels and props). [core]
    pub fn retain(self: Frame) Frame {
        return .{ .ptr = api.fnPtr("avs_copy_video_frame")(self.ptr).? };
    }

    /// Read view of plane `id` (`AVS_PLANAR_*`). [planar]
    pub fn plane(self: Frame, comptime T: type, id: c_int) Plane(T) {
        return Plane(T).fromRaw(
            api.fnPtr("avs_get_read_ptr_p")(self.ptr, id),
            api.fnPtr("avs_get_pitch_p")(self.ptr, id),
            api.fnPtr("avs_get_row_size_p")(self.ptr, id),
            api.fnPtr("avs_get_height_p")(self.ptr, id),
        );
    }

    /// Write view of plane `id`. The frame must be writable (new frames are;
    /// otherwise call `makeWritable` first). [planar]
    pub fn planeMut(self: Frame, comptime T: type, id: c_int) PlaneMut(T) {
        const w = api.fnPtr("avs_get_write_ptr_p")(self.ptr, id);
        std.debug.assert(w != null); // not writable
        return PlaneMut(T).fromRaw(
            w,
            api.fnPtr("avs_get_pitch_p")(self.ptr, id),
            api.fnPtr("avs_get_row_size_p")(self.ptr, id),
            api.fnPtr("avs_get_height_p")(self.ptr, id),
        );
    }

    pub fn pitch(self: Frame, id: c_int) usize {
        return @intCast(api.fnPtr("avs_get_pitch_p")(self.ptr, id));
    }
    pub fn rowSize(self: Frame, id: c_int) usize {
        return @intCast(api.fnPtr("avs_get_row_size_p")(self.ptr, id));
    }
    pub fn height(self: Frame, id: c_int) usize {
        return @intCast(api.fnPtr("avs_get_height_p")(self.ptr, id));
    }

    /// [planar]
    pub fn isWritable(self: Frame) bool {
        return api.fnPtr("avs_is_writable")(self.ptr) != 0;
    }

    /// Make pixels and properties uniquely owned (may copy the frame and
    /// replace `ptr`; earlier plane/property views become invalid). [planar]
    pub fn makeWritable(self: *Frame, env: Env) error{FrameAllocationFailed}!void {
        var p: [*c]c.AVS_VideoFrame = self.ptr;
        _ = api.fnPtr("avs_make_writable")(env.ptr, &p);
        self.ptr = p orelse return error.FrameAllocationFailed;
    }

    /// Make only the property map uniquely owned; pixels stay shared (cheap
    /// re-reference). Use for analysis filters that only add metadata. May
    /// replace `ptr`. [props]
    pub fn makePropertyWritable(self: *Frame, env: Env) error{FrameAllocationFailed}!void {
        var p: [*c]c.AVS_VideoFrame = self.ptr;
        _ = api.fnPtr("avs_make_property_writable")(env.ptr, &p);
        self.ptr = p orelse return error.FrameAllocationFailed;
    }

    /// [props]
    pub fn isPropertyWritable(self: Frame) bool {
        return api.fnPtr("avs_is_property_writable")(self.ptr) != 0;
    }

    /// Read-only property view, valid while the frame is alive. [props]
    pub fn propsRO(self: Frame, env: Env) props.PropsRO {
        return .{ .env = env, .map = api.fnPtr("avs_get_frame_props_ro")(env.ptr, self.ptr).? };
    }

    /// Writable property view. Only for frames whose properties are uniquely
    /// owned: new frames, or after `makeWritable`/`makePropertyWritable`. [props]
    pub fn propsRW(self: Frame, env: Env) props.PropsRW {
        std.debug.assert(self.isPropertyWritable());
        return .{ .env = env, .map = api.fnPtr("avs_get_frame_props_rw")(env.ptr, self.ptr).? };
    }

    /// Copy every property of `src` onto this (writable) frame. [props]
    pub fn copyPropsFrom(self: Frame, env: Env, src: Frame) void {
        api.fnPtr("avs_copy_frame_props")(env.ptr, src.ptr, self.ptr);
    }
};

/// Copy plane `id` of `src` into `dst` (both same geometry; pitches may
/// differ). Used for planes a filter passes through unprocessed. [planar]
pub fn copyPlane(env: Env, dst: Frame, src: Frame, id: c_int) void {
    const s = src.plane(u8, id);
    const d = dst.planeMut(u8, id);
    std.debug.assert(s.width == d.width and s.height == d.height);
    env.bitBlt(d.ptr, d.pitch, s.ptr, s.pitch, s.width, s.height);
}

test "plane views honor independent pitch and active width" {
    const t = std.testing;
    // 3 rows, 5 active u16 samples, pitch 16 bytes (8 samples).
    var buf: [24]u16 align(16) = undefined;
    for (&buf, 0..) |*v, i| v.* = @intCast(i);
    const p = PlaneMut(u16).fromRaw(@ptrCast(&buf), 16, 10, 3);
    try t.expectEqual(@as(usize, 8), p.stride());
    try t.expectEqual(@as(u32, 5), p.width);
    try t.expectEqual(@as(usize, 10), p.rowBytes());
    try t.expectEqualSlices(u16, &.{ 8, 9, 10, 11, 12 }, p.row(1));
    // Span stops after the last active sample: 2 full pitches + 5.
    try t.expectEqual(@as(usize, 21), p.span().len);
    p.row(2)[4] = 999;
    try t.expectEqual(@as(u16, 999), buf[20]);
    try t.expectEqual(@as(u16, 21), buf[21]); // padding untouched
    try t.expectEqual(@as(usize, 0), Plane(f32).fromRaw(@ptrCast(&buf), 16, 0, 0).span().len);
}
