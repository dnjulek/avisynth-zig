//! Host-free lifecycle tests: a mock `AvsApi` counts clip/frame references so
//! create/get_frame success and failure paths can be checked for leaks and
//! double releases, and argument parsing for its error contract.

const std = @import("std");
const avs = @import("avisynth");
const c = avs.c;

const gpa = std.testing.allocator;

// ---------------------------------------------------------------------------
// Mock host objects
// ---------------------------------------------------------------------------

const MockClip = struct {
    refs: i32 = 1,
    vi: c.AVS_VideoInfo,
    /// Filter clips created by avs_new_c_filter.
    filter: ?*c.AVS_FilterInfo = null,
    stored_child: ?*MockClip = null,
    fail_frames: bool = false,
    err: ?[*:0]const u8 = null,
};

var live_clips: i32 = 0;
var live_frames: i32 = 0;
var fail_alloc: bool = false;
var saved: std.ArrayList([]u8) = .empty;

fn mc(p: ?*c.AVS_Clip) *MockClip {
    return @ptrCast(@alignCast(p.?));
}

fn newClip(vi: c.AVS_VideoInfo) *MockClip {
    const m = gpa.create(MockClip) catch unreachable;
    m.* = .{ .vi = vi };
    live_clips += 1;
    return m;
}

fn releaseClip(m: *MockClip) void {
    m.refs -= 1;
    std.debug.assert(m.refs >= 0);
    if (m.refs > 0) return;
    if (m.filter) |fi| {
        if (fi.free_filter) |f| f(fi);
        if (m.stored_child) |ch| releaseClip(ch);
        gpa.destroy(fi);
    }
    gpa.destroy(m);
    live_clips -= 1;
}

fn newFrame() *c.AVS_VideoFrame {
    const f = gpa.create(c.AVS_VideoFrame) catch unreachable;
    f.* = std.mem.zeroes(c.AVS_VideoFrame);
    f._refcount = 1;
    live_frames += 1;
    return f;
}

fn m_release_video_frame(f: [*c]c.AVS_VideoFrame) callconv(.c) void {
    f.*._refcount -= 1;
    std.debug.assert(f.*._refcount >= 0);
    if (f.*._refcount == 0) {
        gpa.destroy(@as(*c.AVS_VideoFrame, f));
        live_frames -= 1;
    }
}
fn m_copy_video_frame(f: [*c]c.AVS_VideoFrame) callconv(.c) [*c]c.AVS_VideoFrame {
    f.*._refcount += 1;
    return f;
}
fn m_set_to_clip(v: [*c]c.AVS_Value, clip: ?*c.AVS_Clip) callconv(.c) void {
    mc(clip).refs += 1;
    v.*.type = 'c';
    v.*.array_size = 0;
    v.*.d.clip = clip;
}
fn m_release_value(v: c.AVS_Value) callconv(.c) void {
    if (v.type == 'c') releaseClip(mc(@ptrCast(v.d.clip)));
}
fn m_take_clip(v: c.AVS_Value, _: ?*c.AVS_ScriptEnvironment) callconv(.c) ?*c.AVS_Clip {
    const m = mc(@ptrCast(v.d.clip));
    m.refs += 1;
    return @ptrCast(m);
}
fn m_release_clip(clip: ?*c.AVS_Clip) callconv(.c) void {
    releaseClip(mc(clip));
}
fn m_copy_clip(clip: ?*c.AVS_Clip) callconv(.c) ?*c.AVS_Clip {
    mc(clip).refs += 1;
    return clip;
}
fn m_get_video_info(clip: ?*c.AVS_Clip) callconv(.c) [*c]const c.AVS_VideoInfo {
    return &mc(clip).vi;
}
fn m_new_c_filter(_: ?*c.AVS_ScriptEnvironment, fi: [*c][*c]c.AVS_FilterInfo, child: c.AVS_Value, store_child: c_int) callconv(.c) ?*c.AVS_Clip {
    const info = gpa.create(c.AVS_FilterInfo) catch unreachable;
    info.* = std.mem.zeroes(c.AVS_FilterInfo);
    info.env = env_ptr;
    const m = newClip(.{ .width = 0, .height = 0, .fps_numerator = 0, .fps_denominator = 0, .num_frames = 0, .pixel_type = 0, .audio_samples_per_second = 0, .sample_type = 0, .num_audio_samples = 0, .nchannels = 0, .image_type = 0 });
    m.filter = info;
    if (child.type == 'c') {
        const ch = mc(@ptrCast(child.d.clip));
        info.vi = ch.vi;
        if (store_child != 0) {
            ch.refs += 1;
            m.stored_child = ch;
            info.child = @ptrCast(ch);
        }
    }
    fi.* = info;
    return @ptrCast(m);
}
fn m_get_frame(clip: ?*c.AVS_Clip, n: c_int) callconv(.c) [*c]c.AVS_VideoFrame {
    const m = mc(clip);
    m.err = null;
    if (m.fail_frames) {
        m.err = "upstream exploded";
        return null;
    }
    if (m.filter) |fi| return fi.get_frame.?(fi, n);
    return newFrame();
}
fn m_clip_get_error(clip: ?*c.AVS_Clip) callconv(.c) [*c]const u8 {
    return mc(clip).err;
}
fn m_new_video_frame_p_a(_: ?*c.AVS_ScriptEnvironment, _: [*c]const c.AVS_VideoInfo, _: [*c]const c.AVS_VideoFrame, _: c_int) callconv(.c) [*c]c.AVS_VideoFrame {
    if (fail_alloc) return null;
    return newFrame();
}
fn m_get_error(_: ?*c.AVS_ScriptEnvironment) callconv(.c) [*c]const u8 {
    if (writable_mode == .refuse) return "mock writability refused";
    return if (fail_alloc) "mock allocation refused" else null;
}

