#!/usr/bin/env python3
"""N5 G1a: the signatures in the code blocks of a doc (MODULES.md, API.md) get the nested errors, as nest_g1a.py
does for the platform. A type block of `Request` or `Body`, and the functions of FLAT, keep the flat errors.
Usage: nest_g1a_docs.py <file.md>"""
import re, sys, os

# The functions of nest_g1a.py, without its command line part.
src = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "nest_g1a.py")).read().split("args = sys.argv[1:]")[0]
nest = {}
exec(src, nest)

FLAT_TYPES = {"Request", "Body", "Writer"}
FLAT = {("Self", "accept!"), ("Self", "accept_with!"), ("Self", "set_auto_response!"), ("Message", "json"),
        ("WebSocket", "json"), ("Request", "post_json")}

type_re = re.compile(r"^(\t*)([A-Z][A-Za-z0-9]*)(\([^)]*\))? *(::|:=)")
sig_re = re.compile(r"^(\t*)([a-z_0-9]+!?) : (.+)$")


def split_comment(s):
    depth = 0
    for i, ch in enumerate(s):
        if ch in "([{": depth += 1
        if ch in ")]}": depth -= 1
        if depth == 0 and ch == "#" and i > 0 and s[i - 1] == " ":
            j = i
            while j > 0 and s[j - 1] == " ": j -= 1
            return s[:j], s[j:]
    return s, ""


path = sys.argv[1]
lines = open(path).read().split("\n")
in_code, stack, count = False, [], 0
for i, line in enumerate(lines):
    if line.startswith("```"):
        in_code = not in_code
        stack = []
        continue
    if not in_code: continue
    m = type_re.match(line)
    if m:
        depth = len(m.group(1))
        stack = stack[:depth] + [m.group(2)]
        continue
    m = sig_re.match(line)
    if not m: continue
    depth = len(m.group(1))
    types = stack[:depth]
    if any(t in FLAT_TYPES for t in types): continue
    if types and (types[-1], m.group(2)) in FLAT: continue
    typ, comment = split_comment(m.group(3))
    new = nest["rewrite_type"](typ.rstrip())
    if new is None: continue
    pad = typ[len(typ.rstrip()):]
    lines[i] = m.group(1) + m.group(2) + " : " + new + pad + comment
    count += 1
open(path, "w").write("\n".join(lines))
print("%s: %d signatures" % (path, count))
