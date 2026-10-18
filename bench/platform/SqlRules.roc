## The SQL rules that `D1` and the SQL of a Durable Object (`Object.Self`) share (MODULES.md 5.1, 7): typed rows with the integer rules, rows with no types, and the map of a constraint failure. Not in `exposes`: only
## platform modules use it. Local object SQL gives the same texts as D1, with no `D1_ERROR: ` (PLAN.md 8f, part 1).
import Js
import Sql
import cbor.Cbor

SqlRules :: [].{
	row_of : Js -> List(Sql)
	row_of = |r| match r {
		Arr(values) => values.map(value_of)
		_ => crash "SqlRules: a row is not an array"
	}

	column_name : Js -> Str
	column_name = |c| match c {
		Text(s) => s
		_ => crash "SqlRules: a column name is not text"
	}

	## Typed rows (5.1): an integer field also reads canonical decimal text (`int_from_text`), and a parse error is
	## `BadData` with the column name.
	typed : List(U8) -> Try(a, [BadData(Str)]) where [a.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	typed = |bytes| match Cbor.parse_with(bytes, { fields: Snake, int_from_text: Bool.True }) {
		Ok(v) => Ok(v)
		Err(InvalidCbor(pos)) => Err(BadData(bad_data(bytes, pos)))
		Err(other) => Err(BadData(missing(Str.inspect(other))))
	}

	## Typed rows as arrays (`D1.all_tuples!`): the same integer rules as `typed`. A row is a CBOR array, so the column has
	## no name: `BadData` gives its index from 0.
	typed_tuples : List(U8) -> Try(a, [BadData(Str)]) where [a.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	typed_tuples = |bytes| match Cbor.parse_with(bytes, { fields: Snake, int_from_text: Bool.True }) {
		Ok(v) => Ok(v)
		Err(InvalidCbor(pos)) => Err(BadData(bad_tuple_data(bytes, pos)))
		Err(other) => Err(BadData(Str.inspect(other)))
	}

	## MODULES.md 5.1, "Constraint kinds": the message ends in `: SQLITE_CONSTRAINT`, or in
	## `: SQLITE_CONSTRAINT (extended: <code>)`. The kind comes from the code, not from the text: a `RAISE` text can look like
	## another failure. `message` is the SQLite text with no `D1_ERROR: ` (or `D1_EXEC_ERROR: `) and no code.
	constraint_of : Str -> Try(Sql.Constraint, [NotConstraint])
	constraint_of = |message| {
		text = message.drop_prefix("D1_ERROR: ").drop_prefix("D1_EXEC_ERROR: ")
		match text.split_last(": SQLITE_CONSTRAINT (extended: ") {
			Ok({ before, after }) if after.ends_with(")") and !after.contains(" ") => Ok({ kind: kind_of(after.drop_suffix(")")), message: before })
			_ =>
				if text.ends_with(": SQLITE_CONSTRAINT") {
					Ok({ kind: Other, message: text.drop_suffix(": SQLITE_CONSTRAINT") })
				} else {
					Err(NotConstraint)
				}
		}
	}
}

## A value of `raw()`: D1 gives a blob as an array of numbers, and a number as a JS `Number` (a size of 2^53 or more
## is an f64, `Real`).
value_of : Js -> Sql
value_of = |v| match v {
	Null | Undefined => Null
	Int(i) => Int(i)
	Num(f) => Real(f)
	Text(s) => Text(s)
	Bytes(b) => Blob(b)
	Arr(items) => Blob(items.map(|i| match i {
		Int(n) => n.to_u8_wrap()
		_ => 0
	}))
	Bool(b) => Int(if b 1 else 0)
	_ => crash "SqlRules: a value of another kind: ${Str.inspect(v)}"
}

## `MissingRequiredField(x)` of the derived parser is `column x: missing`. The tag is not in the type of the `where`
## clause (`[InvalidCbor(U64), ..errs]`), so a match on it closes the union: the module reads its `Str.inspect` text.
missing : Str -> Str
missing = |text| {
	name = text.drop_prefix("MissingRequiredField(\"").drop_suffix("\")")
	if name != text and !name.contains("\"") "column ${name}: missing" else text
}

## The text of `BadData` for the item at `pos` (MODULES.md 5.1): the column is the last key of its path.
bad_data : List(U8), U64 -> Str
bad_data = |bytes, pos| {
	column = match Cbor.path_at(bytes, pos) {
		Ok(steps) => last_key(steps)
		Err(NotFound) => Err(NotFound)
	}
	match column {
		Ok(c) => if rounded_at(bytes, pos) "column ${c}: integer above 2^53, use CAST(${c} AS TEXT)" else "column ${c}: the value does not fit the type"
		Err(_) => "the value at byte ${pos.to_str()} does not fit the type"
	}
}

## The text of `BadData` for the item at `pos` in rows as arrays: the path is `[Index(row), Index(column), ..]`.
bad_tuple_data : List(U8), U64 -> Str
bad_tuple_data = |bytes, pos| match Cbor.path_at(bytes, pos) {
	Ok([Index(_), Index(c), ..]) =>
		if rounded_at(bytes, pos) {
			"column ${c.to_str()} (from 0): integer above 2^53, use CAST(... AS TEXT)"
		} else {
			"column ${c.to_str()} (from 0): the value does not fit the type"
		}
	Ok([Index(r)]) => "row ${r.to_str()}: the row does not fit the type"
	_ => "the value at byte ${pos.to_str()} does not fit the type"
}

last_key : List(Cbor.Step) -> Try(Str, [NotFound])
last_key = |steps| steps.fold(
	Err(NotFound),
	|acc, step| match step {
		Key(k) => Ok(k)
		Index(_) => acc
	},
)

## An f64 with no fraction and a size of 2^53 or more starts at `pos`: a rounded integer of D1.
rounded_at : List(U8), U64 -> Bool
rounded_at = |bytes, pos| match bytes.get(pos) {
	Ok(0xfb) => {
		bits = bytes.sublist({ start: pos + 1, len: 8 }).fold(0.U64, |acc, b| acc.shl_wrap(8).bitwise_or(b.to_u64()))
		f = F64.from_bits(bits)
		f.is_finite() and f.abs() >= 9_007_199_254_740_992.0 and f.to_i128_try().map_ok(|i| i.to_f64() == f) == Ok(Bool.True)
	}
	_ => Bool.False
}

kind_of : Str -> [PrimaryKey, Unique, ForeignKey, Check, NotNull, Trigger, Datatype, Other]
kind_of = |code| match code {
	"SQLITE_CONSTRAINT_PRIMARYKEY" => PrimaryKey
	"SQLITE_CONSTRAINT_UNIQUE" => Unique
	"SQLITE_CONSTRAINT_FOREIGNKEY" => ForeignKey
	"SQLITE_CONSTRAINT_CHECK" => Check
	"SQLITE_CONSTRAINT_NOTNULL" => NotNull
	"SQLITE_CONSTRAINT_TRIGGER" => Trigger
	"SQLITE_CONSTRAINT_DATATYPE" => Datatype
	_ => Other
}

# MODULES.md 5.1, "Constraint kinds": the kind from the extended code, the message with no prefix and no code (8d).
expect SqlRules.constraint_of("D1_ERROR: UNIQUE constraint failed: t.id: SQLITE_CONSTRAINT (extended: SQLITE_CONSTRAINT_PRIMARYKEY)") == Ok({ kind: PrimaryKey, message: "UNIQUE constraint failed: t.id" })
expect SqlRules.constraint_of("D1_ERROR: UNIQUE constraint failed: fake: SQLITE_CONSTRAINT (extended: SQLITE_CONSTRAINT_TRIGGER)") == Ok({ kind: Trigger, message: "UNIQUE constraint failed: fake" })
expect SqlRules.constraint_of("D1_ERROR: label-conflict: SQLITE_CONSTRAINT (extended: SQLITE_CONSTRAINT_TRIGGER)") == Ok({ kind: Trigger, message: "label-conflict" })
expect SqlRules.constraint_of("D1_EXEC_ERROR: Error in line 1: INSERT INTO t VALUES (1): UNIQUE constraint failed: t.id: SQLITE_CONSTRAINT (extended: SQLITE_CONSTRAINT_PRIMARYKEY)") == Ok({ kind: PrimaryKey, message: "Error in line 1: INSERT INTO t VALUES (1): UNIQUE constraint failed: t.id" })
expect SqlRules.constraint_of("x failed: SQLITE_CONSTRAINT") == Ok({ kind: Other, message: "x failed" })
expect SqlRules.constraint_of("D1_ERROR: x: SQLITE_CONSTRAINT (extended: SQLITE_CONSTRAINT_ROWID)") == Ok({ kind: Other, message: "x" })
expect SqlRules.constraint_of("D1_ERROR: near \"SELEC\": syntax error at offset 0: SQLITE_ERROR") == Err(NotConstraint)
expect SqlRules.constraint_of("D1_ERROR: CHECK constraint failed: c >= 0: SQLITE_CONSTRAINT_EXTRA") == Err(NotConstraint)

expect missing("MissingRequiredField(\"id\")") == "column id: missing"
expect missing("Other") == "Other"

# 5.1, "Integers in rows": [{"id": 2^53 as f64}] is the text with CAST, [{"id": 1.5}] is "does not fit".
expect bad_data([0x81, 0xa1, 0x62, 0x69, 0x64, 0xfb, 0x43, 0x40, 0, 0, 0, 0, 0, 0], 5) == "column id: integer above 2^53, use CAST(id AS TEXT)"
expect bad_data([0x81, 0xa1, 0x62, 0x69, 0x64, 0xfb, 0x3f, 0xf8, 0, 0, 0, 0, 0, 0], 5) == "column id: the value does not fit the type"

# PLAN.md 8g P1: rows as arrays (`D1.all_tuples!`) with the integer rules of 5.1. Each row is a CBOR array of two items.
tuples2 : List(U8) -> Try(List((I64, I64)), [BadData(Str)])
tuples2 = |bytes| SqlRules.typed_tuples(bytes)

expect tuples2([0x81, 0x82, 0x01, 0x02]) == Ok([(1, 2)])
expect tuples2([0x80]) == Ok([])
# CAST(x AS TEXT): canonical decimal text of 2^63 - 1 goes into the I64 item.
expect tuples2([0x81, 0x82, 0x01, 0x73].concat("9223372036854775807".to_utf8())) == Ok([(1, 9_223_372_036_854_775_807)])
# 2^53 as an f64 (D1 rounded an id): the column is named by its index, 1.
expect tuples2([0x81, 0x82, 0x01, 0xfb, 0x43, 0x40, 0, 0, 0, 0, 0, 0]) == Err(BadData("column 1 (from 0): integer above 2^53, use CAST(... AS TEXT)"))
expect tuples2([0x82, 0x82, 0x01, 0x02, 0x82, 0xfb, 0xc3, 0x40, 0, 0, 0, 0, 0, 0, 0x02]) == Err(BadData("column 0 (from 0): integer above 2^53, use CAST(... AS TEXT)"))
# 1.5 and the text "01" do not fit.
expect tuples2([0x81, 0x82, 0x01, 0xfb, 0x3f, 0xf8, 0, 0, 0, 0, 0, 0]) == Err(BadData("column 1 (from 0): the value does not fit the type"))
expect tuples2([0x81, 0x82, 0x01, 0x62, 0x30, 0x31]) == Err(BadData("column 1 (from 0): the value does not fit the type"))
# A row with one item for a tuple of two.
expect tuples2([0x81, 0x81, 0x01]) == Err(BadData("row 0: the row does not fit the type"))
# 2^53 - 1 as an f64 with no fraction is exact.
expect tuples2([0x81, 0x82, 0x01, 0xfb, 0x43, 0x3f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]) == Ok([(1, 9_007_199_254_740_991)])
