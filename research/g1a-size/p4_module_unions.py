#!/usr/bin/env python3
"""Prototype P4: one shared closed payload union for each platform module.
Usage: p4_module_unions.py <platform dir> <Module>...
In each Module.roc, every `Infra([...])` in a type annotation becomes `Infra(<Module>Infra)`, and the file gets
`<Module>Infra : [union of all the payloads of that file]` as a top-level alias."""
import re, sys
plat = sys.argv[1]
for mod in sys.argv[2:]:
    p = f"{plat}/{mod}.roc"
    s = open(p).read()
    tags = []
    for m in re.finditer(r"Infra\(\[([^\]]*)\]\)", s):
        for t in re.findall(r"[A-Z]\w*(?:\((?:[^()]|\([^()]*\))*\))?", m.group(1)):
            if t not in tags: tags.append(t)
    name = f"{mod}Infra"
    s = re.sub(r"Infra\(\[[^\]]*\]\)", f"Infra({name})", s)
    alias = f"{name} : [{', '.join(tags)}]\n\n"
    # the alias goes before the first line that starts the type module (`Mod ... ::` or `Mod :: ...`)
    m = re.search(rf"^{mod}\b.*::", s, re.M)
    assert m, mod
    s = s[:m.start()] + alias + s[m.start():]
    open(p, "w").write(s)
    print(mod, "tags:", len(tags), tags)
