const std = @import("std");

/// Raw AviSynth+ C API types and constants (avisynth_c.h with AVSC_NO_DECLSPEC,
/// so API functions are exposed as `*_func` pointer typedefs, not extern symbols).
pub const c = @cImport({
    @cDefine("AVSC_NO_DECLSPEC", "1");
    // Skip the header's built-in LoadLibrary-based AVS_Library helpers (they
    // require windows.h); the C++ loader dependency replaces them.
    @cDefine("EXTERNAL_AVS_C_API_LOADER", "1");
    @cInclude("avisynth_c.h");
});

pub const INTERFACE_VERSION: c_int = c.AVISYNTH_INTERFACE_VERSION;
pub const INTERFACE_BUGFIX_VERSION: c_int = c.AVISYNTHPLUS_INTERFACE_BUGFIX_VERSION;

// The loader's function table definition, wired in via build.zig as an
// anonymous import from the avs_loader dependency — the exact file its
// C++ side is compiled with.
const api_functions_inc = @embedFile("avs_c_api_functions.inc");

/// API function names parsed from avs_c_api_functions.inc, in table order.
pub const api_function_names: []const []const u8 = blk: {
    @setEvalBranchQuota(100_000);
    var names: []const []const u8 = &.{};
    var it = std.mem.tokenizeAny(u8, api_functions_inc, "\r\n");
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (!std.mem.startsWith(u8, trimmed, "FUNC(")) continue;
        const name = trimmed[5..std.mem.indexOfScalarPos(u8, trimmed, 5, ')').?];
        names = names ++ .{name};
    }
    break :blk names;
};

