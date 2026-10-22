#!/usr/bin/env python3
"""Make research/typed-do-ns/platform-a/: a copy of platform/ with option A (a phantom interface type on Rpc, the
stub, the namespace, the class and the service). Run from the submodule root. The copy is not in git (.gitignore)."""
import re, shutil, sys

D = "research/typed-do-ns/platform-a"
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


# ---- Rpc: 4 type arguments, and a typed handler ----
edit("Rpc", [
    ("Rpc(arg, ret, err) :: { name : Str }.{", "Rpc(iface, arg, ret, err) :: { name : Str }.{"),
    ("method : Str -> Rpc(arg, ret, err)", "method : Str -> Rpc(iface, arg, ret, err)"),
    ("name : Rpc(arg, ret, err) -> Str", "name : Rpc(iface, arg, ret, err) -> Str"),
    ("on : Rpc(arg, ret, err), (self, arg => Try(ret, err)) -> Rpc.Handler(self) where",
     "on : Rpc(iface, arg, ret, err), (self, arg => Try(ret, err)) -> Rpc.Serves(iface, self) where"),
    ("\ton = |m, f!| {\n\t\tname: m.name,", "\ton = |m, f!| Rpc.Serves.{\n\t\tname: m.name,"),
    ("on_worker : Rpc(arg, ret, err), (arg => Try(ret, err)) -> Rpc.Handler({}) where",
     "on_worker : Rpc(iface, arg, ret, err), (arg => Try(ret, err)) -> Rpc.Handler({}) where"),
    ("on_worker = |m, f!| Rpc.on(m, |_, a| f!(a))", "on_worker = |m, f!| Rpc.on(m, |_, a| f!(a)).erase()"),
    ("\tHandler(self) : { name : Str, run! : self, List(U8) => Try(List(U8), Str) }",
     "\tHandler(self) : { name : Str, run! : self, List(U8) => Try(List(U8), Str) }\n\n"
     "\t## Option A: a handler of a method of the interface `iface`. A class takes a list of them, so all its methods\n"
     "\t## have one interface.\n"
     "\tServes(iface, self) := { name : Str, run! : self, List(U8) => Try(List(U8), Str) }.{\n"
     "\t\terase : Rpc.Serves(iface, self) -> Rpc.Handler(self)\n"
     "\t\terase = |h| { name: h.name, run!: h.run! }\n"
     "\t}"),
])

# ---- Remote and Service: the interface passes through ----
edit("Remote", [
    ("call : List(Js.Op), U32, Rpc(arg, ret, err), arg, U64", "call : List(Js.Op), U32, Rpc(iface, arg, ret, err), arg, U64"),
])
edit("Service", [
    ("Service :: { name : Str, service : Str, entrypoint : Str }.{", "Service(iface) :: { name : Str, service : Str, entrypoint : Str }.{"),
    ("binding : Str -> Service\n", "binding : Str -> Service(iface)\n"),
    ("binding_with : Str, { service ?: Str, entrypoint ?: Str } -> Service\n", "binding_with : Str, { service ?: Str, entrypoint ?: Str } -> Service(iface)\n"),
    ("declare : Service -> ", "declare : Service(iface) -> "),
    ("fetch : Service, Request", "fetch : Service(iface), Request"),
    ("fetch! : Service, Request", "fetch! : Service(iface), Request"),
    ("call : Service, Rpc(arg, ret, err)", "call : Service(iface), Rpc(iface, arg, ret, err)"),
    ("call! : Service, Rpc(arg, ret, err)", "call! : Service(iface), Rpc(iface, arg, ret, err)"),
])

