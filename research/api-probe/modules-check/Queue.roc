import Io
import Cbor

## A queue of messages of one type. The same declaration sends and reads. `Queue.json`: JS gets
## the message as an object (from CBOR) and sends it with the content type "json".
Queue(a) :: { name : Str, write : a -> List(U8), read : List(U8) -> Try(a, Str) }.{
	json : Str -> Queue(a) where [a.Cbor.Encodable([]), a.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	json = |name| Queue.{ name, write: |v| Cbor.encode(v), read: |b| Cbor.parse(b).map_err(|e| Str.inspect(e)) }

	send_with : Queue(a), a, { delay_ms ?: U64 } -> Io({}, [QueueErr(Io.Thrown)])
	send_with = |q, v, opts| {
		Queue.{ name, write, .. } = q
		Io.new(["queue.send", name, Str.inspect(write(v)), delay(opts)], |r| r.map_ok(|_| {}).map_err(|t| QueueErr(t)))
	}

	send : Queue(a), a -> Io({}, [QueueErr(Io.Thrown)])
	send = |q, v| q.send_with(v, {})

	send_with! : Queue(a), a, { delay_ms ?: U64 } => Try({}, [QueueErr(Io.Thrown)])
	send_with! = |q, v, opts| Io.run!(q.send_with(v, opts))

	send! : Queue(a), a => Try({}, [QueueErr(Io.Thrown)])
	send! = |q, v| Io.run!(q.send(v))

	## `sendBatch`: 100 messages and 256 KB or less.
	send_batch_with : Queue(a), List(a), { delay_ms ?: U64 } -> Io({}, [QueueErr(Io.Thrown)])
	send_batch_with = |q, vs, opts| {
		Queue.{ name, write, .. } = q
		Io.new(["queue.send_batch", name, Str.inspect(vs.map(write)), delay(opts)], |r| r.map_ok(|_| {}).map_err(|t| QueueErr(t)))
	}

	send_batch! : Queue(a), List(a) => Try({}, [QueueErr(Io.Thrown)])
	send_batch! = |q, vs| Io.run!(q.send_batch_with(vs, {}))

	send_batch_with! : Queue(a), List(a), { delay_ms ?: U64 } => Try({}, [QueueErr(Io.Thrown)])
	send_batch_with! = |q, vs, opts| Io.run!(q.send_batch_with(vs, opts))

	## Read each message of a batch as `a`, and give the handler the message too. `Ok` acks it.
	## `Err`, or a body that is not an `a`, retries it.
	each! : Queue(a), Queue.Batch, (Queue.Message, a => Try({}, e)) => { acked : U64, retried : U64 }
	each! = |q, batch, handle!| {
		Queue.{ read, .. } = q
		var $acked = 0
		var $retried = 0
		for m in batch.messages {
			ok = match read(m.body) {
				Ok(v) => handle!(m, v).is_ok()
				Err(_) => Bool.False
			}
			if ok {
				m.ack!()
				$acked = $acked + 1
			} else {
				m.retry!()
				$retried = $retried + 1
			}
		}
		{ acked: $acked, retried: $retried }
	}

	Batch := { queue : Str, messages : List(Queue.Message) }.{
		ack_all! : Queue.Batch => {}
		ack_all! = |b| sync!(["queue.ack_all", b.queue])

		retry_all! : Queue.Batch => {}
		retry_all! = |b| b.retry_all_with!({})

		retry_all_with! : Queue.Batch, { delay_ms ?: U64 } => {}
		retry_all_with! = |b, opts| sync!(["queue.retry_all", b.queue, delay(opts)])
	}

	## `body`: the message as packed CBOR (API.md 5). `attempts` starts at 1.
	Message := { id : Str, timestamp_ms : U64, attempts : U32, body : List(U8) }.{
		ack! : Queue.Message => {}
		ack! = |m| sync!(["queue.ack", m.id])

		retry! : Queue.Message => {}
		retry! = |m| m.retry_with!({})

		retry_with! : Queue.Message, { delay_ms ?: U64 } => {}
		retry_with! = |m, opts| sync!(["queue.retry", m.id, delay(opts)])
	}
}

## `delaySeconds`: whole seconds, rounded up, 86,400 at most (MC10, MODULES.md 6).
delay : { delay_ms ?: U64 } -> Str
delay = |opts| match opts.?delay_ms {
	Ok(ms) => {
		s = (ms + 999) // 1000
		"${(if s > 86_400 86_400 else s).to_str()}s"
	}
	Err(_) => "0s"
}

## A sync call with no result (`ack`, `retry`): one `call!`.
sync! : List(Str) => {}
sync! = |ops| {
	_ = Io.run!(Io.new(ops, |r| r))
	{}
}
