app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

## Runtime probes for FINDINGS-v2-storage-do.md (local wrangler dev). One route for each claim.
import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Sql
import pf.Cbor
import pf.Kv
import pf.Object
import pf.Rpc
import pf.Time
import pf.Log

db = D1.binding("DB")

Blobs : { id : I64, data : List(U8) }

BlobsB : { id : I64, data : Cbor.Bytes }

NoRpc := []

room : Object.Class(NoRpc)
room = Object.class("Room", {
	fetch!: |self, _req| {
		r = self.set_alarm_at!(60_000)
		Ok(Response.from_text(200, Str.inspect(r)))
	},
})

fired : Object.Cell(U64)
fired = Object.cell("fired")

ticker : Object.Class(NoRpc)
ticker = Object.class("Ticker", {
	fetch!: |self, req| match req.segments() {
		["at_bad"] => Ok(Response.from_text(200, Str.inspect(self.set_alarm_at!(60_000))))
		["in"] => Ok(Response.from_text(200, Str.inspect(self.set_alarm_in!(300))))
		["state"] => {
			n = fired.get_or!(self, 0)?
			Ok(Response.from_text(200, "fired=${n.to_str()} alarm=${Str.inspect(self.get_alarm!())} now=${Time.now_ms!().to_str()}"))
		}
		_ => Ok(Response.from_status(404))
	},
	alarm!: |self, info| {
		n = fired.get_or!(self, 0)?
		fired.set!(self, n + 1)?
		Log.info!("ticker alarm", { at: Time.now_ms!(), retry: info.retry_count })
		Ok({})
	},
})

rooms = Object.namespace("ROOMS", { class: room })
tickers = Object.namespace("TICKERS", { class: ticker })

cfg : Kv(Str)
cfg = Kv.json("CFG")

N1 : { id : I64, name : Str }
N2 : { id : I64, name : Try(Str, [Missing]) }
N3 : { id : I64, name : Try(Str, [Null]) }
N4 : { id : I64, name : [Null, Some(Str)] }
N5 : { id : I64, name ?: Str }


