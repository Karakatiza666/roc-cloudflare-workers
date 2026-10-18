## `D1` and `Sql` (MODULES.md 5.1, PLAN.md 8c, 8d). The binding `DB` is in `checks/d1.mjs`, which also makes the tables.
## Each route answers `Ok <text>` or `Err <the error>`. `?sql=` is the SQL, `?p=` the parameters (`i:5,t:abc,r:1.5,n:`),
## `?type=` the row type of a typed read. The twin of a route is `<name>_io`.
import pf.Request
import pf.Response
import pf.D1
import pf.Sql
import pf.Io
import pf.Cbor
import pf.Id64
import Q

db = D1.binding("DB")

## The row types of the typed reads (`?type=`).
Person : { id : I64, name : Str }
IdRow : { id : I64 }
RealRow : { x : F64 }
Count : { n : U64 }
TextRow : { t : Str }
Big : { x : Str }
IdRow64 : { id : Id64 }

## The tuple types of `all_tuples!` (the same columns, in the order of the SELECT).
PersonT : (I64, Str)
IdsT : (I64, I64)
RealsT : (I64, F64)

D1Routes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| {
		sql = Q.text(req, "sql")
		p = params(Q.text(req, "p"))
		max = { max_bytes: Q.num(req, "max") }
		ty = Q.text(req, "type")
		how = |name| match name {
			"" => Direct
			"_io" => Twin
			"_with" => With(max.max_bytes)
			_ => WithTwin(max.max_bytes)
		}
		match path {
			["exec"] => out(db.exec!(sql))
			["exec_io"] => out(Io.run!(db.exec(sql)))
			["run"] => info(db.run!(sql, p))
			["run_io"] => info(Io.run!(db.run(sql, p)))
			["all"] => all!(ty, sql, p, how(""))
			["all_io"] => all!(ty, sql, p, how("_io"))
			["all_with"] => all!(ty, sql, p, how("_with"))
			["all_with_io"] => all!(ty, sql, p, how("_with_io"))
			# PLAN.md 8g P1: the rows as tuples (`raw()`), typed by `?type=` (`person`, `ids`, `reals`, `big`).
			["all_tuples"] => all_tuples!(ty, sql, p, how(""))
			["all_tuples_io"] => all_tuples!(ty, sql, p, how("_io"))
			["all_tuples_with"] => all_tuples!(ty, sql, p, how("_with"))
			["all_tuples_with_io"] => all_tuples!(ty, sql, p, how("_with_io"))
			["session_tuples"] => session_tuples!(ty, sql, p, how(Q.text(req, "how")))
			["first"] => first!(ty, sql, p, how(""))
			["first_io"] => first!(ty, sql, p, how("_io"))
			["first_with"] => first!(ty, sql, p, how("_with"))
			["first_with_io"] => first!(ty, sql, p, how("_with_io"))
			["rows"] => out(db.rows!(sql, p))
			["rows_io"] => out(Io.run!(db.rows(sql, p)))
			["rows_with"] => out(db.rows_with!(sql, p, max))
			["rows_with_io"] => out(Io.run!(db.rows_with(sql, p, max)))
			# `?sql=` holds statements with no parameters, split at `;`. The answer: the count of results and the info of each.
			["batch"] => batch(db.batch!(stmts(sql)))
			["batch_io"] => batch(Io.run!(db.batch(stmts(sql))))
			["batch_with"] => batch(db.batch_with!(stmts(sql), max))
			["batch_with_io"] => batch(Io.run!(db.batch_with(stmts(sql), max)))
			# PLAN.md 8c: 2 inserts and a select, then `first()` of the third reads the count.
			["batch_count"] => batch_count!(Q.text(req, "grp"))
			# The rows of the last statement of a batch, typed by `?type=` with `D1.Result.first` and `all`.
			["batch_first"] => batch_first!(ty, sql)
			# MODULES.md 5.1, "Ids: Id64": `?k=` is the row of `bigids`. Read as `Id64`, write to `rid` with `Text(id.to_str())`, read back.
			["id64"] => id64!(Q.num(req, "k"))
			["session"] => session!(Q.text(req, "k"))
			["session_after"] => session_after!(Q.text(req, "b"), Q.text(req, "k"))
			_ => Response.from_text(404, "no route")
		}
	}
}

out : Try(a, e) -> Response
out = |r| Response.from_text(
	200,
	match r {
		Ok(v) => "Ok ${Str.inspect(v)}"
		Err(e) => "Err ${Str.inspect(e)}"
	},
)

info : Try(Sql.Info, e) -> Response
info = |r| match r {
	Ok(i) => Response.from_text(200, "Ok ${show_info(i)}")
	Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
}

show_info : Sql.Info -> Str
show_info = |i| "changes=${i.changes.to_str()} last_row_id=${Str.inspect(i.last_row_id)} rows_read=${i.rows_read.to_str()} rows_written=${i.rows_written.to_str()}"

