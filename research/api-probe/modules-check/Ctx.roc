import Io
import Response

## The context of the task that runs.
Ctx :: [].{
	## Give the response now. The task goes on for at most 30 s (API.md 10.2).
	respond! : Response => {}
	respond! = |_res| {}

	## Run an operation after the response, with no wait here. An error goes to the log.
	wait_until! : Io(a, e) => {}
	wait_until! = |io| {
		_ = io.run!()
		{}
	}
}
