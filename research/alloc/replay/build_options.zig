//! Replay stub of the build options of harness/build.zig.
pub const small_buffers = false;
pub const ch_shift: u8 = 12;
pub const track_live = true;
pub const owner_tag = true;
// Options of the platform build (hostlib/alloc.zig, the "port" replay).
pub const bench = false;
pub const trace = false;
pub const ask_js = false;
