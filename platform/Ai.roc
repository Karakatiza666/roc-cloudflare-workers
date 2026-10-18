## The Workers AI binding (MODULES.md 13): `env[name].run(model, input, options)`, one wait. Typed in and out (MC5): the
## input crosses as one `Packed` CBOR value (JS reads a plain object), and the result comes back as one `Packed` value
## (`pf.pack`, API.md 5.2), to `Body.default_max` bytes (MC11). A field of the result that the type does not name is
## skipped. An app that names `Cbor` adds the `roc-cbor` URL to its header (PLAN.md 8c, DC1).
import Io
import Js
import Body
import Time
import cbor.Cbor

Ai :: { name : Str }.{
	binding : Str -> Ai
	binding = |name| Ai.{ name }

	## The binding for the manifest (`Worker.new({ bindings: [...] })`, MODULES.md 3): the kind `ai`.
	declare : Ai -> { name : Str, kind : Str, props : List((Str, Str)) }
	declare = |b| { name: b.name, kind: "ai", props: [] }

	## `run(model, input)`: the output as the type of the call (MC7).
	run : Ai, Str, input -> Io(out, [AiErr(Io.Thrown), BadData(Str), TooLarge]) where [input.Cbor.Encodable([]), out.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	run = |ai, model, input| run_io(ai, model, input, { gateway: Err(NoGateway), max_bytes: Body.default_max })

	run! : Ai, Str, input => Try(out, [AiErr(Io.Thrown), BadData(Str), TooLarge]) where [input.Cbor.Encodable([]), out.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	run! = |ai, model, input| Io.run!(run(ai, model, input))

	## `gateway`: the `gateway` option of `run` (AI Gateway). `cache_ttl_ms` is `cacheTtl` in seconds, rounded up (MC10).
	## `max_bytes`: the limit of the output (default `Body.default_max`, MC11).
	run_with : Ai, Str, input, Ai.Options -> Io(out, [AiErr(Io.Thrown), BadData(Str), TooLarge]) where [input.Cbor.Encodable([]), out.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	run_with = |ai, model, input, opts| run_io(
		ai,
		model,
		input,
		{ gateway: opts.?gateway.map_err(|_| NoGateway), max_bytes: opts.?max_bytes ?? Body.default_max },
	)

	run_with! : Ai, Str, input, Ai.Options => Try(out, [AiErr(Io.Thrown), BadData(Str), TooLarge]) where [input.Cbor.Encodable([]), out.Cbor.Parseable([InvalidCbor(U64), ..errs])]
	run_with! = |ai, model, input, opts| Io.run!(run_with(ai, model, input, opts))

	Options : { gateway ?: Ai.Gateway, max_bytes ?: U64 }

	## The AI Gateway options of `run` (Cloudflare docs): `skipCache`, `cacheTtl`, `cacheKey`.
	Gateway : { id : Str, skip_cache ?: Bool, cache_ttl_ms ?: U64, cache_key ?: Str }

	## `run(model, { ..input, stream: true })`: the output stays a stream in JS (a `Body`, MC13), the server-sent events of
	## the model. The input must be a record.
	stream : Ai, Str, input -> Io(Body, [AiErr(Io.Thrown)]) where [input.Cbor.Encodable([])]
	stream = |ai, model, input| Io.new(
		[
			Get(Root("env"), ai.name),
			Record([("input", Lit(Packed(Cbor.encode(input))))]),
			Get(Slot(1), "input"),
			Set(Slot(2), "stream", Lit(Bool(Bool.True))),
			Call(Slot(0), "run", [Lit(Text(model)), Slot(2)]),
			Keep(Slot(4)),
		],
		|r| match r {
			Ok(Ref(ref)) => Ok(Stream(ref))
			Ok(other) => crash "Ai.stream: run gave ${Str.inspect(other)}"
			Err(t) => Err(AiErr(t))
		},
	)

	stream! : Ai, Str, input => Try(Body, [AiErr(Io.Thrown)]) where [input.Cbor.Encodable([])]
	stream! = |ai, model, input| Io.run!(stream(ai, model, input))
}

## Slots: 0 the binding, 1 the call (waits), 2 `pf.pack`. With options, the options are an argument of `run`.
run_io : Ai, Str, input, { gateway : Try(Ai.Gateway, [NoGateway]), max_bytes : U64 } -> Io(out, [AiErr(Io.Thrown), BadData(Str), TooLarge]) where [input.Cbor.Encodable([]), out.Cbor.Parseable([InvalidCbor(U64), ..errs])]
run_io = |ai, model, input, o| {
	args = match o.gateway {
		Ok(g) => [Lit(Text(model)), Lit(Packed(Cbor.encode(input))), Lit(Obj([("gateway", gateway_js(g))]))]
		Err(NoGateway) => [Lit(Text(model)), Lit(Packed(Cbor.encode(input)))]
	}
	Io.new(
		[
			Get(Root("env"), ai.name),
			Call(Slot(0), "run", args),
			Call(Root("pf"), "pack", [Slot(1), Lit(Int(o.max_bytes.to_i64_try() ?? I64.highest))]),
		],
		|r| match r {
			Ok(Packed(bytes)) => match Cbor.parse(bytes) {
				Ok(v) => Ok(v)
				Err(e) => Err(BadData(Str.inspect(e)))
			}
			Ok(other) => crash "Ai.run: pf.pack gave ${Str.inspect(other)}"
			Err(t) => if t.name == "TooLarge" Err(TooLarge) else Err(AiErr(t))
		},
	)
}

## The `gateway` option: `cacheTtl` is in seconds (MC10).
gateway_js : Ai.Gateway -> Js
gateway_js = |g| {
	base = [("id", Text(g.id))]
	with_skip = match g.?skip_cache {
		Ok(b) => base.append(("skipCache", Bool(b)))
		Err(_) => base
	}
	with_ttl = match g.?cache_ttl_ms {
		Ok(ms) => with_skip.append(("cacheTtl", Int(Time.seconds_up(ms).to_i64_try() ?? I64.highest)))
		Err(_) => with_skip
	}
	match g.?cache_key {
		Ok(k) => Obj(with_ttl.append(("cacheKey", Text(k))))
		Err(_) => Obj(with_ttl)
	}
}

expect gateway_js({ id: "g" }) == Obj([("id", Text("g"))])
expect gateway_js({ id: "g", skip_cache: Bool.True, cache_ttl_ms: 1500, cache_key: "k" }) == Obj([("id", Text("g")), ("skipCache", Bool(Bool.True)), ("cacheTtl", Int(2)), ("cacheKey", Text("k"))])
