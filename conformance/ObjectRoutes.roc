## Durable Objects (MODULES.md 7, 9 `Object.Cell`, PLAN.md 8f part 1). The classes of the app (`classes`, in the field
## `objects` of `Worker` in app.roc) and the routes of the Worker that call them. `checks/objects.mjs` has the bindings.
## A route `/objects/counter/<op>?name=<n>` gives the request to the object `<n>` of `Counter`, which answers the op.
import pf.Request
import pf.Response
import pf.Object
import pf.Rpc
import pf.Sql
import pf.Io
import pf.Js
import pf.Time
import pf.Log
import pf.Ctx
import RpcMethods
import RpcErrRoutes
import Q

count : Object.Cell(I64)
count = Object.cell("count")

## roc-cbor 0.2.0: a cell with `Dec` fields (a Dec is exact in the storage: Roc to Roc).
dec_cell : Object.Cell({ a : Dec, b : Dec })
dec_cell = Object.cell("dec")

## The wait of the next alarm in ms (the deadline repro of `research/flake-foreign-sweep/`): `/alarm_nap?ms=`.
nap_cell : Object.Cell(U64)
nap_cell = Object.cell("nap")

## Written after `respond!` (API.md 10.2).
late : Object.Cell(Str)
late = Object.cell("late")

## Typed rows of the object SQL.
Row : { id : I64, u : Str }

Wide : { v : I64 }

Big : { x : Str }

