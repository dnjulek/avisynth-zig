//! Test root for host-free integration tests of the `avisynth` module.
test {
    _ = @import("abi.zig");
    _ = @import("mock.zig");
    _ = @import("readme_example.zig");
}
