//! Filter lifecycle helpers: create (apply) and get_frame contexts, checked
//! argument parsing, durable error reporting, callback thunks and plugin
//! registration.
//!
//! Error contract:
//! - Create: a failing create returns an AviSynth error value whose message
//!   is copied into environment storage (`Env.saveString`), so it outlives the
//!   call. Resources acquired before the failure must be released by the
//!   create function's own `errdefer`s.
//! - get_frame: a failing callback sets `fi.error` to a durable message and
//!   returns null; local frames must be released by `defer`/`errdefer`.
//!
//! Environment lifetime: the `Env` of a create call wraps a stack-local
//! `AVS_ScriptEnvironment` that dies when the call returns: never store it.
//! Frame callbacks use `fi.env` through `FrameCtx.env()`, per call.

const std = @import("std");
const c = @import("avisynth_c");
const api = @import("api.zig");
const Env = @import("env.zig").Env;
const Clip = @import("clip.zig").Clip;
const Frame = @import("frame.zig").Frame;
const value = @import("value.zig");
const Value = value.Value;
const Args = value.Args;

/// Fixed-size message buffer: formatting never allocates and never fails
/// (overlong messages are truncated).
pub const Diag = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    pub fn set(self: *Diag, prefix: []const u8, comptime fmt: []const u8, args: anytype) void {
        var w: std.Io.Writer = .fixed(&self.buf);
        w.print("{s}: ", .{prefix}) catch {};
        w.print(fmt, args) catch {
            @memcpy(self.buf[self.buf.len - 3 ..], "...");
            self.len = self.buf.len;
            return;
        };
        self.len = w.end;
    }

    pub fn message(self: *const Diag) ?[]const u8 {
        return if (self.len == 0) null else self.buf[0..self.len];
    }
};

/// Generic failure: the reason is in the context's `Diag`.
pub const Failed = error.Failed;