ObjectRoutes :: [].{

	## The classes of the app: the manifest names them, and `conformance/worker.js` exports each one.
	counter_class : Object.Class(RpcMethods.Counter)
	counter_class = Object.class("Counter", { fetch!: counter_fetch!, alarm!: counter_alarm!, rpc: [RpcMethods.increment.on(increment!), RpcMethods.ping(RpcMethods.counter_iface).on(object_ping!), RpcMethods.boom.on(boom!), RpcMethods.echo.on(echo!), RpcMethods.hello(RpcMethods.counter_iface).on(object_hello!), RpcMethods.nap.on(nap!), RpcMethods.relay(RpcMethods.counter_iface).on(relay!), RpcMethods.relay_map(RpcMethods.counter_iface).on(relay_map!)].concat(RpcErrRoutes.object_handlers) })

	store_class : Object.Class(RpcMethods.Store)
	store_class = Object.class("Store", { init!: store_init!, fetch!: store_fetch!, rpc: [RpcMethods.fail(RpcMethods.store_iface).on(store_fail!)] })

	flaky_class : Object.Class(RpcMethods.NoRpc)
	flaky_class = Object.class("Flaky", { init!: flaky_init!, fetch!: plain_fetch! })

	slow_class : Object.Class(RpcMethods.NoRpc)
	slow_class = Object.class("Slow", { init!: slow_init!, fetch!: plain_fetch! })

	ticker_class : Object.Class(RpcMethods.NoRpc)
	ticker_class = Object.class("Ticker", { fetch!: ticker_fetch!, alarm!: ticker_alarm! })

	kv_only_class : Object.Class(RpcMethods.NoRpc)
	kv_only_class = Object.class("KvOnly", { fetch!: kv_only_fetch! })

	classes : List(Object.AnyClass)
	classes = [counter_class.erase(), store_class.erase(), flaky_class.erase(), slow_class.erase(), ticker_class.erase(), kv_only_class.erase()]

	## The namespaces: each takes the class value, so a class name is written once.
	counters : Object.Namespace(RpcMethods.Counter)
	counters = Object.namespace("COUNTERS", { class: counter_class })

	stores : Object.Namespace(RpcMethods.Store)
	stores = Object.namespace("STORES", { class: store_class })

	flakies : Object.Namespace(RpcMethods.NoRpc)
	flakies = Object.namespace("FLAKY", { class: flaky_class })

	slows : Object.Namespace(RpcMethods.NoRpc)
	slows = Object.namespace("SLOW", { class: slow_class })

	tickers : Object.Namespace(RpcMethods.NoRpc)
	tickers = Object.namespace("TICKERS", { class: ticker_class })

	kv_only : Object.Namespace(RpcMethods.NoRpc)
	kv_only = Object.namespace("KVONLY", { class: kv_only_class })

	route! : Request, List(Str) => Response
	route! = |req, path| {
		name = Q.text(req, "name")
		match path {
			["counter", .. as op] => forward!(counters.named(name), op, req)
			# `id!` of a named stub (one `call!`) and `self.id` in the object are the same id.
			["id"] => {
				outside = counters.named(name).id!()
				inside = text!(counters.named(name).fetch!(Request.get("http://o/id")))
				Response.from_text(200, "outside=${Str.inspect(outside)} same=${Str.inspect(outside == Ok(inside))}")
			}
			# N4: the bindings that the namespaces give to the manifest: a class value, a class value with `script`, and `namespace_remote`.
			["namespaces"] => {
				far = Object.namespace("FAR2", { class: store_class, script: "other" })
				remote = Object.namespace_remote("FAR", { class: "Far", script: "other" }, RpcMethods.counter_iface)
				Response.from_text(200, Str.inspect([counters.declare(), far.declare(), remote.declare()]))
			}
			# `namespace_named`: `store_ns` (the RPC callee of `RpcErrRoutes`, below) and one more: the class name, no `script`. The interface of NAMED is not the name of its class, so the `iface` prop comes from the interface value.
			["namespaces_named"] => Response.from_text(200, Str.inspect([store_ns.declare(), Object.namespace_named("NAMED", "Counter", RpcMethods.default_iface).declare()]))
			["jurisdiction"] => Response.from_text(200, Str.inspect(counters.jurisdiction(Eu).named(name).id!()))
			# `named_with` and `from_id_with` with a location hint, `unique!`, and `id!` of a stub of an id (no crossing).
			["location"] => {
				a = text!(counters.named_with(name, { location_hint: Weur }).fetch!(Request.get("http://o/id")))
				b = text!(counters.from_id_with(a, { location_hint: ApacNe }).fetch!(Request.get("http://o/id")))
				u = counters.unique!()
				uid = u.id!() ?? "none"
				c = text!(u.fetch!(Request.get("http://o/id")))
				Response.from_text(200, "same=${Str.inspect(a == b)} unique=${Str.inspect(uid == c)} len=${uid.count_utf8_bytes().to_str()}")
			}
			# Two `fetch!` at the same time to a new object: `init!` runs in `blockConcurrencyWhile`, so both see its table.
			["store_pair"] => {
				o = stores.named(name)
				got = Io.both!(o.fetch(Request.get("http://o/count")), o.fetch(Request.get("http://o/count")))
				match got {
					Ok((a, b)) => Response.from_text(200, "${text!(Ok(a))} | ${text!(Ok(b))}")
					Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
				}
			}
			["store_alarm"] => Response.from_text(200, text!(stores.named(name).fetch!(Request.get("http://o/set_alarm"))))
			["flaky"] => Response.from_text(200, text!(flakies.named(name).fetch!(Request.get("http://o/"))))
			["slow"] => Response.from_text(200, text!(slows.named(name).fetch!(Request.get("http://o/"))))
			["ticker"] => Response.from_text(200, text!(tickers.named(name).fetch!(Request.get("http://o/"))))
			["kvonly"] => Response.from_text(200, text!(kv_only.named(name).fetch!(Request.get("http://o/"))))
			# `respond!` in the object, then a wait of 300 ms, then a cell: the Worker gets the response first.
			["respond"] => {
				t0 = Time.now_ms!()
				body = text!(counters.named(name).fetch!(Request.get("http://o/respond")))
				Response.from_text(200, "${body} fast=${Str.inspect(Time.now_ms!() - t0 < 250)}")
			}
			# RPC (MODULES.md 8) on an object stub, and the `Io` twins of `call` and `fetch`.
			["rpc", "increment"] => {
				o = counters.named(name)
				a = o.call!(RpcMethods.increment, { by: 2 })
				b = Io.run!(o.call(RpcMethods.increment, { by: 3 }))
				Response.from_text(200, "${Str.inspect(a)} ${Str.inspect(b)}")
			}
			["rpc", "nap"] => Response.from_text(200, Str.inspect(counters.named(name).call!(RpcMethods.nap, { ms: Q.num(req, "ms") })))
			["rpc", "ping"] => Response.from_text(200, Str.inspect(counters.named(name).call!(RpcMethods.ping(RpcMethods.counter_iface), { n: 7 })))
			["rpc", "boom"] => Response.from_text(200, Str.inspect(counters.named(name).call!(RpcMethods.boom, { n: 3 })))
			["rpc", "nothere"] => Response.from_text(200, Str.inspect(counters.named(name).call!(RpcMethods.nothere(RpcMethods.counter_iface), { n: 1 })))
			["rpc", "echo"] => Response.from_text(200, Str.inspect(counters.named(name).call!(RpcMethods.echo, { big: 1_152_921_504_606_846_976 })))
			["fetch_io"] => Response.from_text(200, text!(Io.run!(counters.named(name).fetch(Request.get("http://o/id")))))
			_ => Response.from_text(404, "no route")
		}
	}
}

