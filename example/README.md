# ZInvert — example AviSynth+ plugin in Zig

A small but complete AviSynth+ plugin built on the [`avisynth`](../README.md) module (consumed as a path dep on `../`), ported from the VapourSynth SDK invert example.

## Build

```sh
zig build -Doptimize=ReleaseFast   # → zig-out/bin/invert_example.dll
```

Load it in a script with `LoadPlugin("...\invert_example.dll")`.

## The filter

```
ZInvert(clip, bool "enabled"=true)
```

- Inverts every plane of planar formats: Y, YUV(A), planar RGB(A) — 8..16-bit integer and 32-bit float. Packed RGB is rejected at create time with an error.
- Integer chroma pivots on the midpoint (`min(2*half - x, peak)`), matching AviSynth+ 3.7.6 `Invert()` and the zero-centered float-chroma negation — so `ZInvert().ZInvert()` is bit-exact identity on integer formats.
- `enabled=false` passes the source frames through untouched (still a filter in the chain).
- Registers `AVS_MT_NICE_FILTER` via the `set_cache_hints` callback, so it runs under `Prefetch()`.

## What the source demonstrates

`src/invert_example.zig`, top to bottom:

- **invertPlane** — generic per-plane loop over `u8`/`u16`/`f32` with pitch stepping.
- **invertGetFrame** — `avs_get_frame` on `fi.child`, `avs_new_video_frame_p_a` (frame props copied via `prop_src`), per-plane read/write pointers + pitch/row_size/height, runtime errors via `fi.error`.
- **invertCreate** — `avs_new_c_filter` with `store_child=1`, reading args with the header inlines (`avs_array_elt`/`avs_defined`/`avs_as_bool`), validation with `avs_new_value_error` (static strings only), returning the clip with `avs_set_to_clip` + deferred `avs_release_clip`.
- **avisynth_c_plugin_init** — `avs.getApi` with an explicit required-functions list (interface V8 floor), error reporting via `avs.getLastError()`, `avs_add_function` registration.

## Testing

`test.bat` (needs `ffmpeg` in PATH and AviSynth+ installed) loads `test.avs` and writes `test_result.png`:

- `test.avs` runs ~40 `Assert()`s: format preservation, per-frame pixel math vs the built-in `Invert()` (luma exact, integer chroma within 1 LSB), pass-through, double-invert identity on every supported depth, and alpha handling. The per-frame checks run over **all** frames at script-load time (a `for` loop setting `global current_frame`) — deliberately not in `ScriptClip`, which only paints runtime errors onto the frame while the decode still "succeeds".
- On success the PNG is a 2×2 grid: source, 8-bit invert, float invert, planar-RGBA invert.
- On failure ffmpeg exits nonzero with the assert message (the bat checks `%errorlevel% neq 0` because ffmpeg uses negative exit codes, which `if errorlevel 1` misses).
