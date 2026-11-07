# The mutations of research/alloc/mut/run.sh: name -> (text of hostlib/alloc.zig, the mutated text).
import sys
M = {
    # 1. No double-free check on the short path of a small free.
    'dfree': ('    if (rdUsize(p) == FREE_MARK and isDoubleFree(h, p)) return;\n', ''),
    # 2. The slow path of a small free only for an empty page: a page that was full is not put back in its avail list.
    'slow': ('    if (live == 0 or U_INAV[h] == 0) smallFreeSlow(h);', '    if (live == 0) smallFreeSlow(h);'),
    # 3. The fused free skips mayFree for small blocks.
    'mayfree': ('        if (k == KIND_SMALL and mayFree(u)) {', '        if (k == KIND_SMALL) {'),
    # 4. A new owner takes its home slot even when another task has it.
    'home': ('    var free_slot: usize = if (SLOT_OWNER[home] == 0) home else 0;', '    var free_slot: usize = home;'),
    # 5. The small realloc thinks the whole class is free after ptr (no offset of ptr in the block).
    'usable': ('        const usable = p + CLASSES[class] - ptr;', '        const usable = CLASSES[class];'),
    # 6. The range compare of the fused free accepts the unit at POOL_HI. Not caught, and no harm: that unit is never
    #    a small or a large unit, so the free is a miss as before.
    'range': ('    if (u -% POOL_LO < POOL_HI -% POOL_LO) {', '    if (u -% POOL_LO <= POOL_HI -% POOL_LO) {'),
}
name, path = sys.argv[1], sys.argv[2]
a, b = M[name]
s = open(path).read()
assert s.count(a) == 1, f'{name}: text not found once'
open(path, 'w').write(s.replace(a, b))