/// Mirror of the C++ `avisynth_c_api_pointers` struct built from
/// avs_c_api_functions.inc. Hand-written (not comptime-derived) so ZLS can
/// resolve the fields; field order MUST match the .inc exactly (verified at
/// comptime below — any drift is a compile error). Regenerate with:
///   sed -E 's/^FUNC\((.+)\)$/    \1: c.\1_func,/' ../avisynthplus-c-api-dynamic-loader/src/avs_c_api_functions.inc
/// Functions missing from the loaded avisynth library are null.
pub const AvsApi = extern struct {
    avs_add_function: c.avs_add_function_func,
    avs_add_function_r: c.avs_add_function_r_func,
    avs_at_exit: c.avs_at_exit_func,
    avs_bit_blt: c.avs_bit_blt_func,
    avs_bits_per_component: c.avs_bits_per_component_func,
    avs_bits_per_pixel: c.avs_bits_per_pixel_func,
    avs_bmp_size: c.avs_bmp_size_func,
    avs_bytes_from_pixels: c.avs_bytes_from_pixels_func,
    avs_check_version: c.avs_check_version_func,
    avs_clear_map: c.avs_clear_map_func,
    avs_clip_get_error: c.avs_clip_get_error_func,
    avs_component_size: c.avs_component_size_func,
    avs_copy_clip: c.avs_copy_clip_func,
    avs_copy_frame_props: c.avs_copy_frame_props_func,
    avs_copy_value: c.avs_copy_value_func,
    avs_copy_video_frame: c.avs_copy_video_frame_func,
    avs_create_script_environment: c.avs_create_script_environment_func,
    avs_delete_script_environment: c.avs_delete_script_environment_func,
    avs_function_exists: c.avs_function_exists_func,
    avs_get_array_elt: c.avs_get_array_elt_func,
    avs_get_array_size: c.avs_get_array_size_func,
    avs_get_as_array: c.avs_get_as_array_func,
    avs_get_as_bool: c.avs_get_as_bool_func,
    avs_get_as_clip: c.avs_get_as_clip_func,
    avs_get_as_error: c.avs_get_as_error_func,
    avs_get_as_float: c.avs_get_as_float_func,
    avs_get_as_int: c.avs_get_as_int_func,
    avs_get_as_long: c.avs_get_as_long_func,
    avs_get_as_string: c.avs_get_as_string_func,
    avs_get_audio: c.avs_get_audio_func,
    avs_get_channel_mask: c.avs_get_channel_mask_func,
    avs_get_cpu_flags: c.avs_get_cpu_flags_func,
    avs_get_env_property: c.avs_get_env_property_func,
    avs_get_error: c.avs_get_error_func,
    avs_get_frame: c.avs_get_frame_func,
    avs_get_frame_props_ro: c.avs_get_frame_props_ro_func,
    avs_get_frame_props_rw: c.avs_get_frame_props_rw_func,
    avs_get_height_p: c.avs_get_height_p_func,
    avs_get_parity: c.avs_get_parity_func,
    avs_get_pitch_p: c.avs_get_pitch_p_func,
    avs_get_plane_height_subsampling: c.avs_get_plane_height_subsampling_func,
    avs_get_plane_width_subsampling: c.avs_get_plane_width_subsampling_func,
    avs_get_read_ptr_p: c.avs_get_read_ptr_p_func,
    avs_get_row_size_p: c.avs_get_row_size_p_func,
    avs_get_var: c.avs_get_var_func,
    avs_get_var_bool: c.avs_get_var_bool_func,
    avs_get_var_double: c.avs_get_var_double_func,
    avs_get_var_int: c.avs_get_var_int_func,
    avs_get_var_long: c.avs_get_var_long_func,
    avs_get_var_string: c.avs_get_var_string_func,
    avs_get_var_try: c.avs_get_var_try_func,
    avs_get_version: c.avs_get_version_func,
    avs_get_video_info: c.avs_get_video_info_func,
    avs_get_write_ptr_p: c.avs_get_write_ptr_p_func,
    avs_invoke: c.avs_invoke_func,
    avs_is_420: c.avs_is_420_func,
    avs_is_422: c.avs_is_422_func,
    avs_is_444: c.avs_is_444_func,
    avs_is_channel_mask_known: c.avs_is_channel_mask_known_func,
    avs_is_color_space: c.avs_is_color_space_func,
    avs_is_planar_rgb: c.avs_is_planar_rgb_func,
    avs_is_planar_rgba: c.avs_is_planar_rgba_func,
    avs_is_property_writable: c.avs_is_property_writable_func,
    avs_is_rgb48: c.avs_is_rgb48_func,
    avs_is_rgb64: c.avs_is_rgb64_func,
    avs_is_writable: c.avs_is_writable_func,
    avs_is_y: c.avs_is_y_func,
    avs_is_y16: c.avs_is_y16_func,
    avs_is_y32: c.avs_is_y32_func,
    avs_is_y8: c.avs_is_y8_func,
    avs_is_yuv420p16: c.avs_is_yuv420p16_func,
    avs_is_yuv420ps: c.avs_is_yuv420ps_func,
    avs_is_yuv422p16: c.avs_is_yuv422p16_func,
    avs_is_yuv422ps: c.avs_is_yuv422ps_func,
    avs_is_yuv444p16: c.avs_is_yuv444p16_func,
    avs_is_yuv444ps: c.avs_is_yuv444ps_func,
    avs_is_yuva: c.avs_is_yuva_func,
    avs_is_yv12: c.avs_is_yv12_func,
    avs_is_yv16: c.avs_is_yv16_func,
    avs_is_yv24: c.avs_is_yv24_func,
    avs_is_yv411: c.avs_is_yv411_func,
    avs_make_property_writable: c.avs_make_property_writable_func,
    avs_make_writable: c.avs_make_writable_func,
    avs_new_c_filter: c.avs_new_c_filter_func,
    avs_new_video_frame_a: c.avs_new_video_frame_a_func,
    avs_new_video_frame_p: c.avs_new_video_frame_p_func,
    avs_new_video_frame_p_a: c.avs_new_video_frame_p_a_func,
    avs_num_components: c.avs_num_components_func,
    avs_pool_allocate: c.avs_pool_allocate_func,
    avs_pool_free: c.avs_pool_free_func,
    avs_prop_delete_key: c.avs_prop_delete_key_func,
    avs_prop_get_clip: c.avs_prop_get_clip_func,
    avs_prop_get_data: c.avs_prop_get_data_func,
    avs_prop_get_data_size: c.avs_prop_get_data_size_func,
    avs_prop_get_data_type_hint: c.avs_prop_get_data_type_hint_func,
    avs_prop_get_float: c.avs_prop_get_float_func,
    avs_prop_get_float_array: c.avs_prop_get_float_array_func,
    avs_prop_get_float_saturated: c.avs_prop_get_float_saturated_func,
    avs_prop_get_frame: c.avs_prop_get_frame_func,
    avs_prop_get_int: c.avs_prop_get_int_func,
    avs_prop_get_int_array: c.avs_prop_get_int_array_func,
    avs_prop_get_int_saturated: c.avs_prop_get_int_saturated_func,
    avs_prop_get_key: c.avs_prop_get_key_func,
    avs_prop_get_type: c.avs_prop_get_type_func,
    avs_prop_num_elements: c.avs_prop_num_elements_func,
    avs_prop_num_keys: c.avs_prop_num_keys_func,
    avs_prop_set_clip: c.avs_prop_set_clip_func,
    avs_prop_set_data: c.avs_prop_set_data_func,
    avs_prop_set_data_h: c.avs_prop_set_data_h_func,
    avs_prop_set_float: c.avs_prop_set_float_func,
    avs_prop_set_float_array: c.avs_prop_set_float_array_func,
    avs_prop_set_frame: c.avs_prop_set_frame_func,
    avs_prop_set_int: c.avs_prop_set_int_func,
    avs_prop_set_int_array: c.avs_prop_set_int_array_func,
    avs_release_clip: c.avs_release_clip_func,
    avs_release_value: c.avs_release_value_func,
    avs_release_video_frame: c.avs_release_video_frame_func,
    avs_row_size: c.avs_row_size_func,
    avs_save_string: c.avs_save_string_func,
    avs_set_cache_hints: c.avs_set_cache_hints_func,
    avs_set_channel_mask: c.avs_set_channel_mask_func,
    avs_set_global_var: c.avs_set_global_var_func,
    avs_set_memory_max: c.avs_set_memory_max_func,
    avs_set_to_array: c.avs_set_to_array_func,
    avs_set_to_bool: c.avs_set_to_bool_func,
    avs_set_to_clip: c.avs_set_to_clip_func,
    avs_set_to_double: c.avs_set_to_double_func,
    avs_set_to_error: c.avs_set_to_error_func,
    avs_set_to_float: c.avs_set_to_float_func,
    avs_set_to_int: c.avs_set_to_int_func,
    avs_set_to_long: c.avs_set_to_long_func,
    avs_set_to_string: c.avs_set_to_string_func,
    avs_set_to_void: c.avs_set_to_void_func,
    avs_set_var: c.avs_set_var_func,
    avs_set_working_dir: c.avs_set_working_dir_func,
    avs_sprintf: c.avs_sprintf_func,
    avs_subframe: c.avs_subframe_func,
    avs_subframe_planar: c.avs_subframe_planar_func,
    avs_subframe_planar_a: c.avs_subframe_planar_a_func,
    avs_take_clip: c.avs_take_clip_func,
    avs_val_defined: c.avs_val_defined_func,
    avs_val_is_array: c.avs_val_is_array_func,
    avs_val_is_bool: c.avs_val_is_bool_func,
    avs_val_is_clip: c.avs_val_is_clip_func,
    avs_val_is_error: c.avs_val_is_error_func,
    avs_val_is_float: c.avs_val_is_float_func,
    avs_val_is_floatf_strict: c.avs_val_is_floatf_strict_func,
    avs_val_is_int: c.avs_val_is_int_func,
    avs_val_is_long_strict: c.avs_val_is_long_strict_func,
    avs_val_is_string: c.avs_val_is_string_func,
    avs_video_frame_amend_pixel_type: c.avs_video_frame_amend_pixel_type_func,
    avs_video_frame_get_pixel_type: c.avs_video_frame_get_pixel_type_func,
    avs_vsprintf: c.avs_vsprintf_func,
};

