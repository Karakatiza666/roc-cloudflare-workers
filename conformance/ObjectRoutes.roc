## Durable Objects (MODULES.md 7, 9 `Object.Cell`, PLAN.md 8f part 1). The classes of the app (`classes`, in the field
## `objects` of `Worker` in app.roc) and the routes of the Worker that call them. `checks/objects.mjs` has the bindings.
## A route `/objects/counter/<op>?name=<n>` gives the request to the object `<n>` of `Counter`, which answers the op.
import pf.Request
import pf.Response
import pf.Object
import pf.Rpc
import pf.Sql
import pf.Io
import pf.Time
import pf.Log
import pf.Ctx
import RpcMethods
import RpcErrRoutes
import Q

counters = Object.namespace("COUNTERS")
stores = Object.namespace("STORES")
flakies = Object.namespace("FLAKY")
slows = Object.namespace("SLOW")
tickers = Object.namespace("TICKERS")
kv_only = Object.namespace("KVONLY")

count : Object.Cell(I64)
count = Object.cell("count")

## Written after `respond!` (API.md 10.2).
late : Object.Cell(Str)
late = Object.cell("late")

## Typed rows of the object SQL.
Row : { id : I64, u : Str }
Wide : { v : I64 }
Big : { x : Str }

ObjectRoutes :: [].{

	## The classes of the app: the manifest names them, and `conformance/worker.js` exports each one.
	classes : List(Object.Class)
	classes = [
		Object.class("Counter", { fetch!: counter_fetch!, alarm!: counter_alarm!, rpc: [RpcMethods.increment.on(increment!), RpcMethods.ping.on(object_ping!), RpcMethods.boom.on(boom!), RpcMethods.echo.on(echo!), RpcMethods.hello.on(object_hello!)].concat(RpcErrRoutes.object_handlers) }),
		Object.class("Store", { init!: store_init!, fetch!: store_fetch! }),
		Object.class("Flaky", { init!: flaky_init!, fetch!: plain_fetch! }),
		Object.class("Slow", { init!: slow_init!, fetch!: plain_fetch! }),
		Object.class("Ticker", { fetch!: ticker_fetch!, alarm!: ticker_alarm! }),
		Object.class("KvOnly", { fetch!: kv_only_fetch! }),
	]

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
				t0 = Time.now_ms!({})
				body = text!(counters.named(name).fetch!(Request.get("http://o/respond")))
				Response.from_text(200, "${body} fast=${Str.inspect(Time.now_ms!({}) - t0 < 250)}")
			}
			# RPC (MODULES.md 8) on an object stub, and the `Io` twins of `call` and `fetch`.
			["rpc", "increment"] => {
				o = counters.named(name)
				a = o.call!(RpcMethods.increment, { by: 2 })
				b = Io.run!(o.call(RpcMethods.increment, { by: 3 }))
				Response.from_text(200, "${Str.inspect(a)} ${Str.inspect(b)}")
			}
			["rpc", "ping"] => Response.from_text(200, Str.inspect(counters.named(name).call!(RpcMethods.ping, { n: 7 })))
			["rpc", "boom"] => Response.from_text(200, Str.inspect(counters.named(name).call!(RpcMethods.boom, { n: 3 })))
			["rpc", "nothere"] => Response.from_text(200, Str.inspect(counters.named(name).call!(RpcMethods.nothere, { n: 1 })))
			["rpc", "echo"] => Response.from_text(200, Str.inspect(counters.named(name).call!(RpcMethods.echo, { big: 1_152_921_504_606_846_976 })))
			["fetch_io"] => Response.from_text(200, text!(Io.run!(counters.named(name).fetch(Request.get("http://o/id")))))
			_ => Response.from_text(404, "no route")
		}
	}
}

## The request to the object: the op as its path, and the query of the route.
forward! : Object, List(Str), Request => Response
forward! = |o, op, req| {
	query = match req.url.split_first("?") {
		Ok({ after, .. }) => "?${after}"
		Err(_) => ""
	}
	Response.from_text(200, text!(o.fetch!(Request.get("http://o/${Str.join_with(op, "/")}${query}"))))
}

