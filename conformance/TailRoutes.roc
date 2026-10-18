## The Tail Worker side (MODULES.md 3, PLAN.md 8f): `handle!` is the `tail!` of the app. It writes one log line for each trace
## item. The producer is a plain JS worker in `checks/tail.mjs` (a fetch that logs and throws, a cron, a fetch with 2 MiB of logs),
## and a second Miniflare instance runs both workers (the tail worker is this app).
import pf.Worker
import pf.Log

TailRoutes :: [].{

	## The `tail!` of the app.
	handle! : List(Worker.TraceItem) => Try({}, [Boom])
	handle! = |items| {
		for item in items {
			request = match item.event() {
				Ok(e) => {
					status = match e.response {
						Ok(r) => r.status.to_str()
						Err(Missing) => "none"
					}
					colo = match e.request.cf {
						Ok(cf) => match cf.colo {
							Ok(c) => c
							Err(Missing) => "none"
						}
						Err(Missing) => "none"
					}
					"${Str.inspect(e.request.method)} ${e.request.url} ${status} headers=${e.request.headers.len().to_str()} colo=${colo}"
				}
				Err(Missing) => "no event"
			}
			script = match item.script_name() {
				Ok(s) => s
				Err(Missing) => "none"
			}
			timestamp = match item.event_timestamp_ms() {
				Ok(t) => if t > 0 "set" else "zero"
				Err(Missing) => "none"
			}
			messages = item.logs().map(|l| l.message)
			bytes = messages.map(|m| m.count_utf8_bytes()).sum()
			first = match item.logs().first() {
				Ok(l) => "${l.level} ${l.message}"
				Err(_) => "none"
			}
			exceptions = item.exceptions().map(|x| "${x.name}: ${x.message}")
			Log.info!(
				"trace",
				{
					script,
					outcome: item.outcome(),
					request,
					timestamp,
					logs: item.logs().len(),
					log_bytes: bytes,
					first,
					exceptions,
				},
			)
		}
		Ok({})
	}
}