/// Context of one create (apply) call.
pub const Create = struct {
    /// Valid only during this call (see module doc).
    env: Env,
    args: Args,
    user_data: ?*anyopaque,
    name: []const u8,
    diag: Diag = .{},

    /// Record a "<name>: <message>" error and return `error.Failed`.
    pub fn fail(self: *Create, comptime fmt: []const u8, args: anytype) error{Failed} {
        self.diag.set(self.name, fmt, args);
        return error.Failed;
    }

    /// Key-based view of this call's arguments for the function's own
    /// parameter string (the one it was registered with): the getters below
    /// addressed by name instead of position, e.g.
    /// `const a = ctx.named(params); const d = try a.int(i32, "d", 1, 0, 16);`.
    /// See `NamedArgs`.
    pub fn named(self: *Create, comptime params: []const u8) NamedArgs(params) {
        return .{ .ctx = self };
    }

    pub fn arg(self: *const Create, i: usize) Value {
        return self.args.at(i);
    }

    pub fn defined(self: *const Create, i: usize) bool {
        return self.args.at(i).isDefined();
    }

    /// Required clip argument: new owned reference.
    pub fn clip(self: *Create, i: usize, comptime key: []const u8) error{Failed}!Clip {
        const v = self.args.at(i);
        if (!v.isDefined()) return self.fail(key ++ " is required.", .{});
        if (!v.isClip()) return self.fail(key ++ " must be a clip.", .{});
        return v.takeClip(self.env);
    }

    /// Optional clip argument: new owned reference, or null when absent.
    pub fn optClip(self: *Create, i: usize, comptime key: []const u8) error{Failed}!?Clip {
        const v = self.args.at(i);
        if (!v.isDefined()) return null;
        return try self.clip(i, key);
    }

    /// Integer argument converted to `T` after checking `[min, max]` on the
    /// full 64-bit value; `default` when absent (null = required).
    pub fn int(self: *Create, comptime T: type, i: usize, comptime key: []const u8, default: ?T, min: T, max: T) error{Failed}!T {
        return (try self.optInt(T, i, key, min, max)) orelse default orelse
            self.fail(key ++ " is required.", .{});
    }

    pub fn optInt(self: *Create, comptime T: type, i: usize, comptime key: []const u8, min: T, max: T) error{Failed}!?T {
        const v = self.args.at(i);
        if (!v.isDefined()) return null;
        if (!v.isInt()) return self.fail(key ++ " must be an integer.", .{});
        return try self.checkInt(T, v.asInt(), key, null, min, max);
    }

    fn checkInt(self: *Create, comptime T: type, x: i64, comptime key: []const u8, index: ?usize, min: T, max: T) error{Failed}!T {
        if (x < min or x > max) {
            if (index) |idx| return self.fail(key ++ "[{d}] value {d} is out of range [{d}, {d}].", .{ idx, x, min, max });
            return self.fail(key ++ " value {d} is out of range [{d}, {d}].", .{ x, min, max });
        }
        return @intCast(x);
    }

    /// Float argument (ints accepted, as AviSynth does). Validated as f64 for
    /// finiteness and `[min, max]` *before* narrowing to `T`: NaN passes plain
    /// range comparisons and inf overflows later conversions.
    pub fn float(self: *Create, comptime T: type, i: usize, comptime key: []const u8, default: ?T, min: T, max: T) error{Failed}!T {
        return (try self.optFloat(T, i, key, min, max)) orelse default orelse
            self.fail(key ++ " is required.", .{});
    }

    pub fn optFloat(self: *Create, comptime T: type, i: usize, comptime key: []const u8, min: T, max: T) error{Failed}!?T {
        const v = self.args.at(i);
        if (!v.isDefined()) return null;
        if (!v.isFloat()) return self.fail(key ++ " must be a number.", .{});
        return try self.checkFloat(T, v.asFloat(), key, null, min, max);
    }

    fn checkFloat(self: *Create, comptime T: type, x: f64, comptime key: []const u8, index: ?usize, min: T, max: T) error{Failed}!T {
        if (!std.math.isFinite(x)) {
            if (index) |idx| return self.fail(key ++ "[{d}] value {d} is not a finite number.", .{ idx, x });
            return self.fail(key ++ " value {d} is not a finite number.", .{x});
        }
        if (x < min or x > max) {
            if (index) |idx| return self.fail(key ++ "[{d}] value {d} is out of range [{d}, {d}].", .{ idx, x, min, max });
            return self.fail(key ++ " value {d} is out of range [{d}, {d}].", .{ x, min, max });
        }
        return @floatCast(x);
    }

    pub fn boolean(self: *Create, i: usize, comptime key: []const u8, default: bool) error{Failed}!bool {
        const v = self.args.at(i);
        if (!v.isDefined()) return default;
        if (!v.isBool()) return self.fail(key ++ " must be a bool.", .{});
        return v.asBool();
    }

    /// Optional string, borrowed from the host for the environment lifetime.
    pub fn string(self: *Create, i: usize, comptime key: []const u8) error{Failed}!?[:0]const u8 {
        const v = self.args.at(i);
        if (!v.isDefined()) return null;
        if (!v.isString()) return self.fail(key ++ " must be a string.", .{});
        return v.asString();
    }

    /// Number of elements of an array argument (a scalar counts as 1; absent
    /// is null). Array parameters are declared `[key]i*` / `[key]f*`; scripts
    /// pass `key=[1, 2]` (AviSynth+ array syntax) or a single value.
    pub fn arrayLen(self: *const Create, i: usize) ?usize {
        const v = self.args.at(i);
        if (!v.isDefined()) return null;
        return v.len();
    }

    /// Copy an int array argument into `out`; null when absent. Fails when
    /// it has more than `out.len` elements (silently ignoring extras would
    /// hide mistakes) or an element is outside `[min, max]`.
    pub fn intArray(self: *Create, comptime T: type, i: usize, comptime key: []const u8, out: []T, min: T, max: T) error{Failed}!?[]T {
        const v = self.args.at(i);
        if (!v.isDefined()) return null;
        const n = v.len();
        if (n > out.len) return self.fail(key ++ " has too many elements (got {d}, max {d}).", .{ n, out.len });
        for (0..n) |k| {
            const e = v.at(k);
            if (!e.isInt()) return self.fail(key ++ "[{d}] must be an integer.", .{k});
            out[k] = try self.checkInt(T, e.asInt(), key, k, min, max);
        }
        return out[0..n];
    }

    /// Float counterpart of `intArray` (each element checked finite first).
    pub fn floatArray(self: *Create, comptime T: type, i: usize, comptime key: []const u8, out: []T, min: T, max: T) error{Failed}!?[]T {
        const v = self.args.at(i);
        if (!v.isDefined()) return null;
        const n = v.len();
        if (n > out.len) return self.fail(key ++ " has too many elements (got {d}, max {d}).", .{ n, out.len });
        for (0..n) |k| {
            const e = v.at(k);
            if (!e.isFloat()) return self.fail(key ++ "[{d}] must be a number.", .{k});
            out[k] = try self.checkFloat(T, e.asFloat(), key, k, min, max);
        }
        return out[0..n];
    }

    /// Per-plane values from an optional array argument: absent -> `default`
    /// for every plane; otherwise up to 3 values, the last one repeating
    /// (vszip's convention for `sigma`, `thr`, ...).
    pub fn perPlaneFloat(self: *Create, comptime T: type, i: usize, comptime key: []const u8, default: T, min: T, max: T) error{Failed}![3]T {
        var buf: [3]T = undefined;
        const got = (try self.floatArray(T, i, key, &buf, min, max)) orelse {
            _ = try self.checkFloat(T, default, key, null, min, max);
            return .{ default, default, default };
        };
        if (got.len == 0) return self.fail(key ++ " must not be empty.", .{});
        var out: [3]T = undefined;
        for (0..3) |k| out[k] = got[@min(k, got.len - 1)];
        return out;
    }

    pub fn perPlaneInt(self: *Create, comptime T: type, i: usize, comptime key: []const u8, default: T, min: T, max: T) error{Failed}![3]T {
        var buf: [3]T = undefined;
        const got = (try self.intArray(T, i, key, &buf, min, max)) orelse {
            _ = try self.checkInt(T, default, key, null, min, max);
            return .{ default, default, default };
        };
        if (got.len == 0) return self.fail(key ++ " must not be empty.", .{});
        var out: [3]T = undefined;
        for (0..3) |k| out[k] = got[@min(k, got.len - 1)];
        return out;
    }

    /// `planes` selection over `num_planes` logical planes. Absent -> every
    /// plane `default_all ? true : false`. Duplicate or out-of-range indexes
    /// are errors.
    pub fn planes(self: *Create, i: usize, num_planes: u8, default_all: bool) error{Failed}![4]bool {
        var process: [4]bool = @splat(false);
        const v = self.args.at(i);
        if (!v.isDefined()) {
            for (0..num_planes) |p| process[p] = default_all;
            return process;
        }
        for (0..v.len()) |k| {
            const e = v.at(k);
            if (!e.isInt()) return self.fail("planes[{d}] must be an integer.", .{k});
            const p = e.asInt();
            if (p < 0 or p >= num_planes) return self.fail("plane index out of range", .{});
            const up: usize = @intCast(p);
            if (process[up]) return self.fail("plane specified twice.", .{});
            process[up] = true;
        }
        return process;
    }

    /// Collect this call's arguments for `Env.invoke` of another function with
    /// the same parameter string: unnamed parameters by position, named ones
    /// only when defined (AviSynth rejects void placeholders). Values and
    /// names are borrowed from this call. Returns the count used.
    pub fn forwardArgs(self: *const Create, comptime params: []const u8, values: []c.AVS_Value, names: []?[*:0]const u8) usize {
        const pn = comptime paramNames(params);
        var n: usize = 0;
        inline for (pn, 0..) |name, i| {
            const v = self.args.at(i);
            if (name == null or v.isDefined()) {
                values[n] = v.raw;
                names[n] = if (name) |s| s.ptr else null;
                n += 1;
            }
        }
        return n;
    }

    /// Return value for a successful create: transfers a reference of `cl` to
    /// the host and releases the caller's handle.
    pub fn returnClip(cl: Clip) Value {
        const v = Value.fromClip(cl);
        cl.release();
        return v;
    }

    /// Error value for a failed create (durable message).
    fn errorValue(self: *Create, err: anyerror) Value {
        var fallback: Diag = .{};
        const msg = self.diag.message() orelse blk: {
            fallback.set(self.name, "{s}", .{@errorName(err)});
            break :blk fallback.message().?;
        };
        const saved = self.env.saveString(msg) orelse return Value.fromError("avisynth: create failed (error message could not be stored)");
        return Value.fromError(saved.ptr);
    }
};