## The request to the object: the op as its path, and the query of the route.
forward! : Object(RpcMethods.Counter), List(Str), Request => Response
forward! = |o, op, req| {
	query = match req.url().split_first("?") {
		Ok({ after, .. }) => "?${after}"
		Err(_) => ""
	}
	Response.from_text(200, text!(o.fetch!(Request.get("http://o/${Str.join_with(op, "/")}${query}"))))
}

## The body of a response of an object as text, or the error.
text! : Try(Response, [Infra([ObjectErr(Io.Thrown)])]) => Str
text! = |r| match r {
	Ok(res) => match res.text!() {
		Ok(t) => if (res.status() == 200) t else "status ${res.status().to_str()} ${t}"
		Err(e) => "body ${Str.inspect(e)}"
	}
	Err(e) => "Err ${Str.inspect(e)}"
}

answer : Str -> Try(Response, e)
answer = |t| Ok(Response.from_text(200, t))

# Counter: object SQL, cells, `list!`, alarms, `delete_all!`, `Response.after`, and RPC methods.

counter_fetch! : Object.Self, Request => Try(Response, e)
counter_fetch! = |self, req| match req.segments() {
	["id"] => answer(self.id())
	# A wait before the response (the deadline repro of research/flake-foreign-sweep/): `/sleep?ms=`.
	["sleep"] => {
		Time.sleep!(Q.num(req, "ms"))
		answer("slept")
	}
	["sql_setup"] => {
		made = [
			"CREATE TABLE IF NOT EXISTS p (id INTEGER PRIMARY KEY)",
			"CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, u TEXT UNIQUE, n INTEGER NOT NULL, c INTEGER CHECK (c >= 0), p INTEGER REFERENCES p(id), b BLOB)",
			"CREATE TABLE IF NOT EXISTS s (id INTEGER PRIMARY KEY, v INTEGER) STRICT",
			"CREATE TABLE IF NOT EXISTS noidx (a TEXT, b TEXT)",
			"CREATE TABLE IF NOT EXISTS wide (k TEXT PRIMARY KEY, v INTEGER)",
			"CREATE TABLE IF NOT EXISTS pt (k TEXT, a, b INTEGER, c, d)",
			"CREATE TABLE IF NOT EXISTS pi (k TEXT PRIMARY KEY, v INTEGER)",
			"CREATE TRIGGER IF NOT EXISTS g BEFORE INSERT ON t WHEN NEW.id = 99 BEGIN SELECT RAISE(ABORT, 'label-conflict'); END",
			"INSERT OR IGNORE INTO t (id, u, n, c, b) VALUES (1, 'a', 1, 1, x'010203')",
		]
		var $failed = []
		for sql in made {
			match self.sql_run!(sql, Sql.none) {
				Ok(_) => {}
				Err(e) => {
					$failed = $failed.append(e)
				}
			}
		}
		answer(Str.inspect($failed))
	}
	# PLAN.md 8d for object SQL: each constraint kind of MODULES.md 5.1 (the texts of D1 with no `D1_ERROR: `).
	["sql_constraint", case] => {
		sql = match case {
			"pk" => "INSERT INTO t (id, u, n) VALUES (1, 'z', 1)"
			"unique" => "INSERT INTO t (id, u, n) VALUES (2, 'a', 1)"
			"notnull" => "INSERT INTO t (id, u) VALUES (3, 'q')"
			"check" => "INSERT INTO t (id, u, n, c) VALUES (4, 'r', 1, -1)"
			"fk" => "INSERT INTO t (id, u, n, p) VALUES (5, 's', 1, 77)"
			"datatype" => "INSERT INTO s (id, v) VALUES (1, 'text')"
			"trigger" => "INSERT INTO t (id, u, n) VALUES (99, 'w', 1)"
			_ => "SELEC 1"
		}
		answer(Str.inspect(self.sql_run!(sql, Sql.none)))
	}
	["sql_run"] => answer(Str.inspect(self.sql_run!("INSERT INTO noidx (a, b) VALUES (?, ?), (?, ?)", ("x", "y", "z", "w"))))
	["sql_all"] => {
		rows : Try(List(Row), _)
		rows = self.sql!("SELECT id, u FROM t WHERE id = ?", [1.I64])
		answer(Str.inspect(rows))
	}
	# The integer rules of MODULES.md 5.1: a parameter outside ±(2^53 - 1) goes as text and is stored exact, `CAST(v AS
	# TEXT)` reads it into an `I64`, and with no cast it is `BadData` with the column.
	["sql_int"] => {
		_ = self.sql_run!("INSERT OR REPLACE INTO wide (k, v) VALUES ('max', ?), ('neg', ?)", (9_223_372_036_854_775_807.I64, -2_687_166_099_708_853_831.I64))
		cast : Try(List(Wide), _)
		cast = self.sql!("SELECT CAST(v AS TEXT) AS v FROM wide ORDER BY k", Sql.none)
		plain : Try(List(Wide), _)
		plain = self.sql!("SELECT v FROM wide WHERE k = 'max'", Sql.none)
		answer("cast=${Str.inspect(cast)} plain=${Str.inspect(plain)}")
	}
	# PLAN.md 8h item 3: parameters as an `Encodable` tuple or list (the same cases as `/d1/params/<case>`).
	["sql_params", "count"] => {
		n : Try(List({ n : I64 }), _)
		n = self.sql!("SELECT count(*) AS n FROM pi WHERE k = 'u64over' OR v < 0", Sql.none)
		answer(
			match n {
				Ok([row]) => "n=${row.n.to_str()}"
				_ => "Err"
			},
		)
	}
	["sql_params", case] => sql_params!(self, case)
	["sql_rows"] => answer(Str.inspect(self.sql_rows!("SELECT id, u, b, 1.5 AS r, NULL AS z FROM t WHERE id = 1", Sql.none)))
	["sql_rows_with"] => answer(Str.inspect(self.sql_rows_with!("SELECT id FROM t WHERE id = 1", Sql.none, { max_bytes: 4 })))
	# MC11: 22 rows of 100,000 bytes (2.2 MB) are above the 1 MiB default and the 2 MiB of the test, and below 4 MiB.
	["sql_big"] => {
		_ = self.sql_run!("CREATE TABLE IF NOT EXISTS big (x TEXT)", Sql.none)
		_ = self.sql_run!("DELETE FROM big", Sql.none)
		_ = self.sql_run!("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 22) INSERT INTO big (x) SELECT printf('%.*c', 100000, 'x') FROM n", Sql.none)
		small : Try(List(Big), _)
		small = self.sql!("SELECT x FROM big", Sql.none)
		two : Try(List(Big), _)
		two = self.sql_with!("SELECT x FROM big", Sql.none, { max_bytes: 2_097_152 })
		four : Try(List(Big), _)
		four = self.sql_with!("SELECT x FROM big", Sql.none, { max_bytes: 4_194_304 })
		rows = self.sql_rows!("SELECT x FROM big", Sql.none)
		show = |r| match r {
			Ok(list) => "Ok rows=${List.len(list).to_str()}"
			Err(e) => "Err ${Str.inspect(e)}"
		}
		answer("default=${show(small)} two=${show(two)} four=${show(four)} rows=${show(rows.map_ok(|x| x.rows))}")
	}
	["sql_syntax"] => answer(Str.inspect(self.sql_run!("SELEC 1", Sql.none)))
	# Cells a1, a2, b1: `list_with!` with a prefix, `list!` of all keys.
	["cells"] => {
		_ = Object.cell("a1").set!(self, "one")
		_ = Object.cell("a2").set!(self, "two")
		_ = Object.cell("b1").set!(self, "three")
		answer("prefix=${Str.inspect(self.list_with!({ prefix: "a" }))} all=${Str.inspect(self.list!())} after=${Str.inspect(self.list_with!({ start_after: "a1", limit: 1 }))}")
	}
	# `get_or!`: the default when the cell has no value, the value after `set!`.
	["cell_or"] => {
		_ = count.delete!(self)
		none = count.get_or!(self, 42)
		_ = count.set!(self, 7)
		some = count.get_or!(self, 42)
		_ = count.delete!(self)
		answer("none=${Str.inspect(none)} some=${Str.inspect(some)}")
	}
	# `get_or!` of a cell whose value is not of its type: `BadData`, not the default.
	["cell_or_bad"] => {
		_ = count.set!(self, 7)
		as_text : Object.Cell(Str)
		as_text = Object.cell("count")
		got = as_text.get_or!(self, "dflt")
		_ = count.delete!(self)
		answer(Str.inspect(got))
	}
	# N6: `find!` gives a missing cell as `Ok(Err(NotFound))`, a value as `Ok(Ok(v))`, a value of another type as `Err(BadData)`.
	["cell_find"] => {
		_ = count.delete!(self)
		none = count.find!(self)
		_ = count.set!(self, 7)
		some = count.find!(self)
		as_text : Object.Cell(Str)
		as_text = Object.cell("count")
		bad = as_text.find!(self)
		_ = count.delete!(self)
		answer("none=${Str.inspect(none)} some=${Str.inspect(some)} bad=${Str.inspect(bad)}")
	}
	# roc-cbor 0.2.0: a `Dec` in a cell is exact (a fraction, the lowest `Dec`: a bignum mantissa).
	["dec_cell"] => {
		want = { a: 0.1, b: Dec.lowest }
		set = dec_cell.set!(self, want)
		got = dec_cell.get!(self)
		_ = dec_cell.delete!(self)
		answer("set=${Str.inspect(set)} same=${Str.inspect(got == Ok(want))} a=${Str.inspect(got.map_ok(|p| p.a.to_str()))} b=${Str.inspect(got.map_ok(|p| p.b.to_str()))}")
	}
	# roc-cbor 0.2.0, object SQL: a fractional `Dec` parameter binds a Number, the list literal `[1]` binds 1.
	["dec_sql"] => {
		_ = self.sql_run!("CREATE TABLE IF NOT EXISTS dec_t (k TEXT, r)", Sql.none)
		_ = self.sql_run!("DELETE FROM dec_t", Sql.none)
		_ = self.sql_run!("INSERT INTO dec_t (k, r) VALUES (?, ?)", ("frac", 3.25))
		_ = self.sql_run!("INSERT INTO dec_t (k, r) VALUES ('lit1', ?)", [1])
		rows : Try(List({ k : Str, t : Str, r : F64 }), _)
		rows = self.sql!("SELECT k, typeof(r) AS t, r FROM dec_t ORDER BY k", Sql.none)
		answer(Str.inspect(rows))
	}
	["cell"] => {
		before = count.get!(self)
		set = count.set!(self, -9_007_199_254_740_993)
		got = count.get!(self)
		del = count.delete!(self)
		after = count.get!(self)
		answer("before=${Str.inspect(before)} set=${Str.inspect(set)} got=${Str.inspect(got)} del=${Str.inspect(del)} after=${Str.inspect(after)}")
	}
	# `get_alarm!` after `set_alarm_at!(t)` gives `t` (and the twins), `delete_alarm!` removes it.
	["alarm"] => {
		t = Time.now_ms!() + 3_600_000
		set = self.set_alarm_at!(t)
		got = self.get_alarm!()
		twin = Io.run!(self.get_alarm())
		del = Io.run!(self.delete_alarm())
		after = self.get_alarm!()
		set2 = Io.run!(self.set_alarm_at(t))
		del2 = self.delete_alarm!()
		answer("set=${Str.inspect(set)} same=${Str.inspect(got == Ok(t))} twin=${Str.inspect(twin == Ok(t))} del=${Str.inspect(del)} after=${Str.inspect(after)} set2=${Str.inspect(set2)} del2=${Str.inspect(del2)}")
	}
	# `set_alarm_in!(ms)` (or its Io twin): the alarm is `ms` after the call, not now. The answer has the clock before and
	# after, and `get_alarm!`. `alarm!` logs "counter alarm" with the id and the time.
	["alarm_in"] => {
		delay = Q.num(req, "ms")
		t0 = Time.now_ms!()
		set = if (Q.text(req, "twin") == "1") Io.run!(self.set_alarm_in(delay)) else self.set_alarm_in!(delay)
		got = self.get_alarm!()
		answer("set=${Str.inspect(set)} id=${self.id()} t0=${t0.to_str()} alarm=${Str.inspect(got)}")
	}
	# An alarm that waits `ms` (the deadline repro of research/flake-foreign-sweep/): the alarm runs 10 ms after the call, then sleeps.
	["alarm_nap"] => {
		_ = nap_cell.set!(self, Q.num(req, "ms"))
		answer(Str.inspect(self.set_alarm_in!(10)))
	}
	# `set_alarm_at!(now + ms)`: the alarm is at that time.
	["alarm_at"] => {
		t = Time.now_ms!() + Q.num(req, "ms")
		set = self.set_alarm_at!(t)
		got = self.get_alarm!()
		answer("set=${Str.inspect(set)} id=${self.id()} t=${t.to_str()} alarm=${Str.inspect(got)}")
	}
	# A table, a cell and an alarm, then `delete_all!`: all three are gone.
	["delete_all"] => {
		_ = self.sql_run!("CREATE TABLE IF NOT EXISTS gone (a)", Sql.none)
		_ = count.set!(self, 5)
		_ = self.set_alarm_at!(Time.now_ms!() + 3_600_000)
		del = if (Q.text(req, "twin") == "1") Io.run!(self.delete_all()) else self.delete_all!()
		table : Try(List({ a : I64 }), _)
		table = self.sql!("SELECT a FROM gone", Sql.none)
		answer("del=${Str.inspect(del)} table=${Str.inspect(table.is_ok())} cell=${Str.inspect(count.get!(self))} alarm=${Str.inspect(self.get_alarm!())}")
	}
	# API.md 10.2: `Response.after` in the `Fetch` of an object: the response, then the work.
	["respond"] => {
		work! = || {
			Time.sleep!(300)
			late.set!(self, "written")
		}
		Ok(Response.from_text(200, "early").after(work!))
	}
	["late"] => answer(Str.inspect(late.get!(self)))
	["pass_through"] => answer(Str.inspect(Ctx.pass_through!()))
	_ => Ok(Response.from_text(404, "no op"))
}

