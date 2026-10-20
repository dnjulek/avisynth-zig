//! `Clip`: an `AVS_Clip*` handle.
//!
//! Ownership is by convention, not enforced: a `Clip` obtained from
//! `Value.takeClip`, `Clip.retain` or filter creation is an **owned**
//! reference and must be released exactly once. `FrameCtx.child()` returns a
//! **borrowed** handle (owned by the filter wrapper): never release it.
//! Plain assignment duplicates the handle without adding a reference.
//!
//! An `AVS_Clip` also carries an environment pointer and error slot. On
//! AviSynth+ <= 3.7.5 that slot is shared by concurrent requests on the same
//! clip, so under MT an error message may be attributed to another frame; the
//! success path is unaffected (fixed upstream by per-call wrappers, #519).

const std = @import("std");
const c = @import("avisynth_c");
const api = @import("api.zig");
const Frame = @import("frame.zig").Frame;

pub const Clip = struct {
    ptr: *c.AVS_Clip,

    pub const FrameError = error{UpstreamFailed};

    /// Request frame `n`. Owned result. On failure, `lastError()` holds the
    /// upstream message (read it before the next operation on this clip). [core]
    pub fn getFrame(self: Clip, n: c_int) FrameError!Frame {
        const f = api.fnPtr("avs_get_frame")(self.ptr, n) orelse return error.UpstreamFailed;
        return .{ .ptr = f };
    }

    /// Error of the last operation on this clip, or null. Host-owned. [core]
    pub fn lastError(self: Clip) ?[:0]const u8 {
        const e = api.fnPtr("avs_clip_get_error")(self.ptr) orelse return null;
        return std.mem.span(e);
    }

    /// Video info, valid while the clip is alive. [core]
    pub fn videoInfo(self: Clip) *const c.AVS_VideoInfo {
        return api.fnPtr("avs_get_video_info")(self.ptr);
    }

    /// Field parity of frame/field `n`. [core]
    pub fn parity(self: Clip, n: c_int) bool {
        return api.fnPtr("avs_get_parity")(self.ptr, n) > 0;
    }

    /// New owned reference to the same clip. [core]
    pub fn retain(self: Clip) Clip {
        return .{ .ptr = api.fnPtr("avs_copy_clip")(self.ptr).? };
    }

    /// Release an owned reference. [core]
    pub fn release(self: Clip) void {
        api.fnPtr("avs_release_clip")(self.ptr);
    }
};

/// Optional owned clip slot for filter state: releases on `deinit` and makes
/// double release impossible through this slot.
pub const OwnedClip = struct {
    clip: ?Clip = null,

    pub fn deinit(self: *OwnedClip) void {
        if (self.clip) |cl| cl.release();
        self.clip = null;
    }

    pub fn get(self: OwnedClip) Clip {
        return self.clip.?;
    }
};