/// Make an `AVS_ApplyFunc` from a Zig create function. The create function
/// returns an owned `Value` (use `Create.returnClip`) or an error; on error the
/// message recorded with `Create.fail` (or the error name) is returned to the
/// script as an AviSynth error.
pub fn applyFn(comptime name: []const u8, comptime create: fn (*Create) anyerror!Value) c.AVS_ApplyFunc {
    return &struct {
        fn apply(env: ?*c.AVS_ScriptEnvironment, args: c.AVS_Value, user_data: ?*anyopaque) callconv(.c) c.AVS_Value {
            var ctx: Create = .{ .env = .init(env), .args = .{ .raw = args }, .user_data = user_data, .name = name };
            const v = create(&ctx) catch |e| return ctx.errorValue(e).raw;
            return v.raw;
        }
    }.apply;
}

/// MT hint returned for `AVS_CACHE_GET_MTMODE`. Choose by state ownership:
/// `.nice` only for immutable configuration plus request-local memory.
pub const MtMode = enum(c_int) {
    nice = c.AVS_MT_NICE_FILTER,
    multi_instance = c.AVS_MT_MULTI_INSTANCE,
    serialized = c.AVS_MT_SERIALIZED,
};

/// Context of one get_frame call. Do not keep it (or `fi`) past the call: on
/// newer hosts `fi` is a per-call copy.
pub const FrameCtx = struct {
    fi: *c.AVS_FilterInfo,
    name: []const u8,
    diag: Diag = .{},

    pub fn env(self: *const FrameCtx) Env {
        return .init(self.fi.env);
    }

    /// Output video info of this filter.
    pub fn vi(self: *const FrameCtx) *const c.AVS_VideoInfo {
        return &self.fi.vi;
    }

    /// The stored primary input. Borrowed: never release.
    pub fn child(self: *const FrameCtx) Clip {
        return .{ .ptr = self.fi.child.? };
    }

    pub fn fail(self: *FrameCtx, comptime fmt: []const u8, args: anytype) error{Failed} {
        self.diag.set(self.name, fmt, args);
        return error.Failed;
    }

    /// Owned frame `n` of `clip`, clamped to its frame range. On failure the
    /// upstream message is captured before any other operation can clear it.
    pub fn getFrame(self: *FrameCtx, clip: Clip, n: c_int) error{Failed}!Frame {
        const last = clip.videoInfo().num_frames - 1;
        return clip.getFrame(std.math.clamp(n, 0, @max(last, 0))) catch {
            const msg = clip.lastError() orelse "unknown upstream error";
            return self.fail("{s}", .{msg});
        };
    }

    pub fn childFrame(self: *FrameCtx, n: c_int) error{Failed}!Frame {
        return self.getFrame(self.child(), n);
    }

    /// New frame with this filter's output format, props copied from
    /// `prop_src` when given.
    pub fn newFrame(self: *FrameCtx, prop_src: ?Frame) error{Failed}!Frame {
        return self.newFrameVi(self.vi(), prop_src);
    }

    pub fn newFrameVi(self: *FrameCtx, video_info: *const c.AVS_VideoInfo, prop_src: ?Frame) error{Failed}!Frame {
        const e = self.env();
        return e.newFrame(video_info, prop_src) catch {
            const msg = e.lastError() orelse "out of memory";
            return self.fail("could not allocate a frame: {s}", .{msg});
        };
    }

    /// `frame.makeWritable` with the host's reason captured on failure (the
    /// frame stays owned by the caller either way).
    pub fn makeWritable(self: *FrameCtx, frame: *Frame) error{Failed}!void {
        const e = self.env();
        frame.makeWritable(e) catch {
            const msg = e.lastError() orelse "out of memory";
            return self.fail("could not make the frame writable: {s}", .{msg});
        };
    }

    /// `frame.makePropertyWritable` with the host's reason captured on failure.
    pub fn makePropertyWritable(self: *FrameCtx, frame: *Frame) error{Failed}!void {
        const e = self.env();
        frame.makePropertyWritable(e) catch {
            const msg = e.lastError() orelse "out of memory";
            return self.fail("could not make the frame properties writable: {s}", .{msg});
        };
    }

    fn setError(self: *FrameCtx, err: anyerror) void {
        var fallback: Diag = .{};
        const msg = self.diag.message() orelse blk: {
            fallback.set(self.name, "{s}", .{@errorName(err)});
            break :blk fallback.message().?;
        };
        const saved = self.env().saveString(msg);
        self.fi.@"error" = if (saved) |s| s.ptr else "avisynth: frame request failed (error message could not be stored)";
    }
};

