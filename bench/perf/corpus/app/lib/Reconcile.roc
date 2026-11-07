## The pure part of the reconcile cron (Registry 7 "Reconcile": R-PU21 to R-PU25, R-PU27; "Scheduled jobs": R-PU35 to R-PU37; R-RE14; slice 119b, docs/slices/119-reconcile.md).
## No effect, no platform import. The effects (the claim, GitHub, the queue, the batches, the clock, the log) are in `worker/ReconcileCron.roc`.
## The tests are `worker/tests/unit/ReconcileTest.roc` (W0) and `worker/tests/cases/reconcile/` (W2).
## The doc comment of each function is the rule. Every function that is not a constant is `crash "todo"` until the code agent writes it (TW18).
import Ingest
import Toolchains
import Webhook

Reconcile :: [].{

	## The cron expression of the reconcile: every 5 min (R-PU23, R-PU35 "Reconcile", first guess). `wrangler.toml` `[triggers] crons` and `Worker.cron` in `main.roc` use the same text.
	cron : Str
	cron = "*/5 * * * *"

	## The most rows of one run (R-PU23, first guess). A run uses 1 + R D1 calls (R-PU23, Design Q47).
	max_rows : U64
	max_rows = 500

	## R-PU37 row 1: the claim sets `next_check_at` of each row that it takes to now plus 15 min (the wall time of a scheduled run).
	claim_ms : U64
	claim_ms = 900_000

	## R-PU37 row 3: the first delay of a failed row (5 min).
	backoff_ms : U64
	backoff_ms = 300_000

	## R-PU37 row 1, R-PU23, R-PU35, R-PU36: the claim. ONE statement: an `UPDATE repo_checks` that sets `next_check_at = ?1 + 900000` on the due rows, with `RETURNING`.
	## Parameters: ?1 now (ms), ?2 the most rows (`max_rows`). The due rows are selected in a subquery: `next_check_at <= ?1` (at or before now), `ORDER BY next_check_at` (the oldest first),
	## then `repo`, `LIMIT ?2`. D1 runs one write at a time, so 2 runs never get the same row, and a second run of the same planned time finds no row.
	## `RETURNING` gives each column that the run needs, so the run makes no other read (1 + R D1 calls, R-PU23): `CAST(repo AS TEXT) AS repo` (a 64-bit id travels as text, R-IK2),
	## the `repository_id` of the `repos` row (a subquery, as text), `etag`, `fail_count`, `app_installed`, and the indexed releases of EVERY `repos` row with that `repository_id`
	## (also a `moved` row; Design Q324, R-TP19) as one JSON text: for each release its `log_index`, `tag`, the `log.hash` of its leaf (base58) and `withdrawn` (empty text for NULL).
	## Slice 119c (Q371, Q378 to Q380): `RETURNING` also gives `repo_etag` (empty text for NULL), the name of the row (`names.value`, kind 3, as `name`), and the `repository_owner_id` (as text) and `state`
	## of the `repos` row of the claimed name, so the run makes no other read for the identity work.
	## SQLite allows a correlated subquery with an aggregate (`json_group_array`) in `RETURNING`, and gives the rows of `RETURNING` in no promised order (Q370 in the slice file).
	claim_sql : () -> Str
	claim_sql = || {
		due = "SELECT repo FROM repo_checks WHERE next_check_at <= ?1 ORDER BY next_check_at, repo LIMIT ?2"
		same_id = "SELECT repository_id FROM repos WHERE repos.repo = repo_checks.repo"
		release = "SELECT r.log_index AS log_index, COALESCE(r.tag, '') AS tag, l.hash AS hash, COALESCE(r.withdrawn, '') AS withdrawn FROM releases r JOIN log l ON l.idx = r.log_index WHERE r.repo IN (SELECT repo FROM repos WHERE repository_id = (${same_id})) ORDER BY r.log_index"
		releases = "(SELECT json_group_array(json_object('log_index', x.log_index, 'tag', x.tag, 'hash', x.hash, 'withdrawn', x.withdrawn)) FROM (${release}) x) AS releases"
		"UPDATE repo_checks SET next_check_at = ?1 + 900000 WHERE repo IN (${due}) RETURNING CAST(repo AS TEXT) AS repo, (SELECT CAST(repository_id AS TEXT) FROM repos WHERE repos.repo = repo_checks.repo) AS repository_id, COALESCE(etag, '') AS etag, fail_count, app_installed, ${releases}, COALESCE(repo_etag, '') AS repo_etag, COALESCE((SELECT value FROM names WHERE names.id = repo_checks.repo AND names.kind = 3), '') AS name, (SELECT CAST(repository_owner_id AS TEXT) FROM repos WHERE repos.repo = repo_checks.repo) AS repository_owner_id, COALESCE((SELECT state FROM repos WHERE repos.repo = repo_checks.repo), 0) AS state"
	}

	## An indexed release of the repository of a claimed row (from the JSON of the claim): its `releases.log_index`, its `tag`, the hash of its artifact (base58) and its `withdrawn` value.
	Indexed : { log_index : U64, tag : Str, hash : Str, withdrawn : Try(Str, [None]) }

	## The column `releases` of the claim: a JSON array of `{ log_index, tag, hash, withdrawn }`, with an empty `withdrawn` for NULL. Any other text is `Err(BadRows)`.
	indexed_of : Str -> Try(List(Reconcile.Indexed), [BadRows])
	indexed_of = |text| {
		parsed : Try(List({ log_index : U64, tag : Str, hash : Str, withdrawn : Str }), _)
		parsed = Json.parse(text)
		items = parsed.map_err(|_| BadRows)?
		Ok(items.map(|r| { log_index: r.log_index, tag: r.tag, hash: r.hash, withdrawn: if (r.withdrawn.is_empty()) Err(None) else Ok(r.withdrawn) }))
	}

	## R-PU37 row 3, R-PU22: the next `next_check_at` of a row. `fail_count` is the count AFTER this run: 0 for a row that passed, the old count + 1 for a row that failed.
	## 0: `now + interval`. n >= 1: `now + min(interval, 300000 * 2^(n - 1))` (5 min, 10 min, 20 min, ...; capped at the interval). A large n never overflows: the result is `now + interval`.
	## `interval` is `Reads.interval_ms(app_installed)` (1 h, or 24 h with the App, R-PU22).
	next_check : U64, U64, U32 -> U64
	next_check = |now, interval, fail_count| {
		var $delay = backoff_ms
		var $n = 1.U32
		while $n < fail_count and $delay < interval {
			$delay = $delay.times_saturated(2)
			$n = $n + 1
		}
		if (fail_count == 0 or $delay > interval) now + interval else now + $delay
	}

	## R-PU23, CLI R-DI2: the list call of the release list of a repository: `https://api.github.com/repos/<full_name>/releases?per_page=100`. `full_name` is the text that GitHub gave in the visibility read
	## (R-TP10: the current name), not changed (no lower case). R-PU27: every `repo_checks` row is a `github.com` name (R-PU40: no P2 path indexes another host), so the run reads no other host.
	list_url : Str -> Str
	list_url = |full_name| "https://api.github.com/repos/${full_name}/releases?per_page=100"

	## One release of the list: the GitHub release `id`, the `tag_name`, and the members that `Ingest.parse_release` reads.
	ListItem : { id : U64, tag : Str, release : Ingest.GithubRelease }

	## The body of a 200 answer of the list call: a JSON array of release objects (other members and `null` values as GitHub gives them, R-AP44). The order of the array is kept.
	## Each item needs an integer `id` of 1 or more, a `tag_name` that is not empty, and what `Ingest.parse_release` needs (`draft`, `prerelease`, `published_at` or `null`, `assets` with `name`).
	## A text that is not a JSON array, or ONE item that is not valid, is `Err(BadList)`: the row fails (R-PU37 row 2). Reason: an item that is skipped would look deleted.
	parse_list : Str -> Try(List(Reconcile.ListItem), [BadList])
	parse_list = |text| {
		# The derived JSON reader cannot read `null` (as `Ingest.parse_release`): `"published_at":null` becomes another member, so the member is missing.
		cleaned = text.replace_each("\"published_at\":null", "\"published_at_null\":0").replace_each("\"published_at\": null", "\"published_at_null\":0")
		parsed : Try(List({ id : U64, tag_name : Str, draft : Bool, prerelease : Bool, published_at : Try(Str, [Missing]), assets : List({ name : Str }) }), _)
		parsed = Json.parse(cleaned)
		items = parsed.map_err(|_| BadList)?
		items.map_try(
			|r| {
				if r.id < 1 or r.tag_name.is_empty() {
					return Err(BadList)
				}
				published_at = match r.published_at {
					Ok(time) => Ok(Toolchains.parse_time(time).map_err(|_| BadList)?)
					Err(Missing) => Err(None)
				}
				Ok({ id: r.id, tag: r.tag_name, release: { draft: r.draft, prerelease: r.prerelease, published_at, assets: r.assets.map(|a| a.name) } })
			},
		)
	}

	## The result of the list call (R-PU23). Input: the status, the `ETag` header, the `Link` header, the body text (empty for a status that is not 200).
	## - 304: `Ok(NotModified)`. The body is not read.
	## - 200: `parse_list`. `Ok(Changed({ etag, list }))` (`etag` is the header text as it came, or `Err(None)`). Slice 119c (Design Q372): the `Link` header does not
	##   change the outcome (the run reads the next page when `has_next(link)`). `Err(BadList)`: `Err(Failed("the release list is not valid"))`.
	## - Any other status: `Err(Failed("the release list read answered status <n>"))`.
	## The texts are proposals (TW24): they go to the log line of the row, never to a client.
	ListOutcome : [NotModified, Changed({ etag : Try(Str, [None]), list : List(Reconcile.ListItem) })]

	list_outcome : { status : U16, etag : Try(Str, [None]), link : Try(Str, [None]), body : Str } -> Try(Reconcile.ListOutcome, [Failed(Str)])
	list_outcome = |answer| match answer.status {
		304 => Ok(NotModified)
		200 => match parse_list(answer.body) {
			Ok(list) => Ok(Changed({ etag: answer.etag, list }))
			Err(BadList) => Err(Failed("the release list is not valid"))
		}
		status => Err(Failed("the release list read answered status ${status.to_str()}"))
	}

	## The work of a 200 list for one claimed row: the writes of the indexed releases and the new candidates.
	## `changes` use the form of `Webhook.Change` (`Ok(value)`: set `withdrawn` and `withdrawn_at`; `Err(Clear)`: set both to NULL). `candidates` are GitHub release ids (for `message_of`).
	Work : { changes : List(Webhook.Change), candidates : List(U64) }

	## R-PU23, R-PU17, R-PU19, R-PU20, R-PU21, R-PU6 (CLI R-DI3 to R-DI5): the work of one list. `rows` are the indexed releases of the repository (all its names), `list` the parsed list.
	## For each row, in the order of `rows` (at most one change for each row), with the list item of the same `tag` (GitHub tags are unique in a repository):
	## 1. No item with the tag, or the item is a draft: the state `Withdrawn("deleted")` (R-PU23: the token shows no draft, so a release that is a draft again is `deleted` too).
	## 2. The item is a prerelease (not a draft): `Withdrawn("prereleased")`.
	## 3. Else (final): `Final({ assets, candidate })`, `assets` all asset names of the item, `candidate` True when exactly one asset is a package asset (`Ingest.is_package_asset`).
	## The change of the row is then the rule of `Webhook.row_changes` for that state (reuse it): a row with a value keeps its first value and time (Design Q339); a final release whose recorded asset
	## `<hash>.tar.zst` is gone gives `asset-replaced` (R-PU20; also the label that GitHub released again with another hash, R-PU19); a candidate with the recorded asset clears a value,
	## ALSO `repo-missing` (slice 119c, R-PU24, Design Q379: the run calls `list_work` only after a public read by id, and the binding of a read by id always allows the clear). So `list_work` does NOT
	## reuse `Webhook.row_changes` as it is for a `repo-missing` row (the webhook job never clears it, Q360): a final candidate whose recorded asset is in `assets` clears it too.
	## `candidates`, in the order of `list`: the id of each item that is final, has exactly one package asset, whose asset URL
	## `https://github.com/<full_name>/releases/download/<tag>/<asset>` is accepted by `Ingest.parse_url` (the tag is a version, R-DI5), and whose tag is the tag of NO row. A tag that is indexed
	## (with the same or another hash) gives no candidate (R-PU14, R-PU19: the registry indexes nothing new for that label).
	list_work : { full_name : Str, rows : List(Reconcile.Indexed), list : List(Reconcile.ListItem) } -> Reconcile.Work
	list_work = |input| {
		changes = input.rows.join_map(
			|r| {
				state = state_of(input.list.find_first(|item| item.tag == r.tag))
				match (state, r.withdrawn) {
					(Final({ assets, candidate }), Ok("repo-missing")) => if (candidate and assets.contains("${r.hash}.tar.zst")) [{ log_index: r.log_index, to: Err(Clear) }] else []
					_ => Webhook.row_changes({ state, rows: [{ log_index: r.log_index, hash: r.hash, withdrawn: r.withdrawn }] })
				}
			},
		)
		candidates = input.list.keep_oks(
			|item| {
				if input.rows.any(|r| r.tag == item.tag) or item.release.draft or item.release.prerelease {
					return Err(No)
				}
				match item.release.assets.keep_if(Ingest.is_package_asset) {
					[one] => match Ingest.parse_url("https://github.com/${input.full_name}/releases/download/${item.tag}/${one}") {
						Ok(_) => Ok(item.id)
						Err(_) => Err(No)
					}
					_ => Err(No)
				}
			},
		)
		{ changes, candidates }
	}

	## The state of an indexed release from its list item (rules 1 to 3 of `list_work`).
	state_of : Try(Reconcile.ListItem, [NotFound]) -> Webhook.State
	state_of = |found| match found {
		Err(NotFound) => Withdrawn("deleted")
		Ok(item) if item.release.draft => Withdrawn("deleted")
		Ok(item) if item.release.prerelease => Withdrawn("prereleased")
		Ok(item) => {
			found_assets = item.release.assets.keep_if(Ingest.is_package_asset)
			Final({ assets: item.release.assets, candidate: found_assets.len() == 1 })
		}
	}

	## R-PU25: the rate limit reserve, from the headers of one GitHub answer (`x-ratelimit-remaining`, `x-ratelimit-limit`, `x-ratelimit-reset`, the reset in s since 1970).
	## All three are whole numbers and `remaining` is under 10 % of `limit` (strict: `remaining * 10 < limit`): `Ok(reset * 1000)`, the time in ms to which the rest of the batch moves.
	## Exactly 10 % is not under. A header that is missing or not a whole number: `Err(Go)`.
	reserve : { remaining : Try(Str, [None]), limit : Try(Str, [None]), reset : Try(Str, [None]) } -> Try(U64, [Go])
	reserve = |headers| {
		number = |h| match h {
			Ok(text) => U64.from_str(text).map_err(|_| Go)
			Err(None) => Err(Go)
		}
		remaining = number(headers.remaining)?
		limit = number(headers.limit)?
		reset = number(headers.reset)?
		if (remaining.times_saturated(10) < limit) Ok(reset.times_saturated(1000)) else Err(Go)
	}

	## R-PU23, R-PU13, R-PU15, R-PU21: the index message of a new candidate (`cloudflare-workers/API.md` RN16). The form is a proposal (TW24): `event` `poll`, `action` `published`,
	## `installation_id` 0, the ids, `repository_ids` `[]`. `Webhook.job_of` gives `Poll({ repository_id, release_id })` for it: the job `Release` with the provenance `poll` (via 2).
	message_of : U64, U64 -> Webhook.Message
	message_of = |repository_id, release_id| { event: "poll", action: "published", installation_id: 0, repository_id, release_id, repository_ids: [] }

	# ---- Slice 119c (Design Q371, Q372; docs/slices/119-reconcile.md sections 11 and 13) ----

	## Q372: the most pages of one list (1,000 releases, first guess). A page `max_pages` whose answer still has `rel="next"`: the row fails with
	## `the release list has more than 10 pages` (a proposal, CLI 3, R-OUT2) and the run reads no page after it.
	max_pages : U64
	max_pages = 10

	## Q372: True when the `Link` header of a list answer has a link with `rel="next"` (GitHub: `<url>; rel="next", <url>; rel="last"`). The URL of the link is not used.
	## `Err(None)`, an empty text, or a header with only `prev`, `first`, `last`: False.
	has_next : Try(Str, [None]) -> Bool
	has_next = |link| match link {
		Ok(text) => Str.split_on(text, ",").any(|part| part.contains("rel=\"next\""))
		Err(None) => Bool.False
	}

	## Q372: the URL of page `n` of the list: page 1 is `list_url(full_name)`, page n >= 2 is `list_url(full_name)` + `&page=<n>`. The Worker makes the URL itself.
	page_url : Str, U64 -> Str
	page_url = |full_name, n| if (n <= 1) list_url(full_name) else "${list_url(full_name)}&page=${n.to_str()}"

	## Q372: the pages as one list, in the order of the pages. A release id that comes 2 times (a release that moved to the next page between 2 reads) is kept once: the first one.
	merge_pages : List(List(Reconcile.ListItem)) -> List(Reconcile.ListItem)
	merge_pages = |pages| pages.join_map(|page| page).fold(
		[],
		|kept, item| if (kept.any(|k| k.id == item.id)) kept else kept.append(item),
	)

	## Q371, R-PU31, R-RE14: the `repo_etag` that the pass batch of a row stores, from a 200 answer of `GET /repositories/{id}`: its `ETag` (`etag`) when the read is public and the `full_name` of
	## the answer in lower case (ASCII) is the name of the row (`row_name`, lower case already). Else `Err(None)` (NULL): a read that is not public, a rename (a `moved` row, or a row whose repository
	## has another name now), or an answer with no `ETag`. A 304 keeps the stored value (the run does not call this for a 304).
	repo_etag_of : { public : Bool, row_name : Str, full_name : Str, etag : Try(Str, [None]) } -> Try(Str, [None])
	repo_etag_of = |input| if (input.public and input.full_name.with_ascii_lowercased() == input.row_name) input.etag else Err(None)
}
