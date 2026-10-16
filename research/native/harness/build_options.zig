// The build options of hostlib as the production host sets them (build.zig of the repo), without the bench exports.
pub const small_buffers = false;
pub const bench = false;
pub const track_live = true;
pub const owner_tag = true;
pub const ask_js = true;