/// Behavior of the mock avs_make_writable / avs_make_property_writable.
const WritableMode = enum {
    /// Already unique: 0, pointer unchanged.
    noop,
    /// Copy: the old reference is released, a new frame returned, 1.
    replace,
    /// The host threw: -1, pointer unchanged (still owned by the caller).
    refuse,
};
var writable_mode: WritableMode = .noop;

fn m_make_writable(_: ?*c.AVS_ScriptEnvironment, pvf: [*c][*c]c.AVS_VideoFrame) callconv(.c) c_int {
    switch (writable_mode) {
        .noop => return 0,
        .replace => {
            const old = pvf.*;
            pvf.* = newFrame();
            m_release_video_frame(old);
            return 1;
        },
        .refuse => return -1,
    }
}
fn m_save_string(_: ?*c.AVS_ScriptEnvironment, s: [*c]const u8, len: c_int) callconv(.c) [*c]u8 {
    const n: usize = @intCast(len);
    const buf = gpa.alloc(u8, n + 1) catch unreachable;
    @memcpy(buf[0..n], s[0..n]);
    buf[n] = 0;
    saved.append(gpa, buf) catch unreachable;
    return buf.ptr;
}
fn m_get_as_long(v: c.AVS_Value) callconv(.c) i64 {
    return switch (v.type) {
        'i' => v.d.integer,
        'l' => v.d.longlong,
        else => unreachable,
    };
}
fn m_get_as_float(v: c.AVS_Value) callconv(.c) f64 {
    return switch (v.type) {
        'i' => @floatFromInt(v.d.integer),
        'f' => v.d.floating_pt,
        'd' => v.d.double_pt,
        else => unreachable,
    };
}
fn m_get_as_bool(v: c.AVS_Value) callconv(.c) c_int {
    return v.d.boolean;
}
fn m_get_array_size(v: c.AVS_Value) callconv(.c) c_int {
    return v.array_size;
}
fn m_get_array_elt(v: c.AVS_Value, i: c_int) callconv(.c) c.AVS_Value {
    return v.d.array[@intCast(i)];
}

var mock_table: avs.AvsApi = std.mem.zeroes(avs.AvsApi);
var env_storage: [64]u8 align(16) = undefined;
const env_ptr: *c.AVS_ScriptEnvironment = @ptrCast(&env_storage);

