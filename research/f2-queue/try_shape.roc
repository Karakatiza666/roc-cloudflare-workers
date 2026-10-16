app [event!] { pf: platform "../../bench/platform/main.roc", cbor: "https://github.com/Karakatiza666/roc-cbor/releases/download/0.1.0/9QL2dCyq7bcmvAEZfDFwi8kBvWLCZpEMS4WQYnZisezw.tar.zst" }

## What bytes does the derived `Cbor.encode` write for the fields of `Worker.TraceItem`? The shim must write the same
## shape (PLAN.md 8f, `js/events.js` `tailEvent`). Run: `roc test research/f2-queue/try_shape.roc` and read the `dbg` lines.
import pf.Worker
import cbor.Cbor

event! = |_| Unhandled

Row : { a : Try(Str, [Missing]), b : Try(U64, [Missing]), c : { x : Str } }

expect {
	r : Row
	r = { a: Err(Missing), b: Ok(5), c: { x: "y" } }
	dbg Cbor.encode(r)
	Bool.True
}

expect {
	r : Row
	r = { a: Ok("s"), b: Err(Missing), c: { x: "y" } }
	dbg Cbor.encode(r)
	Bool.True
}

parse : List(U8) -> Str
parse = |bytes| {
	r : Try(Row, _)
	r = Cbor.parse(bytes)
	Str.inspect(r)
}

# c = { x: "y" } is [161, 97, 120, 97, 121]
expect {
	dbg parse([162, 97, 97, 97, 115, 97, 99, 161, 97, 120, 97, 121])
	Bool.True
}
expect {
	dbg parse([162, 97, 98, 5, 97, 99, 161, 97, 120, 97, 121])
	Bool.True
}
# a: {"Ok": "s"}, b: {"Ok": 5}, c
expect {
	dbg parse([163, 97, 97, 161, 98, 79, 107, 97, 115, 97, 98, 161, 98, 79, 107, 5, 97, 99, 161, 97, 120, 97, 121])
	Bool.True
}
# a: {"Err": "Missing"}, b: {"Err": "Missing"}, c
expect {
	dbg parse([163, 97, 97, 161, 99, 69, 114, 114, 103, 77, 105, 115, 115, 105, 110, 103, 97, 98, 161, 99, 69, 114, 114, 103, 77, 105, 115, 115, 105, 110, 103, 97, 99, 161, 97, 120, 97, 121])
	Bool.True
}
# a: null, b: null, c
expect {
	dbg parse([163, 97, 97, 246, 97, 98, 246, 97, 99, 161, 97, 120, 97, 121])
	Bool.True
}
