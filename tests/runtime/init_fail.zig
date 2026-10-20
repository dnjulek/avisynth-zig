//! Runtime fixture: a plugin whose API load always fails (interface 99), to
//! check that scripts see the reason instead of a silent non-registration.

const avs = @import("avisynth");
const c = avs.c;

export fn avisynth_c_plugin_init2(env: ?*c.AVS_ScriptEnvironment) callconv(.c) [*:0]const u8 {
    const e = env orelse return "init_fail: no environment";
    _ = avs.load(e, .{ .interface = 99, .features = &.{.core} }) catch {
        _ = avs.registerFailureStubs(e, "init_fail", &.{"ZInitFail"}, avs.getLastError());
        return avs.getLastError().ptr;
    };
    return "init_fail: unexpectedly loaded";
}
