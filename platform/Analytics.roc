## The Analytics Engine binding (MODULES.md 13): `env[name].writeDataPoint(...)`. It gives no promise: one `call!`, no
## wait, so it has no `Io` twin (MC3). A binding that is not in the config is `AnalyticsErr` (`Call` on undefined throws, OP7).
import Io
import Js

Analytics :: { name : Str }.{
	binding : Str -> Analytics
	binding = |name| Analytics.{ name }

	## The binding for the manifest (`Worker.new({ bindings: [...] })`, MODULES.md 3): the kind `analytics`.
	declare : Analytics -> { name : Str, kind : Str, props : List((Str, Str)) }
	declare = |b| { name: b.name, kind: "analytics", props: [] }

	## One data point. Workers allows 20 blobs, 20 doubles and 1 index (a text of 96 bytes at most): the limits are those of
	## Workers, the module does not check them.
	write! : Analytics, { blobs : List(Str), doubles : List(F64), indexes : List(Str) } => Try({}, [Infra([AnalyticsErr(Io.Thrown)])])
	write! = |a, point| match Js.call!([
		Get(Root("env"), a.name),
		Call(Slot(0), "writeDataPoint", [Lit(data_point(point))]),
	]) {
		Ok(_) => Ok({})
		Err(t) => Err(Infra(AnalyticsErr(t)))
	}
}

data_point : { blobs : List(Str), doubles : List(F64), indexes : List(Str) } -> Js
data_point = |p| Obj([
	("blobs", Arr(p.blobs.map(|s| Text(s)))),
	("doubles", Arr(p.doubles.map(|d| Num(d)))),
	("indexes", Arr(p.indexes.map(|s| Text(s)))),
])

expect data_point({ blobs: ["a"], doubles: [1.5], indexes: ["i"] }) == Obj([("blobs", Arr([Text("a")])), ("doubles", Arr([Num(1.5)])), ("indexes", Arr([Text("i")]))])
