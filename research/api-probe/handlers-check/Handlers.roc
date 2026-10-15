## Can a record with optional effectful fields build `event!` (API.md AQ6)?
Handlers := {
	fetch! ?: Str => Str,
	scheduled! ?: Str => Str,
}.{
	## The one entry, made from the handlers that the app gives.
	event! : Handlers, [Fetch(Str), Scheduled(Str)] => Str
	event! = |h, e| match e {
		Fetch(req) => match h.?fetch! {
			Ok(f!) => f!(req)
			Err(MissingField) => "unhandled"
		}
		Scheduled(cron) => match h.?scheduled! {
			Ok(f!) => f!(cron)
			Err(MissingField) => "unhandled"
		}
	}
}

only_fetch : Handlers
only_fetch = Handlers.{ fetch!: |req| "fetched ${req}" }

expect only_fetch.?scheduled!.is_err()
