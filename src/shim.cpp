// C shim over avisynth_c_api_loader's C++ interface (std::span<std::string_view>)
// so the Zig module can call it through plain extern "C" functions.
//
// Failure contract: no C++ exception may cross into Zig frames. The name
// vector and the loader's own initialization (strings, unordered_map) can
// throw std::bad_alloc; every entry point catches everything and reports the
// failure through a static, allocation-free fallback message instead.

#include <exception>
#include <new>
#include <string_view>
#include <vector>

#include "avs_c_api_loader.hpp"

namespace
{
    // Set when the shim itself had to swallow an exception; takes precedence
    // over the loader's (possibly stale) message. Written only during plugin
    // init, which AviSynth serializes.
    const char* shim_error{nullptr};
} // namespace

extern "C" {

const avisynth_c_api_pointers* avsz_get_api(AVS_ScriptEnvironment* env, int required_interface_version,
    int required_bugfix_version, const char* const* required_names, size_t required_names_count) noexcept
{
    shim_error = nullptr;
    try
    {
        std::vector<std::string_view> names;
        names.reserve(required_names_count);
        for (size_t i{0}; i < required_names_count; ++i)
            names.emplace_back(required_names[i]);

        return avisynth_c_api_loader::get_api(
            env, required_interface_version, required_bugfix_version, std::span<const std::string_view>{names});
    }
    catch (const std::bad_alloc&)
    {
        shim_error = "avisynth C API loader: out of memory during initialization.";
    }
    catch (...)
    {
        shim_error = "avisynth C API loader: unexpected C++ exception during initialization.";
    }
    return nullptr;
}

const char* avsz_get_last_error(void) noexcept
{
    if (shim_error)
        return shim_error;
    try
    {
        return avisynth_c_api_loader::get_last_error();
    }
    catch (...)
    {
        return "avisynth C API loader: unexpected C++ exception while reading the last error.";
    }
}

} // extern "C"
