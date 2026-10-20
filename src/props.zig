//! Borrowed frame-property map views. [props]
//!
//! A view is valid while its frame is alive and unchanged; reacquire it after
//! `Frame.makeWritable`/`makePropertyWritable`. Reads distinguish a missing
//! key, a wrong type and an out-of-range index from a valid zero.

const std = @import("std");
const c = @import("avisynth_c");
const api = @import("api.zig");
const Env = @import("env.zig").Env;

pub const PropType = enum(u8) {
    unset = 'u',
    int = 'i',
    float = 'f',
    data = 's',
    clip = 'c',
    frame = 'v',
    _,
};

pub const GetError = error{ Unset, WrongType, IndexOutOfRange, PropError };

fn mapErr(e: c_int) GetError!void {
    return switch (e) {
        c.AVS_GETPROPERROR_SUCCESS => {},
        c.AVS_GETPROPERROR_UNSET => error.Unset,
        c.AVS_GETPROPERROR_TYPE => error.WrongType,
        c.AVS_GETPROPERROR_INDEX => error.IndexOutOfRange,
        else => error.PropError,
    };
}

pub const AppendMode = enum(c_int) {
    replace = c.AVS_PROPAPPENDMODE_REPLACE,
    append = c.AVS_PROPAPPENDMODE_APPEND,
    touch = c.AVS_PROPAPPENDMODE_TOUCH,
};

pub const SetError = error{PropSetFailed};

pub const PropsRO = struct {
    env: Env,
    map: *const c.AVS_Map,

    pub fn numKeys(self: PropsRO) usize {
        return @intCast(@max(0, api.fnPtr("avs_prop_num_keys")(self.env.ptr, self.map)));
    }

    pub fn key(self: PropsRO, index: usize) ?[:0]const u8 {
        const k = api.fnPtr("avs_prop_get_key")(self.env.ptr, self.map, @intCast(index)) orelse return null;
        return std.mem.span(k);
    }

    /// Number of elements stored under `key`; null when the key is absent.
    pub fn numElements(self: PropsRO, k: [:0]const u8) ?usize {
        const n = api.fnPtr("avs_prop_num_elements")(self.env.ptr, self.map, k.ptr);
        return if (n < 0) null else @intCast(n);
    }

    pub fn typeOf(self: PropsRO, k: [:0]const u8) PropType {
        return @fromBackingInt(@intCast(@as(u8, @bitCast(api.fnPtr("avs_prop_get_type")(self.env.ptr, self.map, k.ptr)))));
    }

    pub fn getInt(self: PropsRO, k: [:0]const u8, index: usize) GetError!i64 {
        var e: c_int = 0;
        const v = api.fnPtr("avs_prop_get_int")(self.env.ptr, self.map, k.ptr, @intCast(index), &e);
        try mapErr(e);
        return v;
    }

    pub fn getFloat(self: PropsRO, k: [:0]const u8, index: usize) GetError!f64 {
        var e: c_int = 0;
        const v = api.fnPtr("avs_prop_get_float")(self.env.ptr, self.map, k.ptr, @intCast(index), &e);
        try mapErr(e);
        return v;
    }

    /// Data/string element with its explicit length (binary-safe; do not rely
    /// on zero termination). Borrowed from the map.
    pub fn getData(self: PropsRO, k: [:0]const u8, index: usize) GetError![]const u8 {
        var e: c_int = 0;
        const p = api.fnPtr("avs_prop_get_data")(self.env.ptr, self.map, k.ptr, @intCast(index), &e);
        try mapErr(e);
        const n = api.fnPtr("avs_prop_get_data_size")(self.env.ptr, self.map, k.ptr, @intCast(index), &e);
        try mapErr(e);
        if (n <= 0) return &.{};
        return p[0..@intCast(n)];
    }

    /// Every int element of `key`. Borrowed from the map.
    pub fn getIntArray(self: PropsRO, k: [:0]const u8) GetError![]const i64 {
        const n = self.numElements(k) orelse return error.Unset;
        var e: c_int = 0;
        const p = api.fnPtr("avs_prop_get_int_array")(self.env.ptr, self.map, k.ptr, &e);
        try mapErr(e);
        if (n == 0) return &.{};
        return p[0..n];
    }

    /// Every float element of `key`. Borrowed from the map.
    pub fn getFloatArray(self: PropsRO, k: [:0]const u8) GetError![]const f64 {
        const n = self.numElements(k) orelse return error.Unset;
        var e: c_int = 0;
        const p = api.fnPtr("avs_prop_get_float_array")(self.env.ptr, self.map, k.ptr, &e);
        try mapErr(e);
        if (n == 0) return &.{};
        return p[0..n];
    }

    /// Int property or `default` when absent/wrong type (only for optional
    /// metadata such as `_ColorRange`; use `getInt` to tell cases apart).
    pub fn intOr(self: PropsRO, k: [:0]const u8, default: i64) i64 {
        return self.getInt(k, 0) catch default;
    }
};