counter_alarm! : Object.Self, { retry_count : U32, is_retry : Bool } => Try({}, [])
counter_alarm! = |self, _info| {
	Log.info!("counter alarm", { id: self.id(), at: Time.now_ms!() })
	match nap_cell.get!(self) {
		Ok(ms) => Time.sleep!(ms)
		Err(_) => {}
	}
	Ok({})
}

increment! : Object.Self, { by : I64 } => Try(I64, [Infra(Rpc.Infra)])
increment! = |self, { by }| {
	n = (count.get!(self) ?? 0) + by
	count.set!(self, n)?
	Ok(n)
}

object_ping! : Object.Self, { n : I64 } => Try(Str, Rpc.NoErr)
object_ping! = |_self, { n }| Ok("object ping ${n.to_str()}")

nap! : Object.Self, { ms : U64 } => Try(U64, Rpc.NoErr)
nap! = |_self, { ms }| {
	Time.sleep!(ms)
	Ok(ms)
}

object_hello! : Object.Self, {} => Try(Str, Rpc.NoErr)
object_hello! = |_self, {}| Ok("object hello")

boom! : Object.Self, { n : I64 } => Try(I64, [Nope(I64)])
boom! = |_self, { n }| Err(Nope(n))

echo! : Object.Self, { big : U64 } => Try({ big : U64 }, Rpc.NoErr)
echo! = |_self, v| Ok(v)