fn setUp() void {
    mock_table = std.mem.zeroes(avs.AvsApi);
    mock_table.avs_release_video_frame = &m_release_video_frame;
    mock_table.avs_copy_video_frame = &m_copy_video_frame;
    mock_table.avs_set_to_clip = &m_set_to_clip;
    mock_table.avs_release_value = &m_release_value;
    mock_table.avs_take_clip = &m_take_clip;
    mock_table.avs_release_clip = &m_release_clip;
    mock_table.avs_copy_clip = &m_copy_clip;
    mock_table.avs_get_video_info = &m_get_video_info;
    mock_table.avs_new_c_filter = &m_new_c_filter;
    mock_table.avs_get_frame = &m_get_frame;
    mock_table.avs_clip_get_error = &m_clip_get_error;
    mock_table.avs_new_video_frame_p_a = &m_new_video_frame_p_a;
    mock_table.avs_get_error = &m_get_error;
    mock_table.avs_save_string = &m_save_string;
    mock_table.avs_get_as_long = &m_get_as_long;
    mock_table.avs_get_as_float = &m_get_as_float;
    mock_table.avs_get_as_bool = &m_get_as_bool;
    mock_table.avs_get_array_size = &m_get_array_size;
    mock_table.avs_get_array_elt = &m_get_array_elt;
    mock_table.avs_make_writable = &m_make_writable;
    mock_table.avs_make_property_writable = &m_make_writable;
    avs.api.setTableForTesting(&mock_table);
    live_clips = 0;
    live_frames = 0;
    fail_alloc = false;
    writable_mode = .noop;
}

fn tearDown() !void {
    for (saved.items) |s| gpa.free(s);
    saved.clearAndFree(gpa);
    avs.api.setTableForTesting(null);
    try std.testing.expectEqual(@as(i32, 0), live_clips);
    try std.testing.expectEqual(@as(i32, 0), live_frames);
}

const test_vi: c.AVS_VideoInfo = .{
    .width = 64,
    .height = 32,
    .fps_numerator = 24,
    .fps_denominator = 1,
    .num_frames = 10,
    .pixel_type = c.AVS_CS_YV12,
    .audio_samples_per_second = 0,
    .sample_type = 0,
    .num_audio_samples = 0,
    .nchannels = 0,
    .image_type = 0,
};

fn clipValue(m: *MockClip) c.AVS_Value {
    return .{ .type = 'c', .array_size = 0, .d = .{ .clip = m } };
}
fn intValue(v: c_int) c.AVS_Value {
    return c.avs_new_value_int(v);
}

// ---------------------------------------------------------------------------
// A two-input test filter: primary child + an owned secondary clip in Data.
// ---------------------------------------------------------------------------

var deinit_calls: u32 = 0;

const Data = struct {
    other: avs.OwnedClip,
    mode: i32,

    pub fn deinit(self: *Data) void {
        deinit_calls += 1;
        self.other.deinit();
    }
};

const F = avs.Filter(Data, "TestFilter");

fn getFrame(d: *Data, ctx: *avs.FrameCtx, n: c_int) !avs.Frame {
    const a = try ctx.childFrame(n);
    defer a.release();
    const b = try ctx.getFrame(d.other.get(), n);
    defer b.release();
    return ctx.newFrame(a);
}

fn create(ctx: *avs.Create) !avs.Value {
    const clip = try ctx.clip(0, "clip");
    defer clip.release();
    const other = try ctx.clip(1, "other");
    errdefer other.release();
    const mode = try ctx.int(i32, 2, "mode", 0, 0, 3);
    const out = try F.create(ctx.env, clip, .{ .other = .{ .clip = other }, .mode = mode }, F.getFrame(getFrame), .{ .mt_mode = .nice });
    return avs.Create.returnClip(out);
}

const apply = avs.applyFn("TestFilter", create);

fn callApply(args: []c.AVS_Value) avs.Value {
    return .{ .raw = apply.?(env_ptr, c.avs_new_value_array(args.ptr, @intCast(args.len)), null) };
}