pub const PropsRW = struct {
    env: Env,
    map: *c.AVS_Map,

    pub fn ro(self: PropsRW) PropsRO {
        return .{ .env = self.env, .map = self.map };
    }

    // AviSynth's set functions return 0 on success and non-zero when e.g. an
    // append hits a key of another type.

    pub fn setInt(self: PropsRW, k: [:0]const u8, v: i64, mode: AppendMode) SetError!void {
        if (api.fnPtr("avs_prop_set_int")(self.env.ptr, self.map, k.ptr, v, @backingInt(mode)) != 0) return error.PropSetFailed;
    }

    pub fn setFloat(self: PropsRW, k: [:0]const u8, v: f64, mode: AppendMode) SetError!void {
        if (api.fnPtr("avs_prop_set_float")(self.env.ptr, self.map, k.ptr, v, @backingInt(mode)) != 0) return error.PropSetFailed;
    }

    /// Binary-safe: stores exactly `data.len` bytes.
    pub fn setData(self: PropsRW, k: [:0]const u8, data: []const u8, mode: AppendMode) SetError!void {
        const n = std.math.cast(c_int, data.len) orelse return error.PropSetFailed;
        if (api.fnPtr("avs_prop_set_data")(self.env.ptr, self.map, k.ptr, data.ptr, n, @backingInt(mode)) != 0) return error.PropSetFailed;
    }

    pub fn setIntArray(self: PropsRW, k: [:0]const u8, v: []const i64) SetError!void {
        const n = std.math.cast(c_int, v.len) orelse return error.PropSetFailed;
        if (api.fnPtr("avs_prop_set_int_array")(self.env.ptr, self.map, k.ptr, v.ptr, n) != 0) return error.PropSetFailed;
    }

    pub fn setFloatArray(self: PropsRW, k: [:0]const u8, v: []const f64) SetError!void {
        const n = std.math.cast(c_int, v.len) orelse return error.PropSetFailed;
        if (api.fnPtr("avs_prop_set_float_array")(self.env.ptr, self.map, k.ptr, v.ptr, n) != 0) return error.PropSetFailed;
    }

    /// Store a frame (e.g. a separate alpha plane) under `key`; the map
    /// takes its own reference. [props]
    pub fn setFrame(self: PropsRW, k: [:0]const u8, frame: *const c.AVS_VideoFrame, mode: AppendMode) SetError!void {
        if (api.fnPtr("avs_prop_set_frame")(self.env.ptr, self.map, k.ptr, frame, @backingInt(mode)) != 0) return error.PropSetFailed;
    }

    /// Returns whether the key existed.
    pub fn delete(self: PropsRW, k: [:0]const u8) bool {
        return api.fnPtr("avs_prop_delete_key")(self.env.ptr, self.map, k.ptr) != 0;
    }

    pub fn clear(self: PropsRW) void {
        api.fnPtr("avs_clear_map")(self.env.ptr, self.map);
    }
};
