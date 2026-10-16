#!/usr/bin/env python3
"""Revert checks (org rule): each new test must fail when its change is reverted.
For each row: patch the real source, run the named zig test (and the Node harness, when the row has one),
then restore the file. Prints one table. Run from anywhere: python3 research/native/revert-check.py [ROW ...]
"""
import os, subprocess, sys, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, '..', '..'))
ZIG = os.environ.get('ZIG', '/home/george/.local/zig/zig-x86_64-linux-0.17.0/zig')
ENV = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=os.path.join(HERE, '.cache/global'))
Z = 'hostlib/native/zstd.zig'
N = 'hostlib/native/native.zig'

# name, file, old text, new text, zig test filter, node check (True: also build wasm and run run.mjs), the rule
ROWS = [
    ('limit', Z, 'pub fn decode(a: Allocator, input: []const u8, max_out: usize) Error![]u8 {',
     'pub fn decode(a: Allocator, input: []const u8, max_out_arg: usize) Error![]u8 {\n    _ = max_out_arg;\n    const max_out: usize = 1 << 30; // reverted: no limit',
     'zstd_decode', True, 'R-Z3, R-Z4, W2'),
    ('window-not-allocated', Z, '                d.window_len = 0;\n', '', 'window of the frame', False, 'R-Z5'),
    ('owner-check', N, '    if (s.owner != owner) return error.WrongTask;\n', '    _ = owner; // reverted\n', 'handles: a handle of another task', True, 'R-N1, W3'),
    ('generation', N, 'if (!s.used or s.gen != handle >> 8) return', 'if (!s.used) return', 'closed, wrong kind, wild, reused', False, 'R-N2'),
    ('no-task', N, '    if (owner == 0) return error.NoTask;\n', '', 'owner 0 gets no handle', False, 'R-N6'),
    ('per-task-cap', N, '    if (mine >= MAX_PER_TASK or free == null) return', '    if (free == null) return', 'at most 16 handles', False, 'R-N4'),
    ('end-task-free', N, '        if (mode == .free) destroy(a, s);\n', '        _ = a;\n        _ = mode; // reverted\n', 'endTask frees', False, 'R-N3'),
    ('end-task-hook', N, '        close(s);\n    };\n}\n\nfn destroy', '    };\n}\n\nfn destroy', 'endTask frees', True, 'R-N3, W6 (slots stay)'),
    ('stream-pending', Z, '                        @memcpy(s.pend[0..rest.len], rest);\n                        s.pend_len = rest.len;\n',
     '                        s.pend_len = 0; // reverted: the start of a unit is dropped\n', 'chunk sizes', True, 'R-Z8, W4'),
    ('stream-lazy-buffer', Z, '@min(s.buf_max, BLOCK_MAX * 2)', 's.buf_max', 'small output from an 8 MB window', False, 'R-Z11'),
    ('push-limit', Z, '            if (out.items.len > s.push_limit) return s.fail(error.OutputLimit);\n', '', 'output limit of a push', False, 'R-Z12'),
    ('window-limit', Z, '        if (h.window > s.window_limit) return error.WindowTooLarge;\n', '', 'the window limit', False, 'R-Z10'),
    ('blake3-state', N, '    @as(*T, @ptrFromInt(s.ptr)).update(in[4..]);\n',
     '    @as(*T, @ptrFromInt(s.ptr)).* = T.init(.{}); // reverted: no state across chunks\n    @as(*T, @ptrFromInt(s.ptr)).update(in[4..]);\n', 'chunked digests', True, 'R-H1, R-H2, W5'),
    ('oom-slot-last', N, [
        ('    const out = try a.alloc(u8, 4);\n    errdefer a.free(out);\n    const h = try a.create(T);\n    errdefer a.destroy(h);\n    h.* = init;\n    std.mem.writeInt(u32, out[0..4], try insert(owner, kind, @intFromPtr(h)), .little);',
         '    const h = try a.create(T);\n    errdefer a.destroy(h);\n    h.* = init;\n    const hd = try insert(owner, kind, @intFromPtr(h));\n    const out = try a.alloc(u8, 4);\n    std.mem.writeInt(u32, out[0..4], hd, .little);'),
        ('            const out = try a.alloc(u8, 4);\n            errdefer a.free(out);\n            const s = try zstd.Stream.open(a, window, push);\n            errdefer s.deinit();\n            std.mem.writeInt(u32, out[0..4], try insert(owner, .zstd, @intFromPtr(s)), .little);',
         '            const s = try zstd.Stream.open(a, window, push);\n            errdefer s.deinit();\n            const hd = try insert(owner, .zstd, @intFromPtr(s));\n            const out = try a.alloc(u8, 4);\n            std.mem.writeInt(u32, out[0..4], hd, .little);'),
    ], None, 'out of memory is status 4', False, 'R-N5'),
]

def run(cmd, **kw):
    return subprocess.run(cmd, cwd=REPO, env=ENV, capture_output=True, text=True, **kw)

def zig_test(filt):
    r = run([ZIG, 'test', 'hostlib/native/native_test.zig', '--cache-dir', os.path.join(HERE, '.cache/local'), '--test-filter', filt])
    out = r.stdout + r.stderr
    fails = [l.split('...')[0].split('test.')[-1] for l in out.splitlines() if 'FAIL' in l or 'panic' in l or 'Segmentation' in l or 'leaked' in l]
    return r.returncode, out, fails

def node_run():
    b = run([os.path.join(HERE, 'harness/build.sh')])
    if b.returncode: return None, b.stderr[-300:]
    r = run(['node', os.path.join(HERE, 'harness/run.mjs')])
    return r.returncode, [l for l in r.stdout.splitlines() if l.startswith('FAIL')]

want = sys.argv[1:]
print('| Revert | Rule | zig test (reverted) | Node (reverted) | After restore |')
print('| --- | --- | --- | --- | --- |')
bad = 0
for name, f, old, new, filt, node, rule in ROWS:
    if want and name not in want: continue
    path = os.path.join(REPO, f)
    bak = os.path.join(HERE, '.cache', os.path.basename(f) + '.bak')
    shutil.copy(path, bak)
    try:
        src = open(path).read()
        for o, n_ in (old if isinstance(old, list) else [(old, new)]):
            assert o in src, f'{name}: old text not found'
            src = src.replace(o, n_, 1)
        open(path, 'w').write(src)
        rc, out, fails = zig_test(filt)
        zres = 'FAIL as wanted' if rc != 0 else 'PASS (the test misses the revert)'
        if rc == 0: bad += 1
        if rc != 0 and not fails:
            zres = 'BUILD ERROR (invalid check)'
            bad += 1
        nres = '-'
        if node:
            nrc, nf = node_run()
            if nrc is None:
                nres = 'BUILD ERROR (invalid check)'; bad += 1
            else:
                nres = ('FAIL as wanted: %d checks' % len(nf)) if nrc else 'PASS (missed)'
                if not nrc: bad += 1
    finally:
        shutil.copy(bak, path)
    rc2, _, _ = zig_test(filt)
    print(f'| {name} | {rule} | {zres} | {nres} | {"PASS" if rc2 == 0 else "FAIL"} |')
    sys.stdout.flush()
if any(n for n in [1]) and not want:
    pass
# The wasm build must match the restored source.
run([os.path.join(HERE, 'harness/build.sh')])
sys.exit(1 if bad else 0)
