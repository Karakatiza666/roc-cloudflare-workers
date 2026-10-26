app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Queue

queue! : Queue.Batch => Try({}, _)
queue! = |batch| {
	for msg in batch.messages {
		if msg.attempts > 3 {
			msg.ack!()
		}
	}
	Ok({})
}

worker = Worker.new({ queue!: queue! })

event! = |e| worker.event!(e)
