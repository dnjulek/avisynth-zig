# avisynth

Zig module for writing AviSynth+ C-API plugins. The C API is loaded at runtime through [avisynthplus-c-api-dynamic-loader](https://github.com/Asd-g/avisynthplus-c-api-dynamic-loader), so plugins never link `AviSynth.lib`. The [AviSynthPlus](https://github.com/AviSynth/AviSynthPlus) headers are translated at build time for the C types. Both are pinned git deps (see `build.zig.zon`).

The module has two layers:

- **Raw**: `avs.c` (translated `avisynth_c.h`) and `avs.AvsApi`, the loader's function table. Its layout is verified at comptime and by a native ABI probe. This layer is always available as an escape hatch.
- **Convenience**: `avs.load`, `Env`, `Clip`, `Frame`/`Plane`, `PropsRO`/`PropsRW`, `Value`/`Args`, `Format`, and the filter lifecycle helpers (`Filter`, `Create`, `FrameCtx`, `register`). They have explicit ownership, durable error messages, and host-bug workarounds. [vszip's AviSynth+ build](#consumers) is a 25-filter plugin built on them.

## Consumer build

```sh
zig fetch --save git+https://github.com/dnjulek/avisynth-zig.git
```

```zig
// build.zig
const avs_dep = b.dependency("avisynth", .{ .target = target, .optimize = optimize });
mod.addImport("avisynth", avs_dep.module("avisynth"));
```

The module carries the C++20 loader and shim sources (with `link_libcpp`), so `addImport` is all a consumer needs.

## A complete filter

```zig
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
```

`example/src/invert_example.zig` is a fuller reference with a pixel filter and a property-only filter.

## Contracts

**Loading.** Call `avs.load(env, options)` once, from `avisynth_c_plugin_init2`. The loader initializes once and never retries. `LoadOptions` selects `Feature` groups (`core`, `planar`, `props`, `values`, `invoke`, `host`) plus `extra` raw names:
- Every name is checked against the loader table at comptime.
- Every group's minimum interface is checked against `.interface` at comptime.
- All selected functions are required at load time.

Wrappers call through `avs.api.fnPtr`, which panics in safe builds when an entry was neither required nor present.

**Init failure is visible.** `LoadPlugin` returns `true` even when init fails, and the init string never reaches scripts. `registerFailureStubs` resolves `avs_add_function` from the resident host library and registers each function as a stub that raises `"<plugin>: cannot run: <reason>"`, so scripts never see a silent "no function named X". `zig build runtime-test` checks this against the installed host.

**Ownership** (by convention; Zig has no move semantics, and plain assignment copies a handle without adding a reference):

| Operation | Contract |
| --- | --- |
| `Clip.getFrame`, `FrameCtx.childFrame/getFrame`, `Env.newFrame`, `Frame.retain` | owned frame: `release` once, or return it from get_frame (transfer) |
| `Value.takeClip`, `Create.clip/optClip`, `Clip.retain`, `Filter.create` | owned clip: `release` once |
| `FrameCtx.child()` | borrowed: never release |
| `Create.arg/args`, array elements, string arguments | borrowed for the call (argument strings live as long as the environment) |
| `Plane`/`PlaneMut`, `PropsRO`/`PropsRW` | borrow the frame; invalid after `makeWritable` / `makePropertyWritable` (which may replace `ptr`) |
| `Filter.create(env, child, data, …)` | on success the filter owns its copy of `data` (`Data.deinit` runs in `free_filter`); on error nothing was taken |

**Errors.** Create functions return `!avs.Value`. `ctx.fail(fmt, args)` records `"<name>: <message>"`, which reaches the script as an AviSynth error stored with `SaveString`. Frame callbacks return `!avs.Frame`; errors become `fi.error` with a durable message and a null frame. An upstream failure keeps the upstream message. Messages never point into stack buffers.

**Arguments.** `Create.int/float/boolean/string/clip` take `(index, key, default, min, max)`:
- Integers are range-checked on the full 64-bit value before narrowing.
- Floats are checked for finiteness, then range, as f64 before narrowing.
- `intArray`/`floatArray`/`perPlaneFloat`/`planes` cover AviSynth+ array parameters (`[key]i*`; scripts pass `key=[1, 2]` or a scalar). Too many elements, duplicate planes, and out-of-range planes are errors.

`checkParams` validates parameter strings at comptime, and `forwardArgs` re-invokes another function with the same arguments.

**Geometry.** `Plane(T)` keeps `pitch` (bytes) and `width` (samples) separate, and validates sizes and alignment from the host's signed values:
- `row(y)` is the safe accessor.
- `span()` ends at the last active sample.
- `fullSlice()` (`height * stride`, VapourSynth style) is only for frames you allocated or canonical copies.

**Formats.** `Format.fromVideoInfo` decodes planar Gray, YUV(A), and RGB(A) and rejects packed or interleaved layouts. `planeId(i)` maps vszip-style logical planes (Y,U,V / R,G,B, then alpha) to `AVS_PLANAR_*`. These functions are pure, so they are unit-tested without a host.

**MT.** `Filter.create(.., .{ .mt_mode = .nice | .multi_instance | .serialized })` answers `AVS_CACHE_GET_MTMODE`. Choose `.nice` only for immutable configuration plus request-local or exclusively checked-out scratch. Never cache `fi`, the create-time `Env`, or the plugin-init environment. On newer hosts `fi` is a per-call copy.

## Host behavior the layer works around

These were confirmed against the AviSynth+ sources and the installed 3.7.5 (interface 11.1):

1. **`avs_add_function` aliasing.** The callback record `{user_data, func, func_r}` is stored with `SaveString`, whose de-duplicating cache compares keys with `strncmp`. With `user_data == NULL` the record starts with a NUL byte, so two functions whose hashes share a bucket alias each other and one silently runs the other's create. This is still present in master. `register` gives every function a unique tag `user_data` with a distinct non-zero first byte.
2. **`avs_new_video_frame_p_a(…, prop_src = NULL)` crashes.** The C wrapper forwards `&prop_src` and the core dereferences it. `Env.newFrame(vi, null)` uses `avs_new_video_frame_a` instead.
3. **Childless C filters** (sources) must define every callback, or the default parity and audio forwarding dereferences a null child. `Filter.create` installs safe defaults when `child == null`.
4. **MT_NICE error slots** (≤ 3.7.5, fixed upstream as #519). Concurrent calls share `fi.error` and the child clip's error slot, so under MT an error message may be attributed to the wrong frame. Successful frames are unaffected.

## Build and test

```sh
zig build                # compile smoke test (static lib); the product is the module
zig build test           # comptime layout guards, format/plane/Diag unit tests,
                         # native ABI probe (table offsets, struct layouts, AVS_Value
                         # by-value round trip), mock-table lifecycle tests
zig build runtime-test   # Windows + ffmpeg: init-failure stubs in the installed AviSynth+

cd example && zig build -Doptimize=fast && test.bat --no-pause
```

The mock-table tests count clip and frame references through create success, create failure after acquiring inputs, upstream failure, and allocation failure, and assert that nothing leaks or is double-released.

Support claim: Windows x86_64 with AviSynth+ interface ≥ 11 is the tested runtime path (3.7.5 / 11.1 here). The headers are interface 12. Other targets compile, but they have no runtime evidence.

## Consumers

- `example/` uses the local checkout (`.path = "../"`) as a working-tree integration check: edits under `src/` are tested immediately.
- [vszip](https://github.com/dnjulek/vapoursynth-zip) builds an AviSynth+ plugin from its shared kernels (`zig build -Davisynth=true`; adapters in `src/avisynth/`): 25 filters, plus about 1000 differential tests against vszip running under VapourSynth. Its local clone `dev/vapoursynth-zip` consumes this module through `.path = "../.."`.

To check the packaged module like an external consumer, switch a consumer to `zig fetch --save git+https://github.com/dnjulek/avisynth-zig.git` after pushing.

## License

MIT. Dependencies have their own licenses that apply to what a plugin ships: the dynamic loader is MPL-2.0, and the AviSynth+ headers are GPL with the C-interface exception.
