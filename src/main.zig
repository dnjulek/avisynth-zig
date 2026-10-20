//! Zig module for AviSynth+ C-API plugins.
//!
//! Two layers:
//! - Raw: `c` (translated `avisynth_c.h`) and `AvsApi` (the loader's function
//!   table, layout-verified at comptime). Always available as an escape hatch.
//! - Convenience: `load`, `Env`, `Clip`, `Frame`/`Plane`, `PropsRO`/`PropsRW`,
//!   `Value`/`Args`, `Format`, and the filter lifecycle helpers in `filter`.
//!   Each wrapper documents its ownership contract and the `Feature` group of
//!   raw functions it needs; `load` requires those groups up front.

const std = @import("std");

/// Raw AviSynth+ C API types and constants (avisynth_c.h with AVSC_NO_DECLSPEC,
/// so API functions are exposed as `*_func` pointer typedefs, not extern symbols).
/// Translated by the translate-c package in build.zig.
pub const c = @import("avisynth_c");

pub const api = @import("api.zig");
pub const AvsApi = api.AvsApi;
pub const api_function_names = api.api_function_names;
pub const INTERFACE_VERSION = api.INTERFACE_VERSION;
pub const INTERFACE_BUGFIX_VERSION = api.INTERFACE_BUGFIX_VERSION;
pub const getApi = api.getApi;
pub const getLastError = api.getLastError;
pub const Feature = api.Feature;
pub const LoadOptions = api.LoadOptions;
pub const load = api.load;
pub const table = api.table;
pub const checkNames = api.checkNames;

pub const Env = @import("env.zig").Env;
pub const Clip = @import("clip.zig").Clip;
pub const OwnedClip = @import("clip.zig").OwnedClip;

pub const frame = @import("frame.zig");
pub const Frame = frame.Frame;
pub const Plane = frame.Plane;
pub const PlaneMut = frame.PlaneMut;
pub const copyPlane = frame.copyPlane;

pub const props = @import("props.zig");
pub const PropsRO = props.PropsRO;
pub const PropsRW = props.PropsRW;

pub const value = @import("value.zig");
pub const Value = value.Value;
pub const Args = value.Args;

pub const format = @import("format.zig");
pub const Format = format.Format;
pub const ColorFamily = format.ColorFamily;
pub const SampleType = format.SampleType;

pub const filter = @import("filter.zig");
pub const Create = filter.Create;
pub const FrameCtx = filter.FrameCtx;
pub const Filter = filter.Filter;
pub const MtMode = filter.MtMode;
pub const applyFn = filter.applyFn;
pub const register = filter.register;
pub const registerFailureStubs = filter.registerFailureStubs;
pub const Function = filter.Function;

test {
    std.testing.refAllDecls(@This());
    _ = api;
    _ = format;
    _ = frame;
    _ = filter;
}
