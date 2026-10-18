app [event!] { pf: platform "../../platform/main.roc" }
## Probe of the SQL parameter encodings (step 8h item 3): `roc test` prints the CBOR bytes.
import pf.Worker
import pf.Cbor
import pf.Sql

some : Try(Str, [NotFound])
some = Ok("a")
none : Try(Str, [NotFound])
none = Err(NotFound)

expect {
	dbg Cbor.encode((7.I64, Sql.null, Sql.or_null(some), Sql.or_null(none), Sql.blob([1, 2]), 2.5.F64, "x", 9.U64))
	dbg Cbor.encode([Sql.Int(5), Sql.Null, Sql.Text("a"), Sql.Blob([1])])
	dbg Cbor.encode({ a: 1.I64 })
	Bool.True
}

event! : Worker.Event => Worker.Outcome
event! = |_e| crash "x"
