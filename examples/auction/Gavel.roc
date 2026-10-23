## Shared by auction-web and auction-ledger: types, the Rpc method names, the bindings that both Workers use.
## Both apps import this file, so the caller and the callee of each Rpc method have the same types.
import pf.Rpc
import pf.Kv
import pf.D1
import pf.Io
import pf.Memo
import pf.Sql

Gavel :: [].{

	## A lot. The steps are in cents. `max_step_cents` comes from the site config at the time of creation.
	Lot : { id : Str, title : Str, reserve_cents : U64, close_ms : U64, min_step_cents : U64, max_step_cents : U64 }

	Snapshot : { high : U64, bidder : Str, open : Bool, bids_count : U64 }

	## `winner` is "" when the lot closed under its reserve.
	Closeout : { winner : Str, amount_cents : U64 }

	Config : { fee_percent : U64, max_step_cents : U64, currencies : List(Str) }

	## Units of each currency for 1 USD, as the FX feed gives them. `Dec`: a feed number is read exactly, and CBOR keeps it exact (tag 4).
	Rates : { as_of_ms : U64, rates : List({ currency : Str, rate : Dec }) }

	Receipt : { lot_id : Str, winner : Str, amount_cents : U64, fee_cents : U64, converted : List({ currency : Str, amount_cents : U64 }), settled_ms : U64 }

	## The platform errors of this app: the tags that its platform calls can give. A tag of `Rpc.Infra` that is not here is a compile error.
	## The closed union has code for each tag (3 to 6 KB of wasm), so the app lists only its own tags in place of `Rpc.Infra`.
	Faults : [StorageErr(Io.Thrown), SqlErr(Io.Thrown), Constraint(Sql.Constraint), BadData(Str), TooLarge, D1Err(Io.Thrown), KvErr(Io.Thrown), R2Err(Io.Thrown), ObjectErr(Io.Thrown), RpcErr(Io.Thrown), MissingEnv(Str)]

	## What a lot room can answer. Each Rpc method of the room has this error type, and the callee cannot give another tag.
	## `Infra`: a platform call of the room failed (storage, SQL).
	RoomErr : [NotOpen, AlreadyOpen, StillOpen, Infra(Gavel.Faults)]

	## What `settle_due` can answer: only platform errors (D1, KV).
	SettleErr : [Infra(Gavel.Faults)]

	## The interfaces: one type for each callee, with no values. `Rpc(Gavel.Room, ..)` is a method of a lot room. A call of a
	## method of another interface does not compile, and a class takes the methods of one interface only.
	Room := []

	Ledger := []

	## The values of the interfaces. The text is the name that the manifest records: `roc-cloudflare-workers sync` compares it
	## across the Workers of the repo (the service binding and the namespace go to a Worker by name in the Wrangler config).
	room : Rpc.Iface(Gavel.Room)
	room = Rpc.iface("Room")

	ledger : Rpc.Iface(Gavel.Ledger)
	ledger = Rpc.iface("Ledger")

	# The Rpc methods. The Roc callee and the Roc caller both use these values.
	## `open` is a command: its answer is `{}`.
	open : Rpc(Gavel.Room, Gavel.Lot, {}, Gavel.RoomErr)
	open = Gavel.room.method("open")

	snapshot : Rpc(Gavel.Room, {}, Gavel.Snapshot, Gavel.RoomErr)
	snapshot = Gavel.room.method("snapshot")

	close_out : Rpc(Gavel.Room, {}, Gavel.Closeout, Gavel.RoomErr)
	close_out = Gavel.room.method("close_out")

	settle_due : Rpc(Gavel.Ledger, {}, { settled : U32 }, Gavel.SettleErr)
	settle_due = Gavel.ledger.method("settle_due")

	# Bindings with the same name in both wrangler files. The room namespace is in each Worker (the ledger names the script).
	db = D1.binding("DB")

	# The KV binding is declared by one cell of it (`Kv.Cell.declare`): `web.roc` and `ledger.roc` name one cell each.
	config_cell : Kv.Cell(Gavel.Config)
	config_cell = Kv.json("KV").cell("config")

	rates_cell : Kv.Cell(Gavel.Rates)
	rates_cell = Kv.json("KV").cell("fx:rates")

	no_rates : Gavel.Rates
	no_rates = { as_of_ms: 0, rates: [] }

	default_config : Gavel.Config
	default_config = { fee_percent: 5, max_step_cents: 100_000, currencies: ["EUR", "GBP", "JPY"] }

	## The site config, loaded once for each isolate. A missing key gives the default.
	config : Memo(Gavel.Config, _)
	config = Memo.new("gavel-config", { max_age_ms: 60_000, load!: || Gavel.config_cell.get_or!(Gavel.default_config) })

	## Both Workers share one D1 database. Each Worker creates the tables once for each isolate.
	tables : Memo({}, _)
	tables = Memo.new("gavel-tables", { max_age_ms: 3_600_000, load!: create_tables! })

	schema : List(Str)
	schema = [
		"CREATE TABLE IF NOT EXISTS lots (id TEXT PRIMARY KEY, title TEXT NOT NULL, reserve_cents INTEGER NOT NULL, close_ms INTEGER NOT NULL, min_step_cents INTEGER NOT NULL, max_step_cents INTEGER NOT NULL)",
		"CREATE TABLE IF NOT EXISTS settlements (lot_id TEXT PRIMARY KEY, winner TEXT NOT NULL, amount_cents INTEGER NOT NULL, settled_ms INTEGER NOT NULL)",
	]
}

create_tables! : () => Try({}, [Infra([D1Err(Io.Thrown), Constraint(Sql.Constraint)])])
create_tables! = || {
	for sql in Gavel.schema {
		_ = Gavel.db.run!(sql, Sql.none)?
	}
	Ok({})
}
