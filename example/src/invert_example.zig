//! AviSynth+ port of the VapourSynth invert example:
//! https://github.com/vapoursynth/vapoursynth/blob/master/sdk/invert_example.c
//!
//! Registers `ZInvert(clip, bool "enabled")` — inverts all planes of planar
//! 8..16-bit integer and 32-bit float formats — and `ZPlaneMax(clip)`, a
//! property-only analysis filter that stores each plane's maximum as the frame
//! property `ZPlaneMax` (an int/float array) without copying any pixels.
//!
//! Uses the module's convenience layer (`avs.Filter`, `avs.Create` and its
//! named-argument view, `avs.FrameCtx`, `avs.Format`); the raw table stays
//! reachable through `avs.table()` / `avs.c` for anything the wrappers do not
//! cover.

const std = @import("std");
const avs = @import("avisynth");
const c = avs.c;

// ---------------------------------------------------------------------------
// ZInvert: a pixel filter producing a new frame
// ---------------------------------------------------------------------------

const InvertData = struct {
    format: avs.Format,
};

const Invert = avs.Filter(InvertData, "ZInvert");

/// Registered with the function (`avs.register` below) and read back by name
/// in the create function (`ctx.named`): one definition for both.
const invert_params = "c[enabled]b";

fn invertPlane(
    comptime T: type,
    dst: avs.PlaneMut(T),
    src: avs.Plane(T),
    // Result is `minuend - s`, clamped to [0, peak] for integer types.
    // Full-range planes pass minuend == peak; integer chroma passes
    // minuend == peak + 1 (pivot around the midpoint, so neutral stays
    // neutral — same convention as AviSynth+ 3.7.6 Invert() and the
    // zero-centered float chroma negation).
    minuend: if (@typeInfo(T) == .float) T else u32,
    peak: u32,
) void {
    // Source and destination pitches are independent (a cropped source keeps
    // its parent's pitch), so walk rows rather than one shared stride.
    for (0..src.height) |y| {
        for (dst.row(y), src.row(y)) |*d, s| {
            // Saturating sub so out-of-range integer input can't underflow.
            d.* = if (@typeInfo(T) == .float) minuend - s else @intCast(@min(minuend -| s, peak));
        }
    }
}

fn invertGetFrame(comptime T: type) Invert.GetFrameFn {
    return struct {
        fn getFrame(d: *InvertData, ctx: *avs.FrameCtx, n: c_int) !avs.Frame {
            const src = try ctx.childFrame(n);
            defer src.release();
            // prop_src=src carries the frame properties over to the new frame.
            const dst = try ctx.newFrame(src);

            const peak: u32 = if (@typeInfo(T) == .float) 0 else @intFromFloat(d.format.peak());
            for (0..d.format.numPlanes()) |p| {
                const id = d.format.planeId(p);
                const chroma = d.format.isChroma(p);
                const minuend = if (@typeInfo(T) == .float)
                    // Float chroma is centered on 0.0, so inverting is negation.
                    @as(f32, if (chroma) 0.0 else 1.0)
                else if (chroma) peak + 1 else peak;
                invertPlane(T, dst.planeMut(T, id), src.plane(T, id), minuend, peak);
            }
            return dst;
        }
    }.getFrame;
}

fn invertCreate(ctx: *avs.Create) !avs.Value {
    // The leading clip is unnamed, so it is read by position; named
    // parameters are read by name. A key `invert_params` doesn't declare, or a
    // getter that doesn't fit its type (`arg.int("enabled", ...)`), is a
    // compile error.
    const arg = ctx.named(invert_params);
    const clip = try ctx.clip(0, "clip");
    defer clip.release();
    const enabled = try arg.boolean("enabled", true);

    const format = avs.Format.fromVideoInfo(clip.videoInfo()) catch
        return ctx.fail("only planar formats are supported.", .{});

    // Pass the source through untouched (no filter instance at all).
    if (!enabled) return avs.Create.returnClip(clip.retain());

    const get_frame = switch (format.sample) {
        inline else => |s| Invert.getFrame(invertGetFrame(s.Type())),
    };
    // Stateless per-frame work on immutable config: safe under MT_NICE_FILTER.
    const out = try Invert.create(ctx.env, clip, .{ .format = format }, get_frame, .{ .mt_mode = .nice });
    return avs.Create.returnClip(out);
}

