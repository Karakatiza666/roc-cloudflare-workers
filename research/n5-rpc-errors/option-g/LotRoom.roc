## The Durable Object class of one lot (one object for each lot id). Its sockets use the hibernation API.
## SQL table `bids` keeps the history. The cell `state` keeps the open or closed state. The alarm closes the lot.
import pf.Object
import pf.Request
import pf.Response
import pf.Sql
import pf.Io
import pf.Time
import pf.Log
import pf.Cbor
import pf.WebSocket
import Gavel

State : { status : [Open, Closed], reserve_cents : U64, close_ms : U64, min_step_cents : U64, max_step_cents : U64, winner : Str, final_cents : U64 }

state_cell : Object.Cell(State)
state_cell = Object.cell("state")

## The bidder name. It stays with the socket while the object sleeps.
Bidder : { name : Str }

bidder_slot : Object.Attachment(Bidder)
bidder_slot = Object.attachment("bidder")

Top : { bidder : Str, amount_cents : U64, bids_count : U64 }

LotRoom :: [].{

	class : Object.Class
	class = Object.class(
		"LotRoom",
		{
			init!: init!,
			fetch!: fetch!,
			alarm!: alarm!,
			web_socket_message!: on_message!,
			web_socket_close!: on_close!,
			rpc: [Gavel.open.on(open!), Gavel.snapshot.on(snapshot!), Gavel.close_out.on(close_out!)],
		},
	)

	## The rule for a bid, as a pure function. The first bid needs the min step. Later bids need high + min step, and at most high + max step.
	check_bid : State, U64, U64, U64 -> Try({}, [NotOpen, TooLow(U64), TooHigh(U64)])
	check_bid = |st, high, amount, now| {
		floor = high + st.min_step_cents
		if st.status == Closed or now >= st.close_ms {
			Err(NotOpen)
		} else if amount < floor {
			Err(TooLow(floor))
		} else if amount > high + st.max_step_cents {
			Err(TooHigh(high + st.max_step_cents))
		} else {
			Ok({})
		}
	}
}

init! : Object.Self => Try({}, _)
init! = |self| {
	_ = self.sql_run!("CREATE TABLE IF NOT EXISTS bids (seq INTEGER PRIMARY KEY AUTOINCREMENT, bidder TEXT NOT NULL, amount_cents INTEGER NOT NULL, at_ms INTEGER NOT NULL)", Sql.none)?
	Ok({})
}

## The upgrade request comes from auction-web. The bidder name is in the query.
fetch! : Object.Self, Request => Try(Response, _)
fetch! = |self, req| match req.query("bidder") {
	Err(NotFound) => Ok(Response.from_text(400, "bidder is needed"))
	Ok(name) => match self.accept_with!(req, { tags: [name] }) {
		Err(NotUpgrade) => Ok(Response.from_status(426))
		Err(Infra(TooLarge)) => Ok(Response.from_status(400))
		Ok({ socket, response }) => {
			bidder_slot.set!(socket, { name: name })?
			Ok(response)
		}
	}
}

# ---- Bids ----

## The state of the lot. A lot with no state is not open. The other errors stay as they are.
load_state! : Object.Self => Try(State, [NotOpen, Infra([BadData(Str), StorageErr(Io.Thrown)])])
load_state! = |self| match state_cell.get!(self) {
	Ok(st) => Ok(st)
	Err(NotFound) => Err(NotOpen)
	Err(Infra(i)) => Err(Infra(i))
}

## The best bid and the count of bids. One query: the count is also right for an empty table.
top! : Object.Self => Try(Top, _)
top! = |self| {
	rows : List(Top)
	rows = self.sql!("SELECT bidder, amount_cents, (SELECT count(*) FROM bids) AS bids_count FROM bids ORDER BY amount_cents DESC, seq ASC LIMIT 1", Sql.none)?
	match rows {
		[best, ..] => Ok(best)
		[] => Ok({ bidder: "", amount_cents: 0, bids_count: 0 })
	}
}

bid_amount : WebSocket.Message -> Try(U64, [BadMessage])
bid_amount = |msg| {
	parsed : Try({ bid : U64 }, _)
	parsed = match msg {
		Text(_) => msg.json()
		Bytes(b) => Cbor.parse(b)
	}
	match parsed {
		Ok({ bid }) => Ok(bid)
		Err(_) => Err(BadMessage)
	}
}

