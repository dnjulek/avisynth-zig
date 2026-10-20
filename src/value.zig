//! `Value`: an `AVS_Value` with explicit borrowed/owned contracts.
//!
//! Values handed to an apply (create) callback and elements of an array are
//! **borrowed**: never release them. Values produced by `fromClip`, `invoke`
//! or `copy` are **owned**: release exactly once (`release`) or transfer them
//! to the host by returning them.
//!
//! Type tests read the stable `type` tag directly; payload accessors use the
//! V11 `avs_get_as_*` functions, which understand 64-bit 'l'ong / 'd'ouble
//! storage on every target. [values]

const std = @import("std");
const c = @import("avisynth_c");
const api = @import("api.zig");
const Clip = @import("clip.zig").Clip;
const Env = @import("env.zig").Env;

pub const Value = struct {
    raw: c.AVS_Value,

    pub const void_value: Value = .{ .raw = c.avs_void };

    pub fn tag(self: Value) u8 {
        return @intCast(self.raw.type);
    }

    pub fn isDefined(self: Value) bool {
        return self.tag() != 'v';
    }
    pub fn isClip(self: Value) bool {
        return self.tag() == 'c';
    }
    pub fn isBool(self: Value) bool {
        return self.tag() == 'b';
    }
    /// 32-bit int or 64-bit long.
    pub fn isInt(self: Value) bool {
        return self.tag() == 'i' or self.tag() == 'l';
    }
    /// Any number: float/double or int/long (AviSynth promotes ints to float).
    pub fn isFloat(self: Value) bool {
        return switch (self.tag()) {
            'f', 'd', 'i', 'l' => true,
            else => false,
        };
    }
    pub fn isString(self: Value) bool {
        return self.tag() == 's';
    }
    pub fn isArray(self: Value) bool {
        return self.tag() == 'a';
    }
    pub fn isError(self: Value) bool {
        return self.tag() == 'e';
    }

    pub fn asBool(self: Value) bool {
        std.debug.assert(self.isBool());
        return api.fnPtr("avs_get_as_bool")(self.raw) != 0;
    }
    pub fn asInt(self: Value) i64 {
        std.debug.assert(self.isInt());
        return api.fnPtr("avs_get_as_long")(self.raw);
    }
    pub fn asFloat(self: Value) f64 {
        std.debug.assert(self.isFloat());
        return api.fnPtr("avs_get_as_float")(self.raw);
    }
    /// Borrowed host string (valid while the value is alive; argument strings
    /// live for the whole script environment).
    pub fn asString(self: Value) [:0]const u8 {
        std.debug.assert(self.isString());
        return std.mem.span(api.fnPtr("avs_get_as_string")(self.raw));
    }
    pub fn errorMessage(self: Value) ?[:0]const u8 {
        const p = api.fnPtr("avs_get_as_error")(self.raw) orelse return null;
        return std.mem.span(p);
    }

    /// Element count of an array value; 1 for a defined scalar, 0 for void.
    pub fn len(self: Value) usize {
        if (!self.isDefined()) return 0;
        if (!self.isArray()) return 1;
        return @intCast(api.fnPtr("avs_get_array_size")(self.raw));
    }
    /// Borrowed element `i` of an array (the value itself for a scalar).
    pub fn at(self: Value, i: usize) Value {
        std.debug.assert(i < self.len());
        if (!self.isArray()) return self;
        return .{ .raw = api.fnPtr("avs_get_array_elt")(self.raw, @intCast(i)) };
    }

    /// New owned reference to the clip in this value. [core]
    pub fn takeClip(self: Value, env: Env) Clip {
        std.debug.assert(self.isClip());
        return .{ .ptr = api.fnPtr("avs_take_clip")(self.raw, env.ptr).? };
    }

    /// Owned value holding a new reference to `clip` (the clip handle stays
    /// owned by the caller). [core]
    pub fn fromClip(clip: Clip) Value {
        var v: c.AVS_Value = c.avs_void;
        api.fnPtr("avs_set_to_clip")(&v, clip.ptr);
        return .{ .raw = v };
    }

    /// Error value for an apply callback. `durable_msg` must outlive the call:
    /// use `Env.saveString` (or a string literal).
    pub fn fromError(durable_msg: [*:0]const u8) Value {
        return .{ .raw = c.avs_new_value_error(durable_msg) };
    }

    pub fn fromInt(v: c_int) Value {
        return .{ .raw = c.avs_new_value_int(v) };
    }
    pub fn fromBool(v: bool) Value {
        return .{ .raw = c.avs_new_value_bool(@intFromBool(v)) };
    }
    /// `durable` must outlive the value (literal or `Env.saveString`).
    pub fn fromString(durable: [*:0]const u8) Value {
        return .{ .raw = c.avs_new_value_string(durable) };
    }
    /// Borrowing array view over `items` (no copy: `items` must outlive every
    /// use, e.g. a stack array passed to `Env.invoke`). Never release it.
    pub fn arrayView(items: []const c.AVS_Value) Value {
        return .{ .raw = c.avs_new_value_array(@constCast(items.ptr), @intCast(items.len)) };
    }

    /// Deep copy (refcount++ / array copy). Release the result. [core]
    pub fn copy(self: Value) Value {
        var v: c.AVS_Value = c.avs_void;
        api.fnPtr("avs_copy_value")(&v, self.raw);
        return .{ .raw = v };
    }

    /// Release an owned value. Never call on a borrowed value. [core]
    pub fn release(self: Value) void {
        api.fnPtr("avs_release_value")(self.raw);
    }
};

/// Borrowed view of the argument array passed to an apply callback. Indexes
/// are positions in the registered parameter string.
pub const Args = struct {
    raw: c.AVS_Value,

    pub fn len(self: Args) usize {
        return @intCast(self.raw.array_size);
    }

    /// Borrowed argument `i` (void when absent or past the end).
    pub fn at(self: Args, i: usize) Value {
        if (i >= self.len()) return Value.void_value;
        return .{ .raw = c.avs_array_elt(self.raw, @intCast(i)) };
    }
};
