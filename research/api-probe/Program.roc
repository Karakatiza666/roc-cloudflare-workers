## A program of ops for `await!` and `call!` (API.md 6.2). Prototype of the encoder.
import Js

Program :: List(Op).{
	## Encoded as a Js array, so the JS side needs one decoder: [[op, target, ...], ...].
	ops : Program -> List(Op)
	ops = |p| {
		Program.(list) = p
		list
	}

	encode : Program -> List(U8)
	encode = |p| {
		Js.encode(Arr(p.ops().map(op_js)))
	}
}

## Nominal, because `Par` holds lists of ops.
Op := [
	Get(Target, Str),
	Set(Target, Str, Arg),
	Call(Target, Str, List(Arg)),
	Start(Target, Str, List(Arg)),
	New(Target, Str, List(Arg)),
	Fields(Target, List(Str)),
	Keep(Target),
	Array(List(Arg)),
	Record(List((Str, Arg))),
	Par(List(List(Op))),
]

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

op_js : Op -> Js
op_js = |op| match op {
	Get(t, name) => Arr([Text("get"), target_js(t), Text(name)])
	Set(t, name, a) => Arr([Text("set"), target_js(t), Text(name), arg_js(a)])
	Call(t, name, args) => Arr([Text("call"), target_js(t), Text(name), Arr(args.map(arg_js))])
	New(t, name, args) => Arr([Text("new"), target_js(t), Text(name), Arr(args.map(arg_js))])
	Fields(t, names) => Arr([Text("fields"), target_js(t), Arr(names.map(|n| Text(n)))])
	Keep(t) => Arr([Text("keep"), target_js(t)])
	Start(t, name, args) => Arr([Text("start"), target_js(t), Text(name), Arr(args.map(arg_js))])
	Array(args) => Arr([Text("array"), Arr(args.map(arg_js))])
	Record(fields) => Arr([Text("record"), Arr(fields.map(|(k, a)| Arr([Text(k), arg_js(a)])))])
	Par(branches) => Arr([Text("par"), Arr(branches.map(|b| Arr(b.map(op_js))))])
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

## Two queries at the same time, in one crossing (API.md OP6).
both : Program
both = Program.([Par([d1_query("DB", "select 1", []).ops(), d1_query("DB", "select 2", []).ops()])])

expect {
	match Js.decode(Program.encode(both)) {
		Ok(Arr([Arr([Text("par"), Arr([Arr(a), Arr(b)])])])) => a.len() == 4 and b.len() == 4
		_ => Bool.False
	}
}

expect {
	p = Program.([Array([Slot(1), Lit(Null)]), Record([("db", Slot(0))])])
	Js.decode(Program.encode(p)) == Ok(Arr([
		Arr([Text("array"), Arr([Arr([Text("slot"), Num(1)]), Arr([Text("lit"), Null])])]),
		Arr([Text("record"), Arr([Arr([Text("db"), Arr([Text("slot"), Num(0)])])])]),
	]))
}
