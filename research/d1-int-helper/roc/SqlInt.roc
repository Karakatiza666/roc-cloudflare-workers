## Prototype (option B): SQL text helpers for a D1 INTEGER column. Not in the platform.
SqlInt :: [].{
	## `col("p.id")` is `CAST(p.id AS TEXT) AS id`: the alias is the part after the last dot.
	col : Str -> Str
	col = |expr| {
		alias = match expr.split_last(".") {
			Ok({ after, .. }) => after
			Err(_) => expr
		}
		"CAST(${expr} AS TEXT) AS ${alias}"
	}

	## `cols(["id", "parent_id"])` is `CAST(id AS TEXT) AS id, CAST(parent_id AS TEXT) AS parent_id`.
	cols : List(Str) -> Str
	cols = |exprs| Str.join_with(exprs.map(SqlInt.col), ", ")
}

expect SqlInt.col("id") == "CAST(id AS TEXT) AS id"
expect SqlInt.col("p.id") == "CAST(p.id AS TEXT) AS id"
expect SqlInt.cols(["id", "p.parent_id"]) == "CAST(id AS TEXT) AS id, CAST(p.parent_id AS TEXT) AS parent_id"

# A trap of the alias rule: an expression gives a bad alias, so the SQL does not parse. The user must write the CAST.
expect SqlInt.col("a.id + 1") == "CAST(a.id + 1 AS TEXT) AS id + 1"
