## `Ai` (MODULES.md 13). The binding is the JS stub `STUB_AI` of `conformance/bindings.js` (Workers AI has no local form):
## it records `run(model, input, options)`, and `/__stub_calls` gives the record. `?model=` is the model (`@test/throw` throws,
## `@test/big` gives 1.2 MB), `?prompt=` the prompt. The twin of a route is `<name>_io`.
import pf.Request
import pf.Response
import pf.Ai
import pf.Io
import pf.Body
import Q

ai = Ai.binding("STUB_AI")

Input : { prompt : Str, max_tokens : U64 }
Output : { response : Str }
WrongOutput : { response : U64 }

AiRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| {
		model = Q.text(req, "model")
		input : Input
		input = { prompt: Q.text(req, "prompt"), max_tokens: 20 }
		max = Q.num(req, "max")
		ttl = Q.num(req, "ttl")
		match path {
			["run"] => show(ai.run!(model, input))
			["run_io"] => show(Io.run!(ai.run(model, input)))
			# The gateway with all its fields, and the limit.
			["run_with"] => show(ai.run_with!(model, input, { gateway: { id: "gw", skip_cache: Bool.True, cache_ttl_ms: ttl, cache_key: "k1" }, max_bytes: max }))
			["run_with_io"] => show(Io.run!(ai.run_with(model, input, { gateway: { id: "gw", skip_cache: Bool.True, cache_ttl_ms: ttl, cache_key: "k1" }, max_bytes: max })))
			# Only the id of the gateway, and no limit: nothing else goes to JS.
			["run_with_min"] => show(ai.run_with!(model, input, { gateway: { id: "gw" } }))
			# Only the limit: no `gateway` option.
			["run_with_max"] => show(ai.run_with!(model, input, { max_bytes: max }))
			# An output that does not fit its type.
			["run_wrong"] => {
				got : Try(WrongOutput, _)
				got = ai.run!(model, input)
				ok(
					match got {
						Ok(o) => "Ok ${o.response.to_str()}"
						Err(BadData(_)) => "BadData"
						Err(e) => Str.inspect(e)
					},
				)
			}
			["stream"] => stream(ai.stream!(model, input))
			["stream_io"] => stream(Io.run!(ai.stream(model, input)))
			_ => Response.from_text(404, "no route")
		}
	}
}

ok : Str -> Response
ok = |text| Response.from_text(200, text)

show : Try(Output, [AiErr({ name : Str, message : Str }), BadData(Str), TooLarge]) -> Response
show = |r| ok(
	match r {
		Ok(o) => "Ok len=${o.response.count_utf8_bytes().to_str()} ${o.response.to_utf8().take_first(40) |> Str.from_utf8_lossy()}"
		Err(AiErr(t)) => "AiErr ${t.name}: ${t.message}"
		Err(BadData(_)) => "BadData"
		Err(TooLarge) => "TooLarge"
	},
)

## The body of the response is the stream of the model: no copy into wasm.
stream : Try(Body, [AiErr({ name : Str, message : Str })]) -> Response
stream = |r| match r {
	Ok(body) => Response.from_body(200, "text/event-stream", body)
	Err(AiErr(t)) => ok("AiErr ${t.name}: ${t.message}")
}
