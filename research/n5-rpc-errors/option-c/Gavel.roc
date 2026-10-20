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

	## Units of each currency for 1 USD, as the FX feed gives them.
	Rates : { as_of_ms : U64, rates : List({ currency : Str, rate : F64 }) }

	Receipt : { lot_id : Str, winner : Str, amount_cents : U64, fee_cents : U64, converted : List({ currency : Str, amount_cents : U64 }), settled_ms : U64 }

	## The domain errors of a lot room. The infrastructure errors are `Rpc.Infra` (N5 option C).
	RoomErr : [NotOpen, AlreadyOpen, StillOpen]

	# The Rpc methods. The Roc callee and the Roc caller both use these values.
	## `open` is a command: its answer is `{}`.
	open : Rpc(Gavel.Lot, {}, Gavel.RoomErr)
	open = Rpc.method("open")

	snapshot : Rpc({}, Gavel.Snapshot, Gavel.RoomErr)
	snapshot = Rpc.method("snapshot")

	close_out : Rpc({}, Gavel.Closeout, Gavel.RoomErr)
	close_out = Rpc.method("close_out")

	settle_due : Rpc({}, { settled : U32 }, Rpc.NoErr)
	settle_due = Rpc.method("settle_due")

	# Bindings with the same name in both wrangler files. The room namespace is in each Worker (the ledger names the script).
	db = D1.binding("DB")

	## The KV namespace, for `declare` only: the typed values are the cells below.
	kv = Kv.text("KV")

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

create_tables! : () => Try({}, [D1Err(Io.Thrown), Constraint(Sql.Constraint)])
create_tables! = || {
	for sql in Gavel.schema {
		_ = Gavel.db.run!(sql, Sql.none)?
	}
	Ok({})
}
