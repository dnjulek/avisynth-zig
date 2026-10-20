//! Cross-language ABI checks: the Zig view of the loader table and the C
//! value types must match what C++ (same headers/defines/flags/target) sees.

const std = @import("std");
const avs = @import("avisynth");
const c = avs.c;

extern fn avsz_probe_table_size() usize;
extern fn avsz_probe_table_align() usize;
extern fn avsz_probe_table_offsets(count: *usize) [*]const usize;
extern fn avsz_probe_value_layout(count: *usize) [*]const usize;
extern fn avsz_probe_video_info_layout(count: *usize) [*]const usize;
extern fn avsz_probe_filter_info_layout(count: *usize) [*]const usize;
extern fn avsz_probe_make_long(v: i64) c.AVS_Value;
extern fn avsz_probe_read_long(v: c.AVS_Value) i64;
extern fn avsz_probe_echo(v: c.AVS_Value) c.AVS_Value;

fn probe(f: fn (*usize) callconv(.c) [*]const usize) []const usize {
    var n: usize = 0;
    const p = f(&n);
    return p[0..n];
}

fn expectLayout(comptime T: type, got: []const usize) !void {
    const names = @typeInfo(T).@"struct".field_names;
    try std.testing.expectEqual(names.len + 2, got.len);
    try std.testing.expectEqual(@sizeOf(T), got[0]);
    try std.testing.expectEqual(@alignOf(T), got[1]);
    inline for (names, 0..) |name, i| {
        std.testing.expectEqual(@offsetOf(T, name), got[i + 2]) catch |e| {
            std.debug.print("{s}.{s}: zig offset {d}, C++ offset {d}\n", .{ @typeName(T), name, @offsetOf(T, name), got[i + 2] });
            return e;
        };
    }
}

test "AvsApi layout matches the C++ avisynth_c_api_pointers" {
    try std.testing.expectEqual(@sizeOf(avs.AvsApi), avsz_probe_table_size());
    try std.testing.expectEqual(@alignOf(avs.AvsApi), avsz_probe_table_align());
    const offs = probe(avsz_probe_table_offsets);
    const names = @typeInfo(avs.AvsApi).@"struct".field_names;
    try std.testing.expectEqual(names.len, offs.len);
    inline for (names, 0..) |name, i| {
        std.testing.expectEqual(@offsetOf(avs.AvsApi, name), offs[i]) catch |e| {
            std.debug.print("AvsApi.{s}: zig offset {d}, C++ offset {d}\n", .{ name, @offsetOf(avs.AvsApi, name), offs[i] });
            return e;
        };
    }
}

test "value type layouts match C" {
    try expectLayout(c.AVS_Value, probe(avsz_probe_value_layout));
    try expectLayout(c.AVS_VideoInfo, probe(avsz_probe_video_info_layout));
    try expectLayout(c.AVS_FilterInfo, probe(avsz_probe_filter_info_layout));
}

test "AVS_Value by-value calling convention round trips" {
    const v = avsz_probe_make_long(-1234567890123);
    try std.testing.expectEqual(@as(c_short, 'l'), v.type);
    try std.testing.expectEqual(@as(i64, -1234567890123), v.d.longlong);
    try std.testing.expectEqual(@as(i64, 0x7fff_ffff_ffff), avsz_probe_read_long(avsz_probe_make_long(0x7fff_ffff_ffff)));

    var s = c.avs_new_value_array(null, 7);
    s.type = 'x';
    const e = avsz_probe_echo(s);
    try std.testing.expectEqual(s.type, e.type);
    try std.testing.expectEqual(s.array_size, e.array_size);
}