/// Raw callback type stored in `AVS_FilterInfo.get_frame`.
pub const RawGetFrame = @FieldType(c.AVS_FilterInfo, "get_frame");

/// Filter instance helpers for state type `Data`. The filter owns one heap
/// copy of `Data`; `Data.deinit(*Data)` (when declared) runs in `free_filter`
/// and must release everything `Data` owns (secondary clips, tables, pools).
pub fn Filter(comptime Data: type, comptime name: []const u8) type {
    return struct {
        pub const GetFrameFn = fn (*Data, *FrameCtx, c_int) anyerror!Frame;
        const allocator = std.heap.c_allocator;

        /// A `RawGetFrame` calling `f` with `n` clamped to the output range.
        /// Instantiate per comptime specialization and pick one at create time.
        pub fn getFrame(comptime f: GetFrameFn) RawGetFrame {
            return @ptrCast(&struct {
                fn thunk(fi: *c.AVS_FilterInfo, n: c_int) callconv(.c) ?*c.AVS_VideoFrame {
                    const d: *Data = @ptrCast(@alignCast(fi.user_data.?));
                    var ctx: FrameCtx = .{ .fi = fi, .name = name };
                    const nn = std.math.clamp(n, 0, @max(fi.vi.num_frames - 1, 0));
                    const out = f(d, &ctx, nn) catch |e| {
                        ctx.setError(e);
                        return null;
                    };
                    return out.ptr;
                }
            }.thunk);
        }

        pub const Options = struct {
            /// Output video info; default: the child's.
            vi: ?c.AVS_VideoInfo = null,
            mt_mode: MtMode,
            /// Optional get_parity override (fields/bob filters).
            get_parity: @FieldType(c.AVS_FilterInfo, "get_parity") = null,
        };

        /// Create the filter clip. `child` (borrowed; the filter takes its own
        /// reference) becomes `fi.child`; null makes a source filter, which
        /// then needs `opts.vi`. On success the filter owns the copy of `data`;
        /// on error nothing was taken and the caller still owns `data`'s
        /// resources. Returns an owned clip (see `Create.returnClip`).
        pub fn create(env: Env, child: ?Clip, data: Data, get_frame: RawGetFrame, opts: Options) error{OutOfMemory}!Clip {
            std.debug.assert(child != null or opts.vi != null);
            const d = try allocator.create(Data);
            d.* = data;

            // Nothing below can fail, so ownership of `data` moves atomically.
            const child_v: Value = if (child) |cl| Value.fromClip(cl) else Value.void_value;
            defer if (child != null) child_v.release();

            var fi: [*c]c.AVS_FilterInfo = undefined;
            const clip_ptr = api.fnPtr("avs_new_c_filter")(env.ptr, &fi, child_v.raw, @intFromBool(child != null)).?;
            if (opts.vi) |v| fi.*.vi = v;
            fi.*.user_data = d;
            fi.*.get_frame = get_frame;
            fi.*.get_parity = opts.get_parity;
            if (child == null) {
                // Without a stored child the host's default parity/audio
                // forwarding would dereference a null child: a source filter
                // must define every callback.
                if (fi.*.get_parity == null) fi.*.get_parity = @ptrCast(&sourceParity);
                fi.*.get_audio = @ptrCast(&sourceAudio);
            }
            fi.*.set_cache_hints = switch (opts.mt_mode) {
                inline else => |m| @ptrCast(&MtHint(m).hint),
            };
            fi.*.free_filter = @ptrCast(&free);
            return .{ .ptr = clip_ptr };
        }

        fn free(fi: *c.AVS_FilterInfo) callconv(.c) void {
            const d: *Data = @ptrCast(@alignCast(fi.user_data orelse return));
            if (@hasDecl(Data, "deinit")) d.deinit();
            allocator.destroy(d);
            fi.user_data = null;
        }
    };
}

