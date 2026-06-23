//! Child-zone configuration: the comptime argument to `Parent.subzone(...)`.
//!
//! A subzone overrides only what it sets. The optional fields inherit the
//! parent's value when left `null`, so a child opts into a different budget or
//! thread-safety without restating the parent's whole config. The subzone's
//! effective mode is still clamped to the parent's (see `policy.clampMode`).

const SubzoneConfig = @This();

/// Trailing segment of the subzone's path. The full scope path is the parent's
/// path joined with this `name` by '/'. Same validation as a root zone name.
name: []const u8,
/// Soft budget in bytes for this subzone (0 = no budget tracking). Not inherited
/// from the parent.
budget: usize = 0,
/// Hard ceiling in bytes for this subzone (0 = unlimited). Independent of the
/// parent's hardcap.
hardcap: usize = 0,
/// Per-frame tracking override; `null` inherits the parent's setting.
frame_tracking: ?bool = null,
/// Tracy override; `null` inherits the parent's setting.
tracy: ?bool = null,
/// Thread-safety override; `null` inherits the parent's setting.
thread_safe: ?bool = null,
