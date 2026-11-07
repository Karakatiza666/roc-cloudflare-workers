## The pure part of the three compat read routes (Registry 4.1: R-AP4, R-AP39, R-AP40, R-AP41, R-AP54, R-AP56, R-AP67; 6: R-MX11 (row 5: a member is a hash), R-MX13; slice 115b).
## No effect, no platform import. The effects (the D1 call, the Cache API, the clock) are in `worker/CompatReadRoutes.roc`.
## The SQL is in `worker/sql/compat/*.sql` (the bot set is shared with slice 115a). The W1 cases `sql/tests/cases/compat/` run the same files.
## The tests are `worker/tests/unit/CompatReadsTest.roc` (W0) and `worker/tests/cases/compat/` (W2). The slice file is `docs/slices/115b-compat-reads.md`.
## The `detail` texts and the member order of the bodies are proposals for the human review (TW24): the slice file section 6.
## The doc comment of each function is the rule.
import records.Audit
import records.Code
import records.Work
import ClosureQuery
import Problem
import Reads

CompatReads :: [].{

	## R-AP40: the most pairs of one answer.
	audit_limit : U64
	audit_limit = 1000

	## R-AP4, R-AP40: the `Cache-Control` of the 200 answer and of the 304 answer (`max-age=300`). R-AP39 is `no-store`.
	cache_control : Str
	cache_control = "max-age=300"

	## R-AP39: the `Cache-Control` of the answer of `GET /v1/sweeps/{tag}`.
	sweep_cache_control : Str
	sweep_cache_control = "no-store"

	## R-AP39, R-AP48 row 6: the query parameter `target` (default `any`). Only `any` is valid (R-AP67, Design Q147: the target of a sweep is `any`, R-MX4). Any other text, also an empty one,
	## is 400 `bad-request`, `detail` `the query parameter target must be any, got <text>`. Before any D1 call.
	parse_sweep_target : Try(Str, [NotFound]) -> Try({}, Problem)
	parse_sweep_target = |target| match target {
		Err(NotFound) => Ok({})
		Ok("any") => Ok({})
		Ok(text) => Err(Problem.new(BadRequest, "the query parameter target must be any, got ${text}"))
	}

	## R-AP40, R-AP48 row 6: the query parameter `audit`. It is required (R-AP67, Design Q148). Decimal digits, no leading zero (only `0` itself), as R-AP56 gives for `after`; else 400 `bad-request`,
	## `detail` `the query parameter audit must be a count (decimal digits), got <text>`; no parameter: `GET /v1/compat_hints needs the query parameter audit`. A number above
	## `audit_limit` (also above 2^63 - 1 or above 2^64 - 1 as text) gives `audit_limit` (R-AP67, Design Q149: "at most 1000" caps, it is no error). 0 gives 0.
	parse_audit : Try(Str, [NotFound]) -> Try(U64, Problem)
	parse_audit = |audit| match audit {
		Err(NotFound) => Err(Problem.new(BadRequest, "GET /v1/compat_hints needs the query parameter audit"))
		Ok(text) => {
			bytes = text.to_utf8()
			digits = !bytes.is_empty() and bytes.all(|b| b >= '0' and b <= '9')
			plain = bytes.len() == 1 or bytes.first() != Ok('0')
			if digits and plain {
				Ok(U64.min(U64.from_str(text) ?? audit_limit, audit_limit))
			} else {
				Err(Problem.new(BadRequest, "the query parameter audit must be a count (decimal digits), got ${text}"))
			}
		}
	}

	## R-AP39, 404: the tag has no row in `toolchains`. `detail`: `no toolchain for the tag <tag>`. (A tag with no nightly id, R-IK4, has none: no D1 call.)
	no_tag : Str -> Problem
	no_tag = |tag| Problem.new(NotFound, "no toolchain for the tag ${tag}")

	## The `sweeps` row of (nightly, `any`).
	SweepRow : { upto_log_index : U64, time : U64 }

	## R-AP39: the body `{"log_size":<n>,"members":<n>,"missing":[<base58>,...],"sweep":<{"nightly":<tag>,"target":"any","time":<ms>,"upto_log_index":<n>} or null>}`. Every record has
	## its members in alphabetical order, as the derived encoder writes them, so that one state gives one body (R-AP24). `sweep` is written by hand when it is `null` (the
	## derived encoder cannot write `null`). `missing` is every member with no `bot` row (no cap; R-AP67, R-MX11 row 5: a member is a hash), in the order given. `tag` is the tag of the nightly as `toolchains` has it.
	sweep_body : { tag : Str, sweep : Try(CompatReads.SweepRow, [None]), log_size : U64, members : U64, missing : List(Str) } -> Str
	sweep_body = |x| {
		sweep = x.sweep.map_ok(|row| { nightly: x.tag, target: "any", time: row.time, upto_log_index: row.upto_log_index })
		Work.encode({ sweep, log_size: x.log_size, members: x.members, missing: x.missing })
	}

	## A row of the statement `audit`: a pair with hints and no `bot` row. `nightly` is the tag, `target` the name.
	PairRow : { hash : List(U8), nightly : Str, target : Str, pass_count : U64, fail_count : U64, crash_count : U64 }

	## R-AP40: the body `{"pairs":[{"crash_count":<n>,"fail_count":<n>,"hash":<base58>,"nightly":<tag>,"pass_count":<n>,"target":<name>},...]}` in the order of the rows
	## (members in alphabetical order). A hash of other than 32 bytes is `Err(BadRow)`.
	pairs_body : List(CompatReads.PairRow) -> Try(Str, [BadRow(Str)])
	pairs_body = |rows| {
		pairs = rows.map_try(
			|r| {
				hash = Reads.base58_of_bytes(r.hash)?
				Ok({ hash, nightly: r.nightly, target: r.target, pass_count: r.pass_count, fail_count: r.fail_count, crash_count: r.crash_count })
			},
		)?
		answer : Audit.Answer
		answer = { pairs: pairs }
		Ok(Audit.encode(answer))
	}

	## R-AP4: the body `{"hints":[...],"runs":[...]}` (alphabetical): the items have the form and the bytes of `runs` and `hints` of the closure answer (R-AP17: `Closure.Run`,
	## `Closure.Hint`, `error_digest` text or `null`, R-AP58), made from the rows of the closure statements `runs` and `hints` (`ClosureQuery.RunRow`, `ClosureQuery.HintRow`) in their order.
	## A row that does not convert is `Err(BadRow)`.
	compat_body : { runs : List(ClosureQuery.RunRow), hints : List(ClosureQuery.HintRow) } -> Try(Str, [BadRow(Str)])
	compat_body = |x| {
		runs = x.runs.map_try(ClosureQuery.run_of)?
		hints = x.hints.map_try(ClosureQuery.hint_of)?
		Ok("{\"hints\":${Json.to_str(hints)},\"runs\":[${Str.join_with(runs.map(run_text), ",")}]}")
	}

	## One run, members in alphabetical order. `error_digest` is `null` for none (R-AP58).
	run_text = |r| {
		digest = match r.error_digest {
			Ok(text) => Json.to_str(text)
			Err(None) => "null"
		}
		source = match r.source {
			Bot => "bot"
			Author => "author"
		}
		"{\"error_digest\":${digest},\"from\":${Json.to_str(r.from)},\"hash\":${Json.to_str(r.hash)},\"result\":${Json.to_str(Code.result_to_str(r.result))},\"source\":\"${source}\",\"target\":${Json.to_str(r.target)},\"to\":${Json.to_str(r.to)}}"
	}
}