fn sourceParity(_: *c.AVS_FilterInfo, _: c_int) callconv(.c) c_int {
    return 0;
}

/// Source filters declare no audio; a request still gets silence, not a crash.
fn sourceAudio(fi: *c.AVS_FilterInfo, buf: ?*anyopaque, _: i64, count: i64) callconv(.c) c_int {
    const bytes = c.avs_bytes_from_audio_samples(&fi.vi, count);
    if (buf) |b| {
        if (bytes > 0) @memset(@as([*]u8, @ptrCast(b))[0..@intCast(bytes)], 0);
    }
    return 0;
}

fn MtHint(comptime mode: MtMode) type {
    return struct {
        fn hint(_: *c.AVS_FilterInfo, cachehints: c_int, _: c_int) callconv(.c) c_int {
            return if (cachehints == c.AVS_CACHE_GET_MTMODE) @backingInt(mode) else 0;
        }
    };
}

/// One script function for `register`.
pub const Function = struct {
    name: [:0]const u8,
    /// AviSynth parameter string, validated at comptime by `register`.
    params: [:0]const u8,
    apply: c.AVS_ApplyFunc,
    user_data: ?*anyopaque = null,
};

/// Compile error unless `params` is a well-formed AviSynth parameter string:
/// a sequence of `[name]`-optional types from "bifscna." each optionally
/// followed by '*' or '+', with unique names.
pub fn checkParams(comptime params: []const u8) void {
    comptime {
        @setEvalBranchQuota(100_000);
        var names: []const []const u8 = &.{};
        var i: usize = 0;
        while (i < params.len) {
            if (params[i] == '[') {
                const end = std.mem.indexOfScalarPos(u8, params, i, ']') orelse
                    @compileError("unterminated parameter name in \"" ++ params ++ "\"");
                const n = params[i + 1 .. end];
                if (n.len == 0) @compileError("empty parameter name in \"" ++ params ++ "\"");
                for (names) |prev| if (std.ascii.eqlIgnoreCase(prev, n))
                    @compileError("duplicate parameter name '" ++ n ++ "' in \"" ++ params ++ "\"");
                names = names ++ .{n};
                i = end + 1;
                if (i >= params.len) @compileError("parameter '" ++ n ++ "' has no type in \"" ++ params ++ "\"");
            }
            if (std.mem.indexOfScalar(u8, "bifscna.", params[i]) == null)
                @compileError("invalid type '" ++ params[i .. i + 1] ++ "' in \"" ++ params ++ "\"");
            i += 1;
            if (i < params.len and (params[i] == '*' or params[i] == '+')) i += 1;
        }
    }
}

