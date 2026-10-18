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

Top : { bidder : Str, amount_cents : U64, bids_count : U64 }

## One error type for all handlers of the class.
Fault : [StorageErr(Io.Thrown), SqlErr(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge, NotOpen, TooLow(U64), TooHigh(U64), BadMessage, AlreadyOpen, StillOpen, OutOfRange]

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

init! : Object.Self => Try({}, Fault)
init! = |self| {
	_ = self.sql_run!("CREATE TABLE IF NOT EXISTS bids (seq INTEGER PRIMARY KEY AUTOINCREMENT, bidder TEXT NOT NULL, amount_cents INTEGER NOT NULL, at_ms INTEGER NOT NULL)", [])?
	Ok({})
}

## The upgrade request comes from auction-web. The bidder name is in the query.
fetch! : Object.Self, Request => Try(Response, Fault)
fetch! = |self, req| match req.query("bidder") {
	Err(NotFound) => Ok(Response.from_text(400, "bidder is needed"))
	Ok(name) => match self.accept_with!(req, { tags: [name] }) {
		Err(NotUpgrade) => Ok(Response.from_status(426))
		Err(TooLarge) => Ok(Response.from_status(400))
		Ok({ socket, response }) => {
			socket.attach!(
				{
					name
				},
			)?
			Ok(response)
		}
	}
}

# ---- Bids ----

## The best bid and the count of bids. One query: the count is also right for an empty table.
top! : Object.Self => Try(Top, _)
top! = |self| {
	rows : List(Top)
	rows = self.sql!("SELECT bidder, amount_cents, (SELECT count(*) FROM bids) AS bids_count FROM bids ORDER BY amount_cents DESC, seq ASC LIMIT 1", [])?
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
	bidder : Bidder
	bidder = socket.attachment!()?
	name = bidder.name
	st = state_cell.get!(self) ? |_| NotOpen
	best = top!(self)?
	now = Time.now_ms!({})
	LotRoom.check_bid(st, best.amount_cents, amount, now)?
	_ = self.sql_run!("INSERT INTO bids (bidder, amount_cents, at_ms) VALUES (?, ?, ?)", [Text(name), Int(amount.to_i64_wrap()), Int(now.to_i64_wrap())])?
	Ok({ bidder: name, amount_cents: amount })
}

on_message! : Object.Self, Object.Socket, WebSocket.Message => Try({}, Fault)
on_message! = |self, socket, msg| match place_bid!(self, socket, msg) {
	Ok({ bidder, amount_cents }) => {
		broadcast!(self, Json.to_str({ event: "bid", bidder, amount_cents }))
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

reject! : Object.Socket, Str => Try({}, Fault)
reject! = |socket, message| {
	_ = socket.send!(Text(Json.to_str({ event: "error", message })))
	Ok({})
}

broadcast! : Object.Self, Str => {}
broadcast! = |self, text| for s in self.sockets!() {
	_ = s.send!(Text(text))
}

on_close! : Object.Self, Object.Socket, WebSocket.Closed => Try({}, Fault)
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

alarm! : Object.Self, { retry_count : U32, is_retry : Bool } => Try({}, Fault)
alarm! = |self, _info| match state_cell.get!(self) {
	Err(NotFound) => Ok({})
	Err(BadData(s)) => Err(BadData(s))
	Err(StorageErr(t)) => Err(StorageErr(t))
	Ok(st) =>
		if st.status == Closed {
			Ok({})
		} else {
			out = close_now!(self, st)?
			broadcast!(self, Json.to_str({ event: "closed", winner: out.winner, amount_cents: out.amount_cents }))
			for s in self.sockets!() {
				s.close!(1000, "lot closed")
			}
			Ok({})
		}
}

# ---- Rpc ----

open! : Object.Self, Gavel.Lot => Try({}, Fault)
open! = |self, lot| match state_cell.get!(self) {
	Ok(_) => Err(AlreadyOpen)
	Err(NotFound) => {
		state_cell.set!(
			self,
			{ status: Open, reserve_cents: lot.reserve_cents, close_ms: lot.close_ms, min_step_cents: lot.min_step_cents, max_step_cents: lot.max_step_cents, winner: "", final_cents: 0 },
		)?
		self.set_alarm!(lot.close_ms)?
		Ok({})
	}
	Err(BadData(s)) => Err(BadData(s))
	Err(StorageErr(t)) => Err(StorageErr(t))
}

snapshot! : Object.Self, {} => Try(Gavel.Snapshot, Fault)
snapshot! = |self, {}| {
	st = state_cell.get!(self) ? |_| NotOpen
	best = top!(self)?
	Ok({ high: best.amount_cents, bidder: best.bidder, open: st.status == Open, bids_count: best.bids_count })
}

## Used by the ledger. A lot that is past its close time but whose alarm has not run yet is closed here.
close_out! : Object.Self, {} => Try(Gavel.Closeout, Fault)
close_out! = |self, {}| {
	st = state_cell.get!(self) ? |_| NotOpen
	match st.status {
		Closed => Ok({ winner: st.winner, amount_cents: st.final_cents })
		Open =>
			if Time.now_ms!({}) >= st.close_ms {
				Ok(close_now!(self, st)?)
			} else {
				Err(StillOpen)
			}
	}
}
