app [event!] { pf: platform "../../platform/main.roc" }

## auction-web: the HTTP face of Gavel. The lot rooms (live bids) are the Durable Objects of `LotRoom.roc`.
##
## | Route | Does |
## | --- | --- |
## | GET /lots | the catalog, from KV, built from D1 on a miss |
## | POST /lots | admin: make a lot, open its room |
## | GET /lots/:id | the lot and its high bid (Rpc to the room) |
## | GET /lots/:id/image, PUT /lots/:id/image | image in R2 (PUT is admin) |
## | GET /lots/:id/live | WebSocket to the room |
import pf.Worker
import pf.Request
import pf.Response
import pf.Env
import pf.Kv
import pf.Object
import pf.Sql
import pf.R2
import pf.Service
import pf.WebCrypto
import pf.WebSocket
import pf.Time
import pf.Log
import Gavel
import LotRoom

db = Gavel.db

lot_rooms = Object.namespace("LOT_ROOM", { class: LotRoom.class })

images = R2.binding("BUCKET")

ledger = Service.binding_with("LEDGER", { service: "auction-ledger" })

catalog : Kv.Cell(List(Gavel.Lot))
catalog = Kv.json("KV").cell("catalog")

lot_columns = "id, title, reserve_cents, close_ms, min_step_cents, max_step_cents"

## The body of POST /lots.
NewLot : { id : Str, title : Str, reserve_cents : U64, close_ms : U64 }

fetch! : Request => Try(Response, e)
fetch! = |req| match route!(req) {
	Ok(res) => Ok(res)
	Err(e) => Ok(error_response!(e))
}

route! : Request => Try(Response, _)
route! = |req| {
	Gavel.tables.get!()?
	match (req.method(), req.segments()) {
		(GET, ["lots"]) => list_lots!()
		(POST, ["lots"]) => create_lot!(req)
		(GET, ["lots", id]) => show_lot!(id)
		(GET, ["lots", id, "image"]) => get_image!(req, id)
		(PUT, ["lots", id, "image"]) => put_image!(req, id)
		(GET, ["lots", id, "live"]) => live!(req, id)
		_ => Ok(Response.from_status(404))
	}
}

error_response! : [NotFound, Unauthorized, BadRequest(Str), BadData(Str), Constraint(_), Remote(Gavel.RoomErr), ..] => Response
error_response! = |e| match e {
	NotFound => Response.from_text(404, "not found")
	Remote(NotOpen) => Response.from_text(404, "the lot room is not open")
	Remote(AlreadyOpen) => Response.from_text(409, "the lot room is open")
	Unauthorized => Response.from_text(401, "admin token needed")
	BadRequest(msg) => Response.from_text(400, msg)
	BadData(msg) => Response.from_text(400, msg)
	Constraint(_) => Response.from_text(409, "the lot exists")
	_ => {
		Log.error!("request failed", Str.inspect(e))
		Response.from_text(500, "server error")
	}
}

# ---- Admin check ----

require_admin! : Request => Try({}, [Unauthorized, MissingEnv(Str)])
require_admin! = |req| {
	token = Env.secret!("ADMIN_TOKEN")?
	given = (req.header("authorization") ?? "").drop_prefix("Bearer ")
	if WebCrypto.timing_safe_equal!(given.to_utf8(), token.reveal().to_utf8()) Ok({}) else Err(Unauthorized)
}

# ---- Catalog ----

## KV is a cache: a failed read is a miss.
list_lots! : () => Try(Response, _)
list_lots! = || match catalog.get!() {
	Ok(cached) => Ok(Response.from_json(200, cached))
	Err(_) => {
		fresh : List(Gavel.Lot)
		fresh = db.all!("SELECT ${lot_columns} FROM lots ORDER BY close_ms", Sql.none)?
		# The client gets the list first. The cache write is after the response.
		Ok(Response.from_json(200, fresh).after(|| catalog.set_with!(fresh, { ttl_ms: 300_000 })))
	}
}

find_lot! : Str => Try(Gavel.Lot, _)
find_lot! = |id| db.first!("SELECT ${lot_columns} FROM lots WHERE id = ?", [id])

show_lot! : Str => Try(Response, _)
show_lot! = |id| {
	lot = find_lot!(id)?
	snapshot = lot_rooms.named(id).call!(Gavel.snapshot, {})?
	cfg = Gavel.config.get!()?
	Ok(Response.from_json(200, { lot, snapshot, fee_percent: cfg.fee_percent, currencies: cfg.currencies }))
}

create_lot! : Request => Try(Response, _)
create_lot! = |req| {
	require_admin!(req)?
	new : NewLot
	new = req.json!()?
	if new.id == "" or new.close_ms <= Time.now_ms!() {
		return Err(BadRequest("id is empty or the close time is past"))
	}
	cfg = Gavel.config.get!()?
	step = if new.reserve_cents / 100 > 100 new.reserve_cents / 100 else 100
	lot : Gavel.Lot
	lot = { id: new.id, title: new.title, reserve_cents: new.reserve_cents, close_ms: new.close_ms, min_step_cents: step, max_step_cents: cfg.max_step_cents }
	_ = db.run!(
		"INSERT INTO lots (${lot_columns}) VALUES (?, ?, ?, ?, ?, ?)",
		(lot.id, lot.title, lot.reserve_cents, lot.close_ms, lot.min_step_cents, lot.max_step_cents),
	)?
	# The room sets its alarm to the close time. When it fails, remove the row.
	match lot_rooms.named(lot.id).call!(Gavel.open, lot) {
		Ok(_) => {}
		Err(e) => {
			_ = db.run!("DELETE FROM lots WHERE id = ?", [lot.id])
			return Err(e)
		}
	}
	catalog.delete!()?
	Ok(Response.from_json(201, lot))
}

# ---- Images ----

get_image! : Request, Str => Try(Response, _)
get_image! = |req, id| Ok(images.respond!("images/${id}.jpg", req)?)

put_image! : Request, Str => Try(Response, _)
put_image! = |req, id| {
	require_admin!(req)?
	_ = find_lot!(id)?
	meta = images.put_with!("images/${id}.jpg", req.body(), { http: { content_type: req.header("content-type") ?? "image/jpeg" } })?
	Ok(Response.from_json(201, { etag: meta.http_etag, size_bytes: meta.size_bytes }))
}

# ---- Live bids ----

## The room answers with the 101 response. The Worker gives it back with no change.
live! : Request, Str => Try(Response, _)
live! = |req, id| {
	if !WebSocket.is_upgrade(req) {
		return Ok(Response.from_status(426))
	}
	# Only a known lot gets a room.
	_ = find_lot!(id)?
	Ok(lot_rooms.named(id).fetch!(req)?)
}

# ---- Cron ----

settle! : Worker.Scheduled => Try({}, _)
settle! = |s| {
	{ settled } = ledger.call!(Gavel.settle_due, {})?
	Log.info!("settled lots", { cron: s.cron(), settled })
	Ok({})
}

worker = Worker.new({
	fetch!,
	objects: [LotRoom.class],
	bindings: [Gavel.db.declare(), catalog.declare(), images.declare(), lot_rooms.declare(), ledger.declare()],
	crons: [Worker.cron("*/5 * * * *", settle!)],
})

event! = |e| worker.event!(e)
