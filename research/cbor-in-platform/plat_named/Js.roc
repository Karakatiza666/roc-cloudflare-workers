## A JS value that crosses the bridge (API.md 5), and the ops of a program that JS runs (API.md 6.2).
## The Zig host encodes and decodes the CBOR form (API.md 5.1). Roc never sees the bytes.
Js := [
	Undefined,
	Null,
	Bool(Bool),
	Num(F64),
	Int(I64),
	Text(Str),
	Bytes(List(U8)),
	Arr(List(Js)),
	Obj(List((Str, Js))),
	Ref(Js.Ref),
	Error(Str, Str),
	## One value as CBOR, for typed data (API.md 5.2).
	Packed(List(U8)),
].{
	is_eq : _

	## The id of a JS object in the ref table of the task (API.md 9). `==` compares ids (RS1).
	## A record backing, so a ref has no codec (MODULES.md MC13, 15).
	Ref :: { id : U32 }.{
		is_eq : _
	}

	## Where an op finds its object: a root of the task (OP3), an earlier slot, or a ref.
	Target : [Root(Str), Slot(U32), Ref(Js.Ref)]

	## An op argument: a value, or an earlier slot.
	Arg : [Lit(Js), Slot(U32)]

	## One op. Each op puts its result in the next slot (API.md 6.2).
	Op := [
		Get(Js.Target, Str),
		Set(Js.Target, Str, Js.Arg),
		Call(Js.Target, Str, List(Js.Arg)),
		Start(Js.Target, Str, List(Js.Arg)),
		New(Js.Target, Str, List(Js.Arg)),
		Fields(Js.Target, List(Str)),
		Keep(Js.Target),
		Array(List(Js.Arg)),
		Record(List((Str, Js.Arg))),
		Par(List(List(Js.Op))),
		Race(List(List(Js.Op))),
	]

	## The ops as one `Js` array, the format that the JS interpreter reads (OP5):
	## `[["get", target, name], ["call", target, name, [args]], ...]`.
	program : List(Js.Op) -> Js
	program = |ops| Arr(ops.map(op_js))
}

target_js : Js.Target -> Js
target_js = |t| match t {
	Root(name) => Arr([Text("root"), Text(name)])
	Slot(n) => Arr([Text("slot"), Int(n.to_i64())])
	Ref(r) => Arr([Text("ref"), Ref(r)])
}

arg_js : Js.Arg -> Js
arg_js = |a| match a {
	Lit(v) => Arr([Text("lit"), v])
	Slot(n) => Arr([Text("slot"), Int(n.to_i64())])
}

op_js : Js.Op -> Js
op_js = |op| match op {
	Get(t, name) => Arr([Text("get"), target_js(t), Text(name)])
	Set(t, name, a) => Arr([Text("set"), target_js(t), Text(name), arg_js(a)])
	Call(t, name, args) => Arr([Text("call"), target_js(t), Text(name), Arr(args.map(arg_js))])
	Start(t, name, args) => Arr([Text("start"), target_js(t), Text(name), Arr(args.map(arg_js))])
	New(t, name, args) => Arr([Text("new"), target_js(t), Text(name), Arr(args.map(arg_js))])
	Fields(t, names) => Arr([Text("fields"), target_js(t), Arr(names.map(|n| Text(n)))])
	Keep(t) => Arr([Text("keep"), target_js(t)])
	Array(args) => Arr([Text("array"), Arr(args.map(arg_js))])
	Record(fields) => Arr([Text("record"), Arr(fields.map(|(k, a)| Arr([Text(k), arg_js(a)])))])
	Par(branches) => Arr([Text("par"), Arr(branches.map(|b| Arr(b.map(op_js))))])
	Race(branches) => Arr([Text("race"), Arr(branches.map(|b| Arr(b.map(op_js))))])
}

expect {
	ops : List(Js.Op)
	ops = [Get(Root("env"), "DB"), Call(Slot(0), "prepare", [Lit(Text("select 1"))])]
	Js.program(ops) == Arr([
		Arr([Text("get"), Arr([Text("root"), Text("env")]), Text("DB")]),
		Arr([Text("call"), Arr([Text("slot"), Int(0)]), Text("prepare"), Arr([Arr([Text("lit"), Text("select 1")])])]),
	])
}

expect {
	ops : List(Js.Op)
	ops = [Par([[Keep(Root("ctx"))], []]), Race([]), Record([("db", Slot(0))]), Array([Slot(1), Lit(Null)])]
	Js.program(ops) == Arr([
		Arr([Text("par"), Arr([Arr([Arr([Text("keep"), Arr([Text("root"), Text("ctx")])])]), Arr([])])]),
		Arr([Text("race"), Arr([])]),
		Arr([Text("record"), Arr([Arr([Text("db"), Arr([Text("slot"), Int(0)])])])]),
		Arr([Text("array"), Arr([Arr([Text("slot"), Int(1)]), Arr([Text("lit"), Null])])]),
	])
}