test "create success: filter owns secondary clip, everything released" {
    setUp();
    deinit_calls = 0;
    const a = newClip(test_vi);
    const b = newClip(test_vi);
    var args = [_]c.AVS_Value{ clipValue(a), clipValue(b), intValue(2) };
    const result = callApply(&args);
    try std.testing.expect(result.isClip());

    // The returned filter answers frames from both inputs.
    const filt = mc(@ptrCast(result.raw.d.clip));
    const f = m_get_frame(@ptrCast(filt), 3);
    try std.testing.expect(f != null);
    m_release_video_frame(f);

    // Script drops the arguments and the result: Data.deinit releases `other`.
    releaseClip(a);
    releaseClip(b);
    m_release_value(result.raw);
    try std.testing.expectEqual(@as(u32, 1), deinit_calls);
    try tearDown();
}

test "create failure after acquiring inputs releases them and returns a durable message" {
    setUp();
    const a = newClip(test_vi);
    const b = newClip(test_vi);
    var args = [_]c.AVS_Value{ clipValue(a), clipValue(b), intValue(7) };
    const result = callApply(&args);
    try std.testing.expect(result.isError());
    try std.testing.expectEqualStrings("TestFilter: mode value 7 is out of range [0, 3].", std.mem.span(result.raw.d.string));
    try std.testing.expectEqual(@as(i32, 1), a.refs);
    try std.testing.expectEqual(@as(i32, 1), b.refs);
    releaseClip(a);
    releaseClip(b);
    try tearDown();
}

test "create failure on a wrong-typed clip argument leaks nothing" {
    setUp();
    const a = newClip(test_vi);
    var args = [_]c.AVS_Value{ clipValue(a), intValue(1) };
    const result = callApply(&args);
    try std.testing.expect(result.isError());
    try std.testing.expectEqualStrings("TestFilter: other must be a clip.", std.mem.span(result.raw.d.string));
    releaseClip(a);
    try tearDown();
}

test "get_frame upstream failure sets fi.error and releases local frames" {
    setUp();
    const a = newClip(test_vi);
    const b = newClip(test_vi);
    var args = [_]c.AVS_Value{ clipValue(a), clipValue(b) };
    const result = callApply(&args);
    const filt = mc(@ptrCast(result.raw.d.clip));

    b.fail_frames = true; // secondary input fails after the primary frame was acquired
    try std.testing.expect(m_get_frame(@ptrCast(filt), 0) == null);
    try std.testing.expectEqualStrings("TestFilter: upstream exploded", std.mem.span(filt.filter.?.@"error"));
    try std.testing.expectEqual(@as(i32, 0), live_frames);

    b.fail_frames = false;
    fail_alloc = true; // output allocation fails after both inputs were acquired
    filt.filter.?.@"error" = null;
    try std.testing.expect(m_get_frame(@ptrCast(filt), 0) == null);
    try std.testing.expectEqualStrings("TestFilter: could not allocate a frame: mock allocation refused", std.mem.span(filt.filter.?.@"error"));
    try std.testing.expectEqual(@as(i32, 0), live_frames);

    releaseClip(a);
    releaseClip(b);
    m_release_value(result.raw);
    try tearDown();
}

// ---------------------------------------------------------------------------
// Writability contracts
// ---------------------------------------------------------------------------

test "makeWritable/makePropertyWritable: no-op, replacement and refusal" {
    setUp();
    const env: avs.Env = .init(env_ptr);
    inline for (.{ avs.Frame.makeWritable, avs.Frame.makePropertyWritable }) |make| {
        var f: avs.Frame = .{ .ptr = newFrame() };
        const orig = f.ptr;

        writable_mode = .noop;
        try make(&f, env);
        try std.testing.expectEqual(orig, f.ptr);

        writable_mode = .replace;
        try make(&f, env);
        try std.testing.expect(f.ptr != orig);
        try std.testing.expectEqual(@as(i32, 1), live_frames);

        // -1 with the pointer unchanged must be an error, and the frame
        // stays owned (released exactly once below).
        writable_mode = .refuse;
        const kept = f.ptr;
        try std.testing.expectError(error.FrameAllocationFailed, make(&f, env));
        try std.testing.expectEqual(kept, f.ptr);
        f.release();
    }
    try tearDown();
}

