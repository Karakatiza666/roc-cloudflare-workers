app [event!] { pf: platform "../../platform/main.roc" }

## X5 probe B: queue handler calls `batch.retry_all_with!(...)` with no annotation (the case of MODULES.md 15).
import pf.Worker

queue! = |batch| {
	batch.retry_all_with!({ delay_ms: 5000 })
	Ok({})
}

worker = Worker.new({ queue!: queue! })

event! = |e| worker.event!(e)
