const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const loader_dep = b.dependency("avs_loader", .{});
    const avisynth_dep = b.dependency("avisynthplus", .{});
    const translate_c_dep = b.dependency("translate_c", .{});

    // Raw C API types/constants, exposed from main.zig as `avs.c`.
    const avs_c: Translator = .init(translate_c_dep, .{
        .c_source_file = avisynth_dep.path("avs_core/include/avisynth_c.h"),
        .target = target,
        .optimize = optimize,
    });
    avs_c.addIncludePath(avisynth_dep.path("avs_core/include"));
    // API functions as `*_func` pointer typedefs, not extern symbols.
    avs_c.defineCMacro("AVSC_NO_DECLSPEC", null);
    // Skip the header's built-in LoadLibrary-based AVS_Library helpers (they
    // require windows.h); the C++ loader dependency replaces them.
    avs_c.defineCMacro("EXTERNAL_AVS_C_API_LOADER", null);

    const native: Native = .{
        .loader = loader_dep,
        .avisynth = avisynth_dep,
        .shim = b.path("src/shim.cpp"),
    };

    const mod = b.addModule("avisynth", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
        .imports = &.{.{ .name = "avisynth_c", .module = avs_c.mod }},
    });
    native.addTo(mod);

    const lib = b.addLibrary(.{
        .name = "avisynth",
        .linkage = .static,
        .root_module = mod,
    });
    b.installArtifact(lib);

    const test_step = b.step("test", "Run module tests and the native ABI probe");

    const tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // The probe is compiled with the same headers, defines and flags as the
    // module, but only into this test binary (never shipped to consumers).
    const abi_mod = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
        .imports = &.{.{ .name = "avisynth", .module = mod }},
    });
    abi_mod.addIncludePath(avisynth_dep.path("avs_core/include"));
    abi_mod.addIncludePath(loader_dep.path("src"));
    abi_mod.addCSourceFile(.{ .file = b.path("tests/abi_probe.cpp"), .flags = &cpp_flags });
    const abi_tests = b.addTest(.{ .root_module = abi_mod });
    test_step.dependOn(&b.addRunArtifact(abi_tests).step);

    // Runtime check against the installed AviSynth+ (needs ffmpeg in PATH):
    // a plugin whose API load fails must make its functions raise the reason.
    const fail_lib = b.addLibrary(.{
        .name = "avsz_init_fail",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/runtime/init_fail.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "avisynth", .module = mod }},
        }),
    });
    // AviSynth resolves a relative LoadPlugin path against the script's
    // directory: put the DLL next to the generated script.
    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(fail_lib.getEmittedBin(), "avsz_init_fail.dll");
    const script = wf.add("init_fail.avs",
        \\LoadPlugin("./avsz_init_fail.dll")
        \\Assert(FunctionExists("ZInitFail"), "failure stub was not registered")
        \\msg = ""
        \\try { ZInitFail(BlankClip()) } catch (err) { msg = err }
        \\Assert(FindStr(msg, "init_fail: cannot run") > 0, "unexpected error: [" + msg + "]")
        \\Assert(FindStr(msg, "requires interface >= 99") > 0, "reason missing: [" + msg + "]")
        \\BlankClip(length=1)
        \\
    );
    const run = b.addSystemCommand(&.{ "ffmpeg", "-hide_banner", "-loglevel", "error", "-i" });
    run.addFileArg(script);
    run.addArgs(&.{ "-f", "null", "-" });
    run.has_side_effects = true;
    b.step("runtime-test", "Load test plugins in the installed AviSynth+ (Windows, ffmpeg)").dependOn(&run.step);
}

// -fno-c++-static-destructors works around Zig 0.16.0 toolchain: in a
// DLL with a Zig root module, zig's start.zig provides the entry point
// instead of mingw's dllcrt2, so the mingw CRT atexit table is never
// initialized (left at its -1 sentinel). The loader's function-local static
// singleton has a std::string member, and registering its destructor via
// __cxa_atexit then crashes with heap corruption (access violation reading
// 0xFFFFFFFFFFFFFFFF) inside avisynth_c_plugin_init. Skipping static-dtor
// registration is safe here: the loader singleton must live until unload
// anyway, and the OS reclaims its memory. Kept on 0.17.0: one run of
// example/test.avs did not reproduce the crash without it, but heap
// corruption can be intermittent and the flag is harmless.
const cpp_flags = [_][]const u8{ "-std=c++20", "-fno-c++-static-destructors" };

/// The C++ loader + shim and the include paths every consumer of the module
/// needs. Consumers get these compiled in automatically through `addImport`.
const Native = struct {
    loader: *std.Build.Dependency,
    avisynth: *std.Build.Dependency,
    shim: std.Build.LazyPath,

    fn addTo(n: Native, mod: *std.Build.Module) void {
        // C API headers (avisynth_c.h + avs/) and the loader's header/impl.
        mod.addIncludePath(n.avisynth.path("avs_core/include"));
        mod.addIncludePath(n.loader.path("src"));
        mod.addCSourceFiles(.{
            .root = n.loader.path("src"),
            .files = &.{"avs_c_api_loader.cpp"},
            .flags = &cpp_flags,
        });
        mod.addCSourceFile(.{ .file = n.shim, .flags = &cpp_flags });
        // Used to comptime-verify that AvsApi stays in sync with the loader's function table.
        mod.addAnonymousImport("avs_c_api_functions.inc", .{
            .root_source_file = n.loader.path("src/avs_c_api_functions.inc"),
        });
    }
};