# N5 G1a (checks/rpcerr.mjs, "infra"): the callee `fail` in `Store` `?`s a platform error: SqlErr, StorageErr (the class
# has no `alarm!`), and the flat domain tag Constraint. The `Counter` callees `relay` and `relay_map` call it and pass its errors on with `Rpc.forward`.
store_ns = Object.namespace_named("STORES", "Store", RpcMethods.store_iface)

store_fail! : Object.Self, { kind : Str } => Try(I64, [NotOpen, Constraint(Sql.Constraint), Infra(Rpc.Infra)])
store_fail! = |self, { kind }| match kind {
	"sql" => {
		_ = self.sql_run!("SELEC 1", Sql.none)?
		Ok(1)
	}
	"constraint" => {
		_ = self.sql_run!("CREATE TABLE IF NOT EXISTS uniq (k TEXT PRIMARY KEY)", Sql.none)?
		_ = self.sql_run!("DELETE FROM uniq", Sql.none)?
		_ = self.sql_run!("INSERT INTO uniq (k) VALUES ('a')", Sql.none)?
		_ = self.sql_run!("INSERT INTO uniq (k) VALUES ('a')", Sql.none)?
		Ok(1)
	}
	"storage" => {
		self.set_alarm_at!(Time.now_ms!() + 60_000)?
		Ok(1)
	}
	"domain" => Err(NotOpen)
	"crash" => crash "fail callee crash"
	_ => Ok(7)
}

