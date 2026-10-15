import Io
import Response

## The context of the task that runs.
Ctx :: [].{
	## Give the response now. The return value of the handler is then ignored (API.md 10.2).
	## The fake JS side writes the response, and `run.sh` drops the returned one.
	respond! : Response => Try({}, [InvalidState])
	respond! = |res| Io.run!(Io.new(["ctx.respond", res.summary()], |r| r.map_ok(|_| {}).map_err(|_| InvalidState)))

	## Start an operation, with no wait here. A JS throw goes to the log, a Roc `Err` is not seen (D2).
	wait_until! : Io(a, e) => {}
	wait_until! = |io| {
		_ = io.run!()
		{}
	}

	## `ctx.passThroughOnException()`. Only in the `Fetch` of a Worker, else `InvalidState`.
	pass_through! : {} => Try({}, [InvalidState])
	pass_through! = |{}| Io.run!(Io.new(["ctx.pass_through"], |r| r.map_ok(|_| {}).map_err(|_| InvalidState)))
}
