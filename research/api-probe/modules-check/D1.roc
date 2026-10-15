import Io
import Js
import Body
import Cbor
import Sql

## A D1 binding. A value holds only the binding name (API.md 6.3, MC1).
D1 :: { name : Str }.{
	binding : Str -> D1
	binding = |name| D1.{ name }

	## Rows as records of the type that the caller wants. Column names are field names.
	## D1 gives objects, and JS sends them packed as CBOR (API.md 5, AQ9).
	all : D1, Str, List(Sql) -> Io(rows, [D1Err(Io.Thrown), Constraint(Str), BadData(Str), TooLarge])
		where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	all = |db, sql, params| all_in(target(db), sql, params, Body.default_max)

	all! : D1, Str, List(Sql) => Try(rows, [D1Err(Io.Thrown), Constraint(Str), BadData(Str), TooLarge])
		where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	all! = |db, sql, params| Io.run!(all(db, sql, params))

	all_with! : D1, Str, List(Sql), { max_bytes : U64 } => Try(rows, [D1Err(Io.Thrown), Constraint(Str), BadData(Str), TooLarge])
		where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	all_with! = |db, sql, params, opts| Io.run!(all_in(target(db), sql, params, opts.max_bytes))

	## The first row, or `NotFound`.
	first : D1, Str, List(Sql) -> Io(row, [NotFound, D1Err(Io.Thrown), Constraint(Str), BadData(Str), TooLarge])
		where [row.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	first = |db, sql, params| first_in(target(db), sql, params)

	first! : D1, Str, List(Sql) => Try(row, [NotFound, D1Err(Io.Thrown), Constraint(Str), BadData(Str), TooLarge])
		where [row.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	first! = |db, sql, params| Io.run!(first(db, sql, params))

	run : D1, Str, List(Sql) -> Io(Sql.Info, [D1Err(Io.Thrown), Constraint(Str)])
	run = |db, sql, params| run_in(target(db), sql, params)

	run! : D1, Str, List(Sql) => Try(Sql.Info, [D1Err(Io.Thrown), Constraint(Str)])
	run! = |db, sql, params| Io.run!(run(db, sql, params))

	## `withSession`, sync. A session holds a ref, so it is its own type, good for one task (MC13).
	with_session! : D1, [Primary, Any, After(Str)] => Try(D1.Session, [D1Err(Io.Thrown)])
	with_session! = |db, mode| {
		D1.{ name } = db
		arg = match mode {
			Primary => "first-primary"
			Any => "first-unconstrained"
			After(b) => b
		}
		ref : U32
		ref = Io.run!(Io.tree(["d1.session", name, arg], |t| D1Err(t)))?
		Ok(D1.Session.{ name, ref: Js.Ref.fake(ref) })
	}

	## A D1 session (Sessions API): the query functions of `D1` and `bookmark!`.
	Session :: { name : Str, ref : Js.Ref }.{
		all! : D1.Session, Str, List(Sql) => Try(rows, [D1Err(Io.Thrown), Constraint(Str), BadData(Str), TooLarge])
			where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
		all! = |s, sql, params| Io.run!(all_in(session_target(s), sql, params, Body.default_max))

		first! : D1.Session, Str, List(Sql) => Try(row, [NotFound, D1Err(Io.Thrown), Constraint(Str), BadData(Str), TooLarge])
			where [row.Cbor.Parseable([InvalidCbor(U64), ..errs])]
		first! = |s, sql, params| Io.run!(first_in(session_target(s), sql, params))

		run! : D1.Session, Str, List(Sql) => Try(Sql.Info, [D1Err(Io.Thrown), Constraint(Str)])
		run! = |s, sql, params| Io.run!(run_in(session_target(s), sql, params))

		## `getBookmark`, sync: `NotFound` before the first query.
		bookmark! : D1.Session => Try(Str, [NotFound])
		bookmark! = |s| {
			D1.Session.{ ref, .. } = s
			match Io.run!(Io.new(["d1.bookmark", ref.to_str()], |r| r)) {
				Ok(bytes) if bytes != Io.null => Io.decode(bytes).map_err(|_| NotFound)
				_ => Err(NotFound)
			}
		}
	}
}

## The start of the program: a binding or a session.
target : D1 -> Str
target = |db| {
	D1.{ name } = db
	name
}

session_target : D1.Session -> Str
session_target = |s| {
	D1.Session.{ name, ref } = s
	"${name}/session:${ref.to_str()}"
}

err : Io.Thrown -> [D1Err(Io.Thrown), Constraint(Str), TooLarge]
err = |t| if Io.too_large(t) TooLarge else Sql.throw(t, |o| D1Err(o))

all_in : Str, Str, List(Sql), U64 -> Io(rows, [D1Err(Io.Thrown), Constraint(Str), BadData(Str), TooLarge])
	where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
all_in = |at, sql, params, max| Io.typed(ops("d1.all", at, sql, params).append(Io.max(max)), |t| err(t))

first_in : Str, Str, List(Sql) -> Io(row, [NotFound, D1Err(Io.Thrown), Constraint(Str), BadData(Str), TooLarge])
	where [row.Cbor.Parseable([InvalidCbor(U64), ..errs])]
first_in = |at, sql, params| Io.new(ops("d1.first", at, sql, params).append(Io.max(Body.default_max)), |r| match r {
	Ok(bytes) if bytes == Io.null => Err(NotFound)
	Ok(bytes) => Io.decode(bytes)
	Err(t) => Err(err(t))
})

run_in : Str, Str, List(Sql) -> Io(Sql.Info, [D1Err(Io.Thrown), Constraint(Str)])
run_in = |at, sql, params| Io.tree(ops("d1.run", at, sql, params), |t| Sql.throw(t, |o| D1Err(o)))

ops : Str, Str, Str, List(Sql) -> List(Str)
ops = |op, at, sql, params| [op, sql].concat(params.map(|p| p.to_param())).append(at)