// Layout guard: AvsApi must list the same functions in the same order as the
// .inc the C++ loader was compiled with, or every call would go through the
// wrong pointer. Any drift is a compile error.
comptime {
    @setEvalBranchQuota(100_000);
    const fields = @typeInfo(AvsApi).@"struct".fields;
    if (fields.len != api_function_names.len) {
        @compileError(std.fmt.comptimePrint(
            "AvsApi has {d} fields but avs_c_api_functions.inc has {d} FUNC entries — regenerate the field list (see AvsApi doc comment)",
            .{ fields.len, api_function_names.len },
        ));
    }
    for (fields, api_function_names) |field, name| {
        if (!std.mem.eql(u8, field.name, name)) {
            @compileError("AvsApi is out of sync with avs_c_api_functions.inc at '" ++ name ++ "' — regenerate the field list (see AvsApi doc comment)");
        }
    }
    // Every entry is a single function pointer; anything else would break the
    // 1:1 layout match with the C++ struct.
    std.debug.assert(@sizeOf(AvsApi) == fields.len * @sizeOf(fields[0].type));
}

extern fn avsz_get_api(
    env: ?*c.AVS_ScriptEnvironment,
    required_interface_version: c_int,
    required_bugfix_version: c_int,
    required_names: ?[*]const [*:0]const u8,
    required_names_count: usize,
) ?*const AvsApi;

extern fn avsz_get_last_error() [*:0]const u8;

/// Loads avisynth (dll/so/dylib) and its C API function table. Call once from
/// `avisynth_c_plugin_init`; the loader does not retry after a failed first
/// load. Functions listed in `required_names` must exist in the loaded
/// library or loading fails; all others are loaded as optional (null when
/// absent). On error, see `getLastError()`.
pub fn getApi(
    env: *c.AVS_ScriptEnvironment,
    required_interface_version: c_int,
    required_bugfix_version: c_int,
    required_names: []const [*:0]const u8,
) error{AvsApiLoadFailed}!*const AvsApi {
    return avsz_get_api(
        env,
        required_interface_version,
        required_bugfix_version,
        if (required_names.len == 0) null else required_names.ptr,
        required_names.len,
    ) orelse error.AvsApiLoadFailed;
}

/// Error description for the last failed `getApi` call.
/// Valid until the next `getApi` call.
pub fn getLastError() [:0]const u8 {
    return std.mem.span(avsz_get_last_error());
}

test "module compiles" {
    std.testing.refAllDecls(@This());
}

test "AvsApi matches the loader's function table" {
    try std.testing.expectEqual(api_function_names.len, @typeInfo(AvsApi).@"struct".fields.len);
    try std.testing.expect(@hasField(AvsApi, "avs_add_function"));
    try std.testing.expect(@hasField(AvsApi, "avs_get_frame"));
    try std.testing.expect(@hasField(AvsApi, "avs_release_video_frame"));
    try std.testing.expect(@hasField(AvsApi, "avs_vsprintf"));
}