## `i:<I64>`, `r:<F64>`, `t:<text>`, `n:` (null), split at `,`.
params : Str -> List(Sql)
params = |text| if text == "" [] else text.split_on(",").map(|item| match item.split_first(":") {
	Ok({ before: "i", after }) => Int(I64.from_str(after) ?? crash "a bad i: parameter")
	Ok({ before: "r", after }) => Real(F64.from_str(after) ?? crash "a bad r: parameter")
	Ok({ before: "t", after }) => Text(after)
	Ok({ before: "n", after: _ }) => Null
	_ => crash "a bad parameter: ${item}"
})

stmts : Str -> List(Sql.Stmt)
stmts = |text| text.split_on(";").map(|s| Sql.stmt(s, []))

How : [Direct, Twin, With(U64), WithTwin(U64)]

## A typed read into the row type `ty` (`Person` when it is not given).
all! : Str, Str, List(Sql), How => Response
all! = |ty, sql, p, how| match ty {
	"id" => {
		r : Try(List(IdRow), _)
		r = all_by!(sql, p, how)
		out(r)
	}
	"real" => {
		r : Try(List(RealRow), _)
		r = all_by!(sql, p, how)
		out(r)
	}
	"count" => {
		r : Try(List(Count), _)
		r = all_by!(sql, p, how)
		out(r)
	}
	# Large rows: the count of rows only.
	"big" => {
		r : Try(List(Big), _)
		r = all_by!(sql, p, how)
		Response.from_text(
			200,
			match r {
				Ok(rows) => "Ok rows=${rows.len().to_str()}"
				Err(e) => "Err ${Str.inspect(e)}"
			},
		)
	}
	_ => {
		r : Try(List(Person), _)
		r = all_by!(sql, p, how)
		out(r)
	}
}

## `all_tuples!` into the tuple type `ty` (`person`: `(I64, Str)`, `ids`: `(I64, I64)`, `reals`: `(I64, F64)`, `big`: the count of rows).
all_tuples! : Str, Str, List(Sql), How => Response
all_tuples! = |ty, sql, p, how| match ty {
	"ids" => {
		r : Try(List(IdsT), _)
		r = all_tuples_by!(sql, p, how)
		out(r)
	}
	"reals" => {
		r : Try(List(RealsT), _)
		r = all_tuples_by!(sql, p, how)
		out(r.map_ok(|rows| rows.map(|(k, x)| (k, x.to_i128_try()))))
	}
	"big" => {
		r : Try(List(PersonT), _)
		r = all_tuples_by!(sql, p, how)
		Response.from_text(
			200,
			match r {
				Ok(rows) => "Ok rows=${rows.len().to_str()}"
				Err(e) => "Err ${Str.inspect(e)}"
			},
		)
	}
	# A tuple of the wrong shape for the rows (a record type reads no array).
	"record" => {
		r : Try(List(Person), _)
		r = all_tuples_by!(sql, p, how)
		out(r)
	}
	_ => {
		r : Try(List(PersonT), _)
		r = all_tuples_by!(sql, p, how)
		out(r)
	}
}