relay! : Object.Self, { kind : Str } => Try(I64, [NotOpen, Constraint(Sql.Constraint), Infra(Rpc.Infra)])
relay! = |_self, arg| {
	v = store_ns.named("relay").call!(RpcMethods.fail(RpcMethods.store_iface), arg) ? Rpc.forward(|e| e)
	Ok(v)
}

relay_map! : Object.Self, { kind : Str } => Try(I64, [Shut, Constraint(Sql.Constraint), Infra(Rpc.Infra)])
relay_map! = |_self, arg| {
	v = store_ns.named("relay").call!(RpcMethods.fail(RpcMethods.store_iface), arg) ? Rpc.forward(
		|e| match e {
			NotOpen => Shut
			Constraint(c) => Constraint(c)
			Infra(i) => Infra(i)
		},
	)
	Ok(v)
}

# Store: `init!` waits 100 ms, then makes a table (PLAN.md 8f). No `alarm!`: `set_alarm_at!` gives `StorageErr`.

store_init! : Object.Self => Try({}, [Constraint(Sql.Constraint), Infra([SqlErr(Io.Thrown)])])
store_init! = |self| {
	Time.sleep!(100)
	_ = self.sql_run!("CREATE TABLE IF NOT EXISTS items (k TEXT)", Sql.none)?
	Ok({})
}