/// Failure message shown by `registerFailureStubs` stubs (static storage:
/// stub results must outlive every script environment of the process).
var failure_message: [512:0]u8 = @splat(0);

fn failureStub(_: ?*c.AVS_ScriptEnvironment, _: c.AVS_Value, _: ?*anyopaque) callconv(.c) c.AVS_Value {
    return c.avs_new_value_error(&failure_message);
}

/// Plugin-init failure reporting. A failed `load` leaves the plugin without
/// an API table, so its functions are not registered and scripts would only
/// see "there is no function named X" (LoadPlugin itself returns true; the
/// init return string is not visible to scripts). This best-effort fallback
/// resolves `avs_add_function` straight from the already-loaded host library
/// and registers each name as a stub that raises
/// "<plugin>: cannot run: <reason>". Returns false when even that fails.
pub fn registerFailureStubs(env: *c.AVS_ScriptEnvironment, comptime plugin: []const u8, comptime names: []const [:0]const u8, reason: []const u8) bool {
    comptime if (names.len > 255) @compileError("registerFailureStubs: at most 255 names");
    var w: std.Io.Writer = .fixed(failure_message[0 .. failure_message.len - 1]);
    w.print(plugin ++ ": cannot run: {s}", .{reason}) catch {};
    failure_message[w.end] = 0;

    const add = hostAddFunction() orelse return false;
    inline for (names, 0..) |name, i| {
        // Same SaveString-aliasing workaround as `register`.
        _ = add(env, name.ptr, ".*", &failureStub, @ptrCast(&registration_tags.bytes[i + 1]));
    }
    return true;
}

const AddFunctionFn = @typeInfo(c.avs_add_function_func).optional.child;

/// `avs_add_function` of the host library already loaded in this process.
fn hostAddFunction() ?AddFunctionFn {
    if (@import("builtin").os.tag == .windows) {
        const win = struct {
            extern "kernel32" fn GetModuleHandleW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
            extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
        };
        // The plugin is being loaded by avisynth.dll, so it is resident: no
        // reference is taken (nothing to release).
        const module = win.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("avisynth.dll")) orelse return null;
        const p = win.GetProcAddress(module, "avs_add_function") orelse return null;
        return @ptrCast(@alignCast(p));
    }
    const lib_name = if (@import("builtin").os.tag == .macos) "libavisynth.dylib" else "libavisynth.so";
    // dlopen of the resident library; not closed, it outlives the plugin.
    var lib = std.DynLib.open(lib_name) catch return null;
    return lib.lookup(AddFunctionFn, "avs_add_function");
}

/// One parameter of a parameter string.
pub const Param = struct {
    /// null for an unnamed (positional) parameter
    name: ?[:0]const u8,
    /// AviSynth type character: one of "bifscna."
    type: u8,
    /// declared with '*' or '+'
    array: bool,
};

/// The parameters of a parameter string, in argument order. Comptime.
pub fn paramList(comptime params: []const u8) []const Param {
    comptime {
        @setEvalBranchQuota(100_000);
        checkParams(params);
        var out: []const Param = &.{};
        var i: usize = 0;
        while (i < params.len) {
            var name: ?[:0]const u8 = null;
            if (params[i] == '[') {
                const end = std.mem.indexOfScalarPos(u8, params, i, ']').?;
                name = params[i + 1 .. end] ++ "";
                i = end + 1;
            }
            const t = params[i];
            i += 1;
            const array = i < params.len and (params[i] == '*' or params[i] == '+');
            if (array) i += 1;
            out = out ++ .{Param{ .name = name, .type = t, .array = array }};
        }
        return out;
    }
}

/// Per-argument names of a parameter string (null for unnamed parameters),
/// in argument order. Comptime.
pub fn paramNames(comptime params: []const u8) []const ?[:0]const u8 {
    comptime {
        var out: []const ?[:0]const u8 = &.{};
        for (paramList(params)) |p| out = out ++ .{p.name};
        return out;
    }
}

