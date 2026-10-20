// Native ABI probe: compiled with exactly the headers, defines and C++ flags of
// the module, it reports the C/C++ view of the function table and the value
// types, which tests/abi.zig compares field by field with the Zig view.

#include <cstddef>
#include <cstdint>

#include "avs_c_api_loader.hpp"

extern "C" {

size_t avsz_probe_table_size(void) { return sizeof(avisynth_c_api_pointers); }
size_t avsz_probe_table_align(void) { return alignof(avisynth_c_api_pointers); }

const size_t* avsz_probe_table_offsets(size_t* count)
{
    static const size_t offsets[] = {
#define FUNC(name) offsetof(avisynth_c_api_pointers, name),
#include "avs_c_api_functions.inc"
#undef FUNC
    };
    *count = sizeof(offsets) / sizeof(offsets[0]);
    return offsets;
}

// size, align, then field offsets in declaration order.
const size_t* avsz_probe_value_layout(size_t* count)
{
    static const size_t l[] = {
        sizeof(AVS_Value), alignof(AVS_Value),
        offsetof(AVS_Value, type), offsetof(AVS_Value, array_size), offsetof(AVS_Value, d),
    };
    *count = sizeof(l) / sizeof(l[0]);
    return l;
}

const size_t* avsz_probe_video_info_layout(size_t* count)
{
    static const size_t l[] = {
        sizeof(AVS_VideoInfo), alignof(AVS_VideoInfo),
        offsetof(AVS_VideoInfo, width), offsetof(AVS_VideoInfo, height),
        offsetof(AVS_VideoInfo, fps_numerator), offsetof(AVS_VideoInfo, fps_denominator),
        offsetof(AVS_VideoInfo, num_frames), offsetof(AVS_VideoInfo, pixel_type),
        offsetof(AVS_VideoInfo, audio_samples_per_second), offsetof(AVS_VideoInfo, sample_type),
        offsetof(AVS_VideoInfo, num_audio_samples), offsetof(AVS_VideoInfo, nchannels),
        offsetof(AVS_VideoInfo, image_type),
    };
    *count = sizeof(l) / sizeof(l[0]);
    return l;
}

const size_t* avsz_probe_filter_info_layout(size_t* count)
{
    static const size_t l[] = {
        sizeof(AVS_FilterInfo), alignof(AVS_FilterInfo),
        offsetof(AVS_FilterInfo, child), offsetof(AVS_FilterInfo, vi), offsetof(AVS_FilterInfo, env),
        offsetof(AVS_FilterInfo, get_frame), offsetof(AVS_FilterInfo, get_parity),
        offsetof(AVS_FilterInfo, get_audio), offsetof(AVS_FilterInfo, set_cache_hints),
        offsetof(AVS_FilterInfo, free_filter), offsetof(AVS_FilterInfo, error),
        offsetof(AVS_FilterInfo, user_data),
    };
    *count = sizeof(l) / sizeof(l[0]);
    return l;
}

// By-value struct round trips: the calling convention for AVS_Value (returned
// by every apply callback) must agree between the C++ and Zig sides.
AVS_Value avsz_probe_make_long(int64_t v)
{
    AVS_Value r;
    r.type = 'l';
    r.array_size = 0;
    r.d.longlong = v;
    return r;
}

int64_t avsz_probe_read_long(AVS_Value v) { return v.type == 'l' ? v.d.longlong : -1; }

AVS_Value avsz_probe_echo(AVS_Value v) { return v; }

} // extern "C"
