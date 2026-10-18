## `D1` and `Sql` (MODULES.md 5.1, PLAN.md 8c, 8d). The binding `DB` is in `checks/d1.mjs`, which also makes the tables.
## Each route answers `Ok <text>` or `Err <the error>`. `?sql=` is the SQL, `?p=` the parameters (`i:5,t:abc,r:1.5,n:`),
## `?type=` the row type of a typed read. The twin of a route is `<name>_io`.
import pf.Request
import pf.Response
import pf.D1
import pf.Sql
import pf.Io
import pf.Cbor
import Q

db = D1.binding("DB")

## The row types of the typed reads (`?type=`).
Person : { id : I64, name : Str }
IdRow : { id : I64 }
RealRow : { x : F64 }
Count : { n : U64 }
TextRow : { t : Str }
Big : { x : Str }

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
			# PLAN.md 8h item 3: parameters as an `Encodable` tuple or list (`params!`).
			["params", case] => params!(case)
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
stmts = |text| text.split_on(";").map(|s| Sql.stmt(s, Sql.none))

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
	Sql.stmt("INSERT INTO release (grp, version) VALUES (?, ?)", (grp, "1.0.0")),
	Sql.stmt("INSERT INTO release (grp, version) VALUES (?, ?)", (grp, "1.1.0")),
	Sql.stmt("SELECT count(*) AS n FROM release WHERE grp = ?", [grp]),
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
		inserted = s.run!("INSERT INTO kv (k, v) VALUES (?, ?)", (k, "session"))
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
		r = s.first!("SELECT v AS t FROM kv WHERE k = ?", [k])
		out(r)
	}
	Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
}

## The columns of `pt` as `typeof()` and as values.
Typed : { ta : Str, tb : Str, tc : Str, td : Str, a : Str, b : I64, c : F64, hd : Str }
## The columns of `pt` that hold NULL or a value.
Nulls : { an : I64, b : I64, cn : I64, tb : Str }
## A value of `pi` as text, and its `typeof()`.
Stored : { v : Str, t : Str }

typed! : Str => Response
typed! = |k| {
	r : Try(List(Typed), _)
	r = db.all!("SELECT typeof(a) AS ta, typeof(b) AS tb, typeof(c) AS tc, typeof(d) AS td, a, b, c, hex(d) AS hd FROM pt WHERE k = ?", [k])
	out(r)
}

stored! : Str, Try(Sql.Info, e) => Response
stored! = |k, wrote| match wrote {
	Ok(_) => {
		r : Try(List(Stored), _)
		r = db.all!("SELECT CAST(v AS TEXT) AS v, typeof(v) AS t FROM pi WHERE k = ?", [k])
		out(r)
	}
	Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
}

