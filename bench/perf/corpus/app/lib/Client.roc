## The caller of the registry: the client version (Registry R-AP45, R-AP48 row 3) and the rate limit key of user hints (R-CT11). Pure; slice 116b.
## The effects (the settings, the binding `RL_HINTS`, the answer) are in `worker/main.roc` and `worker/HintRoutes.roc`.
## The tests are `worker/tests/unit/ClientTest.roc` (W0) and `worker/tests/cases/hints/` (W2). The slice file is `docs/slices/116b-hint-limits.md`.
## The setting names `MIN_TLN` and `MIN_TLN_WRITE`, the binding name `RL_HINTS` and the `detail` texts are proposals (TW24, R-AP45, R-WH14).
import semver.Semver
import Problem
import Route

Client :: [].{

	## R-AP45: the requests that `MIN_TLN_WRITE` covers: the write routes of R-AP41. `PostCompat`, `PostRelease`, `PostTokens`, `DeleteTokens`, `DeleteMe` and `PutToolchain` (the bot calls the last one, and the bot has no `tln` agent, so it is never refused).
	## Every other route is a read.
	is_write : Route.Id -> Bool
	is_write = |id| match id {
		PostCompat | PostRelease | PutToolchain(_) | PostTokens | DeleteTokens | DeleteMe => Bool.True
		_ => Bool.False
	}

	## R-AP45, R-AP48 row 3: the check of the `User-Agent`. The first product is read: the text up to the first space (Design Q184; `tln/0.4.1 (linux)` is `tln/0.4.1`). Only a first product `tln/<v>` (lower case `tln`)
	## is checked; a header that starts with another product (`curl/8`, `curl/8 tln/0.4.1`, `TLN/0.4.1`, a browser, the compat bot), a missing header, a `tln/` with no version, or a `<v>` that is not a semver
	## (`tln/dev`, `Semver.parse` fails, Design Q183) is not. `min` is the setting `MIN_TLN` (all routes) and `min_write` the setting `MIN_TLN_WRITE` (write routes only, `write` is True). A setting that is an empty text,
	## or a setting that does not exist (the caller passes ""), is not checked. A setting that is not a semver is not checked either (Design Q183). `v` lower than the setting by semver precedence
	## (`Semver.order_relative_to`, numbers, not text: `tln/0.10.0` is above `0.5.0`): `Err({ problem, minimum })`; `problem` is `UnsupportedClient` (400), `minimum` the text of the setting that
	## refused. When both settings refuse a write request, `minimum` is the larger one. `tln/0.5.0` against `0.5.0` is accepted (equal).
	## `detail` (proposal): `tln <v> is older than the minimum version <minimum> that this registry accepts: update tln`.
	check : { user_agent : Try(Str, [NotFound]), write : Bool, min : Str, min_write : Str } -> Try({}, { problem : Problem, minimum : Str })
	check = |x| {
		agent = match x.user_agent {
			Ok(text) => text
			Err(NotFound) => return Ok({})
		}
		first = agent.split_on(" ").first() ?? ""
		if !first.starts_with("tln/") {
			return Ok({})
		}
		text = first.drop_prefix("tln/")
		version = match Semver.parse(text) {
			Ok(v) => v
			Err(_) => return Ok({})
		}
		settings = if (x.write) [x.min, x.min_write] else [x.min]
		refusals = settings.keep_oks(|setting| refuses(version, setting))
		match refusals.fold(Err(NoRefusal), larger) {
			Ok(r) => Err({ problem: Problem.new(UnsupportedClient, "tln ${text} is older than the minimum version ${r.minimum} that this registry accepts: update tln"), minimum: r.minimum })
			Err(NoRefusal) => Ok({})
		}
	}

	## One setting that refuses `version`: `Ok` with the text and the parsed value. An empty or bad setting, or a setting that is not above `version`, is `Err`.
	refuses : Semver, Str -> Try({ minimum : Str, semver : Semver }, [NoRefusal])
	refuses = |version, setting| match Semver.parse(setting) {
		Err(_) => Err(NoRefusal)
		Ok(semver) => match version.order_relative_to(semver) {
			Before => Ok({ minimum: setting, semver })
			_ => Err(NoRefusal)
		}
	}

	## Keep the larger minimum of two refusals.
	larger : Try({ minimum : Str, semver : Semver }, [NoRefusal]), { minimum : Str, semver : Semver } -> Try({ minimum : Str, semver : Semver }, [NoRefusal])
	larger = |best, r| match best {
		Err(NoRefusal) => Ok(r)
		Ok(b) => match r.semver.order_relative_to(b.semver) {
			After => Ok(r)
			_ => Ok(b)
		}
	}

	## R-AP45, R-AP21: the body of the 400 `unsupported-client`: the members of `Problem.to_json` and the member `minimum` (a text).
	refusal_json : { problem : Problem, minimum : Str } -> Str
	refusal_json = |x| {
		base = x.problem.to_json()
		parsed : Try(Wire, _)
		parsed = Json.parse(base)
		match parsed {
			Ok(w) => Json.to_str({ type: w.type, title: w.title, status: w.status, detail: w.detail, minimum: x.minimum })
			Err(_) => base
		}
	}

	## The members of `Problem.to_json`.
	Wire : { type : Str, title : Str, status : U16, detail : Str }

	## R-CT11, R-AP68 row 3 (Design Q168, Q185): the key of the rate limit of one request, from the header `cf-connecting-ip` (the text of the address). It is the one key function of the hint path (slice 116b) and of
	## the ingest path (slice 112b): `HintRoutes` and the ingest route both call it. An IPv4 address: the text as is. An IPv6 address: the /64 prefix as the first 4 groups of 16 bits, each in lower case hex with no
	## leading zero, joined with `:`, then `::/64` (`2001:DB8::1` is `2001:db8:0:0::/64`; `::` is read; two addresses in one /64 have one key). An IPv4-mapped address (`::ffff:1.2.3.4`) is the IPv4 address
	## (`1.2.3.4`), else all mapped clients would share one key. A missing or unreadable address: the key `unknown`.
	rate_key : Try(Str, [NotFound]) -> Str
	rate_key = |ip| match ip {
		Ok(text) => address_key(text) ?? "unknown"
		Err(NotFound) => "unknown"
	}

	## The key of one address text, or `Err` when the text is no address.
	address_key : Str -> Try(Str, [BadAddress])
	address_key = |text| {
		if text.contains(":") {
			lower = text.with_ascii_lowercased()
			mapped = lower.drop_prefix("::ffff:")
			if lower.starts_with("::ffff:") and ipv4(mapped) {
				Ok(mapped)
			} else {
				prefix64(lower)
			}
		} else if ipv4(text) {
			Ok(text)
		} else {
			Err(BadAddress)
		}
	}

	## Four parts, each 1 to 3 decimal digits, at most 255.
	ipv4 : Str -> Bool
	ipv4 = |text| {
		parts = text.split_on(".")
		parts.len() == 4 and parts.all(octet)
	}

	octet : Str -> Bool
	octet = |part| {
		bytes = part.to_utf8()
		bytes.len() >= 1 and bytes.len() <= 3 and bytes.all(|b| b >= 48 and b <= 57) and (U64.from_str(part) ?? 256) <= 255
	}

	## An IPv6 address in lower case: the first 4 groups of 16 bits as `a:b:c:d::/64`.
	prefix64 : Str -> Try(Str, [BadAddress])
	prefix64 = |lower| {
		groups = expand(lower)?
		first4 = groups.take_first(4)
		Ok("${Str.join_with(first4, ":")}::/64")
	}

	## The 8 groups of an IPv6 text, each with no leading zero. `::` stands for the missing zero groups (at least one).
	expand : Str -> Try(List(Str), [BadAddress])
	expand = |lower| match lower.split_on("::") {
		[whole] => {
			groups = side(whole)?
			if (groups.len() == 8) Ok(groups) else Err(BadAddress)
		}
		[head, tail] => {
			a = side(head)?
			b = side(tail)?
			missing = 8 - a.len() - b.len()
			if (a.len() + b.len() <= 7) Ok(a.concat(List.repeat("0", missing)).concat(b)) else Err(BadAddress)
		}
		_ => Err(BadAddress)
	}

	## The groups of one side of the address: an empty text has none.
	side : Str -> Try(List(Str), [BadAddress])
	side = |text| {
		if text == "" {
			Ok([])
		} else {
			parts = text.split_on(":")
			if (parts.all(group)) Ok(parts.map(strip_zeros)) else Err(BadAddress)
		}
	}

	## 1 to 4 hex digits (lower case).
	group : Str -> Bool
	group = |part| {
		bytes = part.to_utf8()
		bytes.len() >= 1 and bytes.len() <= 4 and bytes.all(|b| (b >= 48 and b <= 57) or (b >= 97 and b <= 102))
	}

	strip_zeros : Str -> Str
	strip_zeros = |part| {
		if (part.starts_with("0") and part.count_utf8_bytes() > 1) strip_zeros(part.drop_prefix("0")) else part
	}

	## R-CT11, R-AP25: the problem of the 429 for the limit of the binding. Kind `RateLimited`. `detail` (proposal): `too many user hint requests from this address: try again in a minute`.
	## The `Retry-After` value is `limit_retry_after` seconds (R-AP70 row 9, Design Q168, Q185: the period of the binding).
	rate_problem : () -> Problem
	rate_problem = || Problem.new(RateLimited, "too many user hint requests from this address: try again in a minute")

	## The `Retry-After` of the rate limit answer, in seconds: the period of the binding, 60 (R-CT11: "30 requests a minute").
	limit_retry_after : U64
	limit_retry_after = 60
}
