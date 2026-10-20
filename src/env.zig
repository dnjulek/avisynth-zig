//! `Env`: a borrowed `AVS_ScriptEnvironment*` for the current operation.
//!
//! Inside callbacks build it from `fi.env` for each call; never cache the
//! plugin-init environment or an `AVS_FilterInfo*` for later frame requests.

const std = @import("std");
const c = @import("avisynth_c");
const api = @import("api.zig");
const Frame = @import("frame.zig").Frame;
const Value = @import("value.zig").Value;

pub const Env = struct {
    ptr: *c.AVS_ScriptEnvironment,

    pub fn init(ptr: ?*c.AVS_ScriptEnvironment) Env {
        return .{ .ptr = ptr.? };
    }

    /// Last environment error (e.g. after a failed allocation or registration),
    /// or null. The string is host-owned; copy it if you need it later. [core]
    pub fn lastError(self: Env) ?[:0]const u8 {
        const e = api.fnPtr("avs_get_error")(self.ptr) orelse return null;
        return std.mem.span(e);
    }

    /// Copy `s` into environment-owned storage that lives until the script
    /// environment is destroyed (durable error messages, strings handed back to
    /// the script). Null if the host could not store it. [core]
    pub fn saveString(self: Env, s: []const u8) ?[:0]const u8 {
        const len = std.math.cast(c_int, s.len) orelse return null;
        const p = api.fnPtr("avs_save_string")(self.ptr, s.ptr, len) orelse return null;
        return p[0..s.len :0];
    }

    /// Format into a stack buffer, then `saveString`. Messages longer than the
    /// buffer are truncated with "...".
    pub fn saveFmt(self: Env, comptime fmt: []const u8, args: anytype) ?[:0]const u8 {
        var buf: [1024]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
            @memcpy(buf[buf.len - 3 ..], "...");
            break :blk buf[0..];
        };
        return self.saveString(s);
    }

    pub const RegisterError = error{RegistrationFailed};

    /// Register a script function. AviSynth returns -1 on failure and stores
    /// the reason in the environment error (`lastError`). [core]
    pub fn addFunction(self: Env, name: [:0]const u8, params: [:0]const u8, apply: c.AVS_ApplyFunc, user_data: ?*anyopaque) RegisterError!void {
        if (api.fnPtr("avs_add_function")(self.ptr, name.ptr, params.ptr, apply, user_data) != 0)
            return error.RegistrationFailed;
    }

    /// True when a script function with this name is registered. [core]
    pub fn functionExists(self: Env, name: [:0]const u8) bool {
        return api.fnPtr("avs_function_exists")(self.ptr, name.ptr) != 0;
    }

    pub const FrameError = error{FrameAllocationFailed};

    /// New writable frame for `vi`, copying frame properties from `prop_src`
    /// when given. Caller owns the result. [planar]
    pub fn newFrame(self: Env, vi: *const c.AVS_VideoInfo, prop_src: ?Frame) FrameError!Frame {
        const p = if (prop_src) |src|
            api.fnPtr("avs_new_video_frame_p_a")(self.ptr, vi, src.ptr, c.AVS_FRAME_ALIGN)
        else
            // Never pass a null prop_src to avs_new_video_frame_p_a: the C
            // wrapper forwards `&prop_src`, and the core dereferences it
            // whenever that address is non-null (crash on AviSynth+ <= 3.7.5).
            api.fnPtr("avs_new_video_frame_a")(self.ptr, vi, c.AVS_FRAME_ALIGN);
        return .{ .ptr = p orelse return error.FrameAllocationFailed };
    }

    /// Row copy with independent pitches (`avs_bit_blt`). [planar]
    pub fn bitBlt(self: Env, dst: [*]u8, dst_pitch: usize, src: [*]const u8, src_pitch: usize, row_size: usize, height: usize) void {
        api.fnPtr("avs_bit_blt")(self.ptr, dst, @intCast(dst_pitch), src, @intCast(src_pitch), @intCast(row_size), @intCast(height));
    }

    /// Call a script function/filter. The returned value is owned (release it);
    /// an error value is converted into `error.InvokeFailed` with its message
    /// available through `invoke_error`. [invoke]
    pub fn invoke(self: Env, name: [:0]const u8, args: Value, arg_names: ?[]const ?[*:0]const u8, err_msg: ?*?[:0]const u8) error{InvokeFailed}!Value {
        const names: [*c][*c]const u8 = if (arg_names) |n| @ptrCast(@constCast(n.ptr)) else null;
        const v: Value = .{ .raw = api.fnPtr("avs_invoke")(self.ptr, name.ptr, args.raw, names) };
        if (v.isError()) {
            if (err_msg) |m| m.* = v.errorMessage();
            v.release();
            return error.InvokeFailed;
        }
        return v;
    }

    /// `avs_get_env_property` (`AVS_AEP_*`). [host]
    pub fn property(self: Env, prop: c_int) i64 {
        return api.fnPtr("avs_get_env_property")(self.ptr, prop);
    }

    /// Host interface version (major, bugfix). [host]
    pub fn interfaceVersion(self: Env) struct { c_int, c_int } {
        return .{
            @intCast(self.property(c.AVS_AEP_INTERFACE_VERSION)),
            @intCast(self.property(c.AVS_AEP_INTERFACE_BUGFIX)),
        };
    }

    /// `AVS_CPUF_*` flags. [host]
    pub fn cpuFlags(self: Env) c_int {
        return api.fnPtr("avs_get_cpu_flags")(self.ptr);
    }
};
