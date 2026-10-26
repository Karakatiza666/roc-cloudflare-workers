app [event!] { pf: platform "../../platform/main.roc" }

## X5 probe A: `scheduled!` calls `s.no_retry!()` with no annotation. Worker.new gives the type.
import pf.Worker

scheduled! = |s| {
	s.no_retry!()
	Ok({})
}

worker = Worker.new({ scheduled!: scheduled! })

event! = |e| worker.event!(e)
