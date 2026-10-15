import Io
import Cbor

## A queue of messages of one type. The same declaration sends and reads. `Queue.json`: JS gets
## the message as an object (from CBOR) and sends it with the content type "json".
Queue(a) :: { name : Str, write : a -> List(U8), read : List(U8) -> Try(a, Str) }.{
	json : Str -> Queue(a) where [a.Cbor.Encodable([]), a.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	json = |name| Queue.{ name, write: |v| Cbor.encode(v), read: |b| Cbor.parse(b).map_err(|e| Str.inspect(e)) }

	send_with : Queue(a), a, { delay_ms ?: U64 } -> Io({}, [QueueErr(Io.Thrown)])
	send_with = |q, v, _opts| {
		Queue.{ name, write, .. } = q
		Io.new(["queue.send", name, Str.inspect(write(v))], |r| r.map_ok(|_| {}).map_err(|t| QueueErr(t)))
	}

	send : Queue(a), a -> Io({}, [QueueErr(Io.Thrown)])
	send = |q, v| q.send_with(v, {})

	send_with! : Queue(a), a, { delay_ms ?: U64 } => Try({}, [QueueErr(Io.Thrown)])
	send_with! = |q, v, opts| Io.run!(q.send_with(v, opts))

	send! : Queue(a), a => Try({}, [QueueErr(Io.Thrown)])
	send! = |q, v| Io.run!(q.send(v))

	## Read each message of a batch as `a`. `Ok` acks it. `Err`, or a body that is not an `a`, retries it.
	each! : Queue(a), Queue.Batch, (a => Try({}, e)) => { acked : U64, retried : U64 }
	each! = |q, batch, handle!| {
		Queue.{ read, .. } = q
		var $acked = 0
		var $retried = 0
		for m in batch.messages {
			ok = match read(m.body) {
				Ok(v) => handle!(v).is_ok()
				Err(_) => Bool.False
			}
			if ok {
				$acked = $acked + 1
			} else {
				$retried = $retried + 1
			}
		}
		{ acked: $acked, retried: $retried }
	}

	Batch : { queue : Str, messages : List(Queue.Message) }

	## `body`: the message as packed CBOR (API.md 5).
	Message : { id : Str, body : List(U8), attempts : U32 }
}