const PropData = struct {};
const FP = avs.Filter(PropData, "PropFilter");

fn propGetFrame(_: *PropData, ctx: *avs.FrameCtx, n: c_int) !avs.Frame {
    var f = try ctx.childFrame(n);
    errdefer f.release();
    try ctx.makePropertyWritable(&f);
    return f;
}

test "FrameCtx.makePropertyWritable failure sets fi.error and leaks nothing" {
    setUp();
    const a = newClip(test_vi);
    const clip = try FP.create(.init(env_ptr), .{ .ptr = @ptrCast(a) }, .{}, FP.getFrame(propGetFrame), .{ .mt_mode = .nice });
    const filt = mc(clip.ptr);

    writable_mode = .refuse;
    try std.testing.expect(m_get_frame(@ptrCast(filt), 0) == null);
    try std.testing.expectEqualStrings("PropFilter: could not make the frame properties writable: mock writability refused", std.mem.span(filt.filter.?.@"error"));
    try std.testing.expectEqual(@as(i32, 0), live_frames);

    writable_mode = .replace;
    const f = m_get_frame(@ptrCast(filt), 0);
    try std.testing.expect(f != null);
    m_release_video_frame(f);

    releaseClip(a);
    releaseClip(filt);
    try tearDown();
}

// ---------------------------------------------------------------------------
// Argument parsing contracts
// ---------------------------------------------------------------------------

fn testCreate(args: []c.AVS_Value) avs.Create {
    return .{ .env = .init(env_ptr), .args = .{ .raw = c.avs_new_value_array(args.ptr, @intCast(args.len)) }, .user_data = null, .name = "T" };
}

test "Create argument getters: defaults, ranges, finiteness, arrays, planes" {
    setUp();
    defer tearDown() catch unreachable;
    const nan = std.math.nan(f32);
    var arr3 = [_]c.AVS_Value{ intValue(0), intValue(2), intValue(2) };
    var arr4 = [_]c.AVS_Value{ intValue(0), intValue(1), intValue(2), intValue(3) };
    var farr = [_]c.AVS_Value{ c.avs_new_value_float(1.5), c.avs_new_value_float(nan) };
    var args = [_]c.AVS_Value{
        c.avs_void, // 0: absent
        intValue(5), // 1
        c.avs_new_value_float(nan), // 2
        c.avs_new_value_array(&arr3, 3), // 3: duplicate plane
        c.avs_new_value_array(&arr4, 4), // 4: too many
        c.avs_new_value_array(&farr, 2), // 5: nan element
        intValue(1), // 6: scalar used as a 1-element array
        c.avs_new_value_float(2.5), // 7
    };
    var ctx = testCreate(&args);

    try std.testing.expectEqual(@as(u8, 9), try ctx.int(u8, 0, "a", 9, 0, 10));
    try std.testing.expectError(error.Failed, ctx.int(u8, 0, "a", null, 0, 10));
    try std.testing.expectEqualStrings("T: a is required.", ctx.diag.message().?);
    try std.testing.expectEqual(@as(i32, 5), try ctx.int(i32, 1, "b", null, 0, 10));
    try std.testing.expectError(error.Failed, ctx.int(u2, 1, "b", null, 0, 3));
    try std.testing.expectEqualStrings("T: b value 5 is out of range [0, 3].", ctx.diag.message().?);
    // ints are accepted where floats are expected
    try std.testing.expectEqual(@as(f32, 5), try ctx.float(f32, 1, "b", null, 0, 10));
    try std.testing.expectError(error.Failed, ctx.float(f32, 2, "c", null, -1, 1));
    try std.testing.expectEqualStrings("T: c value nan is not a finite number.", ctx.diag.message().?);
    try std.testing.expectError(error.Failed, ctx.planes(3, 3, true));
    try std.testing.expectEqualStrings("T: plane specified twice.", ctx.diag.message().?);
    try std.testing.expectError(error.Failed, ctx.planes(4, 3, true));
    try std.testing.expectEqualStrings("T: plane index out of range", ctx.diag.message().?);
    try std.testing.expectEqual([4]bool{ true, true, true, false }, try ctx.planes(0, 3, true));
    try std.testing.expectEqual([4]bool{ false, true, false, false }, try ctx.planes(6, 3, true));
    var buf: [3]i32 = undefined;
    try std.testing.expectError(error.Failed, ctx.intArray(i32, 4, "d", &buf, 0, 9));
    try std.testing.expectEqualStrings("T: d has too many elements (got 4, max 3).", ctx.diag.message().?);
    try std.testing.expectError(error.Failed, ctx.perPlaneFloat(f32, 5, "e", 0, -10, 10));
    try std.testing.expectEqualStrings("T: e[1] value nan is not a finite number.", ctx.diag.message().?);
    try std.testing.expectEqual([3]f32{ 2.5, 2.5, 2.5 }, try ctx.perPlaneFloat(f32, 7, "g", 0, 0, 10));
    try std.testing.expectEqual([3]f32{ 4, 4, 4 }, try ctx.perPlaneFloat(f32, 0, "g", 4, 0, 10));
    try std.testing.expect(!try ctx.boolean(0, "h", false));
}