store_fetch! : Object.Self, Request => Try(Response, e)
store_fetch! = |self, req| match req.segments() {
	["set_alarm"] => answer(Str.inspect(self.set_alarm_at!(Time.now_ms!() + 60_000)))
	_ => {
		n : Try(List({ n : U64 }), _)
		n = self.sql!("SELECT count(*) AS n FROM items", Sql.none)
		answer(Str.inspect(n))
	}
}

# Flaky: `init!` gives `Err` while the key `fail-init` is in the local KV namespace `OBJFLAGS` (a raw program: the `Kv`
# module is another part of 8f).
flaky_init! : Object.Self => Try({}, [InitFailed, KvErr(Io.Thrown)])
flaky_init! = |_self| match Js.await!([Get(Root("env"), "OBJFLAGS"), Call(Slot(0), "get", [Lit(Text("fail-init"))])]) {
	Ok(Text(_)) => Err(InitFailed)
	Ok(_) => Ok({})
	Err(t) => Err(KvErr(t))
}

# Slow: `init!` waits longer than the `Init` deadline of the test (`initMs` in conformance/worker.js).
slow_init! : Object.Self => Try({}, [])
slow_init! = |_self| {
	Time.sleep!(6_000)
	Ok({})
}

plain_fetch! : Object.Self, Request => Try(Response, e)
plain_fetch! = |self, _req| answer("ok ${self.id()}")

# Ticker: `alarm!` gives `Err` while `retry_count` is less than 2, and logs `retry_count` and `is_retry`.
ticker_fetch! : Object.Self, Request => Try(Response, e)
ticker_fetch! = |self, _req| answer(Str.inspect(self.set_alarm_at!(Time.now_ms!() + 10)))

ticker_alarm! : Object.Self, { retry_count : U32, is_retry : Bool } => Try({}, [Retry(U32)])
ticker_alarm! = |_self, info| {
	Log.info!("ticker alarm", { retry_count: info.retry_count, is_retry: info.is_retry })
	if (info.retry_count < 2) Err(Retry(info.retry_count)) else Ok({})
}

# KvOnly: a class in a `new_classes` migration (KV-backed). The shim stops its first event with the class name.
kv_only_fetch! : Object.Self, Request => Try(Response, [Constraint(Sql.Constraint), Infra([SqlErr(Io.Thrown), BadData(Str), TooLarge])])
kv_only_fetch! = |self, _req| {
	rows : List({ x : I64 })
	rows = self.sql!("SELECT 1 AS x", Sql.none)?
	Ok(Response.from_text(200, Str.inspect(rows)))
}

Typed : { ta : Str, tb : Str, tc : Str, td : Str, a : Str, b : I64, c : F64, hd : Str }

Nulls : { an : I64, b : I64, cn : I64, tb : Str }

Stored : { v : Str, t : Str }

TextRow : { t : Str }

typed! : Object.Self, Str => Try(Response, e)
typed! = |self, k| {
	r : Try(List(Typed), _)
	r = self.sql!("SELECT typeof(a) AS ta, typeof(b) AS tb, typeof(c) AS tc, typeof(d) AS td, a, b, c, hex(d) AS hd FROM pt WHERE k = ?", [k])
	answer(Str.inspect(r))
}

stored! : Object.Self, Str, Try(a, e) => Try(Response, e2)
stored! = |self, k, wrote| match wrote {
	Ok(_) => {
		r : Try(List(Stored), _)
		r = self.sql!("SELECT CAST(v AS TEXT) AS v, typeof(v) AS t FROM pi WHERE k = ?", [k])
		answer(Str.inspect(r))
	}
	Err(e) => answer("Err ${Str.inspect(e)}")
}

missing : Try(I64, [Nope])
missing = Err(Nope)

