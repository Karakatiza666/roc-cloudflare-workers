## The context of a task (MODULES.md 11, API.md 10.2): respond now and work after, work after the task, and the
## origin on an error. Each function is one `call!` with no wait. The JS side is in `js/helpers.js` (the root `pf`).
import Io
import Js
import Response
import Entry

Ctx :: [].{

	## Give the response to Workers now. The task goes on, and the return value of `event!` is then ignored.
	## Only in the `Fetch` of a Worker (phase B: also `EntrypointFetch` and the `Fetch` of an object). Elsewhere,
	## and on a second call, `InvalidState`. Read the request body before: workerd ends it with the response.
	respond! : Response => Try({}, [InvalidState])
	respond! = |res| match Io.call!([Call(Root("pf"), "respond", [Lit(Entry.outcome(Respond(res)))])]) {
		Ok(_) => Ok({})
		Err(t) if t.name == "InvalidStateError" => Err(InvalidState)
		# A response that Workers refuses (a bad status or header): the same as from `event!`, a bug of the app.
		Err(t) => crash "Ctx.respond!: ${t.name}: ${t.message}"
	}

	## Start the operation now (`Io.start!`) and give its promise to `ctx.waitUntil`, in one `call!`. The reader of
	## the `Io` does not run, so a Roc-level `Err` is not seen. A JS throw goes to the log. The context of the task
	## stays until the operation settles, or until the 30 s limit of `waitUntil` (API.md 6.5, RS1).
	wait_until! : Io(a, e) => {}
	wait_until! = |io| match Io.call!([Start(Root("pf"), "spawn", [Lit(Js.program(io.ops))]), Call(Root("ctx"), "waitUntil", [Slot(0)])]) {
		Ok(_) => {}
		Err(t) => crash "Ctx.wait_until!: ${t.name}: ${t.message}"
	}

	## `ctx.passThroughOnException()`: after it, an `Err` of the `fetch` handler makes the shim throw, so Workers
	## sends the request to the origin. Only in the `Fetch` of a Worker. Elsewhere `InvalidState`.
	pass_through! : {} => Try({}, [InvalidState])
	pass_through! = |_| match Io.call!([Call(Root("pf"), "passThrough", [])]) {
		Ok(_) => Ok({})
		Err(t) if t.name == "InvalidStateError" => Err(InvalidState)
		Err(t) => crash "Ctx.pass_through!: ${t.name}: ${t.message}"
	}
}
