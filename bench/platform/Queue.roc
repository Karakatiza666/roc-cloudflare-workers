## Queues (MODULES.md 6): the producer binding, and the consumer functions of the event `Queue` (API.md 10.1).
## One constant gives the type and the format (MC6), so the producer and the consumer agree. A message crosses as
## CBOR (MC5): JS gets a plain object (the same as from `JSON.parse`), and sends it with the content type of the
## declaration. `Queue.v8` also keeps a `BigInt` and a `Cbor.Bytes` field (a `Uint8Array` in JS).
import Io
import Js
import Log
import Time
import cbor.Cbor

Queue(a) :: { name : Str, content_type : Str, write : a -> Js, read : List(U8) -> Try(a, Str) }.{

	## The content type "json": a JS consumer gets the message as an object. No `BigInt` (use `Queue.v8`).
	json : Str -> Queue(a) where [a.Cbor.Encodable([]), a.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	json = |name| Queue.{
		name,
		content_type: "json",
		write: |v| Packed(Cbor.encode(v)),
		read: |body| Cbor.parse(body).map_err(|e| Str.inspect(e)),
	}

	## The content type "v8" (the structured clone of Workers): also a `BigInt`, and a `Cbor.Bytes` field reaches a
	## JS consumer as a `Uint8Array`.
	v8 : Str -> Queue(a) where [a.Cbor.Encodable([]), a.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	v8 = |name| Queue.{
		name,
		content_type: "v8",
		write: |v| Packed(Cbor.encode(v)),
		read: |body| Cbor.parse(body).map_err(|e| Str.inspect(e)),
	}

	## The content type "text".
	text : Str -> Queue(Str)
	text = |name| Queue.{
		name,
		content_type: "text",
		write: |s| Text(s),
		read: |body| Cbor.parse(body).map_err(|e| Str.inspect(e)),
	}

	## The content type "bytes": the message is an `ArrayBuffer` in JS.
	bytes : Str -> Queue(List(U8))
	bytes = |name| Queue.{
		name,
		content_type: "bytes",
		write: |b| Bytes(b),
		read: |b| Cbor.parse(b).map_err(|e| Str.inspect(e)),
	}

	## `send`: 128 KB or less for a message. One wait.
	send : Queue(a), a -> Io({}, [QueueErr(Io.Thrown)])
	send = |q, v| q.send_with(v, {})

	send! : Queue(a), a => Try({}, [QueueErr(Io.Thrown)])
	send! = |q, v| Io.run!(q.send(v))

	## `delay_ms` goes to `delaySeconds` (MC10): whole seconds, rounded up. More than 24 h is `QueueErr` (Workers throws).
	send_with : Queue(a), a, { delay_ms ?: U64 } -> Io({}, [QueueErr(Io.Thrown)])
	send_with = |q, v, opts| {
		write = q.write
		Io.new(
			[
				Get(Root("env"), q.name),
				Call(Slot(0), "send", [Lit(write(v)), Lit(Obj(options(q.content_type, opts.?delay_ms)))]),
			],
			done,
		)
	}

	send_with! : Queue(a), a, { delay_ms ?: U64 } => Try({}, [QueueErr(Io.Thrown)])
	send_with! = |q, v, opts| Io.run!(q.send_with(v, opts))

	## `sendBatch`: 100 messages and 256 KB or less (Workers throws for more: `QueueErr`).
	send_batch : Queue(a), List(a) -> Io({}, [QueueErr(Io.Thrown)])
	send_batch = |q, vs| q.send_batch_with(vs, {})

	send_batch! : Queue(a), List(a) => Try({}, [QueueErr(Io.Thrown)])
	send_batch! = |q, vs| Io.run!(q.send_batch(vs))

	send_batch_with : Queue(a), List(a), { delay_ms ?: U64 } -> Io({}, [QueueErr(Io.Thrown)])
	send_batch_with = |q, vs, opts| {
		write = q.write
		items = vs.map(|v| Obj([("body", write(v)), ("contentType", Text(q.content_type))]))
		batch_options = match opts.?delay_ms {
			Ok(ms) => [("delaySeconds", Int(Time.seconds_up(ms).to_i64_try() ?? I64.highest))]
			Err(_) => []
		}
		Io.new(
			[
				Get(Root("env"), q.name),
				Call(Slot(0), "sendBatch", [Lit(Arr(items)), Lit(Obj(batch_options))]),
			],
			done,
		)
	}

	send_batch_with! : Queue(a), List(a), { delay_ms ?: U64 } => Try({}, [QueueErr(Io.Thrown)])
	send_batch_with! = |q, vs, opts| Io.run!(q.send_batch_with(vs, opts))

	## Read each message of the batch as `a`, and give the handler the message too (`id`, `timestamp_ms`, `attempts`,
	## which starts at 1). `Ok` acks the message. `Err(e)` retries it and logs `Str.inspect(e)`. A body that is not an
	## `a` is logged and retried too, so after `max_retries` it goes to the dead letter queue, if the queue has one.
	each! : Queue(a), Queue.Batch, (Queue.Message, a => Try({}, e)) => { acked : U64, retried : U64 }
	each! = |q, batch, handle!| {
		read = q.read
		var $acked = 0
		var $retried = 0
		for m in batch.messages {
			failure = match read(m.body) {
				Ok(v) => match handle!(m, v) {
					Ok(_) => Ok({})
					Err(e) => Err(Str.inspect(e))
				}
				Err(why) => Err("the body is not the type of the queue: ${why}")
			}
			match failure {
				Ok(_) => {
					m.ack!()
					$acked = $acked + 1
				}
				Err(why) => {
					Log.warn!("queue message failed", { queue: batch.queue, id: m.id, attempts: m.attempts, error: why })
					m.retry!()
					$retried = $retried + 1
				}
			}
		}
		{ acked: $acked, retried: $retried }
	}

	## A consumer batch: the queue name (not the binding name) and its messages. A batch has the limit of the Queues
	## config (MC11), so it crosses with no `max_bytes`.
	Batch := { queue : Str, messages : List(Queue.Message) }.{

		## `batch.ackAll()`: no wait.
		ack_all! : Queue.Batch => {}
		ack_all! = |_b| drop!([Call(Root("event"), "ackAll", [])])

		retry_all! : Queue.Batch => {}
		retry_all! = |_b| drop!([Call(Root("event"), "retryAll", [])])

		## `delay_ms`: whole seconds, rounded up, at most 86,400 (a retry has no `Try`, so it cannot be an error).
		retry_all_with! : Queue.Batch, { delay_ms : U64 } => {}
		retry_all_with! = |_b, { delay_ms }| drop!([Call(Root("event"), "retryAll", [Lit(Obj(retry_options(delay_ms)))])])
	}

	## One message. `body`: the message as CBOR (MC5). `attempts` starts at 1. A function finds its message in the batch
	## of the task by `id` (`pf.findById`), so a message holds no ref.
	Message := { id : Str, timestamp_ms : U64, attempts : U32, body : List(U8) }.{

		## `message.ack()`: no wait.
		ack! : Queue.Message => {}
		ack! = |m| drop!(of_message(m, "ack", []))

		retry! : Queue.Message => {}
		retry! = |m| drop!(of_message(m, "retry", []))

		retry_with! : Queue.Message, { delay_ms : U64 } => {}
		retry_with! = |m, { delay_ms }| drop!(of_message(m, "retry", [Lit(Obj(retry_options(delay_ms)))]))
	}
}

## `{ contentType, delaySeconds }` of `send`.
options : Str, Try(U64, [MissingField]) -> List((Str, Js))
options = |content_type, delay_ms| match delay_ms {
	Ok(ms) => [("contentType", Text(content_type)), ("delaySeconds", Int(Time.seconds_up(ms).to_i64_try() ?? I64.highest))]
	Err(_) => [("contentType", Text(content_type))]
}

## `{ delaySeconds }` of a retry: 86,400 s at most (MODULES.md 6, Delays).
retry_options : U64 -> List((Str, Js))
retry_options = |ms| {
	s = Time.seconds_up(ms)
	[("delaySeconds", Int((if s > 86_400 86_400 else s).to_i64_try() ?? 86_400))]
}

## The message of the batch of the task, then the call: `pf.findById(event.messages, id)`.
of_message : Queue.Message, Str, List(Js.Arg) -> List(Js.Op)
of_message = |m, method, args| [
	Get(Root("event"), "messages"),
	Call(Root("pf"), "findById", [Slot(0), Lit(Text(m.id))]),
	Call(Slot(1), method, args),
]

## A call with no result and no wait. A throw is dropped: `ack` and `retry` have no `Try` (MODULES.md 6).
drop! : List(Js.Op) => {}
drop! = |ops| {
	_ = Io.call!(ops)
	{}
}

done : Try(Js, Io.Thrown) -> Try({}, [QueueErr(Io.Thrown)])
done = |r| match r {
	Ok(_) => Ok({})
	Err(t) => Err(QueueErr(t))
}

expect retry_options(0) == [("delaySeconds", Int(0))]
expect retry_options(1_001) == [("delaySeconds", Int(2))]
expect retry_options(1_000 * 90_000) == [("delaySeconds", Int(86_400))]
expect options("json", Err(MissingField)) == [("contentType", Text("json"))]
expect options("text", Ok(2_500)) == [("contentType", Text("text")), ("delaySeconds", Int(3))]