sql_params! : Object.Self, Str => Try(Response, e)
sql_params! = |self, case| match case {
	"tuple" => {
		_ = self.sql_run!("INSERT INTO pt (k, a, b, c, d) VALUES (?, ?, ?, ?, ?)", ("tuple", "héllo", 42.I64, 1.5.F64, Sql.blob([1, 2, 3])))
		typed!(self, "tuple")
	}
	"null" => {
		present : Try(I64, [Nope])
		present = Ok(7)
		_ = self.sql_run!("INSERT INTO pt (k, a, b, c) VALUES (?, ?, ?, ?)", ("null", Sql.null, Sql.or_null(present), Sql.or_null(present)))
		_ = self.sql_run!("INSERT INTO pt (k, a, b, c) VALUES (?, ?, ?, ?)", ("null_err", Sql.null, Sql.or_null(missing), Sql.or_null(missing)))
		a : Try(List(Nulls), _)
		a = self.sql!("SELECT a IS NULL AS an, b, c IS NULL AS cn, typeof(b) AS tb FROM pt WHERE k = ?", ["null"])
		b : Try(List(Nulls), _)
		b = self.sql!("SELECT a IS NULL AS an, ifnull(b, -1) AS b, c IS NULL AS cn, typeof(b) AS tb FROM pt WHERE k = ?", ["null_err"])
		answer("ok=${Str.inspect(a)} err=${Str.inspect(b)}")
	}
	"u64max" => stored!(self, "u64max", self.sql_run!("INSERT INTO pi (k, v) VALUES (?, ?)", ("u64max", 9_223_372_036_854_775_807.U64)))
	"u64over" => stored!(self, "u64over", self.sql_run!("INSERT INTO pi (k, v) VALUES (?, ?)", ("u64over", 9_223_372_036_854_775_808.U64)))
	"p53" => stored!(self, "p53", self.sql_run!("INSERT INTO pi (k, v) VALUES (?, ?)", ("p53", 9_007_199_254_740_993.I64)))
	"record" => answer(Str.inspect(self.sql_run!("INSERT INTO pi (k, v) VALUES (?, ?)", { k: "record", v: 1.I64 })))
	"empty_record" => answer(Str.inspect(self.sql_run!("SELECT 1", {})))
	"err_null" => {
		bare : Try(I64, [Null])
		bare = Err(Null)
		answer(Str.inspect(self.sql_run!("INSERT INTO pi (k, v) VALUES (?, ?)", ("err_null", bare))))
	}
	"tag_item" => {
		bare : [Hit(I64), Miss]
		bare = Hit(3)
		answer(Str.inspect(self.sql_run!("INSERT INTO pi (k, v) VALUES (?, ?)", ("tag_item", bare))))
	}
	"bool" => answer(Str.inspect(self.sql_run!("INSERT INTO pi (k, v) VALUES (?, ?)", ("bool", Bool.True))))
	# v2 probe finding 28: a bare value is one parameter; the old `Sql` tag form is BadParam with the new form.
	"bare" => {
		r : Try(List(TextRow), _)
		r = self.sql!("SELECT ? AS t", "one")
		answer(Str.inspect(r))
	}
	"old_text" => {
		old : List([Text(Str)])
		old = [Text("ann")]
		answer(Str.inspect(self.sql_run!("INSERT INTO pi (k, v) VALUES ('old_text', ?)", old)))
	}
	# v2 probe findings 30, 31: a NULL and a boolean column in `sql!` (the rules of `D1.all!`).
	"read_null" => {
		r : Try(List(TextRow), _)
		r = self.sql!("SELECT NULL AS t", Sql.none)
		answer(Str.inspect(r))
	}
	"read_bool" => {
		r : Try(List({ b : Bool }), _)
		r = self.sql!("SELECT 1 = 1 AS b", Sql.none)
		answer(Str.inspect(r))
	}
	"none" => {
		r : Try(List({ id : I64 }), _)
		r = self.sql!("SELECT 1 AS id", Sql.none)
		answer(Str.inspect(r))
	}
	"single" => {
		r : Try(List(TextRow), _)
		r = self.sql!("SELECT ? AS t", ["one"])
		answer(Str.inspect(r))
	}
	"runtime_list" => {
		items : List(Sql)
		items = ["rt", "text"].map(|t| Text(t)).append(Int(5)).append(Real(2.5)).append(Blob([9]))
		_ = self.sql_run!("INSERT INTO pt (k, a, b, c, d) VALUES (?, ?, ?, ?, ?)", items)
		typed!(self, "rt")
	}
	_ => Ok(Response.from_text(404, "no case"))
}