test "Create.named: getters by parameter name match the positional ones" {
    setUp();
    defer tearDown() catch unreachable;
    const nan = std.math.nan(f32);
    var arr3 = [_]c.AVS_Value{ intValue(0), intValue(2), intValue(2) };
    var farr = [_]c.AVS_Value{ c.avs_new_value_float(1.5), c.avs_new_value_float(nan) };
    var args = [_]c.AVS_Value{
        c.avs_void, // 0: a, absent
        intValue(5), // 1: b
        c.avs_new_value_float(nan), // 2: c
        c.avs_new_value_array(&arr3, 3), // 3: planes, duplicate plane
        c.avs_new_value_array(&farr, 2), // 4: e, nan element
        c.avs_new_value_float(2.5), // 5: g, scalar used as a 1-element array
        c.avs_new_value_bool(1), // 6: h
        c.avs_void, // 7: s, absent
    };
    var ctx = testCreate(&args);
    const a = ctx.named("[a]i[b]i[c]f[planes]i*[e]f*[g]f*[h]b[s]s");

    try std.testing.expectEqual(@as(u8, 9), try a.int(u8, "a", 9, 0, 10));
    try std.testing.expect(!a.defined("a"));
    try std.testing.expect(a.defined("b"));
    try std.testing.expectEqual(@as(?usize, 2), a.arrayLen("e"));
    try std.testing.expectError(error.Failed, a.int(u8, "a", null, 0, 10));
    try std.testing.expectEqualStrings("T: a is required.", ctx.diag.message().?);
    try std.testing.expectError(error.Failed, a.int(u2, "b", null, 0, 3));
    try std.testing.expectEqualStrings("T: b value 5 is out of range [0, 3].", ctx.diag.message().?);
    try std.testing.expectEqual(@as(?i32, null), try a.optInt(i32, "a", 0, 10));
    try std.testing.expectError(error.Failed, a.float(f32, "c", null, -1, 1));
    try std.testing.expectEqualStrings("T: c value nan is not a finite number.", ctx.diag.message().?);
    try std.testing.expectError(error.Failed, a.planes("planes", 3, true));
    try std.testing.expectEqualStrings("T: plane specified twice.", ctx.diag.message().?);
    try std.testing.expectError(error.Failed, a.perPlaneFloat(f32, "e", 0, -10, 10));
    try std.testing.expectEqualStrings("T: e[1] value nan is not a finite number.", ctx.diag.message().?);
    try std.testing.expectEqual([3]f32{ 2.5, 2.5, 2.5 }, try a.perPlaneFloat(f32, "g", 0, 0, 10));
    try std.testing.expect(try a.boolean("h", false));
    try std.testing.expectEqual(@as(?[:0]const u8, null), try a.string("s"));
    var buf: [1]f32 = undefined;
    try std.testing.expectError(error.Failed, a.floatArray(f32, "e", &buf, -10, 10));
    try std.testing.expectEqualStrings("T: e has too many elements (got 2, max 1).", ctx.diag.message().?);
}
