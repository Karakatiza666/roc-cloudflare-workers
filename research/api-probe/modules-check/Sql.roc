## SQL values and results, the same for D1 and for the storage of a Durable Object.
## `parser_for` and `encoder_for`: prototype only. The fake JS side sends `Sql.Rows` as CBOR,
## and the platform reads `rows!` as a `Js` tree (MODULES.md 5.1).
Sql := [Null, Int(I64), Real(F64), Text(Str), Blob(List(U8))].{
	parser_for : _
	encoder_for : _

	to_param : Sql -> Str
	to_param = |v| match v {
		Null => "null"
		Int(n) => n.to_str()
		Real(_) => "real"
		Text(t) => t
		Blob(_) => "blob"
	}

	stmt : Str, List(Sql) -> Sql.Stmt
	stmt = |sql, params| { sql, params }

	Stmt : { sql : Str, params : List(Sql) }

	Info : { changes : U64, last_row_id : I64, rows_read : U64, rows_written : U64, duration_ms : F64 }

	Rows : { columns : List(Str), rows : List(List(Sql)) }

	## MC9: a throw whose message has "constraint failed" is `Constraint(message)`, with the SQLite
	## text after "D1_ERROR: ". Each other throw goes to `other`. The type is `Io.Thrown` (no import: `Io` imports `Sql`).
	throw : { name : Str, message : Str }, ({ name : Str, message : Str } -> [Constraint(Str), ..e]) -> [Constraint(Str), ..e]
	throw = |t, other| if t.message.contains("constraint failed") Constraint(t.message.drop_prefix("D1_ERROR: ")) else other(t)
}
