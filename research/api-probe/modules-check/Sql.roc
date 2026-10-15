## SQL values and results, the same for D1 and for the storage of a Durable Object.
Sql := [Null, Int(I64), Real(F64), Text(Str), Blob(List(U8))].{
	to_param : Sql -> Str
	to_param = |v| match v {
		Null => "null"
		Int(n) => n.to_str()
		Real(_) => "real"
		Text(t) => t
		Blob(_) => "blob"
	}

	Info : { changes : U64, last_row_id : I64 }
}
