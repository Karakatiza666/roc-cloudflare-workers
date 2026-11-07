## The pure part of the ingest limits and the cache drop (Registry R-AP68 rows 3, 5, 12, its items "Rate key", "What the IP limit counts", "Owner count",
## "429 texts"; R-AP69; R-PU34 rows 1, 2; R-AP25; Design Q166 to Q168; slice 112b). No effect, no platform import.
## The effects are in `worker/IngestRoutes.roc` (slice 112b adds them to the flow of slice 112a, `docs/slices/112b-ingest-limits.md` section 3).
## The tests are in `worker/tests/unit/IngestLimitsTest.roc` (W0) and `worker/tests/cases/ingest-limits/` (W2).
import Problem

IngestLimits :: [].{

	## R-WH14, R-PU34 row 1: the rate limit binding (60 a minute for each key, `wrangler.toml` `[[ratelimits]]`).
	ip_binding : Str
	ip_binding = "RL_INGEST"

	## R-AP68 row 3: the `Retry-After` of the IP limit is the period of the binding, in seconds.
	ip_retry_after : U64
	ip_retry_after = 60

	## R-PU34 row 2: at most this many new names of one owner a day from ingests.
	owner_limit : U64
	owner_limit = 20

	## The rate key of the IP limit is `Client.rate_key` (worker/lib/Client.roc, slice 116b, Design Q185): one function for the ingest and the user hints.

	## R-AP68 "429 texts" (a proposal of the design).
	ip_limited : Problem
	ip_limited = Problem.new(RateLimited, "too many ingests from this address: at most 60 a minute")

	owner_limited : Str -> Problem
	owner_limited = |owner| Problem.new(RateLimited, "too many new repositories of the owner ${owner} today: at most 20 a day from ingests")

	## R-AP68 "Owner count": the owner is the text before the first `/` of the lower-case name (`Ingest.Target.name`). The `names` values of its repositories
	## are in the byte range from `lo` (inclusive) to `hi` (exclusive): `<owner>/` and `<owner>0` (`/` is 0x2F, `0` is 0x30).
	owner_of : Str -> Str
	owner_of = |name| name.split_on("/").first() ?? name

	owner_range : Str -> { lo : Str, hi : Str }
	owner_range = |owner| { lo: "${owner}/", hi: "${owner}0" }

	## 00:00 UTC of the day of `now_ms` (ms since 1970). The owner count takes the `repos` rows with `time` at or after it.
	day_start : U64 -> U64
	day_start = |now_ms| now_ms - now_ms % day_ms

	day_ms : U64
	day_ms = 86_400_000

	## R-AP68 row 5: only for a new label (`Ingest.after_read` gives `Index`) of a name with no `repos` row. With `count` (the `repos` rows of the owner from
	## `day_start`) at least `owner_limit`: `Err((owner_limited(owner), <Retry-After>))`, the seconds from `now_ms` to the next 00:00 UTC, rounded up (at 00:00:00.000 it is 86400).
	## Else `Ok({})`.
	owner_check : { owner : Str, has_repo : Bool, count : U64, now_ms : U64 } -> Try({}, (Problem, U64))
	owner_check = |input| {
		if !input.has_repo and input.count >= owner_limit {
			Err((owner_limited(input.owner), seconds_to_next_day(input.now_ms)))
		} else {
			Ok({})
		}
	}

	## The seconds from `now_ms` to the next 00:00 UTC, rounded up.
	seconds_to_next_day : U64 -> U64
	seconds_to_next_day = |now_ms| {
		left_ms = day_ms - now_ms % day_ms
		(left_ms + 999) // 1000
	}

	## R-AP69 "The query value": each byte outside `A-Z a-z 0-9 - . _ ~` as `%` and 2 upper-case hex digits (also each byte of a UTF-8 character).
	query_value : Str -> Str
	query_value = |text| text.to_utf8().fold("", |acc, b| if (unreserved(b)) "${acc}${Str.from_utf8_lossy([b])}" else "${acc}%${hex_digit(b // 16)}${hex_digit(b % 16)}")

	## `A-Z a-z 0-9 - . _ ~` (RFC 3986).
	unreserved : U8 -> Bool
	unreserved = |b| (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or (b >= 48 and b <= 57) or b == 45 or b == 46 or b == 95 or b == 126

	hex_digit : U8 -> Str
	hex_digit = |n| Str.from_utf8_lossy([if (n < 10) 48 + n else 55 + n])

	## R-AP69: the 4 keys, in the order of the table: `<origin>/v1/releases?group=<g>`, `<origin>/v1/releases?group=<g>&series=<s>`,
	## `<origin>/v1/packages/<name>/releases` (the lower-case `owner/repo`, R-IK2), `<origin>/v1/artifacts/<hash>`. `<g>`, `<s>`: `query_value` of the group and the series.
	drop_keys : { origin : Str, group : Str, series : Str, name : Str, hash : Str } -> List(Str)
	drop_keys = |input| {
		group = query_value(input.group)
		releases = "${input.origin}/v1/releases?group=${group}"
		[
			releases,
			"${releases}&series=${query_value(input.series)}",
			"${input.origin}/v1/packages/${input.name}/releases",
			"${input.origin}/v1/artifacts/${input.hash}",
		]
	}
}