// ---------------------------------------------------------------------------
// ZPlaneMax: a property-only filter (copy-on-write of the property map)
// ---------------------------------------------------------------------------

const MaxData = struct {
    format: avs.Format,
};

const PlaneMax = avs.Filter(MaxData, "ZPlaneMax");

const plane_max_params = "c";

fn planeMaxGetFrame(comptime T: type) PlaneMax.GetFrameFn {
    return struct {
        fn getFrame(d: *MaxData, ctx: *avs.FrameCtx, n: c_int) !avs.Frame {
            var frame = try ctx.childFrame(n);
            errdefer frame.release();
            const env = ctx.env();
            // Pixels stay shared with the source; only the props get a private
            // copy. `frame.ptr` may change, so take views only after this.
            try frame.makePropertyWritable(env);

            var maxima: [4]f64 = undefined;
            for (0..d.format.numPlanes()) |p| {
                const plane = frame.plane(T, d.format.planeId(p));
                var m: T = if (@typeInfo(T) == .float) -std.math.inf(T) else 0;
                for (0..plane.height) |y| {
                    for (plane.row(y)) |s| m = @max(m, s);
                }
                maxima[p] = if (@typeInfo(T) == .float) m else @floatFromInt(m);
            }

            const props = frame.propsRW(env);
            const np = d.format.numPlanes();
            props.setFloatArray("ZPlaneMax", maxima[0..np]) catch return ctx.fail("could not set ZPlaneMax.", .{});
            return frame;
        }
    }.getFrame;
}

fn planeMaxCreate(ctx: *avs.Create) !avs.Value {
    const clip = try ctx.clip(0, "clip");
    defer clip.release();
    const format = avs.Format.fromVideoInfo(clip.videoInfo()) catch
        return ctx.fail("only planar formats are supported.", .{});
    const get_frame = switch (format.sample) {
        inline else => |s| PlaneMax.getFrame(planeMaxGetFrame(s.Type())),
    };
    const out = try PlaneMax.create(ctx.env, clip, .{ .format = format }, get_frame, .{ .mt_mode = .nice });
    return avs.Create.returnClip(out);
}

// ---------------------------------------------------------------------------
// Plugin entry point
// ---------------------------------------------------------------------------

/// Interface 11 floor: the convenience layer's `values` group (64-bit aware
/// argument accessors) is V11, and V11 hosts call `avisynth_c_plugin_init2`.
const load_options: avs.LoadOptions = .{ .interface = 11 };

/// `avisynth_c_plugin_init2` opts into V11 value handling (64-bit long/double
/// arguments are passed through instead of being narrowed). Hosts older than
/// V11 only look for `avisynth_c_plugin_init`, which this plugin deliberately
/// does not export, so it simply does not load there.
export fn avisynth_c_plugin_init2(env: ?*c.AVS_ScriptEnvironment) callconv(.c) [*:0]const u8 {
    const e = env orelse return "ZInvert: plugin init called without a script environment.";

    // On a failed load there is no API table to register the real filters,
    // and LoadPlugin still returns true. Register stubs instead so a call
    // raises the reason ("ZInvert: cannot run: ... requires interface >= 11")
    // rather than "there is no function named ZInvert".
    _ = avs.load(e, load_options) catch {
        _ = avs.registerFailureStubs(e, "invert_example", &.{ "ZInvert", "ZPlaneMax" }, avs.getLastError());
        return avs.getLastError().ptr;
    };

    if (avs.register(.init(e), &.{
        .{ .name = "ZInvert", .params = invert_params, .apply = avs.applyFn("ZInvert", invertCreate) },
        .{ .name = "ZPlaneMax", .params = plane_max_params, .apply = avs.applyFn("ZPlaneMax", planeMaxCreate) },
    })) |err| return err;

    return "ZInvert example plugin";
}
