## Time (MODULES.md 11): the clock, and a sleep that is a wait. A timeout is a race with a sleep (API.md 6.5).
import Io
import Js

Time :: [].{

	## `Date.now()`: one `call!`, no wait. On the edge it is coarse: it moves only at I/O.
	now_ms! : () => U64
	now_ms! = || match Js.call!([Get(Root("global"), "Date"), Call(Slot(0), "now", [])]) {
		Ok(Int(i)) => i.to_u64_try() ?? crash "Time.now_ms!: Date.now() is negative"
		Ok(Num(f)) => f.to_u64_try() ?? crash "Time.now_ms!: Date.now() is not a time"
		Ok(other) => crash "Time.now_ms!: Date.now() gave ${Str.inspect(other)}"
		Err(t) => crash "Time.now_ms!: ${t.name}: ${t.message}"
	}

	## `scheduler.wait(ms)`: one wait. The timer stops when the signal of the task aborts (the end of the task, or a
	## lost branch of `Io.race!`, OP8). The error type is open, so the twin joins the errors of the other branches.
	sleep : U64 -> Io({}, e)
	sleep = |ms| Io.new(
		[
			Get(Root("global"), "scheduler"),
			Keep(Root("signal")),
			Record([("signal", Slot(1))]),
			Call(Slot(0), "wait", [Lit(Int(ms.to_i64_try() ?? I64.highest)), Slot(2)]),
		],
		|_| Ok({}),
	)

	sleep! : U64 => {}
	sleep! = |ms| {
		_ = Io.run!(sleep(ms))
		{}
	}

	## Milliseconds to whole seconds, rounded up (MC10), for a Workers option in seconds: 1 ms gives 1 s, so a
	## duration never becomes shorter (KV `expirationTtl`, Queues `delaySeconds`, a `max-age`).
	seconds_up : U64 -> U64
	seconds_up = |ms| ms // 1000 + (if (ms % 1000 > 0) 1 else 0)
}

# MC10: the module converts, and it rounds up.
expect Time.seconds_up(1) == 1
expect Time.seconds_up(1_000) == 1
expect Time.seconds_up(1_001) == 2
expect Time.seconds_up(0) == 0
expect Time.seconds_up(U64.highest) == 18_446_744_073_709_552
