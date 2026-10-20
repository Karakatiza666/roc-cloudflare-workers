## N5 option C, as an app module over the platform of today (no platform edit). In the proposal these items are in
## `platform/Rpc.roc`: `Rpc.Infra`, `Rpc.Fault(err)`, and the new types of `on`, `on_worker` and `call!`.
## Here `on` and `call!` wrap the platform ones with the wire error `Wire(err)`. The real platform writes a third
## reply head (`{"Infra": tag}`) by hand and needs no `Wire`.
import pf.Rpc
import pf.Object
import pf.Service
import pf.Io
import pf.Sql
import pf.Cbor

RpcX :: [].{

	## The infrastructure errors of the platform: one closed union. Each tag is the tag that a platform function
	## gives today, so `?` of a platform call in a handler needs no per-call code. All payloads are CBOR data.
	Infra : [
		StorageErr(Io.Thrown),
		SqlErr(Io.Thrown),
		Constraint(Sql.Constraint),
		D1Err(Io.Thrown),
		KvErr(Io.Thrown),
		R2Err(Io.Thrown),
		CacheErr(Io.Thrown),
		QueueErr(Io.Thrown),
		ObjectErr(Io.Thrown),
		ServiceErr(Io.Thrown),
		RpcErr(Io.Thrown),
		HttpErr(Io.Thrown),
		Network(Io.Thrown),
		SocketErr(Io.Thrown),
		BodyErr(Io.Thrown),
		CryptoErr(Io.Thrown),
		AiErr(Io.Thrown),
		VectorizeErr(Io.Thrown),
		WorkflowsErr(Io.Thrown),
		EmailErr(Io.Thrown),
		AnalyticsErr(Io.Thrown),
		AssetsErr(Io.Thrown),
		SecretsStoreErr(Io.Thrown),
		LimitErr(Io.Thrown),
		BadData(Str),
		InvalidJson(Str),
		MissingEnv(Str),
		TooLarge,
		TimedOut,
	]

	## The error of a handler: a domain error in `Fail`, or an infrastructure tag as the platform gives it.
	Fault(err) : [
		Fail(err),
		StorageErr(Io.Thrown),
		SqlErr(Io.Thrown),
		Constraint(Sql.Constraint),
		D1Err(Io.Thrown),
		KvErr(Io.Thrown),
		R2Err(Io.Thrown),
		CacheErr(Io.Thrown),
		QueueErr(Io.Thrown),
		ObjectErr(Io.Thrown),
		ServiceErr(Io.Thrown),
		RpcErr(Io.Thrown),
		HttpErr(Io.Thrown),
		Network(Io.Thrown),
		SocketErr(Io.Thrown),
		BodyErr(Io.Thrown),
		CryptoErr(Io.Thrown),
		AiErr(Io.Thrown),
		VectorizeErr(Io.Thrown),
		WorkflowsErr(Io.Thrown),
		EmailErr(Io.Thrown),
		AnalyticsErr(Io.Thrown),
		AssetsErr(Io.Thrown),
		SecretsStoreErr(Io.Thrown),
		LimitErr(Io.Thrown),
		BadData(Str),
		InvalidJson(Str),
		MissingEnv(Str),
		TooLarge,
		TimedOut,
	]

	## What the caller gets.
	Outcome(ret, err) : Try(ret, [RpcErr(Io.Thrown), BadData(Str), Remote(err), Infra(RpcX.Infra)])

	## The domain error, or the infrastructure error. Pure. The platform writes it once.
	split : RpcX.Fault(err) -> Try(err, RpcX.Infra)
	split = |f| match f {
		Fail(e) => Ok(e)
		StorageErr(t) => Err(StorageErr(t))
		SqlErr(t) => Err(SqlErr(t))
		Constraint(c) => Err(Constraint(c))
		D1Err(t) => Err(D1Err(t))
		KvErr(t) => Err(KvErr(t))
		R2Err(t) => Err(R2Err(t))
		CacheErr(t) => Err(CacheErr(t))
		QueueErr(t) => Err(QueueErr(t))
		ObjectErr(t) => Err(ObjectErr(t))
		ServiceErr(t) => Err(ServiceErr(t))
		RpcErr(t) => Err(RpcErr(t))
		HttpErr(t) => Err(HttpErr(t))
		Network(t) => Err(Network(t))
		SocketErr(t) => Err(SocketErr(t))
		BodyErr(t) => Err(BodyErr(t))
		CryptoErr(t) => Err(CryptoErr(t))
		AiErr(t) => Err(AiErr(t))
		VectorizeErr(t) => Err(VectorizeErr(t))
		WorkflowsErr(t) => Err(WorkflowsErr(t))
		EmailErr(t) => Err(EmailErr(t))
		AnalyticsErr(t) => Err(AnalyticsErr(t))
		AssetsErr(t) => Err(AssetsErr(t))
		SecretsStoreErr(t) => Err(SecretsStoreErr(t))
		LimitErr(t) => Err(LimitErr(t))
		BadData(s) => Err(BadData(s))
		InvalidJson(s) => Err(InvalidJson(s))
		MissingEnv(s) => Err(MissingEnv(s))
		TooLarge => Err(TooLarge)
		TimedOut => Err(TimedOut)
	}

	## The reply on the wire, as the platform would parse it: `{"Ok": value}`, `{"Err": tag}` (the domain, the same
	## bytes as today) or `{"Infra": tag}`. Nominal with a derived parser: a structural union with a payload of a
	## type variable has no derived codec in generic code (the build error of README Q4).
	Reply3(ret, err) := [Ok(ret), Err(err), Infra(RpcX.Infra)].{
		parser_for : _
	}

	## Prototype only: the parse of `Reply3` as `call!` does it, from the bytes of the reply.
	reply_of3 : List(U8) -> RpcX.Outcome(ret, err) where [ret.Cbor.Readable(e1), err.Cbor.Readable(e2)]
	reply_of3 = |bytes| {
		r : Try(RpcX.Reply3(ret, err), _)
		r = Cbor.parse(bytes)
		match r {
			Ok(Reply3.Ok(v)) => Ok(v)
			Ok(Reply3.Err(e)) => Err(Remote(e))
			Ok(Reply3.Infra(i)) => Err(Infra(i))
			Err(e) => Err(BadData(Str.inspect(e)))
		}
	}

	## Prototype only: the wire over the reply of today is `{"Err": {"Fail": e}}` or `{"Err": {"Infra": i}}`.
	Wire(err) := [Fail(err), Infra(RpcX.Infra)].{
		parser_for : _
	}

	wire : Rpc(arg, ret, err) -> Rpc(arg, ret, RpcX.Wire(err))
	wire = |m| Rpc.method(m.name())

	## The callee in a Durable Object. The heads are bytes, written by hand as `Rpc.on` does today. Only `ret`,
	## `err` and the closed `Infra` go to `Cbor.encode`, so no generic nominal type is encoded in the lambda
	## (roc-lang/roc#12482).
	on : Rpc(arg, ret, err), (self, arg => Try(ret, RpcX.Fault(err))) -> Rpc.Handler(self) where [arg.Cbor.Readable(errs), ret.Cbor.Writable, err.Cbor.Writable]
	on = |m, f!| {
		name: m.name(),
		run!: |self, bytes| match Cbor.parse(bytes) {
			Ok(a) => match f!(self, a) {
				Ok(r) => Ok(ok_head.concat(Cbor.encode(r)))
				Err(fault) => match RpcX.split(fault) {
					Ok(e) => Ok(err_head.concat(fail_head).concat(Cbor.encode(e)))
					Err(i) => Ok(err_head.concat(infra_head).concat(Cbor.encode(i)))
				}
			}
			Err(e) => Err("bad argument: ${Str.inspect(e)}")
		},
	}

	## The callee in a Worker.
	on_worker : Rpc(arg, ret, err), (arg => Try(ret, RpcX.Fault(err))) -> Rpc.Handler({}) where [arg.Cbor.Readable(errs), ret.Cbor.Writable, err.Cbor.Writable]
	on_worker = |m, f!| RpcX.on(m, |_, a| f!(a))

	from_wire : Try(ret, [RpcErr(Io.Thrown), BadData(Str), Remote(RpcX.Wire(err))]) -> RpcX.Outcome(ret, err)
	from_wire = |r| match r {
		Ok(v) => Ok(v)
		Err(RpcErr(t)) => Err(RpcErr(t))
		Err(BadData(s)) => Err(BadData(s))
		Err(Remote(Wire.Fail(e))) => Err(Remote(e))
		Err(Remote(Wire.Infra(i))) => Err(Infra(i))
	}

	## The caller, on an object.
	call! : Object, Rpc(arg, ret, err), arg => RpcX.Outcome(ret, err) where [arg.Cbor.Writable, ret.Cbor.Readable(e1), err.Cbor.Readable(e2)]
	call! = |o, m, a| RpcX.from_wire(o.call!(RpcX.wire(m), a))

	## The caller, on a service.
	call_service! : Service, Rpc(arg, ret, err), arg => RpcX.Outcome(ret, err) where [arg.Cbor.Writable, ret.Cbor.Readable(e1), err.Cbor.Readable(e2)]
	call_service! = |s, m, a| RpcX.from_wire(s.call!(RpcX.wire(m), a))
}

