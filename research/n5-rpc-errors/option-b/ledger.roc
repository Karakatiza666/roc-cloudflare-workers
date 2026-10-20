app [event!] { pf: platform "../../../platform/main.roc" }

## auction-ledger: settles closed lots and keeps the FX rates. Its only public route is GET /health.
##
## | Entry | Does |
## | --- | --- |
## | Rpc `settle_due` (default entry point) | for each closed lot with no settlement: close_out on the room, receipt in R2, row in D1 |
## | Cron `0 * * * *` (`Worker.cron`) | read the FX feed (WebSocket client), store the rates in KV, then settle |
import pf.Worker
import pf.Request
import pf.Response
import pf.R2
import pf.WebSocket
import pf.Time
import pf.Object
import pf.Sql
import pf.Log
import Gavel

receipts = R2.binding("RECEIPTS")

## The class `LotRoom` is in the script of auction-web.
lot_rooms = Object.namespace("LOT_ROOM", { class: "LotRoom", script: "auction-web" })

feed_url = "wss://fx.example.com/stream"

## The longest wait for the feed.
feed_limit_ms = 20_000

## One message of the feed.
Tick : { currency : Str, rate : F64 }

fetch! : Request => Try(Response, e)
fetch! = |req| match (req.method(), req.segments()) {
	(GET, ["health"]) => Ok(Response.from_text(200, "ok"))
	_ => Ok(Response.from_status(404))
}

# ---- Settlement ----

settle_due! : {} => Try({ settled : U32 }, Gavel.SettleErr)
settle_due! = |{}| {
	Gavel.tables.get!()?
	cfg = Gavel.config.get!()?
	now = Time.now_ms!()
	rates = Gavel.rates_cell.get_or!(Gavel.no_rates)?
	due : List({ id : Str })
	due = Gavel.db.all!("SELECT id FROM lots WHERE close_ms <= ? AND id NOT IN (SELECT lot_id FROM settlements) ORDER BY close_ms LIMIT 50", [now])?
	var $settled = 0.U32
	for lot in due {
		# One bad lot (for example, a room that is still open) does not stop the others.
		match settle_one!(lot.id, cfg, rates, now) {
			Ok({}) => {
				$settled = $settled + 1
			}
			Err(e) => Log.warn!("settle failed", { lot: lot.id, error: Str.inspect(e) })
		}
	}
	Ok({ settled: $settled })
}

## The receipt goes to R2 first and the row to D1 last. A failure between them leaves the lot due, and the next run does it again.
settle_one! : Str, Gavel.Config, Gavel.Rates, U64 => Try({}, _)
settle_one! = |id, cfg, rates, now| {
	closeout = lot_rooms.named(id).call!(Gavel.close_out, {})?
	receipt = make_receipt(id, closeout, cfg, rates, now)
	_ = receipts.put_with!("receipts/${id}.json", Text(Json.to_str(receipt)), { http: { content_type: "application/json" } })?
	_ = Gavel.db.run!(
		"INSERT OR REPLACE INTO settlements (lot_id, winner, amount_cents, settled_ms) VALUES (?, ?, ?, ?)",
		(id, closeout.winner, closeout.amount_cents, now),
	)?
	Ok({})
}

## A currency with no rate is left out of the receipt.
make_receipt : Str, Gavel.Closeout, Gavel.Config, Gavel.Rates, U64 -> Gavel.Receipt
make_receipt = |id, closeout, cfg, rates, now| {
	converted = cfg.currencies.keep_oks(
		|currency| match rates.rates.find_first(|r| r.currency == currency) {
			Ok(r) => Ok({ currency, amount_cents: (closeout.amount_cents.to_f64() * r.rate).round_to_u64_try() ?? 0 })
			Err(NotFound) => Err(NoRate)
		},
	)
	{ lot_id: id, winner: closeout.winner, amount_cents: closeout.amount_cents, fee_cents: closeout.amount_cents * cfg.fee_percent / 100, converted, settled_ms: now }
}

expect {
	cfg = { fee_percent: 5, max_step_cents: 0, currencies: ["EUR", "XXX"] }
	rates = { as_of_ms: 1, rates: [{ currency: "EUR", rate: 0.5 }] }
	r = make_receipt("l1", { winner: "ann", amount_cents: 1000 }, cfg, rates, 9)
	r.fee_cents == 50 and r.converted == [{ currency: "EUR", amount_cents: 500 }]
}

# ---- FX feed ----

has_all : List(Str), List(Tick) -> Bool
has_all = |currencies, ticks| currencies.all(|c| ticks.any(|t| t.currency == c))

## Subscribe, read ticks until each currency has a rate or the time limit ends, then store the rates in KV.
refresh_rates! : () => Try({ stored : U64 }, _)
refresh_rates! = || {
	cfg = Gavel.config.get!()?
	ws = WebSocket.connect!(feed_url)?
	_ = ws.send_json!({ op: "subscribe", base: "USD", currencies: cfg.currencies })
	deadline = Time.now_ms!() + feed_limit_ms
	no_ticks : List(Tick)
	no_ticks = []
	var $ticks = no_ticks
	while !has_all(cfg.currencies, $ticks) {
		now = Time.now_ms!()
		if now >= deadline {
			break
		}
		match ws.receive().timeout(deadline - now).run!() {
			Ok(msg) => {
				tick : Try(Tick, _)
				tick = msg.json()
				# A frame that is not a tick (a heartbeat) is skipped.
				match tick {
					Ok(t) => {
						$ticks = $ticks.append(t)
					}
					Err(_) => {}
				}
			}
			Err(TimedOut) => break
			Err(Closed(_)) => break
		}
	}
	ws.close!(1000, "done")
	missing = cfg.currencies.keep_if(|c| !$ticks.any(|t| t.currency == c))
	if !missing.is_empty() {
		return Err(MissingRates(missing))
	}
	rates : Gavel.Rates
	rates = { as_of_ms: Time.now_ms!(), rates: $ticks.map(|t| { currency: t.currency, rate: t.rate }) }
	Gavel.rates_cell.set_with!(rates, { ttl_ms: 7_200_000 })?
	Ok({ stored: rates.rates.len() })
}

hourly! : Worker.Scheduled => Try({}, _)
hourly! = |_s| {
	match refresh_rates!() {
		Ok({ stored }) => Log.info!("fx rates stored", { count: stored })
		Err(e) => Log.warn!("fx refresh failed", Str.inspect(e))
	}
	{ settled } = settle_due!({})?
	Log.info!("settled lots", { settled: settled })
	Ok({})
}

worker = Worker.new({
	fetch!,
	rpc: [Gavel.settle_due.on_worker(settle_due!)],
	bindings: [Gavel.db.declare(), Gavel.kv.declare(), receipts.declare(), lot_rooms.declare()],
	crons: [Worker.cron("0 * * * *", hourly!)],
})

event! = |e| worker.event!(e)
