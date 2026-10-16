## Queues (MODULES.md 6). Phase A has the payload types of the event `Queue` (API.md 10.1) only.
## The binding and its functions (`send!`, `each!`, `ack!`, `retry!`) come in phase B (PLAN.md 8f).
Queue(a) :: { name : Str }.{

	## A consumer batch: the queue name (not the binding name) and its messages.
	Batch := { queue : Str, messages : List(Queue.Message) }

	## One message. `body`: the message as CBOR (MC5). `attempts` starts at 1.
	Message := { id : Str, timestamp_ms : U64, attempts : U32, body : List(U8) }
}