## The body of a response of an object as text, or the error.
text! : Try(Response, [ObjectErr(Io.Thrown)]) => Str
text! = |r| match r {
	Ok(res) => match res.text!() {
		Ok(t) => if res.status == 200 t else "status ${res.status.to_str()} ${t}"
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
		answer(match n { Ok([row]) => "n=${row.n.to_str()}", _ => "Err" })
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
	["cell"] => {
		before = count.get!(self)
		set = count.set!(self, -9_007_199_254_740_993)
		got = count.get!(self)
		del = count.delete!(self)
		after = count.get!(self)
		answer("before=${Str.inspect(before)} set=${Str.inspect(set)} got=${Str.inspect(got)} del=${Str.inspect(del)} after=${Str.inspect(after)}")
	}
	# `get_alarm!` after `set_alarm!(t)` gives `t` (and the twins), `delete_alarm!` removes it.
	["alarm"] => {
		t = Time.now_ms!({}) + 3_600_000
		set = self.set_alarm!(t)
		got = self.get_alarm!()
		twin = Io.run!(self.get_alarm())
		del = Io.run!(self.delete_alarm())
		after = self.get_alarm!()
		set2 = Io.run!(self.set_alarm(t))
		del2 = self.delete_alarm!()
		answer("set=${Str.inspect(set)} same=${Str.inspect(got == Ok(t))} twin=${Str.inspect(twin == Ok(t))} del=${Str.inspect(del)} after=${Str.inspect(after)} set2=${Str.inspect(set2)} del2=${Str.inspect(del2)}")
	}
	# A table, a cell and an alarm, then `delete_all!`: all three are gone.
	["delete_all"] => {
		_ = self.sql_run!("CREATE TABLE IF NOT EXISTS gone (a)", Sql.none)
		_ = count.set!(self, 5)
		_ = self.set_alarm!(Time.now_ms!({}) + 3_600_000)
		del = if Q.text(req, "twin") == "1" Io.run!(self.delete_all()) else self.delete_all!()
		table : Try(List({ a : I64 }), _)
		table = self.sql!("SELECT a FROM gone", Sql.none)
		answer("del=${Str.inspect(del)} table=${Str.inspect(table.is_ok())} cell=${Str.inspect(count.get!(self))} alarm=${Str.inspect(self.get_alarm!())}")
	}
	# API.md 10.2: `Response.after` in the `Fetch` of an object: the response, then the work.
	["respond"] => {
		work! = |_| {
			Time.sleep!(300)
			late.set!(self, "written")
		}
		Ok(Response.from_text(200, "early").after(work!))
	}
	["late"] => answer(Str.inspect(late.get!(self)))
	["pass_through"] => answer(Str.inspect(Ctx.pass_through!({})))
	_ => Ok(Response.from_text(404, "no op"))
}

counter_alarm! : Object.Self, { retry_count : U32, is_retry : Bool } => Try({}, [])
counter_alarm! = |_self, _info| Ok({})

increment! : Object.Self, { by : I64 } => Try(I64, [StorageErr(Io.Thrown)])
increment! = |self, { by }| {
	n = (count.get!(self) ?? 0) + by
	count.set!(self, n)?
	Ok(n)
}

object_ping! : Object.Self, { n : I64 } => Try(Str, Rpc.NoErr)
object_ping! = |_self, { n }| Ok("object ping ${n.to_str()}")

object_hello! : Object.Self, {} => Try(Str, Rpc.NoErr)
object_hello! = |_self, {}| Ok("object hello")

boom! : Object.Self, { n : I64 } => Try(I64, [Nope(I64)])
boom! = |_self, { n }| Err(Nope(n))

echo! : Object.Self, { big : U64 } => Try({ big : U64 }, Rpc.NoErr)
echo! = |_self, v| Ok(v)

# Store: `init!` waits 100 ms, then makes a table (PLAN.md 8f). No `alarm!`: `set_alarm!` gives `StorageErr`.

store_init! : Object.Self => Try({}, [SqlErr(Io.Thrown), Constraint(Sql.Constraint)])
store_init! = |self| {
	Time.sleep!(100)
	_ = self.sql_run!("CREATE TABLE IF NOT EXISTS items (k TEXT)", Sql.none)?
	Ok({})
}

store_fetch! : Object.Self, Request => Try(Response, e)
store_fetch! = |self, req| match req.segments() {
	["set_alarm"] => answer(Str.inspect(self.set_alarm!(Time.now_ms!({}) + 60_000)))
	_ => {
		n : Try(List({ n : U64 }), _)
		n = self.sql!("SELECT count(*) AS n FROM items", Sql.none)
		answer(Str.inspect(n))
	}
}

# Flaky: `init!` gives `Err` while the key `fail-init` is in the local KV namespace `OBJFLAGS` (a raw program: the `Kv`
# module is another part of 8f).
flaky_init! : Object.Self => Try({}, [InitFailed, KvErr(Io.Thrown)])
flaky_init! = |_self| match Io.await!([Get(Root("env"), "OBJFLAGS"), Call(Slot(0), "get", [Lit(Text("fail-init"))])]) {
	Ok(Text(_)) => Err(InitFailed)
	Ok(_) => Ok({})
	Err(t) => Err(KvErr(t))
}

# Slow: `init!` waits longer than the `Init` deadline of the test (`initMs` in conformance/worker.js).
slow_init! : Object.Self => Try({}, [])
slow_init! = |_self| {
	Time.sleep!(3_000)
	Ok({})
}

plain_fetch! : Object.Self, Request => Try(Response, e)
plain_fetch! = |self, _req| answer("ok ${self.id()}")

# Ticker: `alarm!` gives `Err` while `retry_count` is less than 2, and logs `retry_count` and `is_retry`.
ticker_fetch! : Object.Self, Request => Try(Response, e)
ticker_fetch! = |self, _req| answer(Str.inspect(self.set_alarm!(Time.now_ms!({}) + 10)))

ticker_alarm! : Object.Self, { retry_count : U32, is_retry : Bool } => Try({}, [Retry(U32)])
ticker_alarm! = |_self, info| {
	Log.info!("ticker alarm", { retry_count: info.retry_count, is_retry: info.is_retry })
	if info.retry_count < 2 Err(Retry(info.retry_count)) else Ok({})
}

# KvOnly: a class in a `new_classes` migration (KV-backed). The shim stops its first event with the class name.
kv_only_fetch! : Object.Self, Request => Try(Response, [SqlErr(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge])
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
