"""Make the build copy of one allocator version: add the peak probes, and stubs
for the harness exports that the version does not have.
python3 probe.py <version.zig> <out alloc.zig>"""
import sys

src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()

PROBE_VARS = '''pub var CHUNKS_USED: usize = 0;
var PEAK_USED: usize = 0;
var LIVE_PEAK: usize = 0;
var LARGE_HIST: [8]u32 = @splat(0);
export fn heap_peak() usize {
    return PEAK_USED << CH_SHIFT;
}
export fn live_peak() usize {
    return LIVE_PEAK;
}
export fn large_hist(i: usize) u32 {
    return LARGE_HIST[i];
}
export fn peak_reset() void {
    PEAK_USED = 0;
    LIVE_PEAK = 0;
    LARGE_HIST = @splat(0);
}'''
ALLOC_LINE = '''    const cap = rdUsize(span);
    t.live +%= cap;
    if (TRACK_LIVE) LIVE_BYTES +%= cap;'''
PROBE_LINE = ALLOC_LINE + '''
    if (LIVE_BYTES > LIVE_PEAK) LIVE_PEAK = LIVE_BYTES;
    if (CHUNKS_USED > PEAK_USED) PEAK_USED = CHUNKS_USED;
    if (total > 4096) LARGE_HIST[@min(7, std.math.log2_int(usize, total) - 12)] += 1;'''

# Peak probes: only versions with page accounting (v1 and later). v6 and later
# mark the place with "// probe: alloc" (the block capacity is in `cap`).
MARK = '    // probe: alloc'
if 'pub var CHUNKS_USED: usize = 0;' in s and s.count(MARK) == 1:
    s = s.replace('pub var CHUNKS_USED: usize = 0;', PROBE_VARS, 1)
    s = s.replace(MARK, PROBE_LINE.split('\n', 3)[3].replace('total', 'cap'), 1)
elif 'pub var CHUNKS_USED: usize = 0;' in s and s.count(ALLOC_LINE) == 1:
    s = s.replace('pub var CHUNKS_USED: usize = 0;', PROBE_VARS, 1)
    s = s.replace(ALLOC_LINE, PROBE_LINE, 1)

# Stubs: the platform exports these names from every build.
STUBS = {
    'heap_grows': 'export fn heap_grows() usize {\n    return 0;\n}',
    'set_grow_chunks': 'export fn set_grow_chunks(n: usize) void {\n    _ = n;\n}',
    'set_large_min_run': 'export fn set_large_min_run(n: usize) void {\n    _ = n;\n}',
    'heap_peak': 'export fn heap_peak() usize {\n    return 0;\n}',
    'live_peak': 'export fn live_peak() usize {\n    return 0;\n}',
    'large_hist': 'export fn large_hist(i: usize) u32 {\n    _ = i;\n    return 0;\n}',
    'peak_reset': 'export fn peak_reset() void {}',
    'set_large_steps': 'export fn set_large_steps(n: u8) void {\n    _ = n;\n}',
    'set_small_steps': 'export fn set_small_steps(n: u8) void {\n    _ = n;\n}',
    'set_place': 'export fn set_place(m: u8) void {\n    _ = m;\n}',
    'set_free_mark': 'export fn set_free_mark(k: usize) void {\n    _ = k;\n}',
    'free_mark': 'export fn free_mark() usize {\n    return 0;\n}',
    'double_frees': 'export fn double_frees() u32 {\n    return 0;\n}',
    'mark_false': 'export fn mark_false() u32 {\n    return 0;\n}',
}
missing = [k for k in STUBS if f'export fn {k}(' not in s]
if missing:
    s += '\n// ---------------------------------------------------------------- harness stubs\n\n' + '\n'.join(STUBS[k] for k in missing) + '\n'
# Trace build (env TRACE=1): each top-level API call goes to the JS import `js_trace`.
# scripts/trace.mjs records it; replay/ runs the record against each version.
import os
if os.environ.get('TRACE') == '1':
    for name in ['hostAlloc', 'hostDealloc', 'hostRealloc', 'adopt', 'taskEnd', 'sumTask']:
        s = s.replace(f'pub fn {name}(', f'fn {name}0(', 1)
    s += '''
// ---------------------------------------------------------------- trace (TRACE=1)

extern "env" fn js_trace(op: u32, owner: usize, a: usize, b: usize, c: usize) void;
var TRACE_DEPTH: u32 = 0;
pub fn hostAlloc(length: usize, alignment: usize) usize {
    TRACE_DEPTH += 1;
    const p = hostAlloc0(length, alignment);
    TRACE_DEPTH -= 1;
    if (TRACE_DEPTH == 0) js_trace(1 | (@as(u32, @intCast(alignment)) << 8), OWNER, 0, length, p);
    return p;
}
pub fn hostDealloc(ptr: usize) void {
    if (TRACE_DEPTH == 0) js_trace(2, OWNER, ptr, 0, 0);
    TRACE_DEPTH += 1;
    hostDealloc0(ptr);
    TRACE_DEPTH -= 1;
}
pub fn hostRealloc(ptr: usize, new_length: usize, alignment: usize) usize {
    TRACE_DEPTH += 1;
    const p = hostRealloc0(ptr, new_length, alignment);
    TRACE_DEPTH -= 1;
    if (TRACE_DEPTH == 0) js_trace(3 | (@as(u32, @intCast(alignment)) << 8), OWNER, ptr, new_length, p);
    return p;
}
pub fn adopt(ptr: usize) void {
    js_trace(6, OWNER, ptr, 0, 0);
    adopt0(ptr);
}
pub fn taskEnd(owner: usize) usize {
    js_trace(4, owner, 0, 0, 0);
    return taskEnd0(owner);
}
pub fn sumTask(owner: usize) u64 {
    js_trace(5, owner, 0, 0, 0);
    return sumTask0(owner);
}
'''
open(dst, 'w').write(s)
