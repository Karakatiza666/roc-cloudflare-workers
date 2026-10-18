## The context of a task (MODULES.md 11, API.md 10.2): work after the task, and the origin on an error. To respond now
## and work after, a `fetch!` handler gives `res.after(work!)` (`Response.after`). Each function is one `call!` with no
## wait. The JS side is in `js/helpers.js` (the root `pf`).
import Io
import Js

Ctx :: [].{

	## Start the operation now (`Io.start!`) and give its promise to `ctx.waitUntil`, in one `call!`. The reader of
	## the `Io` does not run, so its result is dropped: only an `Io({}, e)` fits, and an operation with a result (for
	## example `cache.put`, which gives the response to send) is a type error. A Roc-level `Err` is not seen. A JS throw
	## goes to the log. The context of the task stays until the operation settles, or until the 30 s limit of
	## `waitUntil` (API.md 6.5, RS1).
	wait_until! : Io({}, e) => {}
	wait_until! = |io| match Js.call!([Start(Root("pf"), "spawn", [Lit(Js.program(io.ops))]), Call(Root("ctx"), "waitUntil", [Slot(0)])]) {
		Ok(_) => {}
		Err(t) => crash "Ctx.wait_until!: ${t.name}: ${t.message}"
	}

	## `ctx.passThroughOnException()`: after it, an `Err` of the `fetch` handler makes the shim throw, so Workers
	## sends the request to the origin. Only in the `Fetch` of a Worker. Elsewhere `InvalidState`.
	pass_through! : () => Try({}, [InvalidState])
	pass_through! = || match Js.call!([Call(Root("pf"), "passThrough", [])]) {
		Ok(_) => Ok({})
		Err(t) if t.name == "InvalidStateError" => Err(InvalidState)
		Err(t) => crash "Ctx.pass_through!: ${t.name}: ${t.message}"
	}
}
