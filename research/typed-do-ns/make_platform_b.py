#!/usr/bin/env python3
"""Make research/typed-do-ns/platform-b/: a copy of platform/ with option B (the namespace and the stub carry an
interface record of Rpc values, and `call` takes a function that picks one field). `Rpc` and the class do not change.
Run from the submodule root. The copy is not in git (.gitignore)."""
import re, shutil, sys

D = "research/typed-do-ns/platform-b"
shutil.rmtree(D, ignore_errors=True)
shutil.copytree("platform", D)


def edit(name, pairs):
    p = f"{D}/{name}.roc"
    s = open(p).read()
    for old, new in pairs:
        if old not in s:
            sys.exit(f"{name}: not found: {old[:80]}")
        s = s.replace(old, new)
    open(p, "w").write(s)


p = f"{D}/Object.roc"
s = open(p).read()
pairs = [
    ("Object :: { namespace : Str, jurisdiction : Str, target : [Named(Str), Id(Str)], location_hint : Str }.{",
     "Object(r) :: { namespace : Str, jurisdiction : Str, target : [Named(Str), Id(Str)], location_hint : Str, iface : r }.{"),
    ("namespace : Str, { class : Object.Class, script ?: Str } -> Object.Namespace\n",
     "namespace : Str, { class : Object.Class, iface : r, script ?: Str } -> Object.Namespace(r)\n"),
    ("Object.Namespace.{ binding, jurisdiction: \"\", class: opts.class.name, script: opts.?script ?? \"\" }",
     "Object.Namespace.{ binding, jurisdiction: \"\", class: opts.class.name, script: opts.?script ?? \"\", iface: opts.iface }"),
    ("namespace_remote : Str, { class : Str, script : Str } -> Object.Namespace\n",
     "namespace_remote : Str, { iface : r, class : Str, script : Str } -> Object.Namespace(r)\n"),
    ("Object.Namespace.{ binding, jurisdiction: \"\", class: opts.class, script: opts.script }",
     "Object.Namespace.{ binding, jurisdiction: \"\", class: opts.class, script: opts.script, iface: opts.iface }"),
    ("Namespace := { binding : Str, jurisdiction : Str, class : Str, script : Str }.{",
     "Namespace(r) := { binding : Str, jurisdiction : Str, class : Str, script : Str, iface : r }.{"),
    ("\tcall : Object, Rpc(arg, ret, err), arg -> Io(",
     "\t## Option B: `pick` takes the interface record of the namespace and gives one of its methods (`|r| r.open`).\n"
     "\tcall : Object(r), (r -> Rpc(arg, ret, err)), arg -> Io("),
    ("\tcall = |obj, m, a| {\n\t\ts = stub_ops(obj)\n\t\tRemote.call(s.ops, s.slot, m, a, Remote.rpc_max)",
     "\tcall = |obj, pick, a| {\n\t\ts = stub_ops(obj)\n\t\tRemote.call(s.ops, s.slot, pick(obj.iface), a, Remote.rpc_max)"),
    ("\tcall! : Object, Rpc(arg, ret, err), arg =>", "\tcall! : Object(r), (r -> Rpc(arg, ret, err)), arg =>"),
    ("\tlocation_hint: hint.map_ok(location_text) ?? \"\",\n}", "\tlocation_hint: hint.map_ok(location_text) ?? \"\",\n\tiface: ns.iface,\n}"),
]
for old, new in pairs:
    if old not in s:
        sys.exit(f"Object: not found: {old[:80]}")
    s = s.replace(old, new)
out = []
for line in s.split("\n"):
    if re.match(r"^\s*[a-z_!]+ : ", line):
        line = re.sub(r"\bObject\.Namespace\b(?!\()", "Object.Namespace(r)", line)
        line = re.sub(r"\bObject\b(?![.(])", "Object(r)", line)
    out.append(line)
open(p, "w").write("\n".join(out))

edit("Worker", [
    ("Object.namespace(\"ROOMS\", { class: Object.class(\"Room\", {}) }).declare(),",
     "Object.namespace(\"ROOMS\", { class: Object.class(\"Room\", {}), iface: {} }).declare(),"),
    ("Object.namespace(\"FAR2\", { class: Object.class(\"Far2\", {}), script: \"other\" }).declare(),",
     "Object.namespace(\"FAR2\", { class: Object.class(\"Far2\", {}), iface: {}, script: \"other\" }).declare(),"),
    ("Object.namespace_remote(\"FAR\", { class: \"Far\", script: \"other\" }).declare(),",
     "Object.namespace_remote(\"FAR\", { iface: {}, class: \"Far\", script: \"other\" }).declare(),"),
])
print("ok", D)
