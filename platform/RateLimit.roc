## The Rate Limiting binding (MODULES.md 10): `env[name].limit({ key })`, one wait. A binding holds its name (MC1).
import Io
import Js

RateLimit :: { name : Str }.{
	binding : Str -> RateLimit
	binding = |name| RateLimit.{ name }

	## `Ok({})` when the key is under the limit, else `RateLimited`, so `limiter.limit!(ip)?` stops the handler.
	limit : RateLimit, Str -> Io({}, [RateLimited, LimitErr(Io.Thrown)])
	limit = |rl, key| Io.new(
		[
			Get(Root("env"), rl.name),
			Call(Slot(0), "limit", [Lit(Obj([("key", Text(key))]))]),
			Get(Slot(1), "success"),
		],
		|r| match r {
			Ok(Bool(b)) => if b Ok({}) else Err(RateLimited)
			Ok(other) => Err(LimitErr({ name: "BadData", message: "limit gave success ${Str.inspect(other)}" }))
			Err(t) => Err(LimitErr(t))
		},
	)

	limit! : RateLimit, Str => Try({}, [RateLimited, LimitErr(Io.Thrown)])
	limit! = |rl, key| Io.run!(limit(rl, key))
}