## The checks and the insert have no wait between them, so no other bid can come in between (MODULES.md 7, Transactions).
place_bid! : Object.Self, Object.Socket, WebSocket.Message => Try({ bidder : Str, amount_cents : U64 }, _)
place_bid! = |self, socket, msg| {
	amount = bid_amount(msg)?
	{ name } = bidder_slot.get!(socket)?
	st = load_state!(self)?
	best = top!(self)?
	now = Time.now_ms!()
	LotRoom.check_bid(st, best.amount_cents, amount, now)?
	_ = self.sql_run!("INSERT INTO bids (bidder, amount_cents, at_ms) VALUES (?, ?, ?)", (name, amount, now))?
	Ok({ bidder: name, amount_cents: amount })
}

on_message! : Object.Self, Object.Socket, WebSocket.Message => Try({}, _)
on_message! = |self, socket, msg| match place_bid!(self, socket, msg) {
	Ok({ bidder, amount_cents }) => {
		_ = self.broadcast!(Text(Json.to_str({ event: "bid", bidder, amount_cents })))
		Ok({})
	}
	Err(NotOpen) => reject!(socket, "the lot is not open")
	Err(BadMessage) => reject!(socket, "send { \"bid\": cents }")
	Err(TooLow(n)) => reject!(socket, "the bid must be at least ${n.to_str()}")
	Err(TooHigh(n)) => reject!(socket, "the bid must be at most ${n.to_str()}")
	Err(e) => {
		_ = reject!(socket, "internal error")
		Log.error!("bid failed", Str.inspect(e))
		Ok({})
	}
}

reject! : Object.Socket, Str => Try({}, _)
reject! = |socket, message| {
	_ = socket.send!(Text(Json.to_str({ event: "error", message })))
	Ok({})
}

on_close! : Object.Self, Object.Socket, WebSocket.Closed => Try({}, _)
on_close! = |self, socket, closed| {
	Log.info!("socket closed", { lot: self.id(), code: closed.code, clean: closed.clean })
	socket.close!(closed.code, closed.reason)
	Ok({})
}

# ---- Close ----

## Close the lot: pick the winner, keep it in the cell. The reserve rule is here.
close_now! : Object.Self, State => Try(Gavel.Closeout, _)
close_now! = |self, st| {
	best = top!(self)?
	met = best.bids_count > 0 and best.amount_cents >= st.reserve_cents
	out = if met { winner: best.bidder, amount_cents: best.amount_cents } else { winner: "", amount_cents: 0 }
	state_cell.set!(self, { ..st, status: Closed, winner: out.winner, final_cents: out.amount_cents })?
	Ok(out)
}

alarm! : Object.Self, { retry_count : U32, is_retry : Bool } => Try({}, _)
alarm! = |self, _info| match state_cell.get!(self) {
	Err(NotFound) => Ok({})
	Err(e) => Err(e)
	Ok(st) =>
		if st.status == Closed {
			Ok({})
		} else {
			out = close_now!(self, st)?
			_ = self.broadcast!(Text(Json.to_str({ event: "closed", winner: out.winner, amount_cents: out.amount_cents })))
			for s in self.sockets!() {
				s.close!(1000, "lot closed")
			}
			Ok({})
		}
}

# ---- Rpc ----

open! : Object.Self, Gavel.Lot => Try({}, Gavel.RoomErr)
open! = |self, lot| match state_cell.get!(self) {
	Ok(_) => Err(AlreadyOpen)
	Err(NotFound) => {
		state_cell.set!(
			self,
			{ status: Open, reserve_cents: lot.reserve_cents, close_ms: lot.close_ms, min_step_cents: lot.min_step_cents, max_step_cents: lot.max_step_cents, winner: "", final_cents: 0 },
		)?
		self.set_alarm_at!(lot.close_ms)?
		Ok({})
	}
	Err(Infra(i)) => Err(Infra(i))
}

snapshot! : Object.Self, {} => Try(Gavel.Snapshot, _)
snapshot! = |self, {}| {
	st = load_state!(self)?
	best = top!(self)?
	Ok({ high: best.amount_cents, bidder: best.bidder, open: st.status == Open, bids_count: best.bids_count })
}

## Used by the ledger. A lot that is past its close time but whose alarm has not run yet is closed here.
close_out! : Object.Self, {} => Try(Gavel.Closeout, _)
close_out! = |self, {}| {
	st = load_state!(self)?
	match st.status {
		Closed => Ok({ winner: st.winner, amount_cents: st.final_cents })
		Open =>
			if Time.now_ms!() >= st.close_ms {
				Ok(close_now!(self, st)?)
			} else {
				Err(StillOpen)
			}
	}
}