/// `Create`'s argument getters addressed by parameter name (from
/// `Create.named`). The name is resolved to its position at compile time, and
/// is also the name in error messages.
///
/// Compile errors instead of silent misreads:
/// - a name that `params` does not declare (names are matched exactly);
/// - a getter that does not fit the declared type: `int`/`optInt` need `i`,
///   `float`/`optFloat` need `f`, `boolean` needs `b`, `string` needs `s`,
///   `clip`/`optClip` need `c`, all of them scalar; `intArray`/`perPlaneInt`/
///   `planes` need `i*` (or `i+`), `floatArray`/`perPlaneFloat` need `f*`.
///   `defined`, `arrayLen`, `arg` and `index` take any parameter.
///
/// Unnamed parameters (typically the leading clip, `c`) have no name: read
/// them with the positional getters (`ctx.clip(0, "clip")`).
pub fn NamedArgs(comptime params: []const u8) type {
    const list = comptime paramList(params);
    return struct {
        ctx: *Create,

        const Self = @This();

        /// Argument position of `key`.
        pub fn index(comptime key: []const u8) usize {
            comptime {
                for (list, 0..) |p, i| {
                    if (p.name) |n| if (std.mem.eql(u8, n, key)) return i;
                }
                @compileError("parameter '" ++ key ++ "' is not declared in \"" ++ params ++ "\"");
            }
        }

        /// `index(key)`, checked against the getter's expected type.
        fn typed(comptime key: []const u8, comptime types: []const u8, comptime array: bool, comptime getter: []const u8) usize {
            comptime {
                const i = index(key);
                const p = list[i];
                if (std.mem.indexOfScalar(u8, types, p.type) == null or p.array != array) {
                    const declared = [_]u8{p.type} ++ (if (p.array) "*" else "");
                    const wanted = types ++ (if (array) "*" else "");
                    @compileError(getter ++ "(\"" ++ key ++ "\"): parameter is declared '" ++ declared ++
                        "' in \"" ++ params ++ "\"; " ++ getter ++ " reads '" ++ wanted ++ "'");
                }
                return i;
            }
        }

        pub fn arg(self: Self, comptime key: []const u8) Value {
            return self.ctx.arg(comptime index(key));
        }

        pub fn defined(self: Self, comptime key: []const u8) bool {
            return self.ctx.defined(comptime index(key));
        }

        pub fn arrayLen(self: Self, comptime key: []const u8) ?usize {
            return self.ctx.arrayLen(comptime index(key));
        }

        pub fn clip(self: Self, comptime key: []const u8) error{Failed}!Clip {
            return self.ctx.clip(comptime typed(key, "c", false, "clip"), key);
        }

        pub fn optClip(self: Self, comptime key: []const u8) error{Failed}!?Clip {
            return self.ctx.optClip(comptime typed(key, "c", false, "optClip"), key);
        }

        pub fn int(self: Self, comptime T: type, comptime key: []const u8, default: ?T, min: T, max: T) error{Failed}!T {
            return self.ctx.int(T, comptime typed(key, "i", false, "int"), key, default, min, max);
        }

        pub fn optInt(self: Self, comptime T: type, comptime key: []const u8, min: T, max: T) error{Failed}!?T {
            return self.ctx.optInt(T, comptime typed(key, "i", false, "optInt"), key, min, max);
        }

        pub fn float(self: Self, comptime T: type, comptime key: []const u8, default: ?T, min: T, max: T) error{Failed}!T {
            return self.ctx.float(T, comptime typed(key, "f", false, "float"), key, default, min, max);
        }

        pub fn optFloat(self: Self, comptime T: type, comptime key: []const u8, min: T, max: T) error{Failed}!?T {
            return self.ctx.optFloat(T, comptime typed(key, "f", false, "optFloat"), key, min, max);
        }

        pub fn boolean(self: Self, comptime key: []const u8, default: bool) error{Failed}!bool {
            return self.ctx.boolean(comptime typed(key, "b", false, "boolean"), key, default);
        }

        pub fn string(self: Self, comptime key: []const u8) error{Failed}!?[:0]const u8 {
            return self.ctx.string(comptime typed(key, "s", false, "string"), key);
        }

        pub fn intArray(self: Self, comptime T: type, comptime key: []const u8, out: []T, min: T, max: T) error{Failed}!?[]T {
            return self.ctx.intArray(T, comptime typed(key, "i", true, "intArray"), key, out, min, max);
        }

        pub fn floatArray(self: Self, comptime T: type, comptime key: []const u8, out: []T, min: T, max: T) error{Failed}!?[]T {
            return self.ctx.floatArray(T, comptime typed(key, "f", true, "floatArray"), key, out, min, max);
        }

        pub fn perPlaneInt(self: Self, comptime T: type, comptime key: []const u8, default: T, min: T, max: T) error{Failed}![3]T {
            return self.ctx.perPlaneInt(T, comptime typed(key, "i", true, "perPlaneInt"), key, default, min, max);
        }

        pub fn perPlaneFloat(self: Self, comptime T: type, comptime key: []const u8, default: T, min: T, max: T) error{Failed}![3]T {
            return self.ctx.perPlaneFloat(T, comptime typed(key, "f", true, "perPlaneFloat"), key, default, min, max);
        }

        pub fn planes(self: Self, comptime key: []const u8, num_planes: u8, default_all: bool) error{Failed}![4]bool {
            return self.ctx.planes(comptime typed(key, "i", true, "planes"), num_planes, default_all);
        }
    };
}

