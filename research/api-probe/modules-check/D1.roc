import Io
import Cbor
import Sql

## A D1 binding. A value holds only the binding name (API.md 6.3).
D1 :: { name : Str }.{
	binding : Str -> D1
	binding = |name| D1.{ name }

	## Rows as records of the type that the caller wants. Column names are field names.
	## D1 gives objects, and JS sends them packed as CBOR (API.md 5, AQ9).
	all : D1, Str, List(Sql) -> Io(rows, [D1Err(Io.Thrown), BadData(Str)])
		where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	all = |db, sql, params| Io.typed(ops(db, "d1.all", sql, params), |t| D1Err(t))

	all! : D1, Str, List(Sql) => Try(rows, [D1Err(Io.Thrown), BadData(Str)])
		where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	all! = |db, sql, params| Io.run!(all(db, sql, params))

	## The first row, or `NotFound`.
	first : D1, Str, List(Sql) -> Io(a, [NotFound, D1Err(Io.Thrown), BadData(Str)])
		where [a.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	first = |db, sql, params| Io.new(ops(db, "d1.first", sql, params), |r| match r {
		Ok(bytes) if bytes == Io.null => Err(NotFound)
		Ok(bytes) => Io.decode(bytes)
		Err(t) => Err(D1Err(t))
	})

	first! : D1, Str, List(Sql) => Try(a, [NotFound, D1Err(Io.Thrown), BadData(Str)])
		where [a.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	first! = |db, sql, params| Io.run!(first(db, sql, params))

	run : D1, Str, List(Sql) -> Io(Sql.Info, [D1Err(Io.Thrown), BadData(Str)])
	run = |db, sql, params| Io.typed(ops(db, "d1.run", sql, params), |t| D1Err(t))

	run! : D1, Str, List(Sql) => Try(Sql.Info, [D1Err(Io.Thrown), BadData(Str)])
	run! = |db, sql, params| Io.run!(run(db, sql, params))
}

ops : D1, Str, Str, List(Sql) -> List(Str)
ops = |db, op, sql, params| {
	D1.{ name } = db
	[op, sql].concat(params.map(|p| p.to_param())).append(name)
}
