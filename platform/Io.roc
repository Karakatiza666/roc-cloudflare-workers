## One operation as a value: a program and the function that reads its result (API.md 6.5).
## Pure data: it does nothing until a run. The raw program forms are in `Js`.
import Js

Io(a, e) := { ops : List(Js.Op), waits : Bool, read : Try(Js, Io.Thrown) -> Try(a, e) }.{
	## What JS threw: the name and the message of the error (API.md 4, status 1).
	Thrown : Js.Thrown

	## Low level: an operation from `Js` ops, that runs with `Js.await!` (one JSPI wait).
	new : List(Js.Op), (Try(Js, Io.Thrown) -> Try(a, e)) -> Io(a, e)
	new = |ops, read| { ops, waits: Bool.True, read }

	## Low level: an operation from `Js` ops, that runs with `Js.call!` (no wait). A promise in it is an error (status 2).
	sync : List(Js.Op), (Try(Js, Io.Thrown) -> Try(a, e)) -> Io(a, e)
	sync = |ops, read| { ops, waits: Bool.False, read }

	map : Io(a, e), (a -> b) -> Io(b, e)
	map = |io, f| {
		read = io.read
		{ ops: io.ops, waits: io.waits, read: |r| read(r).map_ok(f) }
	}

	## Handle an error: `Ok` gives a value in place of it, `Err` gives the error of the new type (`Try.on_err`).
	recover : Io(a, e), (e -> Try(a, f)) -> Io(a, f)
	recover = |io, f| {
		read = io.read
		{ ops: io.ops, waits: io.waits, read: |r| read(r).on_err(f) }
	}

	## The usual call: one crossing.
	run! : Io(a, e) => Try(a, e)
	run! = |io| {
		read = io.read
		read(if io.waits Js.await!(io.ops) else Js.call!(io.ops))
	}

	## Two operations at the same time, in one crossing (`Par`, OP6).
	both! : Io(a, e), Io(b, e) => Try((a, b), e)
	both! = |x, y| {
		rx = x.read
		ry = y.read
		(bx, by) = match Js.await!([Par([x.ops, y.ops])]) {
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
		got = match Js.await!([Par(ios.map(|io| io.ops))]) {
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
		match Js.await!([Race(ios.map(|io| io.ops))]) {
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

	## The operation, or `Err(TimedOut)` when `ms` pass first: a race with a sleep (`Race`, OP8). The loser is aborted
	## as in `race!` (a receive that lost takes no message). The sleep is the one of `Time.sleep`.
	timeout : Io(a, e), U64 -> Io(a, [TimedOut, ..e])
	timeout = |io, ms| {
		read = io.read
		sleep = [
			Get(Root("global"), "scheduler"),
			Keep(Root("signal")),
			Record([("signal", Slot(1))]),
			Call(Slot(0), "wait", [Lit(Int(ms.to_i64_try() ?? I64.highest)), Slot(2)]),
		]
		{
			ops: [Race([io.ops, sleep])],
			waits: Bool.True,
			read: |r| timeout_read(read, r),
		}
	}

	## The same as `timeout`, with a point in time: `deadline_ms` is on the clock of `Time.now_ms!` (`Date.now()`).
	## One deadline for many reads needs no sum of the time left. The wait is `max(0, deadline_ms - Date.now())` at
	## the time the program runs (`pf.waitUntil`), not when the `Io` is made. A deadline in the past waits 0 ms:
	## the operation wins only when it has a result already, else the answer is `Err(TimedOut)` at once.
	timeout_at : Io(a, e), U64 -> Io(a, [TimedOut, ..e])
	timeout_at = |io, deadline_ms| {
		read = io.read
		sleep = [
			Keep(Root("signal")),
			Call(Root("pf"), "waitUntil", [Lit(Int(deadline_ms.to_i64_try() ?? I64.highest)), Slot(0)]),
		]
		{
			ops: [Race([io.ops, sleep])],
			waits: Bool.True,
			read: |r| timeout_read(read, r),
		}
	}

	## Start an operation, and give its promise as a ref (for `Ctx.wait_until!`). No wait.
	## The reader does not run: a Roc-level `Err` is not seen. A JS throw goes to the log (6.5).
	start! : Io(a, e) => Js.Ref
	start! = |io| match Js.call!([Start(Root("pf"), "spawn", [Lit(Js.program(io.ops))]), Keep(Slot(0))]) {
		Ok(Ref(r)) => r
		Ok(_) => crash "Io.start!: the result is not a ref"
		Err(t) => crash "Io.start!: ${t.name}: ${t.message}"
	}
}

## The result of the `Race` of `timeout`: `[0, branch]` is the operation, `[1, branch]` the sleep. The `?` widens the
## error type of `read` with `TimedOut` (a `match` that passes `Err(x)` on does not compile).
timeout_read : (Try(Js, Io.Thrown) -> Try(a, e)), Try(Js, Io.Thrown) -> Try(a, [TimedOut, ..e])
timeout_read = |read, r| {
	got = match r {
		Ok(Arr([Int(0), b])) => read(branch(b))
		Ok(Arr([Int(_), _])) => return Err(TimedOut)
		Ok(_) => crash "Io.timeout: the Race result is not [index, branch]"
		Err(t) => read(Err(t))
	}
	v = got?
	Ok(v)
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
