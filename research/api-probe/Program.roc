## A program of ops for `await!` and `call!` (API.md 6.2). Prototype of the encoder.
import Js

Program := List([
	Get(Target, Str),
	Set(Target, Str, Arg),
	Call(Target, Str, List(Arg)),
	New(Target, Str, List(Arg)),
	Fields(Target, List(Str)),
	Keep(Target),
]).{
	## Encoded as a Js array, so the JS side needs one decoder: [[op, target, ...], ...].
	encode : Program -> List(U8)
	encode = |p| {
		Program.(ops) = p
		Js.encode(Arr(ops.map(op_js)))
	}
}

Target : [Root(Str), Slot(U32), Ref(U32)]

Arg : [Lit(Js), Slot(U32)]

target_js : Target -> Js
target_js = |t| match t {
	Root(name) => Arr([Text("root"), Text(name)])
	Slot(n) => Arr([Text("slot"), Num(n.to_f64())])
	Ref(id) => Ref(id)
}

arg_js : Arg -> Js
arg_js = |a| match a {
	Lit(v) => Arr([Text("lit"), v])
	Slot(n) => Arr([Text("slot"), Num(n.to_f64())])
}

op_js = |op| match op {
	Get(t, name) => Arr([Text("get"), target_js(t), Text(name)])
	Set(t, name, a) => Arr([Text("set"), target_js(t), Text(name), arg_js(a)])
	Call(t, name, args) => Arr([Text("call"), target_js(t), Text(name), Arr(args.map(arg_js))])
	New(t, name, args) => Arr([Text("new"), target_js(t), Text(name), Arr(args.map(arg_js))])
	Fields(t, names) => Arr([Text("fields"), target_js(t), Arr(names.map(|n| Text(n)))])
	Keep(t) => Arr([Text("keep"), target_js(t)])
}

d1_query : Str, Str, List(Js) -> Program
d1_query = |binding, sql, params| Program.([
	Get(Root("env"), binding),
	Call(Slot(0), "prepare", [Lit(Text(sql))]),
	Call(Slot(1), "bind", params.map(|v| Lit(v))),
	Call(Slot(2), "raw", [Lit(Obj([("columnNames", Bool(Bool.True))]))]),
])

expect {
	bytes = Program.encode(d1_query("DB", "select 1", [Int(7)]))
	match Js.decode(bytes) {
		Ok(Arr(ops)) => ops.len() == 4
		_ => Bool.False
	}
}
