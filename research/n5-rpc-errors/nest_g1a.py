#!/usr/bin/env python3
"""N5 G1a, step 1 of the real migration: rewrite the error unions in the signatures of platform modules.
`Try(ok, [A, KvErr(Io.Thrown), BadData(Str)])` and `Io(ok, [...])` become `[A, Infra([KvErr(Io.Thrown), BadData(Str)])]`.
`--bodies` also wraps the tags that the bodies make (`Err(KvErr(t))`, `|t| StorageErr(t)`) in `Infra(...)`. The rest
of the bodies (helpers, match patterns, flat functions) is changed by hand after this step (roc check shows each one).
Usage: nest_g1a.py [--bodies] <platform dir> <module> ..."""
import re, sys

INFRA = ["StorageErr", "SqlErr", "Constraint", "D1Err", "KvErr", "R2Err", "CacheErr", "QueueErr", "ObjectErr",
         "ServiceErr", "RpcErr", "HttpErr", "Network", "SocketErr", "BodyErr", "CryptoErr", "AiErr", "VectorizeErr",
         "WorkflowsErr", "EmailErr", "AnalyticsErr", "AssetsErr", "SecretsStoreErr", "LimitErr", "BadData",
         "InvalidJson", "MissingEnv", "TooLarge", "TimedOut"]

# Functions that keep flat errors: bad input of the app (request parse, argument limits).
FLAT = {
    "Object": {"accept!", "accept_with!", "accept_tags!", "set_auto_response!"},
    "WebSocket": {"json"},
}


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


def last_arrow(s):
    """The index after the last top-level `->` or `=>`."""
    depth, best = 0, -1
    for i, ch in enumerate(s):
        if ch in "([{": depth += 1
        if ch in ")]}": depth -= 1
        if depth == 0 and s[i:i + 2] in ("->", "=>"): best = i + 2
    return best


def tag_name(t): return t.split("(")[0]


def nest_union(err):
    if not err.startswith("[") or ".." in err: return None
    tags = split_top(err[1:-1])
    infra = [t for t in tags if tag_name(t) in INFRA]
    if not infra: return None
    other = [t for t in tags if tag_name(t) not in INFRA]
    return "[" + ", ".join(other + ["Infra([" + ", ".join(infra) + "])"]) + "]"


def rewrite_type(typ):
    a = last_arrow(typ)
    if a < 0: return None
    head, ret = typ[:a], typ[a:]
    lead = len(ret) - len(ret.lstrip())
    r = ret.lstrip()
    for ctor in ("Try(", "Io("):
        if r.startswith(ctor):
            close = match_close(r, len(ctor) - 1)
            args = split_top(r[len(ctor):close])
            if len(args) != 2: return None
            n = nest_union(args[1])
            if n is None: return None
            return head + ret[:lead] + ctor + args[0] + ", " + n + ")" + r[close + 1:]
    return None


TAG_RE = re.compile(r"(Err\(|\|[a-z_]+\| )(" + "|".join(INFRA) + r")\b")


def wrap_expr(s):
    """`Err(KvErr(t))` -> `Err(Infra(KvErr(t)))`, `|t| StorageErr(t)` -> `|t| Infra(StorageErr(t))`."""
    out, i = "", 0
    while True:
        m = TAG_RE.search(s, i)
        if not m:
            return out + s[i:]
        start = m.start(2)
        end = m.end(2)
        if end < len(s) and s[end] == "(":
            end = match_close(s, end) + 1
        out += s[i:start] + "Infra(" + s[start:end] + ")"
        i = end


def rewrite(path, module, bodies):
    sig_re = re.compile(r"^(\t*)([a-z_0-9]+!?) : (.+)$")
    lines = open(path).read().split("\n")
    count = 0
    for i, line in enumerate(lines):
        m = sig_re.match(line)
        if m:
            if m.group(2) in FLAT.get(module, set()): continue
            new = rewrite_type(m.group(3))
            if new is None: continue
            lines[i] = m.group(1) + m.group(2) + " : " + new
            count += 1
        elif bodies and not line.lstrip().startswith("#") and not line.lstrip().startswith("expect"):
            # Only the expression side of a match arm: the pattern side is fixed by hand.
            k = line.find(" => ")
            lines[i] = line[:k + 4] + wrap_expr(line[k + 4:]) if k >= 0 else wrap_expr(line)
    open(path, "w").write("\n".join(lines))
    print("%s: %d signatures" % (module, count))


args = sys.argv[1:]
bodies = args[0] == "--bodies"
if bodies: args = args[1:]
for mod in args[1:]:
    rewrite("%s/%s.roc" % (args[0], mod), mod, bodies)
