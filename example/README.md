# ZInvert: example AviSynth+ plugin in Zig

A small but complete plugin built on the [`avisynth`](../README.md) module's convenience layer, ported from the VapourSynth SDK invert example. It depends on the module through a local path (`.path = "../"`), so it always tests the working tree. To consume the published module instead:

```sh
zig fetch --save git+https://github.com/dnjulek/avisynth-zig.git
```

## Build

```sh
zig build -Doptimize=fast   # -> zig-out/bin/invert_example.dll
```

Load it in a script with `LoadPlugin("...\invert_example.dll")`. It needs AviSynth+ with interface ≥ 11 (it exports only `avisynth_c_plugin_init2`).

## The filters

```
ZInvert(clip, bool "enabled"=true)
ZPlaneMax(clip)
```

- `ZInvert` inverts every plane of planar formats: Y, YUV(A), planar RGB(A), 8..16-bit integer and 32-bit float. Packed formats are rejected at create time.
  - Integer chroma pivots on the midpoint (`min(2*half - x, peak)`, as in AviSynth+ 3.7.6 `Invert()`), and float chroma is negated, so `ZInvert().ZInvert()` is a bit-exact identity on integer formats.
  - `enabled=false` returns the input clip itself (no filter instance).
- `ZPlaneMax` is property-only. It stores each plane's maximum as the float array property `ZPlaneMax` without copying pixels: the property map is made writable with `avs_make_property_writable`, and pixel buffers stay shared with the source.
- Both register `AVS_MT_NICE_FILTER`.

## What the source demonstrates

`src/invert_example.zig`, top to bottom:

- **`avs.Filter(Data, name)`**: one `Data` copy owned by the filter, get_frame thunks per comptime type (`Invert.getFrame(invertGetFrame(T))`), and the MT hint.
- **`invertPlane`**: per-row processing with independent source and destination pitches (a cropped source keeps its parent's pitch).
- **`ctx.childFrame` / `ctx.newFrame(src)`**: owned frames, props copied, errors becoming durable `fi.error` messages.
- **`planeMaxGetFrame`**: `makePropertyWritable` (which may replace the frame pointer, so views are taken after it) followed by `propsRW().setFloatArray`.
- **`create`**: `ctx.clip` (owned) plus `defer release`, `ctx.boolean`, `avs.Format.fromVideoInfo`, and `avs.Create.returnClip`.
- **`avisynth_c_plugin_init2`**: `avs.load(.{ .interface = 11 })`, `avs.registerFailureStubs` on failure, and `avs.register` (comptime-checked parameter strings, checked registration results).

## Testing

`test.bat [--no-pause]` (needs `ffmpeg` in PATH and AviSynth+ installed) loads `test.avs` and writes `test_result.png`:

- Format preservation, per-frame pixel math vs the built-in `Invert()` (luma exact, integer chroma within 1 LSB), pass-through, and double-invert identity on every supported depth, plus alpha.
- Cropped sources (mismatched pitches) against the built-in.
- `ZPlaneMax` against `YPlaneMax/UPlaneMax/VPlaneMax`, with untouched pixels and no property leaking into the source frame.

The per-frame checks run over **all** frames at script-load time (a `for` loop setting `global current_frame`), deliberately not in `ScriptClip`, which only paints runtime errors onto the frame while the decode still "succeeds".
