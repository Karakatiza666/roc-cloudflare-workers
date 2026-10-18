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
import pf.R2
import pf.Service
import pf.WebCrypto
import pf.WebSocket
import pf.Time
import pf.Log
import Gavel
import LotRoom

db = Gavel.db

lot_rooms = Gavel.lot_rooms

images = R2.binding("BUCKET")

ledger = Service.binding("LEDGER")

catalog : Kv(List(Gavel.Lot))
catalog = Kv.json("KV")

catalog_key = "catalog"

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
	match (req.method, req.segments()) {
		(GET, ["lots"]) => list_lots!()
		(POST, ["lots"]) => create_lot!(req)
		(GET, ["lots", id]) => show_lot!(id)
		(GET, ["lots", id, "image"]) => get_image!(req, id)
		(PUT, ["lots", id, "image"]) => put_image!(req, id)
		(GET, ["lots", id, "live"]) => live!(req, id)
		_ => Ok(Response.from_status(404))
	}
}

error_response! : [NotFound, Unauthorized, BadRequest(Str), BadData(Str), Constraint(_), ..] => Response
error_response! = |e| match e {
	NotFound => Response.from_text(404, "not found")
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
list_lots! = || {
	lots = match catalog.get!(catalog_key) {
		Ok(cached) => cached
		Err(_) => {
			fresh : List(Gavel.Lot)
			fresh = db.all!("SELECT ${lot_columns} FROM lots ORDER BY close_ms", [])?
			match catalog.put_with!(catalog_key, fresh, { ttl_ms: 300_000 }) {
				Ok({}) => {}
				Err(e) => Log.warn!("catalog cache write failed", Str.inspect(e))
			}
			fresh
		}
	}
	Ok(Response.from_json(200, lots))
}

find_lot! : Str => Try(Gavel.Lot, _)
find_lot! = |id| db.first!("SELECT ${lot_columns} FROM lots WHERE id = ?", [Text(id)])

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
	if new.id == "" or new.close_ms <= Time.now_ms!({}) {
		return Err(BadRequest("id is empty or the close time is past"))
	}
	cfg = Gavel.config.get!()?
	step = if new.reserve_cents / 100 > 100 new.reserve_cents / 100 else 100
	lot : Gavel.Lot
	lot = { id: new.id, title: new.title, reserve_cents: new.reserve_cents, close_ms: new.close_ms, min_step_cents: step, max_step_cents: cfg.max_step_cents }
	_ = db.run!(
		"INSERT INTO lots (${lot_columns}) VALUES (?, ?, ?, ?, ?, ?)",
		[Text(lot.id), Text(lot.title), Int(lot.reserve_cents.to_i64_wrap()), Int(lot.close_ms.to_i64_wrap()), Int(lot.min_step_cents.to_i64_wrap()), Int(lot.max_step_cents.to_i64_wrap())],
	)?
	# The room sets its alarm to the close time. When it fails, remove the row.
	match lot_rooms.named(lot.id).call!(Gavel.open, lot) {
		Ok({}) => {}
		Err(e) => {
			_ = db.run!("DELETE FROM lots WHERE id = ?", [Text(lot.id)])
			return Err(e)
		}
	}
	catalog.delete!(catalog_key)?
	Ok(Response.from_json(201, lot))
}

# ---- Images ----

get_image! : Request, Str => Try(Response, _)
get_image! = |req, id| {
	key = "images/${id}.jpg"
	# R2 wants an etag with no quotes, a browser sends it with quotes.
	found = match req.header("if-none-match") {
		Ok(tag) => images.get_with!(key, { only_if: { etag_does_not_match: tag.drop_prefix("\"").drop_suffix("\"") } })
		Err(NotFound) => images.get!(key)
	}
	match found {
		Ok(obj) => Ok(Response.from_body(200, obj.meta.http.?content_type ?? "image/jpeg", obj.body).with_header("etag", obj.meta.http_etag))
		Err(PreconditionFailed) => Ok(Response.from_status(304))
		Err(e) => Err(e)
	}
}

put_image! : Request, Str => Try(Response, _)
put_image! = |req, id| {
	require_admin!(req)?
	_ = find_lot!(id)?
	meta = images.put_with!("images/${id}.jpg", req.body, { http: { content_type: req.header("content-type") ?? "image/jpeg" } })?
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

scheduled! : Worker.Scheduled => Try({}, _)
scheduled! = |s| {
	{ settled } = ledger.call!(Gavel.settle_due, {})?
	Log.info!("settled lots", { cron: s.cron, settled })
	Ok({})
}

worker = Worker.{ fetch!, scheduled!, objects: [LotRoom.class] }

event! = |e| worker.event!(e)
