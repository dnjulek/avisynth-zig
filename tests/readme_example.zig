//! The README "A complete filter" example, compiled as part of `zig build test`
//! so the documented code cannot rot. Keep in sync with README.md.

const avs = @import("avisynth");

const Data = struct { format: avs.Format };
const F = avs.Filter(Data, "MyInvert");

fn getFrame(comptime T: type) F.GetFrameFn {
    return struct {
        fn f(d: *Data, ctx: *avs.FrameCtx, n: c_int) !avs.Frame {
            const src = try ctx.childFrame(n); // owned; error -> fi.error
            defer src.release();
            const dst = try ctx.newFrame(src); // props copied from src
            for (0..d.format.numPlanes()) |p| {
                const id = d.format.planeId(p);
                const s = src.plane(T, id);
                const o = dst.planeMut(T, id); // independent pitch
                for (0..s.height) |y| for (o.row(y), s.row(y)) |*x, v| {
                    x.* = ~v;
                };
            }
            return dst; // transfers the reference to the host
        }
    }.f;
}

fn create(ctx: *avs.Create) !avs.Value {
    const clip = try ctx.clip(0, "clip");
    defer clip.release();
    const fmt = avs.Format.fromVideoInfo(clip.videoInfo()) catch
        return ctx.fail("only planar formats are supported.", .{});
    if (fmt.isFloat()) return ctx.fail("integer formats only.", .{});
    const gf = switch (fmt.sample) {
        inline .u8, .u16 => |s| F.getFrame(getFrame(s.Type())),
        .f32 => unreachable,
    };
    return avs.Create.returnClip(try F.create(ctx.env, clip, .{ .format = fmt }, gf, .{ .mt_mode = .nice }));
}

export fn avisynth_c_plugin_init2(env: ?*avs.c.AVS_ScriptEnvironment) callconv(.c) [*:0]const u8 {
    const e = env orelse return "no environment";
    _ = avs.load(e, .{ .interface = 11 }) catch {
        _ = avs.registerFailureStubs(e, "myplugin", &.{"MyInvert"}, avs.getLastError());
        return avs.getLastError().ptr;
    };
    if (avs.register(.init(e), &.{
        .{ .name = "MyInvert", .params = "c", .apply = avs.applyFn("MyInvert", create) },
    })) |err| return err;
    return "myplugin";
}

test "readme example compiles" {
    _ = &avisynth_c_plugin_init2;
}
