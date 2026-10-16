## SQL values and results (MODULES.md 5.1): the same types for D1 and, in phase B, for the storage of a Durable
## Object. A parameter is a `Sql` value. `rows!` (no types) gives `Sql` values.
Sql := [Null, Int(I64), Real(F64), Text(Str), Blob(List(U8))].{
	is_eq : _

	## One statement of `D1.batch!`.
	stmt : Str, List(Sql) -> Sql.Stmt
	stmt = |sql, params| { sql, params }

	Stmt : { sql : Str, params : List(Sql) }

	## The `meta` of a query. `last_row_id` is `Err(Rounded)` when D1 gave it with a size of 2^53 or more: D1 gives each
	## number as a JS `Number`, so a larger rowid is rounded (MODULES.md 5.1, "Integers in rows").
	Info : { changes : U64, last_row_id : Try(I64, [Rounded]), rows_read : U64, rows_written : U64, duration_ms : F64 }

	## Rows with no types: the column names, then one list of values for each row.
	Rows : { columns : List(Str), rows : List(List(Sql)) }

	## A constraint failure (MC9): the kind from the extended code in the message text, and the SQLite text
	## (5.1, table "Constraint kinds").
	Constraint : { kind : [PrimaryKey, Unique, ForeignKey, Check, NotNull, Trigger, Datatype, Other], message : Str }
}
