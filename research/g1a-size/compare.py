#!/usr/bin/env python3
"""Usage: compare.py base.tsv new.tsv [N]. The tsv files come from wasmfuncs.mjs (roc build --debug).
Functions with the same name (a hash of the code) are matched. The others are paired by size rank (a heuristic:
the big functions are mega functions with inlined code, and their hash changes with any change)."""
import sys
def load(f):
    d = {}
    for l in open(f):
        i, s, n, t, k = (l.rstrip('\n').split('\t') + [''] * 5)[:5]
        d[n or 'f' + i] = (int(s), int(t or 0), k)
    return d
b, g = load(sys.argv[1]), load(sys.argv[2]); N = int(sys.argv[3]) if len(sys.argv) > 3 else 8
# roc_tail_driver.N is a counter, not a hash of the code: it is not a match
common = {k for k in set(b) & set(g) if not k.startswith('roc_tail_driver')}
print(f"functions: base {len(b)}, new {len(g)}, same name {len(common)}")
print(f"code bytes: base {sum(v[0] for v in b.values()):,}, new {sum(v[0] for v in g.values()):,}")
print(f"same name: base {sum(b[k][0] for k in common):,}, new {sum(g[k][0] for k in common):,}")
ub = sorted((k for k in b if k not in common), key=lambda k: -b[k][0])
ug = sorted((k for k in g if k not in common), key=lambda k: -g[k][0])
print(f"other: base {sum(b[k][0] for k in ub):,} in {len(ub)} functions, new {sum(g[k][0] for k in ug):,} in {len(ug)}")
rows = []
for i in range(max(len(ub), len(ug))):
    sb = b[ub[i]][0] if i < len(ub) else 0
    gk = ug[i] if i < len(ug) else None
    sg = g[gk][0] if gk else 0
    rows.append((sg - sb, sb, sg, g[gk][1] if gk else 0, g[gk][2] if gk else ''))
rows.sort(reverse=True)
print("rank-paired unmatched functions, the largest growth: delta, base bytes, new bytes, tags, kind")
for r in rows[:N]: print(*r, sep='\t')
print("same-name functions (equal hash), the largest growth:")
for k in sorted(common, key=lambda k: b[k][0] - g[k][0])[:5]: print(g[k][0] - b[k][0], b[k][0], g[k][0], g[k][1], g[k][2], sep='\t')
print("functions with kind (new):")
for k, v in sorted(g.items(), key=lambda kv: -kv[1][0]):
    if v[2]: print(v[0], v[1], v[2], 'same hash in base' if k in common else 'not in base')
