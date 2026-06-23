//! Parent/child lifecycle links for zones.
//!
//! Each zone core embeds a `Header`. A child attaches to its parent at init and
//! detaches at deinit, maintaining the parent's live-child count so a parent
//! `deinit` can refuse (`.live_children`) while children are still alive. The
//! count is atomic; the parent pointer and control allocator are set once.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// Lifecycle links embedded in a zone core.
pub const Header = struct {
    /// The allocator the owning core was created on; also where it is freed.
    control_allocator: Allocator,
    /// Parent header, or null for a root zone.
    parent: ?*Header,
    /// Number of children currently attached to this header.
    live_children: std.atomic.Value(usize) = .init(0),
};

/// Initialize `header` in place with its control allocator and optional parent,
/// starting with zero live children. Does not attach to the parent -- call
/// `attachToParent` once the child becomes live.
pub fn init(header: *Header, control_allocator: Allocator, parent: ?*Header) void {
    header.* = .{
        .control_allocator = control_allocator,
        .parent = parent,
        .live_children = .init(0),
    };
}

/// Increment the parent's live-child count, if there is a parent. Call once,
/// after `init`, when the child becomes live.
pub fn attachToParent(header: *Header) void {
    if (header.parent) |parent| {
        _ = parent.live_children.fetchAdd(1, .acq_rel);
    }
}

/// Decrement the parent's live-child count, if there is a parent. Call once,
/// when the child is torn down.
pub fn detachFromParent(header: *Header) void {
    if (header.parent) |parent| {
        _ = parent.live_children.fetchSub(1, .acq_rel);
    }
}

/// Whether any child is still attached. A parent uses this to return
/// `.live_children` from `deinit` instead of freeing out from under a child.
pub fn hasLiveChildren(header: *const Header) bool {
    return header.live_children.load(.acquire) != 0;
}

test "child attach and detach updates parent live child count" {
    var parent: Header = undefined;
    init(&parent, std.testing.allocator, null);

    var child: Header = undefined;
    init(&child, std.testing.allocator, &parent);

    try std.testing.expect(!hasLiveChildren(&parent));
    attachToParent(&child);
    try std.testing.expect(hasLiveChildren(&parent));
    detachFromParent(&child);
    try std.testing.expect(!hasLiveChildren(&parent));
}