# ---- Object: the stub, the namespace and the class carry the interface ----
p = f"{D}/Object.roc"
s = open(p).read()
pairs = [
    ("Object :: { namespace : Str,", "Object(iface) :: { namespace : Str,"),
    ("namespace : Str, { class : Object.Class, script ?: Str } -> Object.Namespace\n",
     "namespace : Str, { class : Object.Class(iface), script ?: Str } -> Object.Namespace(iface)\n"),
    ("class: opts.class.name, script: opts.?script ?? \"\" }", "class: opts.class.name(), script: opts.?script ?? \"\" }"),
    ("namespace_remote : Str, { class : Str, script : Str } -> Object.Namespace\n",
     "namespace_remote : Str, { class : Str, script : Str } -> Object.Namespace(iface)\n"),
    ("Namespace := { binding : Str,", "Namespace(iface) := { binding : Str,"),
    ("rpc ?: List(Rpc.Handler(Object.Self)),", "rpc ?: List(Rpc.Serves(iface, Object.Self)),"),
    ("\t} -> Object.Class\n\tclass = |name, h| {\n", "\t} -> Object.Class(iface)\n\tclass = |name, h| Object.Class.{\n"),
    ("methods: (h.?rpc ?? []).map(|m| m.name),", "methods: (h.?rpc ?? []).map(|m| m.erase().name),"),
    ("Rpc({ method, arg }) => match (h.?rpc ?? []).find_first(|m| m.name == method) {\n\t\t\t\t\tOk(m) => {\n\t\t\t\t\t\trun! = m.run!",
     "Rpc({ method, arg }) => match (h.?rpc ?? []).map(|m| m.erase()).find_first(|m| m.name == method) {\n\t\t\t\t\tOk(m) => {\n\t\t\t\t\t\trun! = m.run!"),
    ("\tClass : { name : Str, handlers : List(Str), methods : List(Str), run! : Str, Object.Event => [Respond(Response), Reply(Js), Done, Failed(Str), Unhandled] }",
     "\tClass(iface) := { name : Str, handlers : List(Str), methods : List(Str), run! : Str, Object.Event => [Respond(Response), Reply(Js), Done, Failed(Str), Unhandled] }.{\n"
     "\t\tname : Object.Class(iface) -> Str\n"
     "\t\tname = |c| c.name\n\n"
     "\t\t## For `Worker.new({ objects })`: a list has one type, and two classes have two interfaces.\n"
     "\t\terase : Object.Class(iface) -> Object.AnyClass\n"
     "\t\terase = |c| { name: c.name, handlers: c.handlers, methods: c.methods, run!: c.run! }\n"
     "\t}\n\n"
     "\t## A class with its interface erased.\n"
     "\tAnyClass : { name : Str, handlers : List(Str), methods : List(Str), run! : Str, Object.Event => [Respond(Response), Reply(Js), Done, Failed(Str), Unhandled] }"),
    ("call : Object, Rpc(arg, ret, err)", "call : Object(iface), Rpc(iface, arg, ret, err)"),
    ("call! : Object, Rpc(arg, ret, err)", "call! : Object(iface), Rpc(iface, arg, ret, err)"),
]
for old, new in pairs:
    if old not in s:
        sys.exit(f"Object: not found: {old[:80]}")
    s = s.replace(old, new)
# The other signatures: a bare `Object` or `Object.Namespace` in an annotation gets `(iface)`.
out = []
for line in s.split("\n"):
    if re.match(r"^\s*[a-z_!]+ : ", line):
        line = re.sub(r"\bObject\.Namespace\b(?!\()", "Object.Namespace(iface)", line)
        line = re.sub(r"\bObject\b(?![.(])", "Object(iface)", line)
    out.append(line)
open(p, "w").write("\n".join(out))

# ---- Worker: `objects` takes erased classes ----
edit("Worker", [
    ("\tobjects : List(Object.Class),", "\tobjects : List(Object.AnyClass),"),
    ("\t\tobjects ?: List(Object.Class),", "\t\tobjects ?: List(Object.AnyClass),"),
    ("Object.namespace(\"ROOMS\", { class: Object.class(\"Room\", {}) }).declare(),",
     "Object.namespace(\"ROOMS\", { class: room_class }).declare(),"),
    ("Object.namespace(\"FAR2\", { class: Object.class(\"Far2\", {}), script: \"other\" }).declare(),",
     "Object.namespace(\"FAR2\", { class: far2_class, script: \"other\" }).declare(),"),
])
s = open(f"{D}/Worker.roc").read()
s += "\nNoRpc := []\n\nroom_class : Object.Class(NoRpc)\nroom_class = Object.class(\"Room\", {})\n\nfar2_class : Object.Class(NoRpc)\nfar2_class = Object.class(\"Far2\", {})\n"
open(f"{D}/Worker.roc", "w").write(s)
print("ok", D)