all_tuples_by! : Str, List(Sql), How => Try(rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
all_tuples_by! = |sql, p, how| match how {
	Direct => db.all_tuples!(sql, p)
	Twin => Io.run!(db.all_tuples(sql, p))
	With(m) => db.all_tuples_with!(sql, p, { max_bytes: m })
	WithTwin(m) => Io.run!(db.all_tuples_with(sql, p, { max_bytes: m }))
}

## The four forms on a `D1.Session` (`how`: `""`, `_io`, `_with`, `_with_io`). `big`: the count of rows.
session_tuples! : Str, Str, List(Sql), How => Response
session_tuples! = |ty, sql, p, how| match db.with_session!(Primary) {
	Ok(s) => {
		r : Try(List(PersonT), _)
		r = match how {
			Direct => s.all_tuples!(sql, p)
			Twin => Io.run!(s.all_tuples(sql, p))
			With(m) => s.all_tuples_with!(sql, p, { max_bytes: m })
			WithTwin(m) => Io.run!(s.all_tuples_with(sql, p, { max_bytes: m }))
		}
		if ty == "big" {
			Response.from_text(
				200,
				match r {
					Ok(rows) => "Ok rows=${rows.len().to_str()}"
					Err(e) => "Err ${Str.inspect(e)}"
				},
			)
		} else {
			out(r)
		}
	}
	Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
}

first! : Str, Str, List(Sql), How => Response
first! = |ty, sql, p, how| match ty {
	"id" => {
		r : Try(IdRow, _)
		r = first_by!(sql, p, how)
		out(r)
	}
	# The F64 as an integer, so the check sees that 2^60 is exact.
	"real" => {
		r : Try(RealRow, _)
		r = first_by!(sql, p, how)
		out(r.map_ok(|row| { x_as_integer: row.x.to_i128_try() }))
	}
	"text" => {
		r : Try(TextRow, _)
		r = first_by!(sql, p, how)
		out(r)
	}
	_ => {
		r : Try(Person, _)
		r = first_by!(sql, p, how)
		out(r)
	}
}

all_by! : Str, List(Sql), How => Try(rows, [D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [rows.Cbor.Parseable([InvalidCbor(U64), ..errs])]
all_by! = |sql, p, how| match how {
	Direct => db.all!(sql, p)
	Twin => Io.run!(db.all(sql, p))
	With(m) => db.all_with!(sql, p, { max_bytes: m })
	WithTwin(m) => Io.run!(db.all_with(sql, p, { max_bytes: m }))
}

first_by! : Str, List(Sql), How => Try(row, [NotFound, D1Err(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge]) where [row.Cbor.Parseable([InvalidCbor(U64), ..errs])]
first_by! = |sql, p, how| match how {
	Direct => db.first!(sql, p)
	Twin => Io.run!(db.first(sql, p))
	With(m) => db.first_with!(sql, p, { max_bytes: m })
	WithTwin(m) => Io.run!(db.first_with(sql, p, { max_bytes: m }))
}

batch : Try(List(D1.Result), e) -> Response
batch = |r| match r {
	Ok(results) => Response.from_text(200, "Ok results=${results.len().to_str()} ${Str.join_with(results.map(|x| show_info(x.info())), "; ")}")
	Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
}

## PLAN.md 8c: 2 inserts and a select in one `batch!`: 3 results, and `first()` of the third reads the count.
batch_count! : Str => Response
batch_count! = |grp| match db.batch!([
	Sql.stmt("INSERT INTO release (grp, version) VALUES (?, ?)", [Text(grp), Text("1.0.0")]),
	Sql.stmt("INSERT INTO release (grp, version) VALUES (?, ?)", [Text(grp), Text("1.1.0")]),
	Sql.stmt("SELECT count(*) AS n FROM release WHERE grp = ?", [Text(grp)]),
]) {
	Ok([a, b, counted]) => {
		count : Try(Count, _)
		count = counted.first()
		all : Try(List(Count), _)
		all = counted.all()
		Response.from_text(200, "Ok results=3 written=${a.info().rows_written.to_str()},${b.info().rows_written.to_str()} count=${Str.inspect(count)} all=${Str.inspect(all)}")
	}
	Ok(other) => Response.from_text(200, "Ok results=${other.len().to_str()}")
	Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
}

## `D1.Result.first` of the last statement of a batch, typed by `ty` (`id`: `{ id : I64 }`).
batch_first! : Str, Str => Response
batch_first! = |ty, sql| match db.batch!(stmts(sql)) {
	Ok(results) => match results.last() {
		Ok(last) => match ty {
			"id" => {
				r : Try(IdRow, _)
				r = last.first()
				out(r)
			}
			_ => {
				r : Try(Person, _)
				r = last.first()
				out(r)
			}
		}
		Err(_) => Response.from_text(200, "Err no result")
	}
	Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
}

## `with_session!(Primary)`: `bookmark!` before a query, an insert of `k`, then `bookmark!` again.
session! : Str => Response
session! = |k| match db.with_session!(Primary) {
	Ok(s) => {
		before = s.bookmark!()
		inserted = s.run!("INSERT INTO kv (k, v) VALUES (?, ?)", [Text(k), Text("session")])
		after = s.bookmark!()
		Response.from_text(200, "before=${Str.inspect(before)} insert=${Str.inspect(inserted.map_ok(|_| {}))} after=${after ?? "none"}")
	}
	Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
}

## A session `After(b)` reads the row `k`.
session_after! : Str, Str => Response
session_after! = |b, k| match db.with_session!(After(b)) {
	Ok(s) => {
		r : Try(TextRow, _)
		r = s.first!("SELECT v AS t FROM kv WHERE k = ?", [Text(k)])
		out(r)
	}
	Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
}

## Reads `bigids` row `k` with `CAST(id AS TEXT)` into an `Id64` field, stores it in `rid` as a text parameter, reads it back.
## The answer: the id as I64 and U64, the id read back, and the JSON of the `Web` form.
id64! : U64 => Response
id64! = |k| {
	r : Try(IdRow64, _)
	r = db.first!("SELECT CAST(id AS TEXT) AS id FROM bigids WHERE k = ?", [Int(k.to_i64_wrap())])
	match r {
		Ok({ id }) => match db.run!("INSERT OR REPLACE INTO rid (id, v) VALUES (?, ?)", [Text(id.to_str()), Text("id64")]) {
			Ok(_) => {
				back : Try(IdRow64, _)
				back = db.first!("SELECT CAST(id AS TEXT) AS id FROM rid WHERE v = 'id64' AND id = ?", [Text(id.to_str())])
				match back {
					Ok(b) => Response.from_text(200, "Ok i64=${id.to_str()} u64=${id.to_u64_str()} same=${Str.inspect(b.id == id)} json=${Encoding.Json.to_str({ id: b.id.to_web() })}")
					Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
				}
			}
			Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
		}
		Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
	}
}
