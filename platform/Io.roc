## One operation as a value: a program and the function that reads its result (API.md 6.5).
## Pure data: it does nothing until a run.
import Js
import Host

Io(a, e) := { ops : List(Js.Op), waits : Bool, read : Try(Js, Io.Thrown) -> Try(a, e) }.{
	## What JS threw: the name and the message of the error (API.md 4, status 1).
	Thrown : { name : Str, message : Str }

	## An operation that runs with `await!` (one JSPI wait).
	new : List(Js.Op), (Try(Js, Io.Thrown) -> Try(a, e)) -> Io(a, e)
	new = |ops, read| { ops, waits: Bool.True, read }

	## An operation that runs with `call!` (no wait). A promise in it is an error (status 2).
	sync : List(Js.Op), (Try(Js, Io.Thrown) -> Try(a, e)) -> Io(a, e)
	sync = |ops, read| { ops, waits: Bool.False, read }

	map : Io(a, e), (a -> b) -> Io(b, e)
	map = |io, f| {
		read = io.read
		{ ops: io.ops, waits: io.waits, read: |r| read(r).map_ok(f) }
	}

	## The usual call: one crossing.
	run! : Io(a, e) => Try(a, e)
	run! = |io| {
		read = io.read
		read(if io.waits await!(io.ops) else call!(io.ops))
	}

	## Run a program with one wait (`Js.await!` in API.md 6.4). The value of the last op, or what JS threw.
	await! : List(Js.Op) => Try(Js, Io.Thrown)
	await! = |ops| result(Host.await!(Js.program(ops)))

	## Run a program with no wait (`Js.call!` in API.md 6.4).
	call! : List(Js.Op) => Try(Js, Io.Thrown)
	call! = |ops| result(Host.call!(Js.program(ops)))

	## Two operations at the same time, in one crossing (`Par`, OP6).
	both! : Io(a, e), Io(b, e) => Try((a, b), e)
	both! = |x, y| {
		rx = x.read
		ry = y.read
		(bx, by) = match await!([Par([x.ops, y.ops])]) {
			Ok(Arr([vx, vy])) => (branch(vx), branch(vy))
			Ok(_) => crash "Io.both!: the Par result is not two branches"
			Err(t) => (Err(t), Err(t))
		}
		a = rx(bx)?
		b = ry(by)?
		Ok((a, b))
	}

	## Many operations at the same time, in one crossing (`Par`, OP6).
	all! : List(Io(a, e)) => List(Try(a, e))
	all! = |ios| {
		if ios.is_empty() {
			return []
		}
		got = match await!([Par(ios.map(|io| io.ops))]) {
			Ok(Arr(items)) if items.len() == ios.len() => items.map(branch)
			Ok(_) => crash "Io.all!: the Par result has another length"
			Err(t) => ios.map(|_| Err(t))
		}
		ios.map2(got, |io, r| {
			read = io.read
			read(r)
		})
	}

	## The first operation to settle wins (`Race`, OP8). `index` is its place in the list.
	## The others are aborted. A `Race` with no branch is a bad program (status 3).
	race! : List(Io(a, e)) => { index : U64, result : Try(a, e) }
	race! = |ios| {
		match await!([Race(ios.map(|io| io.ops))]) {
			Ok(Arr([Int(i), r])) => {
				index = i.to_u64_try() ?? crash "Io.race!: a bad index"
				match ios.get(index) {
					Ok(io) => {
						read = io.read
						{ index, result: read(branch(r)) }
					}
					Err(_) => crash "Io.race!: the index is not a branch"
				}
			}
			Ok(_) => crash "Io.race!: the Race result is not [index, branch]"
			Err(t) => match ios.first() {
				Ok(io) => {
					read = io.read
					{ index: 0, result: read(Err(t)) }
				}
				Err(_) => crash "Io.race!: no branch"
			}
		}
	}

	## Start an operation, and give its promise as a ref (for `Ctx.wait_until!`). No wait.
	## The reader does not run: a Roc-level `Err` is not seen. A JS throw goes to the log (6.5).
	start! : Io(a, e) => Js.Ref
	start! = |io| match call!([Start(Root("pf"), "spawn", [Lit(Js.program(io.ops))]), Keep(Slot(0))]) {
		Ok(Ref(r)) => r
		Ok(_) => crash "Io.start!: the result is not a ref"
		Err(t) => crash "Io.start!: ${t.name}: ${t.message}"
	}

	## The pin table of the isolate (API.md RS2): `Js.pin!`, `pinned!` and `unpin!` of API.md, here for the reason of
	## `await!` and `call!` (`Host` imports `Js`, no import cycles). Each is one `call!`, no wait.
	## `pin!` keeps the value for later tasks of this isolate by name: each `Ref` in it keeps its object. A full table
	## (shim option `pinLimit`) is `PinErr`.
	pin! : Str, Js, { max_age_ms : U64 } => Try({}, [PinErr(Io.Thrown)])
	pin! = |name, value, opts| {
		age = opts.max_age_ms.to_i64_try() ?? I64.highest
		match call!([Call(Root("pf"), "pin", [Lit(Text(name)), Lit(value), Lit(Int(age))])]) {
			Ok(_) => Ok({})
			Err(t) => Err(PinErr(t))
		}
	}

	## The value that `pin!` kept (J1 to J7: each object gets a new ref of this task). `NotPinned`: no entry, or an
	## entry past its age.
	pinned! : Str => Try(Js, [NotPinned])
	pinned! = |name| match call!([Call(Root("pf"), "pinned", [Lit(Text(name))])]) {
		Ok(Undefined) => Err(NotPinned)
		Ok(v) => Ok(v)
		Err(t) => crash "Io.pinned!: ${t.name}: ${t.message}"
	}

	## Remove the entry. No entry: no change.
	unpin! : Str => {}
	unpin! = |name| match call!([Call(Root("pf"), "unpin", [Lit(Text(name))])]) {
		Ok(_) => {}
		Err(t) => crash "Io.unpin!: ${t.name}: ${t.message}"
	}
}

## Status 0 to 3 of a hosted call (API.md 4). Status 3 is a platform bug: crash.
result : { status : U8, value : Js } -> Try(Js, Io.Thrown)
result = |r| match r.status {
	0 => Ok(r.value)
	3 => crash "bad program: ${thrown(r.value).name}: ${thrown(r.value).message}"
	_ => Err(thrown(r.value))
}

thrown : Js -> Io.Thrown
thrown = |v| match v {
	Error(name, message) => { name, message }
	_ => { name: "Error", message: "" }
}

## One branch of `Par` or `Race`: `[status, value]` (OP6).
branch : Js -> Try(Js, Io.Thrown)
branch = |b| match b {
	Arr([Int(0), v]) => Ok(v)
	Arr([Int(3), v]) => crash "bad program: ${thrown(v).name}: ${thrown(v).message}"
	Arr([Int(_), v]) => Err(thrown(v))
	_ => crash "Io: a branch result is not [status, value]"
}