/// Distinct non-null `user_data` tags for `register` (see there).
const registration_tags = struct {
    var bytes: [256]u8 align(256) = @splat(0);
};

/// Register every function, stopping at the first failure. Returns null on
/// success, else a durable "<name>: <reason>" message for the plugin-init
/// return value. Functions registered before a failure stay registered.
///
/// Host bug workaround (AviSynth+ 3.7.5 and current master): avs_add_function
/// stores its binary {user_data, func, func_r} record with SaveString, whose
/// de-duplicating cache compares keys with strncmp. With user_data == NULL the
/// record starts with a NUL byte, so two records whose hashes share a bucket
/// compare equal and one function silently gets another's callback. Each
/// function without its own user_data therefore gets a unique tag pointer
/// whose lowest address byte (the record's first byte) is distinct and
/// non-zero. A caller-supplied user_data must likewise not start with 0x00.
pub fn register(env: Env, comptime functions: []const Function) ?[*:0]const u8 {
    comptime {
        @setEvalBranchQuota(1_000_000);
        if (functions.len > 255) @compileError("register: at most 255 functions per call");
        for (functions) |f| checkParams(f.params);
    }
    inline for (functions, 0..) |f, i| {
        const ud: *anyopaque = f.user_data orelse @ptrCast(&registration_tags.bytes[i + 1]);
        env.addFunction(f.name, f.params, f.apply, ud) catch {
            const reason = env.lastError() orelse "unknown error";
            const saved = env.saveFmt("could not register {s}: {s}", .{ f.name, reason });
            return if (saved) |s| s.ptr else "avisynth: function registration failed";
        };
    }
    return null;
}

test "Diag formats and truncates" {
    var d: Diag = .{};
    try std.testing.expect(d.message() == null);
    d.set("F", "x={d}", .{3});
    try std.testing.expectEqualStrings("F: x=3", d.message().?);
    const long: [600]u8 = @splat('a');
    d.set("F", "{s}", .{&long});
    try std.testing.expectEqual(@as(usize, 512), d.message().?.len);
    try std.testing.expect(std.mem.endsWith(u8, d.message().?, "..."));
}

test "paramNames" {
    const n = comptime paramNames("cc[frames]i*[mismatch]b");
    try std.testing.expectEqual(@as(usize, 4), n.len);
    try std.testing.expect(n[0] == null and n[1] == null);
    try std.testing.expectEqualStrings("frames", n[2].?);
    try std.testing.expectEqualStrings("mismatch", n[3].?);
}

test "paramList" {
    const p = comptime paramList("c[thr]f*[n]i[on]b[s]s.+");
    try std.testing.expectEqual(@as(usize, 6), p.len);
    try std.testing.expect(p[0].name == null and p[0].type == 'c' and !p[0].array);
    try std.testing.expect(std.mem.eql(u8, p[1].name.?, "thr") and p[1].type == 'f' and p[1].array);
    try std.testing.expect(p[2].type == 'i' and !p[2].array);
    try std.testing.expect(p[3].type == 'b' and p[4].type == 's');
    try std.testing.expect(p[5].name == null and p[5].type == '.' and p[5].array);
}

test "NamedArgs.index resolves at compile time" {
    const A = NamedArgs("c[d]i[a]i[h]f[channels]s[rclip]c");
    comptime {
        std.debug.assert(A.index("d") == 1);
        std.debug.assert(A.index("h") == 3);
        std.debug.assert(A.index("rclip") == 5);
    }
}

test "checkParams accepts real signatures" {
    checkParams("c[enabled]b");
    checkParams("c[min]f*[max]f*[tv_range]b[mask]b[planes]i*");
    checkParams("cc+");
    checkParams(".*");
    checkParams("");
}
