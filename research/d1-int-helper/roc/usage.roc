app [event!] { pf: platform "../../../platform/main.roc" }

## The code that a user writes for a read, a write, a compare and an add, in options A, B and C. `roc check` only.
## Table: `CREATE TABLE item (id INTEGER PRIMARY KEY, parent INTEGER, name TEXT)`, ids are random 64-bit.
import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Sql
import DbInt
import SqlInt

db = D1.binding("DB")

worker = Worker.new({ fetch!: |req| handle!(req) })

event! = |e| worker.event!(e)

handle! : Request => Try(Response, _)
handle! = |_req| {
	a = option_a!(42)
	b = option_b!(42)
	c = option_c!(42)
	Ok(Response.from_status(if a.is_ok() and b.is_ok() and c.is_ok() 200 else 500))
}

# ---- A: no helper. I64 fields, CAST by hand. ----
ItemA : { id : I64, parent : I64, name : Str }

option_a! : I64 => Try(Bool, _)
option_a! = |id| {
	# read: each INTEGER column that can be 2^53 or more needs its own CAST
	item : ItemA
	item = db.first!("SELECT CAST(id AS TEXT) AS id, CAST(parent AS TEXT) AS parent, name FROM item WHERE id = ?", [id])?
	# write: the I64 binds as text from 2^53; the INTEGER column converts it
	_ = db.run!("INSERT INTO item (id, parent, name) VALUES (?, ?, ?)", (item.id + 1, item.parent, item.name))?
	# exact new id: RETURNING with a CAST (meta.last_row_id is Err(Rounded))
	made : { id : I64 }
	made = db.first!("INSERT INTO item (parent, name) VALUES (?, ?) RETURNING CAST(id AS TEXT) AS id", (item.id, "x"))?
	# compare and add: plain I64
	Ok(item.parent == id and made.id > 0 and 1 + item.id != made.id)
}

# ---- B: SQL helper. Same I64 fields, the CAST text comes from SqlInt. ----
option_b! : I64 => Try(Bool, _)
option_b! = |id| {
	item : ItemA
	item = db.first!("SELECT ${SqlInt.cols(["id", "parent"])}, name FROM item WHERE id = ?", [id])?
	_ = db.run!("INSERT INTO item (id, parent, name) VALUES (?, ?, ?)", (item.id + 1, item.parent, item.name))?
	made : { id : I64 }
	made = db.first!("INSERT INTO item (parent, name) VALUES (?, ?) RETURNING ${SqlInt.col("id")}", (item.id, "x"))?
	Ok(item.parent == id and made.id > 0)
}

# ---- C: number-like type. DbInt fields, CAST by hand (required, also for small ids). ----
ItemC : { id : DbInt, parent : DbInt, name : Str }

option_c! : I64 => Try(Bool, _)
option_c! = |id| {
	key = DbInt.from_i64(id)
	item : ItemC
	item = db.first!("SELECT CAST(id AS TEXT) AS id, CAST(parent AS TEXT) AS parent, name FROM item WHERE id = ?", [key])?
	_ = db.run!("INSERT INTO item (id, parent, name) VALUES (?, ?, ?)", (item.id + 1, item.parent, item.name))?
	made : { id : DbInt }
	made = db.first!("INSERT INTO item (parent, name) VALUES (?, ?) RETURNING CAST(id AS TEXT) AS id", (item.id, "x"))?
	# literal on the right: fine. A literal on the left (`1 + item.id`) needs an annotation.
	Ok(item.parent == key and made.id > 0 and item.id + 1 != made.id and item.id.to_i64() == id)
}
