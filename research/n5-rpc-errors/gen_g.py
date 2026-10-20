#!/usr/bin/env python3
"""Option G1a in a copy of the platform: each public `!` function whose error union has infrastructure tags gives
them nested, `Infra([<its own tags>])`. The old function is renamed `<name>_flat!`, and the new one is
`a0.<name>_flat!(a1, ...).map_err(nest_k)` with a generated `nest_k`. A real implementation writes the nested tags
in the bodies; the extra `map_err` makes the prototype wasm a little larger, not smaller.
Usage: gen_g.py <platform copy dir> <module> ..."""
import os, re, sys

# G0 (control): NEST_IDENTITY=1 makes the same wrappers with the flat error, to measure the wrapper cost alone.
IDENTITY = os.environ.get("NEST_IDENTITY") == "1"

INFRA = ["StorageErr", "SqlErr", "Constraint", "D1Err", "KvErr", "R2Err", "CacheErr", "QueueErr", "ObjectErr",
         "ServiceErr", "RpcErr", "HttpErr", "Network", "SocketErr", "BodyErr", "CryptoErr", "AiErr", "VectorizeErr",
         "WorkflowsErr", "EmailErr", "AnalyticsErr", "AssetsErr", "SecretsStoreErr", "LimitErr", "BadData",
         "InvalidJson", "MissingEnv", "TooLarge", "TimedOut"]

def split_top(s, sep=","):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([{": depth += 1
        if ch in ")]}": depth -= 1
        if ch == sep and depth == 0:
            out.append(cur.strip()); cur = ""
        else:
            cur += ch
    if cur.strip(): out.append(cur.strip())
    return out

def match_close(s, i):
    depth = 0
    for j in range(i, len(s)):
        if s[j] in "([{": depth += 1
        if s[j] in ")]}":
            depth -= 1
            if depth == 0: return j
    raise ValueError(s)

def tag_name(t): return t.split("(")[0]
def tag_arity(t): return 0 if "(" not in t else len(split_top(t[t.index("(") + 1:-1]))

def rewrite(path, module):
    lines = open(path).read().split("\n")
    sig_re = re.compile(r"^(\t+)([a-z_0-9]+!) : (.+)$")
    found, nests = [], {}
    for idx, line in enumerate(lines):
        m = sig_re.match(line)
        if not m or " => Try(" not in m.group(3): continue
        indent, name, typ = m.groups()
        args_s, rest = typ.split(" => ", 1)
        if not rest.startswith("Try("): continue
        close = match_close(rest, 3)
        ok, err = split_top(rest[4:close])
        where = rest[close + 1:]
        if not err.startswith("["): continue
        tags = split_top(err[1:-1])
        infra = [t for t in tags if tag_name(t) in INFRA]
        if not infra: continue
        other = [t for t in tags if tag_name(t) not in INFRA]
        nested = err if IDENTITY else "[" + ", ".join(other + ["Infra([" + ", ".join(infra) + "])"]) + "]"
        if err not in nests: nests[err] = (len(nests), tags, nested)
        found.append((idx, indent, name, args_s, ok, err, nested, where))
    names = {f[2] for f in found}
    text = "\n".join(lines)
    for n in names:  # calls inside the module go to the flat function
        text = re.sub(r"(\b[a-z_][A-Za-z0-9_]*|[)\]])\." + re.escape(n) + r"\(", r"\1." + n[:-1] + "_flat!(", text)
    lines = text.split("\n")
    for (idx, indent, name, args_s, ok, err, nested, where) in sorted(found, reverse=True):
        flat = name[:-1] + "_flat!"
        lines[idx] = lines[idx].replace(indent + name + " : ", indent + flat + " : ", 1)
        for j in range(idx + 1, min(idx + 4, len(lines))):
            if lines[j].startswith(indent + name + " = "):
                lines[j] = lines[j].replace(indent + name + " = ", indent + flat + " = ", 1); break
        else: raise ValueError(name)
        n_args = len(split_top(args_s))
        ps = ["a%d" % i for i in range(n_args)]
        k = nests[err][0]
        call = "%s.%s(%s)" % (ps[0], flat, ", ".join(ps[1:]))
        new = [indent + "%s : %s => Try(%s, %s)%s" % (name, args_s, ok, nested, where),
               indent + "%s = |%s| %s.map_err(nest_%d)" % (name, ", ".join(ps), call, k), ""]
        # the doc comment above the annotation stays above the new function
        lines[idx:idx] = new
    out = ["", "# ---- Option G1a (research/n5-rpc-errors/gen_g.py): the nested errors ----"]
    for err, (k, tags, nested) in nests.items():
        out.append("nest_%d : %s -> %s" % (k, err, nested))
        out.append("nest_%d = |e| match e {" % k)
        for t in tags:
            n, a = tag_name(t), tag_arity(t)
            pat = n if a == 0 else "%s(%s)" % (n, ", ".join("p%d" % i for i in range(a)))
            out.append("\t%s => %s" % (pat, "Infra(%s)" % pat if n in INFRA and not IDENTITY else pat))
        out.append("}")
        out.append("")
    open(path, "w").write("\n".join(lines).rstrip("\n") + "\n" + "\n".join(out))
    print("%s: %d functions, %d error unions" % (module, len(found), len(nests)))

d = sys.argv[1]
for mod in sys.argv[2:]:
    rewrite("%s/%s.roc" % (d, mod), mod)
