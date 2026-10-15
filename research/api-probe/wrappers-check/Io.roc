## Can `Io` (API.md 6.5) be a nominal type with a function field and two type
## variables, and do the error unions of two `Io`s join in `both!`?
## Js values are `Str` here, and the crossing is a function that the caller gives.
Io(a, e) := { ops : List(Str), waits : Bool, read : Try(Str, Thrown) -> Try(a, e) }.{
	new : List(Str), (Try(Str, Thrown) -> Try(a, e)) -> Io(a, e)
	new = |ops, read| { ops, waits: Bool.True, read }

	map : Io(a, e), (a -> b) -> Io(b, e)
	map = |io, f| {
		read = io.read
		{ ops: io.ops, waits: io.waits, read: |r| read(r).map_ok(f) }
	}

	run_via! : Io(a, e), (List(Str) => Try(Str, Thrown)) => Try(a, e)
	run_via! = |io, cross!| {
		read = io.read
		read(cross!(io.ops))
	}

	## Two operations in one crossing (a `Par` op in the real module).
	both_via! : Io(a, e), Io(b, e), (List(Str) => Try(Str, Thrown)) => Try((a, b), e)
	both_via! = |x, y, cross!| {
		rx = x.read
		ry = y.read
		a = rx(cross!(x.ops))?
		b = ry(cross!(y.ops))?
		Ok((a, b))
	}
}

Thrown : { name : Str, message : Str }