fetch! : Request => Try(Response, _)
fetch! = |req| match req.segments() {
	["setup"] => {
		db.exec!("CREATE TABLE IF NOT EXISTS blobs (id INTEGER PRIMARY KEY, data BLOB)")?
		_ = db.run!("DELETE FROM blobs", Sql.none)?
		_ = db.run!("INSERT INTO blobs (id, data) VALUES (?, ?)", (1.I64, Sql.blob([1, 2, 3])))?
		Ok(Response.from_text(200, "ok"))
	}
	["blob_list"] => {
		rows : Try(List(Blobs), _)
		rows = db.all!("SELECT id, data FROM blobs", Sql.none)
		Ok(Response.from_text(200, Str.inspect(rows)))
	}
	["blob_cbor_bytes"] => {
		rows : Try(List(BlobsB), _)
		rows = db.all!("SELECT id, data FROM blobs", Sql.none)
		Ok(Response.from_text(200, Str.inspect(rows)))
	}
	["bare"] => Ok(Response.from_text(200, Str.inspect(db.run!("INSERT INTO blobs (id) VALUES (?)", 5.I64))))
	["bare_str"] => Ok(Response.from_text(200, Str.inspect(db.run!("INSERT INTO blobs (id) VALUES (?)", "7"))))
	["tag"] => Ok(Response.from_text(200, Str.inspect(db.run!("INSERT INTO blobs (id) VALUES (?)", [Int(9)]))))
	["tuple1"] => Ok(Response.from_text(200, Str.inspect(db.run!("INSERT INTO blobs (id) VALUES (?)", (11.I64)))))
	["u64over"] => Ok(Response.from_text(200, Str.inspect(db.run!("INSERT INTO blobs (id) VALUES (?)", [9_223_372_036_854_775_808.U64]))))
	["rowid"] => {
		r = db.run!("INSERT INTO blobs (id) VALUES (?)", [123.I64])
		Ok(Response.from_text(200, Str.inspect(r)))
	}
	["null_setup"] => {
		db.exec!("CREATE TABLE IF NOT EXISTS nul (id INTEGER PRIMARY KEY, name TEXT)")?
		_ = db.run!("DELETE FROM nul", Sql.none)?
		_ = db.run!("INSERT INTO nul (id, name) VALUES (1, NULL), (2, 'bob')", Sql.none)?
		Ok(Response.from_text(200, "ok"))
	}
	["null1"] => {
		r : Try(List(N1), _)
		r = db.all!("SELECT id, name FROM nul ORDER BY id", Sql.none)
		Ok(Response.from_text(200, Str.inspect(r)))
	}
	["null2"] => {
		r : Try(List(N2), _)
		r = db.all!("SELECT id, name FROM nul ORDER BY id", Sql.none)
		Ok(Response.from_text(200, Str.inspect(r)))
	}
	["null3"] => {
		r : Try(List(N3), _)
		r = db.all!("SELECT id, name FROM nul ORDER BY id", Sql.none)
		Ok(Response.from_text(200, Str.inspect(r)))
	}
	["null4"] => {
		r : Try(List(N4), _)
		r = db.all!("SELECT id, name FROM nul ORDER BY id", Sql.none)
		Ok(Response.from_text(200, Str.inspect(r)))
	}
	["null5"] => {
		r : Try(List(N5), _)
		r = db.all!("SELECT id, name FROM nul ORDER BY id", Sql.none)
		Ok(Response.from_text(200, Str.inspect(r)))
	}
	["ty_bool"] => {
		r : Try(List({ ok : Bool }), _)
		r = db.all!("SELECT 1 AS ok", Sql.none)
		Ok(Response.from_text(200, Str.inspect(r)))
	}
	["ty_f64_from_int"] => {
		r : Try(List({ x : F64 }), _)
		r = db.all!("SELECT 1 AS x", Sql.none)
		Ok(Response.from_text(200, Str.inspect(r)))
	}
	["ty_str_from_int"] => {
		r : Try(List({ x : Str }), _)
		r = db.all!("SELECT 1 AS x", Sql.none)
		Ok(Response.from_text(200, Str.inspect(r)))
	}
	["ty_i64_from_real"] => {
		r : Try(List({ x : I64 }), _)
		r = db.all!("SELECT 2.0 AS x", Sql.none)
		Ok(Response.from_text(200, Str.inspect(r)))
	}
	["ty_i64_from_frac"] => {
		r : Try(List({ x : I64 }), _)
		r = db.all!("SELECT 2.5 AS x", Sql.none)
		Ok(Response.from_text(200, Str.inspect(r)))
	}
	["ty_extra_col"] => {
		r : Try(List({ x : I64 }), _)
		r = db.all!("SELECT 2 AS x, 'extra' AS y", Sql.none)
		Ok(Response.from_text(200, Str.inspect(r)))
	}
	["ty_missing_col"] => {
		r : Try(List({ x : I64, z : I64 }), _)
		r = db.all!("SELECT 2 AS x", Sql.none)
		Ok(Response.from_text(200, Str.inspect(r)))
	}
	["ty_camel"] => {
		r : Try(List({ first_name : Str }), _)
		r = db.all!("SELECT 'a' AS firstName", Sql.none)
		Ok(Response.from_text(200, Str.inspect(r)))
	}
	["ty_first_none"] => {
		r : Try({ id : I64 }, _)
		r = db.first!("SELECT id FROM nul WHERE id = 99", Sql.none)
		Ok(Response.from_text(200, Str.inspect(r)))
	}
	["tuples_record"] => {
		r : Try(List({ id : I64, name : Try(Str, [Null]) }), _)
		r = db.all_tuples!("SELECT id, name FROM nul ORDER BY id", Sql.none)
		Ok(Response.from_text(200, Str.inspect(r)))
	}
	["tuples_ok"] => {
		r : Try(List((I64, Try(Str, [Null]))), _)
		r = db.all_tuples!("SELECT id, name FROM nul ORDER BY id", Sql.none)
		Ok(Response.from_text(200, Str.inspect(r)))
	}
	["room"] => Ok(rooms.named("a").fetch!(req)?)
	["ticker", .. as rest] => Ok(tickers.named("t").fetch!(Request.get("http://o/${Str.join_with(rest, "/")}"))?)
	["kv_ttl"] => Ok(Response.from_text(200, Str.inspect(cfg.put_with!("k", "v", { ttl_ms: 10_000 }))))
	["kv_cache_ttl"] => Ok(Response.from_text(200, Str.inspect(cfg.get_with!("k", { cache_ttl_ms: 10_000 }))))
	_ => Ok(Response.from_status(404))
}

worker = Worker.new({ fetch!: fetch!, objects: [room.erase(), ticker.erase()] })

event! = |e| worker.event!(e)
