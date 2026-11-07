## The handler of `GET /v1/packages` (Registry 4.3: R-AP7, R-SN1 to R-SN5; slice 107). The decisions are in `lib/Shorts.roc` (pure, W0).
## This module only orders the effects. The tests are W2: `worker/tests/cases/shorts/`.
## The flow is the flow of `ReadRoutes.serve!` (slice 106 section 3.3), with these differences:
## 1. The checks that need no D1 come first: `Shorts.parse_query(req.query_all("short"), req.query_all("q"))`. `Err(Bad(problem))` is `Err(Refuse(problem))`. `Err(TooMany(count))` is an `Ok` answer:
##    status 413, content type `application/problem+json`, the body `Shorts.too_large_json(count)`. No D1 call, no Cache API read or put.
## 2. The cache key is `req.url()`. The `Cache-Control` of the answer is `Shorts.short_cache_control` for `Short`, `Shorts.search_cache_control` for `Search` (R-AP7).
##    `ReadRoutes.serve!` has a fixed `max-age=60`, so this module has its own copy of the flow, or the code agent gives `ReadRoutes.serve!` the max age as an argument (slice file 10.2).
## 3. One D1 call: `with_session!(Reads.session_of(..))` and one statement (or one `batch!`), R-AP41 row 1. For `Short`: the rows of `Shorts.Row`, with the successor chain in a recursive CTE.
##    For `Search`: the rows of `Shorts.SearchRow`.
## 4. The body is `Shorts.matches_body(Shorts.entries_of(..))` or `Shorts.search_body(..)`. A 200 answer is not empty-checked: an empty list is 200 (R-SN1).
##    ETag, 304, Cache API, `no-cache` bypass: `Reads.etag_of`, `Reads.etag_matches`, `Reads.bypass_cache` (R-AP24, R-AP43, R-AP54, R-AP55).
import pf.Request
import pf.Response
import pf.D1
import pf.Sql
import lib.Shorts
import ReadRoutes

ShortRoutes :: [].{

	## `GET /v1/packages` (R-AP7).
	list! : Request => Try(Response, ReadRoutes.Error)
	list! = |req| match Shorts.parse_query(req.query_all("short"), req.query_all("q")) {
		Err(Bad(problem)) => Err(Refuse(problem))
		Err(TooMany(count)) => Ok(Response.from_bytes(413, "application/problem+json", Shorts.too_large_json(count).to_utf8()))
		Ok(Short(values)) => {
			lowered = values.map(|v| v.with_ascii_lowercased())
			stmt = Sql.stmt(short_sql, [Json.to_str(lowered)])
			ReadRoutes.serve!(req, Shorts.short_cache_control, [stmt], |results, _now| short_answer(results, values))
		}
		Ok(Search(text)) => {
			stmt = Sql.stmt(search_sql, [text.with_ascii_lowercased()])
			ReadRoutes.serve!(req, Shorts.search_cache_control, [stmt], |results, _now| search_answer(results, text))
		}
	}

	short_answer : List(D1.Result), List(Str) -> Try(Str, ReadRoutes.Error)
	short_answer = |results, values| match results {
		[result] => {
			rows : List(Shorts.Row)
			rows = result.all().map_err(|e| Fault(Str.inspect(e)))?
			entries = Shorts.entries_of(values, rows).map_err(bad_row)?
			Ok(Shorts.matches_body(entries))
		}
		_ => Err(Fault("short: the batch gave ${results.len().to_str()} results, not 1"))
	}

	search_answer : List(D1.Result), Str -> Try(Str, ReadRoutes.Error)
	search_answer = |results, text| match results {
		[result] => {
			rows : List(Shorts.SearchRow)
			rows = result.all().map_err(|e| Fault(Str.inspect(e)))?
			Shorts.search_body(text, rows).map_err(bad_row)
		}
		_ => Err(Fault("search: the batch gave ${results.len().to_str()} results, not 1"))
	}

	bad_row : [BadRow(Str)] -> ReadRoutes.Error
	bad_row = |e| match e {
		BadRow(text) => Fault(text)
	}

	## R-SN1, R-AP41 row 1: `?1` is the JSON list of the lower case values. The names of kind 3 with a release whose repo part (or repo part minus `roc-`) is a value,
	## and the names on their successor chain (depth below 5). `Shorts.entries_of` decides the match and the end.
	short_sql : Str
	short_sql = "WITH RECURSIVE hits(id) AS (SELECT n.id FROM names n WHERE n.kind = 3 AND instr(n.value, '/') > 0 AND EXISTS (SELECT 1 FROM releases r WHERE r.repo = n.id) AND (substr(n.value, instr(n.value, '/') + 1) IN (SELECT value FROM json_each(?1)) OR (substr(n.value, instr(n.value, '/') + 1) LIKE 'roc-%' AND length(substr(n.value, instr(n.value, '/') + 1)) > 4 AND substr(n.value, instr(n.value, '/') + 5) IN (SELECT value FROM json_each(?1))))), chain(id, depth) AS (SELECT id, 0 FROM hits UNION SELECT p.successor, c.depth + 1 FROM chain c JOIN repos p ON p.repo = c.id WHERE p.state = 2 AND p.successor IS NOT NULL AND c.depth < 5) SELECT DISTINCT n.value AS name, p.state AS state, sn.value AS successor, (SELECT min(r.log_index) FROM releases r WHERE r.repo = c.id) AS first_log_index FROM chain c JOIN names n ON n.id = c.id JOIN repos p ON p.repo = c.id LEFT JOIN names sn ON sn.id = p.successor"

	## R-SN5: the indexed names that contain the lower case text. `Shorts.rank` orders them.
	search_sql : Str
	search_sql = "SELECT n.value AS name, p.state AS state, (SELECT min(r.log_index) FROM releases r WHERE r.repo = n.id) AS first_log_index FROM names n JOIN repos p ON p.repo = n.id WHERE n.kind = 3 AND instr(n.value, ?1) > 0 AND EXISTS (SELECT 1 FROM releases r WHERE r.repo = n.id)"
}