## The first bytes of a reply: a map of one entry and its key (as `ok_head`, `err_head` of `platform/Rpc.roc`).
ok_head : List(U8)
ok_head = [0xa1, 0x62, 0x4f, 0x6b]

err_head : List(U8)
err_head = [0xa1, 0x63, 0x45, 0x72, 0x72]

## `{"Infra": ...}`: the head of the third reply form in the proposal.
infra_head : List(U8)
infra_head = [0xa1, 0x65, 0x49, 0x6e, 0x66, 0x72, 0x61]

## `{"Fail": ...}`: prototype only (the wire over the reply of today).
fail_head : List(U8)
fail_head = [0xa1, 0x64, 0x46, 0x61, 0x69, 0x6c]

# The bytes of the hand-written heads are the bytes of the derived encoder.
expect Cbor.encode(Infra(TooLarge)) == infra_head.concat(Cbor.encode(TooLarge))
expect Cbor.encode(Fail(NotOpen)) == fail_head.concat(Cbor.encode(NotOpen))

# The three reply forms parse, and a storage error stays a typed tag.
expect {
	t = { name: "Error", message: "disk" }
	r : RpcX.Outcome(U64, [NotOpen, StillOpen])
	r = RpcX.reply_of3(infra_head.concat(Cbor.encode(StorageErr(t))))
	r == Err(Infra(StorageErr(t)))
}

expect {
	r : RpcX.Outcome(U64, [NotOpen, StillOpen])
	r = RpcX.reply_of3(err_head.concat(Cbor.encode(StillOpen)))
	r == Err(Remote(StillOpen))
}

expect {
	r : RpcX.Outcome(U64, [NotOpen, StillOpen])
	r = RpcX.reply_of3(ok_head.concat(Cbor.encode(7.U64)))
	r == Ok(7)
}
