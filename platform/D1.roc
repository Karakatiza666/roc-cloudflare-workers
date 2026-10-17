## A D1 database (MODULES.md 5.1): `env[name]`, one program for each call. Typed rows cross as one `Packed` value
## (API.md 5.2) and `Cbor.parse_with` reads them into the type of the call (MC7), with `int_from_text`, so
## `CAST(id AS TEXT)` goes straight into an `I64` field. A constraint failure is `Constraint` (MC9), a read above its
## limit is `TooLarge` (MC11). A parameter outside ±(2^53 - 1) goes as decimal text: D1 takes no `BigInt`.
import Io
import Js
import Body
import Sql
import SqlRules
import cbor.Cbor

D1 :: { name : Str }.{
	binding : Str -> D1
	binding = |name| D1.{ name }

	## The rows as the type of the call: `rows : List(Pkg)`. To `Body.default_max` bytes of CBOR.
	all : D1, Str, List(Sql) -> Io(rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	all = |db, sql, params| all_io(start(db), sql, params, Body.default_max)

	all! : D1, Str, List(Sql) => Try(rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	all! = |db, sql, params| Io.run!(all(db, sql, params))

	all_with : D1, Str, List(Sql), { max_bytes : U64 } -> Io(rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	all_with = |db, sql, params, opts| all_io(start(db), sql, params, opts.max_bytes)

	all_with! : D1, Str, List(Sql), { max_bytes : U64 } => Try(rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	all_with! = |db, sql, params, opts| Io.run!(all_with(db, sql, params, opts))

	## `all` with the rows as tuples (D1 `raw()`): `rows : List((Str, I64))`. The tuple has one item for each column of the SELECT, in
	## its order, so the caller keeps the order in the SQL. About twice as fast as `all` for 200 rows (PLAN.md 8g). The same
	## limit and integer rules as `all`; `BadData` names the column by its index (from 0), not by name.
	all_tuples : D1, Str, List(Sql) -> Io(rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	all_tuples = |db, sql, params| all_tuples_io(start(db), sql, params, Body.default_max)

	all_tuples! : D1, Str, List(Sql) => Try(rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	all_tuples! = |db, sql, params| Io.run!(all_tuples(db, sql, params))

	all_tuples_with : D1, Str, List(Sql), { max_bytes : U64 } -> Io(rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	all_tuples_with = |db, sql, params, opts| all_tuples_io(start(db), sql, params, opts.max_bytes)

	all_tuples_with! : D1, Str, List(Sql), { max_bytes : U64 } => Try(rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	all_tuples_with! = |db, sql, params, opts| Io.run!(all_tuples_with(db, sql, params, opts))

	## The first row (D1 `first()`), or `NotFound`.
	first : D1, Str, List(Sql) -> Io(row, [NotFound, D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [row.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	first = |db, sql, params| first_io(start(db), sql, params, Body.default_max)

	first! : D1, Str, List(Sql) => Try(row, [NotFound, D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [row.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	first! = |db, sql, params| Io.run!(first(db, sql, params))

	first_with : D1, Str, List(Sql), { max_bytes : U64 } -> Io(row, [NotFound, D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [row.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	first_with = |db, sql, params, opts| first_io(start(db), sql, params, opts.max_bytes)

	first_with! : D1, Str, List(Sql), { max_bytes : U64 } => Try(row, [NotFound, D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [row.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	first_with! = |db, sql, params, opts| Io.run!(first_with(db, sql, params, opts))

	## A write: D1 `run()`, and its `meta`.
	run : D1, Str, List(Sql) -> Io(Sql.Info, [D1Err(Io.Thrown), Constraint(Sql.Constraint)])
	run = |db, sql, params| run_io(start(db), sql, params)

	run! : D1, Str, List(Sql) => Try(Sql.Info, [D1Err(Io.Thrown), Constraint(Sql.Constraint)])
	run! = |db, sql, params| Io.run!(run(db, sql, params))

	## Rows with no types (`raw({ columnNames: true })`), for columns that are not known at compile time.
	rows : D1, Str, List(Sql) -> Io(Sql.Rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), TooLarge])
	rows = |db, sql, params| rows_io(start(db), sql, params, Body.default_max)

	rows! : D1, Str, List(Sql) => Try(Sql.Rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), TooLarge])
	rows! = |db, sql, params| Io.run!(rows(db, sql, params))

	rows_with : D1, Str, List(Sql), { max_bytes : U64 } -> Io(Sql.Rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), TooLarge])
	rows_with = |db, sql, params, opts| rows_io(start(db), sql, params, opts.max_bytes)

	rows_with! : D1, Str, List(Sql), { max_bytes : U64 } => Try(Sql.Rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), TooLarge])
	rows_with! = |db, sql, params, opts| Io.run!(rows_with(db, sql, params, opts))

	## One transaction and one crossing (API.md 6.2): one `D1.Result` for each statement, in order. The rows of all
	## statements together are at most `Body.default_max` bytes.
	batch : D1, List(Sql.Stmt) -> Io(List(D1.Result), [D1Err(Io.Thrown), Constraint(Sql.Constraint), TooLarge])
	batch = |db, stmts| batch_io(start(db), stmts, Body.default_max)

	batch! : D1, List(Sql.Stmt) => Try(List(D1.Result), [D1Err(Io.Thrown), Constraint(Sql.Constraint), TooLarge])
	batch! = |db, stmts| Io.run!(batch(db, stmts))

	batch_with : D1, List(Sql.Stmt), { max_bytes : U64 } -> Io(List(D1.Result), [D1Err(Io.Thrown), Constraint(Sql.Constraint), TooLarge])
	batch_with = |db, stmts, opts| batch_io(start(db), stmts, opts.max_bytes)

	batch_with! : D1, List(Sql.Stmt), { max_bytes : U64 } => Try(List(D1.Result), [D1Err(Io.Thrown), Constraint(Sql.Constraint), TooLarge])
	batch_with! = |db, stmts, opts| Io.run!(batch_with(db, stmts, opts))

	## Statements with no parameters (D1 `exec`), for a schema. A constraint failure has the message
	## `Error in line <n>: <sql>: <text>` (5.1).
	exec : D1, Str -> Io({}, [D1Err(Io.Thrown), Constraint(Sql.Constraint)])
	exec = |db, sql| Io.new(
		[Get(Root("env"), db.name), Call(Slot(0), "exec", [Lit(Text(sql))])],
		|r| match r {
			Ok(_) => Ok({})
			Err(t) => Err(thrown(t))
		},
	)

	exec! : D1, Str => Try({}, [D1Err(Io.Thrown), Constraint(Sql.Constraint)])
	exec! = |db, sql| Io.run!(exec(db, sql))

	## `withSession`, sync (one `call!`, no wait): `Primary` is `"first-primary"`, `Any` `"first-unconstrained"`,
	## `After(b)` the bookmark of an earlier session. The session holds a ref: it is good for one task (MC13).
	with_session! : D1, [Primary, Any, After(Str)] => Try(D1.Session, [D1Err(Io.Thrown)])
	with_session! = |db, mode| {
		arg = match mode {
			Primary => "first-primary"
			Any => "first-unconstrained"
			After(b) => b
		}
		match Io.call!([Get(Root("env"), db.name), Call(Slot(0), "withSession", [Lit(Text(arg))])]) {
			Ok(Ref(r)) => Ok(D1.Session.{ ref: r })
			Ok(other) => crash "D1.with_session!: withSession gave ${Str.inspect(other)}"
			Err(t) => Err(D1Err(t))
		}
	}

	## A D1 session (Sessions API): the query functions of `D1` (not `exec`), and `bookmark!`.
	Session :: { ref : Js.Ref }.{
		all : D1.Session, Str, List(Sql) -> Io(rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
		all = |s, sql, params| all_io(session_start(s), sql, params, Body.default_max)

		all! : D1.Session, Str, List(Sql) => Try(rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
		all! = |s, sql, params| Io.run!(all(s, sql, params))

		all_with : D1.Session, Str, List(Sql), { max_bytes : U64 } -> Io(rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
		all_with = |s, sql, params, opts| all_io(session_start(s), sql, params, opts.max_bytes)

		all_with! : D1.Session, Str, List(Sql), { max_bytes : U64 } => Try(rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
		all_with! = |s, sql, params, opts| Io.run!(all_with(s, sql, params, opts))

		## `all` with the rows as tuples (D1 `raw()`): `rows : List((Str, I64))`. The tuple has one item for each column of the SELECT, in
		## its order, so the caller keeps the order in the SQL. About twice as fast as `all` for 200 rows (PLAN.md 8g). The same
		## limit and integer rules as `all`; `BadData` names the column by its index (from 0), not by name.
		all_tuples : D1.Session, Str, List(Sql) -> Io(rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
		all_tuples = |s, sql, params| all_tuples_io(session_start(s), sql, params, Body.default_max)

		all_tuples! : D1.Session, Str, List(Sql) => Try(rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
		all_tuples! = |s, sql, params| Io.run!(all_tuples(s, sql, params))

		all_tuples_with : D1.Session, Str, List(Sql), { max_bytes : U64 } -> Io(rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
		all_tuples_with = |s, sql, params, opts| all_tuples_io(session_start(s), sql, params, opts.max_bytes)

		all_tuples_with! : D1.Session, Str, List(Sql), { max_bytes : U64 } => Try(rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
		all_tuples_with! = |s, sql, params, opts| Io.run!(all_tuples_with(s, sql, params, opts))

		first : D1.Session, Str, List(Sql) -> Io(row, [NotFound, D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [row.Cbor.Parseable([InvalidCbor(U64), ..errs])]
		first = |s, sql, params| first_io(session_start(s), sql, params, Body.default_max)

		first! : D1.Session, Str, List(Sql) => Try(row, [NotFound, D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [row.Cbor.Parseable([InvalidCbor(U64), ..errs])]
		first! = |s, sql, params| Io.run!(first(s, sql, params))

		first_with : D1.Session, Str, List(Sql), { max_bytes : U64 } -> Io(row, [NotFound, D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [row.Cbor.Parseable([InvalidCbor(U64), ..errs])]
		first_with = |s, sql, params, opts| first_io(session_start(s), sql, params, opts.max_bytes)

		first_with! : D1.Session, Str, List(Sql), { max_bytes : U64 } => Try(row, [NotFound, D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [row.Cbor.Parseable([InvalidCbor(U64), ..errs])]
		first_with! = |s, sql, params, opts| Io.run!(first_with(s, sql, params, opts))

		run : D1.Session, Str, List(Sql) -> Io(Sql.Info, [D1Err(Io.Thrown), Constraint(Sql.Constraint)])
		run = |s, sql, params| run_io(session_start(s), sql, params)

		run! : D1.Session, Str, List(Sql) => Try(Sql.Info, [D1Err(Io.Thrown), Constraint(Sql.Constraint)])
		run! = |s, sql, params| Io.run!(run(s, sql, params))

		rows : D1.Session, Str, List(Sql) -> Io(Sql.Rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), TooLarge])
		rows = |s, sql, params| rows_io(session_start(s), sql, params, Body.default_max)

		rows! : D1.Session, Str, List(Sql) => Try(Sql.Rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), TooLarge])
		rows! = |s, sql, params| Io.run!(rows(s, sql, params))

		rows_with : D1.Session, Str, List(Sql), { max_bytes : U64 } -> Io(Sql.Rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), TooLarge])
		rows_with = |s, sql, params, opts| rows_io(session_start(s), sql, params, opts.max_bytes)

		rows_with! : D1.Session, Str, List(Sql), { max_bytes : U64 } => Try(Sql.Rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), TooLarge])
		rows_with! = |s, sql, params, opts| Io.run!(rows_with(s, sql, params, opts))

		batch : D1.Session, List(Sql.Stmt) -> Io(List(D1.Result), [D1Err(Io.Thrown), Constraint(Sql.Constraint), TooLarge])
		batch = |s, stmts| batch_io(session_start(s), stmts, Body.default_max)

		batch! : D1.Session, List(Sql.Stmt) => Try(List(D1.Result), [D1Err(Io.Thrown), Constraint(Sql.Constraint), TooLarge])
		batch! = |s, stmts| Io.run!(batch(s, stmts))

		batch_with : D1.Session, List(Sql.Stmt), { max_bytes : U64 } -> Io(List(D1.Result), [D1Err(Io.Thrown), Constraint(Sql.Constraint), TooLarge])
		batch_with = |s, stmts, opts| batch_io(session_start(s), stmts, opts.max_bytes)

		batch_with! : D1.Session, List(Sql.Stmt), { max_bytes : U64 } => Try(List(D1.Result), [D1Err(Io.Thrown), Constraint(Sql.Constraint), TooLarge])
		batch_with! = |s, stmts, opts| Io.run!(batch_with(s, stmts, opts))

		## `getBookmark`, sync: `NotFound` before the first query of the session.
		bookmark! : D1.Session => Try(Str, [NotFound])
		bookmark! = |s| match Io.call!([Call(Ref(s.ref), "getBookmark", [])]) {
			Ok(Text(b)) => Ok(b)
			Ok(Null) => Err(NotFound)
			Ok(other) => crash "D1.Session.bookmark!: getBookmark gave ${Str.inspect(other)}"
			Err(t) => crash "D1.Session.bookmark!: ${t.name}: ${t.message}"
		}
	}

	## The result of one statement of `batch!`: its `meta`, and its rows as CBOR, typed at the use (MC7).
	Result :: { info : Sql.Info, rows : List(U8) }.{
		info : D1.Result -> Sql.Info
		info = |r| r.info

		all : D1.Result -> Try(rows, [BadData(Str)]) where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
		all = |r| SqlRules.typed(r.rows)

		## The first row, or `NotFound`.
		first : D1.Result -> Try(row, [NotFound, BadData(Str)]) where [row.Cbor.Parseable([InvalidCbor(U64), ..errs])]
		first = |r| match first_item(r.rows) {
			Ok(bytes) => SqlRules.typed(bytes).map_err(|BadData(text)| BadData(text))
			Err(Empty) => Err(NotFound)
			Err(Bad) => Err(BadData("the rows are not an array"))
		}
	}
}

## Where a program starts: the binding (`env[name]`, slot 0) or a session (its ref, no op).
At : { ops : List(Js.Op), obj : Js.Target }

start : D1 -> At
start = |db| { ops: [Get(Root("env"), db.name)], obj: Slot(0) }

session_start : D1.Session -> At
session_start = |s| { ops: [], obj: Ref(s.ref) }

## `prepare(sql)`, then `bind(...params)`: the ops, and the slot of the bound statement.
bound : At, Str, List(Sql) -> { ops : List(Js.Op), stmt : U32 }
bound = |at, sql, params| {
	n = at.ops.len().to_u32_wrap()
	{
		ops: at.ops.concat([Call(at.obj, "prepare", [Lit(Text(sql))]), Call(Slot(n), "bind", params.map(|p| Lit(SqlRules.param(p))))]),
		stmt: n + 1,
	}
}

all_io : At, Str, List(Sql), U64 -> Io(rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
all_io = |at, sql, params, max| {
	b = bound(at, sql, params)
	s = b.stmt
	Io.new(
		b.ops.concat([Call(Slot(s), "all", []), Get(Slot(s + 1), "results"), Call(Root("pf"), "pack", [Slot(s + 2), Lit(Int(limit(max)))])]),
		|r| match r {
			Ok(Packed(bytes)) => match SqlRules.typed(bytes) {
				Ok(v) => Ok(v)
				Err(BadData(text)) => Err(BadData(text))
			}
			Ok(other) => crash "D1.all: pf.pack gave ${Str.inspect(other)}"
			Err(t) => Err(read_error(t))
		},
	)
}

first_io : At, Str, List(Sql), U64 -> Io(row, [NotFound, D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [row.Cbor.Parseable([InvalidCbor(U64), ..errs])]
first_io = |at, sql, params, max| {
	b = bound(at, sql, params)
	s = b.stmt
	Io.new(
		b.ops.concat([Call(Slot(s), "first", []), Call(Root("pf"), "pack", [Slot(s + 1), Lit(Int(limit(max)))])]),
		|r| match r {
			# `first()` gives `null` for no row.
			Ok(Packed([0xf6])) => Err(NotFound)
			Ok(Packed(bytes)) => match SqlRules.typed(bytes) {
				Ok(v) => Ok(v)
				Err(BadData(text)) => Err(BadData(text))
			}
			Ok(other) => crash "D1.first: pf.pack gave ${Str.inspect(other)}"
			Err(t) => Err(read_error(t))
		},
	)
}

run_io : At, Str, List(Sql) -> Io(Sql.Info, [D1Err(Io.Thrown), Constraint(Sql.Constraint)])
run_io = |at, sql, params| {
	b = bound(at, sql, params)
	s = b.stmt
	Io.new(
		b.ops.concat([Call(Slot(s), "run", []), Get(Slot(s + 1), "meta"), Call(Root("pf"), "pack", [Slot(s + 2)])]),
		|r| match r {
			Ok(Packed(bytes)) => info_of(bytes).map_err(|text| D1Err({ name: "BadData", message: text }))
			Ok(other) => crash "D1.run: pf.pack gave ${Str.inspect(other)}"
			Err(t) => Err(thrown(t))
		},
	)
}

rows_io : At, Str, List(Sql), U64 -> Io(Sql.Rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), TooLarge])
rows_io = |at, sql, params, max| {
	b = bound(at, sql, params)
	s = b.stmt
	Io.new(
		b.ops.concat([Call(Slot(s), "raw", [Lit(Obj([("columnNames", Bool(Bool.True))]))]), Call(Root("pf"), "limit", [Slot(s + 1), Lit(Int(limit(max)))])]),
		|r| match r {
			Ok(Arr(items)) => match items {
				[Arr(names), .. as rest] => Ok({ columns: names.map(SqlRules.column_name), rows: rest.map(SqlRules.row_of) })
				_ => crash "D1.rows: raw gave no column names"
			}
			Ok(other) => crash "D1.rows: raw gave ${Str.inspect(other)}"
			Err(t) => Err(read_error(t))
		},
	)
}

## `raw()` with no column names, then `pf.pack`: the rows as CBOR arrays, read as tuples. `raw()` does not send the keys, so
## the host writes less and the parser has no key to match (PLAN.md 8g, P1).
all_tuples_io : At, Str, List(Sql), U64 -> Io(rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
all_tuples_io = |at, sql, params, max| {
	b = bound(at, sql, params)
	s = b.stmt
	Io.new(
		b.ops.concat([Call(Slot(s), "raw", []), Call(Root("pf"), "pack", [Slot(s + 1), Lit(Int(limit(max)))])]),
		|r| match r {
			Ok(Packed(bytes)) => match SqlRules.typed_tuples(bytes) {
				Ok(v) => Ok(v)
				Err(BadData(text)) => Err(BadData(text))
			}
			Ok(other) => crash "D1.all_tuples: pf.pack gave ${Str.inspect(other)}"
			Err(t) => Err(read_error(t))
		},
	)
}

## `prepare` and `bind` for each statement, then `batch` of them, then the `results` and the `meta` of each result as
## `Packed` values (`pf.packEach`, API.md 6.4). `max`: the limit of all rows together.
batch_io : At, List(Sql.Stmt), U64 -> Io(List(D1.Result), [D1Err(Io.Thrown), Constraint(Sql.Constraint), TooLarge])
batch_io = |at, stmts, max| {
	built = stmts.fold(
		{ ops: at.ops, slots: [] },
		|acc, st| {
			b = bound({ ops: acc.ops, obj: at.obj }, st.sql, st.params)
			{ ops: b.ops, slots: acc.slots.append(Slot(b.stmt)) }
		},
	)
	n = built.ops.len().to_u32_wrap()
	Io.new(
		built.ops.concat([
			Array(built.slots),
			Call(at.obj, "batch", [Slot(n)]),
			Call(Root("pf"), "packEach", [Slot(n + 1), Lit(Text("results")), Lit(Int(limit(max)))]),
			Call(Root("pf"), "packEach", [Slot(n + 2), Lit(Text("meta"))]),
		]),
		|r| match r {
			Ok(Arr(items)) => Ok(items.map(result_of))
			Ok(other) => crash "D1.batch: packEach gave ${Str.inspect(other)}"
			Err(t) => Err(read_error(t))
		},
	)
}

result_of : Js -> D1.Result
result_of = |item| match item {
	Obj(fields) => match (field(fields, "results"), field(fields, "meta")) {
		(Packed(rows), Packed(meta)) => match info_of(meta) {
			Ok(info) => D1.Result.{ info, rows }
			Err(text) => crash "D1.batch: ${text}"
		}
		_ => crash "D1.batch: a result has no results or meta"
	}
	_ => crash "D1.batch: a result is not an object"
}

## The `meta` of D1, as `pf.pack` writes it. `last_row_id` is an F64: a rowid of size 2^53 or more is an f64, and an
## integer field does not read it (MODULES.md 5.1).
Meta : { changes : U64, last_row_id : F64, rows_read : U64, rows_written : U64, duration : F64 }

info_of : List(U8) -> Try(Sql.Info, Str)
info_of = |bytes| {
	parsed : Try(Meta, _)
	parsed = Cbor.parse_with(bytes, { fields: Snake, int_from_text: Bool.False })
	match parsed {
		Ok(m) => Ok({ changes: m.changes, last_row_id: row_id(m.last_row_id), rows_read: m.rows_read, rows_written: m.rows_written, duration_ms: m.duration })
		Err(e) => Err("the meta of D1 does not fit: ${Str.inspect(e)}")
	}
}

## A rowid of size 2^53 or more can be the rounded value of many rowids (5.1).
row_id : F64 -> Try(I64, [Rounded])
row_id = |f| if f.abs() < 9_007_199_254_740_992.0 Ok(f.to_i64_try() ?? 0) else Err(Rounded)

## The bytes of the first item of a CBOR array (the first row of `D1.Result.first`). A `where` clause cannot name
## `List(row)` (MODULES.md 15), so the module cuts the first row out and parses it as a `row`.
first_item : List(U8) -> Try(List(U8), [Empty, Bad])
first_item = |bytes| {
	h = head(bytes, 0)?
	if h.major != 4 {
		Err(Bad)
	} else if h.arg == 0 {
		Err(Empty)
	} else {
		end = skip(bytes, h.next)?
		Ok(bytes.sublist({ start: h.next, len: end - h.next }))
	}
}

## The head of the CBOR item at `pos`: its major type, its argument, and the offset after the head.
head : List(U8), U64 -> Try({ major : U8, arg : U64, next : U64 }, [Bad])
head = |bytes, pos| {
	ib = bytes.get(pos) ? |_| Bad
	info = ib.bitwise_and(31)
	width = match info {
		24 => 1
		25 => 2
		26 => 4
		27 => 8
		_ => if info < 24 0 else return Err(Bad)
	}
	if pos + 1 + width > bytes.len() {
		return Err(Bad)
	}
	arg = if width == 0 info.to_u64() else bytes.sublist({ start: pos + 1, len: width }).fold(0.U64, |acc, b| acc.shl_wrap(8).bitwise_or(b.to_u64()))
	Ok({ major: ib.shr_zf_wrap(5), arg, next: pos + 1 + width })
}

## The offset after the whole item at `pos`. A loop with a count of the items left, not a recursion.
skip : List(U8), U64 -> Try(U64, [Bad])
skip = |bytes, pos| {
	var $at = pos
	var $todo = 1.U64
	while $todo > 0 {
		h = head(bytes, $at)?
		left = bytes.len() - h.next
		(next, more) = match h.major {
			2 | 3 => if h.arg > left return Err(Bad) else (h.next + h.arg, 0)
			4 => if h.arg > left return Err(Bad) else (h.next, h.arg)
			5 => if h.arg > left // 2 return Err(Bad) else (h.next, h.arg * 2)
			6 => (h.next, 1)
			_ => (h.next, 0)
		}
		$at = next
		$todo = $todo - 1 + more
	}
	Ok($at)
}

## MC9: a constraint failure, else `D1Err`.
thrown : Io.Thrown -> [D1Err(Io.Thrown), Constraint(Sql.Constraint)]
thrown = |t| match SqlRules.constraint_of(t.message) {
	Ok(c) => Constraint(c)
	Err(NotConstraint) => D1Err(t)
}

## A read: also the limit of `pf.pack`, `pf.packEach` and `pf.limit` (MC11).
read_error : Io.Thrown -> [D1Err(Io.Thrown), Constraint(Sql.Constraint), TooLarge]
read_error = |t| if t.name == "TooLarge" TooLarge else match thrown(t) {
	Constraint(c) => Constraint(c)
	D1Err(e) => D1Err(e)
}

## A limit as the `Int` of a program (I64).
limit : U64 -> I64
limit = |n| n.to_i64_try() ?? I64.highest

field : List((Str, Js)), Str -> Js
field = |fields, name| match fields.find_first(|(k, _)| k == name) {
	Ok((_, v)) => v
	Err(_) => Undefined
}

# 5.1: `last_row_id` of size 2^53 or more is `Rounded`.
expect row_id(5.0) == Ok(5)
expect row_id(9_007_199_254_740_991.0) == Ok(9_007_199_254_740_991)
expect row_id(9_007_199_254_740_992.0) == Err(Rounded)
expect row_id(-2_687_166_099_708_854_000.0) == Err(Rounded)

# The first row of a batch result: [{"a": [1, 2]}, 7] gives {"a": [1, 2]}; [] is `Empty`.
expect first_item([0x82, 0xa1, 0x61, 0x61, 0x82, 0x01, 0x02, 0x07]) == Ok([0xa1, 0x61, 0x61, 0x82, 0x01, 0x02])
expect first_item([0x80]) == Err(Empty)
expect first_item([0xa0]) == Err(Bad)
expect first_item([0x81, 0x82, 0x01]) == Err(Bad)