## PLAN.md 8h item 3: each `?case` writes with parameters of one form and reads the result back.
params! : Str => Response
params! = |case| match case {
	# A tuple of (Str, I64, F64, a blob): the types of the columns in SQL.
	"tuple" => {
		_ = db.run!("INSERT INTO pt (k, a, b, c, d) VALUES (?, ?, ?, ?, ?)", ("tuple", "héllo", 42.I64, 1.5.F64, Sql.blob([1, 2, 3])))
		typed!("tuple")
	}
	"tuple_io" => {
		_ = Io.run!(db.run("INSERT INTO pt (k, a, b, c, d) VALUES (?, ?, ?, ?, ?)", ("tuple_io", "x", 7.I64, 2.5.F64, Sql.blob([255]))))
		typed!("tuple_io")
	}
	"null" => {
		present : Try(I64, [Nope])
		present = Ok(7)
		_ = db.run!("INSERT INTO pt (k, a, b, c) VALUES (?, ?, ?, ?)", ("null", Sql.null, Sql.or_null(present), Sql.or_null(present)))
		_ = db.run!("INSERT INTO pt (k, a, b, c) VALUES (?, ?, ?, ?)", ("null_err", Sql.null, Sql.or_null(missing), Sql.or_null(missing)))
		a : Try(List(Nulls), _)
		a = db.all!("SELECT a IS NULL AS an, b, c IS NULL AS cn, typeof(b) AS tb FROM pt WHERE k = ?", ["null"])
		b : Try(List(Nulls), _)
		b = db.all!("SELECT a IS NULL AS an, ifnull(b, -1) AS b, c IS NULL AS cn, typeof(b) AS tb FROM pt WHERE k = ?", ["null_err"])
		Response.from_text(200, "ok=${Str.inspect(a)} err=${Str.inspect(b)}")
	}
	"u64max" => stored!("u64max", db.run!("INSERT INTO pi (k, v) VALUES (?, ?)", ("u64max", 9_223_372_036_854_775_807.U64)))
	"u64over" => stored!("u64over", db.run!("INSERT INTO pi (k, v) VALUES (?, ?)", ("u64over", 9_223_372_036_854_775_808.U64)))
	# 2^53 + 1 as an I64 and as a U64: text binds, an INTEGER column gives the exact integer.
	"p53" => stored!("p53", db.run!("INSERT INTO pi (k, v) VALUES (?, ?)", ("p53", 9_007_199_254_740_993.I64)))
	"p53_u64" => stored!("p53_u64", db.run!("INSERT INTO pi (k, v) VALUES (?, ?)", ("p53_u64", 9_007_199_254_740_993.U64)))
	"i64min" => stored!("i64min", db.run!("INSERT INTO pi (k, v) VALUES (?, ?)", ("i64min", -9_223_372_036_854_775_808.I64)))
	"record" => out(db.run!("INSERT INTO pi (k, v) VALUES (?, ?)", { k: "record", v: 1.I64 }))
	"empty_record" => out(db.run!("SELECT 1", {}))
	"err_null" => {
		bare : Try(I64, [Null])
		bare = Err(Null)
		out(db.run!("INSERT INTO pi (k, v) VALUES (?, ?)", ("err_null", bare)))
	}
	# A tag with a payload encodes as a map, so the item is refused. (`Err(Null)` of a `Try(a, [Null])` encodes as CBOR null; `Err(e)` of another `Try` has no encoder.)
	"tag_item" => {
		bare : [Hit(I64), Miss]
		bare = Hit(3)
		out(db.run!("INSERT INTO pi (k, v) VALUES (?, ?)", ("tag_item", bare)))
	}
	"bool" => out(db.run!("INSERT INTO pi (k, v) VALUES (?, ?)", ("bool", Bool.True)))
	"bad_session" => match db.with_session!(Primary) {
		Ok(s) => out(s.run!("INSERT INTO pi (k, v) VALUES (?, ?)", ("bad_session", Bool.False)))
		Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
	}
	"bad_batch" => batch(db.batch!([Sql.stmt("INSERT INTO pi (k, v) VALUES (?, ?)", ("bad_batch", Bool.True))]))
	"none" => {
		r : Try(List(IdRow), _)
		r = db.all!("SELECT 1 AS id", Sql.none)
		out(r)
	}
	"single" => {
		r : Try(List(TextRow), _)
		r = db.all!("SELECT ? AS t", ["one"])
		out(r)
	}
	# `Sql.stmt` with tuples of different types in one batch.
	"stmt_batch" => match db.batch!([
		Sql.stmt("INSERT INTO pi (k, v) VALUES (?, ?)", ("b1", 1.I64)),
		Sql.stmt("INSERT INTO pt (k, a, b) VALUES (?, ?, ?)", ("b2", "two", Sql.null)),
		Sql.stmt("SELECT count(*) AS n FROM pi WHERE k = ?", ["b1"]),
		Sql.stmt("SELECT 1", Sql.none),
	]) {
		Ok([a, b, c, d]) => {
			count : Try(Count, _)
			count = c.first()
			Response.from_text(200, "Ok changes=${a.info().changes.to_str()},${b.info().changes.to_str()},${d.info().changes.to_str()} count=${Str.inspect(count)}")
		}
		Ok(other) => Response.from_text(200, "Ok results=${other.len().to_str()}")
		Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
	}
	# A `List(Sql)` built at run time.
	"runtime_list" => {
		items : List(Sql)
		items = ["rt", "text"].map(|t| Text(t)).append(Int(5)).append(Real(2.5)).append(Blob([9]))
		_ = db.run!("INSERT INTO pt (k, a, b, c, d) VALUES (?, ?, ?, ?, ?)", items)
		typed!("rt")
	}
	"session" => match db.with_session!(Primary) {
		Ok(s) => {
			_ = s.run!("INSERT INTO pt (k, a, b, c, d) VALUES (?, ?, ?, ?, ?)", ("session", "s", 3.I64, 0.5.F64, Sql.blob([4])))
			r : Try(TextRow, _)
			r = s.first!("SELECT a || typeof(d) AS t FROM pt WHERE k = ? AND b = ?", ("session", 3.I64))
			out(r)
		}
		Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
	}
	_ => Response.from_text(404, "no case")
}

missing : Try(I64, [Nope])
missing = Err(Nope)
