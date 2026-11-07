## The pure part of the GitHub webhook and the index queue (Registry 4: R-AP12, R-AP79; 7: R-PU3, R-PU11, R-PU12, R-PU13, R-PU24, R-PU26, R-PU31, R-PU32, R-PU33, R-PU35, R-PU45; slice 118).
## No effect, no platform import. The effects (the body read, the secret, the compare, the queue send and consume, GitHub, D1, the clock) are in `worker/WebhookRoutes.roc` and `worker/IndexQueue.roc`.
## The tests are in `worker/tests/unit/WebhookTest.roc` (W0) and `worker/tests/cases/webhook/` (W2). The slice file is `docs/slices/118-webhook.md`.
## The names of the queues, the texts of the `detail` and the form of the message are proposals for the human review (TW24): slice file section 5.
## The doc comment of each function is the rule. Every function that is not given is `crash "todo"` until the code agent writes it (TW18).
import Ingest
import Problem

Webhook :: [].{

	## The queue of the index jobs (R-WH14 `INDEX`) and its dead letter queue (`INDEX_DLQ`): the names in `wrangler.toml` (R-PU45, Design Q331). The binding `INDEX` is in `main.roc`; the code has no producer for `INDEX_DLQ` (Design Q329).
	queue_name : Str
	queue_name = "talon-index"

	dlq_name : Str
	dlq_name = "talon-index-dlq"

	## The most attempts of a job: the first delivery and 4 retries. `wrangler.toml` has `max_retries = 4` for the consumer of `queue_name` (R-PU45, R-PU35, R-PU13).
	max_attempts : U32
	max_attempts = 5

	## R-PU11: the message of one event that the Worker uses. It holds the event, the action and the GitHub ids, never a name (R-PU32). A number that does not apply to the event is 0, a list that does not apply is `[]`.
	## It crosses as a CBOR map (`Queue.json`): a JS peer and the test see the JSON object with the 6 members. `repository_ids` is for the events `installation` and `installation_repositories`.
	Message : { event : Str, action : Str, installation_id : U64, repository_id : U64, release_id : U64, repository_ids : List(U64) }

	## What the Worker does with an event: send the message, or ignore it (answer 202 and send nothing).
	Decision : [Send(Webhook.Message), Ignore]

	## R-AP12: the problem 401 of a signature that is missing or not good. One text for all the causes (the answer shows no more than the registry publishes). Given.
	bad_signature : Problem
	bad_signature = Problem.new(Unauthenticated, "the signature of the webhook is missing or not valid")

	## R-AP12: the header `X-Hub-Signature-256`. The text must be `sha256=` and exactly 64 hex digits (`0-9`, `a-f`; `A-F` is accepted, no test). The result is the 32 bytes.
	## Any other text is `Err(Malformed)`: no prefix, another prefix (`sha1=`), 63 or 65 digits, a character that is not a hex digit, white space around, an empty text.
	parse_signature : Str -> Try(List(U8), [Malformed])
	parse_signature = |header| {
		if !header.starts_with("sha256=") {
			return Err(Malformed)
		}
		digits = header.drop_prefix("sha256=").to_utf8()
		if digits.len() != 64 {
			return Err(Malformed)
		}
		digits.chunks_of(2).map_try(
			|pair| match pair {
				[hi, lo] => Ok(hex_value(hi)? * 16 + hex_value(lo)?)
				_ => Err(Malformed)
			},
		)
	}

	hex_value : U8 -> Try(U8, [Malformed])
	hex_value = |c|
		if c >= '0' and c <= '9' {
			Ok(c - '0')
		} else if c >= 'a' and c <= 'f' {
			Ok(c - 'a' + 10)
		} else if c >= 'A' and c <= 'F' {
			Ok(c - 'A' + 10)
		} else {
			Err(Malformed)
		}

	## R-PU11, R-PU3, R-AP79 rows 6 to 9: the event and the body of a webhook, after the signature (R-AP79 row 5, Design Q320). `event` is the header `X-GitHub-Event`.
	## 0. An empty `event` (the route passes "" for a missing header): `Err` 400 `BadRequest`, whatever the body (R-AP79 row 6, Design Q321). The proposal of the `detail`: `the webhook has no X-GitHub-Event header`.
	## 1. An event other than `release`, `repository`, `installation`, `installation_repositories` (`ping`, `star`, ...): `Ok(Ignore)`. The body is not read.
	## 2. The body is not a JSON object, or its member `action` is missing or not text: `Err` 400 `BadRequest`. Other members are ignored (R-AP44), also nested ones.
	## 3. The actions that the Worker uses (R-PU11): `release`: `published`, `released`, `edited`, `prereleased`, `unpublished`, `deleted`. `repository`: `privatized`, `publicized`.
	##    `installation`: `created`, `deleted`, `suspend`, `unsuspend` (Design Q322). `installation_repositories`: `added`, `removed`. Any other action (`release` `created`, a draft, R-PU11; `repository` `archived`; `installation` `new_permissions_accepted`) is `Ok(Ignore)` (R-AP79 row 9).
	## 4. The ids. `release`: `repository.id` and `release.id` are JSON integers of 1 or more, else 400 `BadRequest`. `repository`: `repository.id`. `installation_id` is `installation.id` when it is an integer of 1 or more, else 0
	##    (a missing `installation` is not an error). `installation` (all 4 actions): `repository_ids` are the `id` of each item of `repositories` (a missing or empty list is `[]`). `installation_repositories`: the `id` of each item of
	##    `repositories_added` for `added`, of `repositories_removed` for `removed`. An item with no integer `id` is 400 `BadRequest`.
	## 5. `Ok(Send(message))`: `event` and `action` as sent, the ids as in rule 4, the numbers that do not apply 0, the lists that do not apply `[]`.
	## The texts of the `detail` of a 400 are proposals (slice file section 5).
	parse_event : { event : Str, body : List(U8) } -> Try(Webhook.Decision, Problem)
	parse_event = |input| {
		if input.event.is_empty() {
			return Err(bad_request("the webhook has no X-GitHub-Event header"))
		}
		if !used_event(input.event) {
			return Ok(Ignore)
		}
		text = Str.from_utf8(input.body).map_err(|_| bad_request("the webhook body is not UTF-8"))?
		head : Try({ action : Str }, _)
		head = Json.parse(text)
		action = match head {
			Ok(h) => h.action
			Err(_) => return Err(bad_request("the webhook body is not a JSON object with a text member action"))
		}
		if !used_action(input.event, action) {
			return Ok(Ignore)
		}
		match input.event {
			"release" => release_message(text, action)
			"repository" => repository_message(text, action)
			"installation" => installation_message(text, action)
			_ => installation_repositories_message(text, action)
		}
	}

	bad_request : Str -> Problem
	bad_request = |detail| Problem.new(BadRequest, detail)

	message_of : Str, Str, U64, U64, U64, List(U64) -> Webhook.Message
	message_of = |event, action, installation_id, repository_id, release_id, repository_ids| { event, action, installation_id, repository_id, release_id, repository_ids }

	used_event : Str -> Bool
	used_event = |event| ["release", "repository", "installation", "installation_repositories"].contains(event)

	## The pairs of event and action that the Worker uses (R-PU11, Design Q322).
	used_action : Str, Str -> Bool
	used_action = |event, action| match event {
		"release" => ["published", "released", "edited", "prereleased", "unpublished", "deleted"].contains(action)
		"repository" => ["privatized", "publicized"].contains(action)
		"installation" => ["created", "deleted", "suspend", "unsuspend"].contains(action)
		"installation_repositories" => ["added", "removed"].contains(action)
		_ => Bool.False
	}

	## `installation.id` when it is an integer of 1 or more, else 0. A missing installation is not an error.
	installation_id_of : Str -> U64
	installation_id_of = |text| {
		parsed : Try({ installation : Try({ id : U64 }, [Missing]) }, _)
		parsed = Json.parse(text)
		match parsed {
			Ok({ installation: Ok(i) }) => i.id
			_ => 0
		}
	}

	release_message : Str, Str -> Try(Webhook.Decision, Problem)
	release_message = |text, action| {
		parsed : Try({ release : { id : U64 }, repository : { id : U64 } }, _)
		parsed = Json.parse(text)
		match parsed {
			Ok(r) if r.repository.id >= 1 and r.release.id >= 1 => Ok(Send(message_of("release", action, installation_id_of(text), r.repository.id, r.release.id, [])))
			_ => Err(bad_request("the webhook body has no valid repository id and release id"))
		}
	}

	repository_message : Str, Str -> Try(Webhook.Decision, Problem)
	repository_message = |text, action| {
		parsed : Try({ repository : { id : U64 } }, _)
		parsed = Json.parse(text)
		match parsed {
			Ok(r) if r.repository.id >= 1 => Ok(Send(message_of("repository", action, installation_id_of(text), r.repository.id, 0, [])))
			_ => Err(bad_request("the webhook body has no valid repository id"))
		}
	}

	installation_message : Str, Str -> Try(Webhook.Decision, Problem)
	installation_message = |text, action| {
		parsed : Try({ repositories : Try(List({ id : U64 }), [Missing]) }, _)
		parsed = Json.parse(text)
		match parsed {
			Ok(r) => Ok(Send(message_of("installation", action, installation_id_of(text), 0, 0, ids_of(r.repositories))))
			Err(_) => Err(bad_request("the webhook body has a repository without an id"))
		}
	}

	installation_repositories_message : Str, Str -> Try(Webhook.Decision, Problem)
	installation_repositories_message = |text, action| {
		ids = if action == "added" {
			parsed : Try({ repositories_added : Try(List({ id : U64 }), [Missing]) }, _)
			parsed = Json.parse(text)
			parsed.map_ok(|r| ids_of(r.repositories_added))
		} else {
			parsed : Try({ repositories_removed : Try(List({ id : U64 }), [Missing]) }, _)
			parsed = Json.parse(text)
			parsed.map_ok(|r| ids_of(r.repositories_removed))
		}
		match ids {
			Ok(list) => Ok(Send(message_of("installation_repositories", action, installation_id_of(text), 0, 0, list)))
			Err(_) => Err(bad_request("the webhook body has a repository without an id"))
		}
	}

	ids_of : Try(List({ id : U64 }), [Missing]) -> List(U64)
	ids_of = |items| match items {
		Ok(list) => list.map(|i| i.id)
		Err(Missing) => []
	}

	## What the consumer does for a message (R-PU11 "The queue consumer does the work"). `Release` is the job of slice 118b. `Privatized` and `Publicized` are the actions of the event `repository` (R-PU33).
	## `AppInstalled` is the event `installation` or `installation_repositories` (R-PU26, Design Q322): `installed` is True for `created`, `unsuspend` and `added`, False for `deleted`, `suspend` and `removed`.
	## `Poll` (slice 119b) is the message of the reconcile (`Reconcile.message_of`: event `poll`, action `published`): the job `Release` with the action `published`, no installation, and the provenance `poll` (via 2, R-PU15, R-PU21).
	Job : [Release({ action : Str, repository_id : U64, release_id : U64, installation_id : U64 }), Privatized(U64), Publicized(U64), AppInstalled({ repository_ids : List(U64), installed : Bool }), Poll({ repository_id : U64, release_id : U64 })]

	## The job of a message. The pairs of `parse_event` rule 3 give a job. The pair (`poll`, `published`) gives `Poll` (slice 119b; the reconcile writes it, never the webhook route). Any other event or action (a message that this Worker did not write) is `Err(Unknown)`.
	job_of : Webhook.Message -> Try(Webhook.Job, [Unknown])
	job_of = |m| match (m.event, m.action) {
		("release", action) if used_action("release", action) => Ok(Release({ action, repository_id: m.repository_id, release_id: m.release_id, installation_id: m.installation_id }))
		("repository", "privatized") => Ok(Privatized(m.repository_id))
		("repository", "publicized") => Ok(Publicized(m.repository_id))
		("installation", action) if used_action("installation", action) => Ok(AppInstalled({ repository_ids: m.repository_ids, installed: action == "created" or action == "unsuspend" }))
		("installation_repositories", action) if used_action("installation_repositories", action) => Ok(AppInstalled({ repository_ids: m.repository_ids, installed: action == "added" }))
		("poll", "published") => Ok(Poll({ repository_id: m.repository_id, release_id: m.release_id }))
		_ => Err(Unknown)
	}

	## R-PU13, R-PU35: the delay of the retry after the attempt `attempts` (the first delivery is attempt 1) in ms: 60 000 after attempt 1, 300 000 after 2, 900 000 after 3, 3 600 000 after 4
	## (1, 5, 15 and 60 min, first guess). The delays are one after the other, each from the failed attempt. Attempt 5 and later: `Err(GiveUp)`: the consumer retries with no delay, and the platform
	## moves the message to `dlq_name` because `max_retries` is used up (R-PU35).
	retry_delay_ms : U32 -> Try(U64, [GiveUp])
	retry_delay_ms = |attempts| match attempts {
		0 | 1 => Ok(60_000)
		2 => Ok(300_000)
		3 => Ok(900_000)
		4 => Ok(3_600_000)
		_ => Err(GiveUp)
	}

	## R-PU31, R-PU12, R-PU33: the answer of `GET /repositories/{repository_id}` for a job `Privatized`. The event body is old when GitHub sends an event again (R-PU12), so the Worker reads the repository.
	## 404: `Ok(Withdraw)` (the repository is deleted, or private and not readable, R-PU24, R-TP11). 200 with `visibility` `public`: `Ok(Stale)` (the event is old: nothing changes). 200 with `private` or `internal`
	## (`Ingest.parse_repo`): `Ok(Withdraw)`. 200 with a body that `Ingest.parse_repo` refuses: `Err(Upstream(text))`. Any other status: `Err(Upstream(text))`. The text is for the log line, with no name.
	repository_outcome : { status : U16, body : Str } -> Try([Withdraw, Stale], [Upstream(Str)])
	repository_outcome = |answer| match answer.status {
		404 => Ok(Withdraw)
		200 => match Ingest.parse_repo(answer.body) {
			Ok(repo) => if (repo.public) Ok(Stale) else Ok(Withdraw)
			Err(BadRepo) => Err(Upstream("the repository answer is not a repository"))
		}
		status => Err(Upstream("GitHub answered the repository read with status ${status.to_str()}"))
	}

	# ---- Slice 118b: the job Release (R-PU12, R-PU13, R-PU14, R-PU17, R-PU20, Design Q328, Q332 to Q339, Q360 to Q363; docs/slices/118-webhook.md sections 8, 13, 14) ----
	# The job, in order (the effects are in `IndexQueue.release!`, the decisions are the functions below):
	# 1. `GET /repositories/{repository_id}` (R-PU31). `repository_outcome`: 404, private or internal is the job `Privatized` (R-PU33), then the job ends with `Ok` (a release event of a repository that is not public is ignored). A 200 public answer gives `full_name`
	#    (`Identity.full_name_of`) and the ids for the identity. From here on the repository is public: a job with `installation_id` of 1 or more sets `repo_checks.app_installed` to 1 on every row of the repository id,
	#    whatever the rest of the job gives (a conflict, no asset, 2 package assets, a stale event, `deleted`, a 404, a refusal; Q362). A row that exists keeps `next_check_at`.
	#    `deleted` (Q336): no release read, no `releases` write. `UPDATE repo_checks SET next_check_at = <now> WHERE repo IN (the `repos` rows of the repository id whose state is not `moved`)` (as `Publicized`), then ack. The next reconcile sets `withdrawn` = `deleted` (R-PU23). A repository with no row writes nothing.
	# 2. `GET /repos/{full_name}/releases/{release_id}` (R-PU12, Q328; the event body is not used). 404: the job ends with `Ok` (a release that is gone: R-PU13). Another status: a failure. `parse_release`. `release_step`.
	# 3. The indexed rows of that release: the `releases` rows of every `repos` row of the `repository_id` with the `tag` of the read (`Webhook.Indexed`, in the order of `log_index`). `row_changes` gives the writes of R-PU17 and R-PU20 (one `UPDATE releases SET withdrawn, withdrawn_at`). The state is `Withdrawn(value)` for `Withdraw(value)`, else `Final({ assets, candidate })` with `candidate` True only for `Index` (Q360).
	# 4. `Index(url)`: the pre-read of the label (the label SQL of `IngestRoutes` with `via` 1) and `Ingest.after_read`: `Conflict`: no write of the index, the log line `Log.warn!("index label conflict", { repository_id, release_id, group, version })`, then the job ends with `Ok` (Q333).
	#    `Answer`: nothing to add. `AddProvenance(log_index)`: the `provenance` row with `via` 1 only (R-PU14, R-PU15). `Index`: `IngestRoutes.index!(session, target, flow)` with `via` 1 and no claims, and the same `identity!` as the ingest (the shared flow, never a copy).
	#    The release is read again by tag inside `index!` (`Ingest.release_url`): it is the 3rd GitHub read of the job, and the tests pin it (Q337).
	#    A refusal of `index!` with a 4xx problem is final: `Log.warn!("index job refused", { repository_id, release_id, type })` (`type` is the problem type, no name) and ack. A 5xx problem or a fault is a failure (retry) (Q361, R-PU45 "Refusals").
	#    `Identity.Changed` (403 `repository-changed`): the same, nothing is written for the name (R-TP9 row 4).
	# 5. `NoAsset`: the job is a failure (`Err`, so the consumer retries with `retry_delay_ms`), except at the end: `after_no_asset`. `TooMany` and `Skip`: the job ends with `Ok`, no retry.
	# 6. A row that the index adds with `installation_id` of 1 or more has `app_installed` 1 and the interval of 24 h (`Reads.interval_ms(Bool.True)`, Q335). The other rows: see step 1 (Q362).

	## The answer of `GET /repos/{full_name}/releases/{release_id}`: the `tag_name` and the members that `Ingest.parse_release` reads (`draft`, `prerelease`, `published_at`, the names of the assets).
	## A text that is not JSON, or with a missing or empty `tag_name`, or that `Ingest.parse_release` refuses, is `Err(BadRelease)` (a failure of the job: GitHub gave a bad answer).
	ReleaseRead : { tag : Str, release : Ingest.GithubRelease }

	parse_release : Str -> Try(Webhook.ReleaseRead, [BadRelease])
	parse_release = |text| {
		release = Ingest.parse_release(text).map_err(|_| BadRelease)?
		parsed : Try({ tag_name : Str }, _)
		parsed = Json.parse(text)
		match parsed {
			Ok(r) if !r.tag_name.is_empty() => Ok({ tag: r.tag_name, release })
			_ => Err(BadRelease)
		}
	}

	## What the job does with a release that it has read (R-PU12: the state on GitHub governs, the action only names the reason).
	## - `Withdraw(value)`: the release is not final (`draft` or `prerelease`) and `action` is `unpublished`, `prereleased` or `edited`: `value` is the action (Q332: `edited` is `edited`). The rows get `withdrawn` = `value` (R-PU17).
	## - `Index(url)`: the release is final and has exactly one package asset (`Ingest.is_package_asset`): the URL of that asset, `https://github.com/<full_name>/releases/download/<tag>/<asset>` with the `full_name` as GitHub gave it (R-PU13). Any action. A stale event
	##   (`unpublished` for a release that is final again) is the same (Q338).
	## - `NoAsset`: final, and no package asset: the job reads again later (R-PU13).
	## - `TooMany`: final, and 2 or more package assets: not a candidate (CLI 7.3, R-DI4), no read again.
	## - `Skip`: not final, and `action` is `published` or `released` (an event that is old, R-PU12): the job does nothing (Q338). The action `deleted` never comes here: the job does no release read for it (Q336).
	Step : [Index(Str), Withdraw(Str), NoAsset, TooMany, Skip]

	release_step : { action : Str, full_name : Str, read : Webhook.ReleaseRead } -> Webhook.Step
	release_step = |input| {
		release = input.read.release
		found = release.assets.keep_if(Ingest.is_package_asset)
		if release.draft or release.prerelease {
			if (["unpublished", "prereleased", "edited"].contains(input.action)) Withdraw(input.action) else Skip
		} else {
			match found {
				[] => NoAsset
				[one] => Index("https://github.com/${input.full_name}/releases/download/${input.read.tag}/${one}")
				_ => TooMany
			}
		}
	}

	## An indexed label of the release: the `releases` row (`log_index`), the `hash` of its artifact (base58) and its `withdrawn` value.
	Indexed : { log_index : U64, hash : Str, withdrawn : Try(Str, [None]) }

	## The state of the release for `row_changes`: `Final({ assets, candidate })` when the release is final (`assets` are all its asset names, also the ones that are not packages; `candidate` is True when the step is `Index`, False for
	## `NoAsset` and `TooMany`, Q360), `Withdrawn(value)` for the `Withdraw(value)` step.
	State : [Final({ assets : List(Str), candidate : Bool }), Withdrawn(Str)]

	## A change of one row: `Ok(value)` sets `withdrawn` to `value` and `withdrawn_at` to the clock, `Err(Clear)` sets both to NULL.
	Change : { log_index : U64, to : Try(Str, [Clear]) }

	## R-PU17, R-PU20, Q339, Q360: the writes for the indexed rows of the release. A row that needs no write is not in the list. The list has the order of `rows`.
	## - `Withdrawn(value)`: each row with no `withdrawn` value gets `Ok(value)`. A row that has a value keeps its first value and time (Q339).
	## - `Final({ assets, candidate })`: the recorded asset of a row is `<hash>.tar.zst`. It is in `assets`: a row with a `withdrawn` value gets `Err(Clear)` ONLY when `candidate` is True (the release is a candidate again with the same hash, R-PU17;
	##   the asset is there again, R-PU20), and never when the value is `repo-missing` (only the reconcile clears it, R-PU24, Q360). A row with no value needs no write. It is not in `assets`: a row with no value gets `Ok("asset-replaced")`
	##   (R-PU20), whatever `candidate` is; a row with a value keeps it.
	row_changes : { state : Webhook.State, rows : List(Webhook.Indexed) } -> List(Webhook.Change)
	row_changes = |input| input.rows.keep_oks(|row| change_of(input.state, row))

	## The change of one row, or `Err(NoChange)`.
	change_of : Webhook.State, Webhook.Indexed -> Try(Webhook.Change, [NoChange])
	change_of = |state, row| match (state, row.withdrawn) {
		(Withdrawn(value), Err(None)) => Ok({ log_index: row.log_index, to: Ok(value) })
		(Withdrawn(_), Ok(_)) => Err(NoChange)
		(Final({ assets, candidate }), withdrawn) => {
			there = assets.contains("${row.hash}.tar.zst")
			match withdrawn {
				Err(None) => if (there) Err(NoChange) else Ok({ log_index: row.log_index, to: Ok("asset-replaced") })
				Ok("repo-missing") => Err(NoChange)
				Ok(_) => if (there and candidate) Ok({ log_index: row.log_index, to: Err(Clear) }) else Err(NoChange)
			}
		}
	}

	## R-PU13, Design Q334: what the job does for a release with no package asset at the attempt `attempts` (the first delivery is attempt 1). Attempts 1 to 4: `Retry(ms)`, the delay of `retry_delay_ms`.
	## Attempt 5 and later: `Done` (the consumer acks the message and writes the info line `index job no asset`, no dead letter queue).
	after_no_asset : U32 -> [Retry(U64), Done]
	after_no_asset = |attempts| match retry_delay_ms(attempts) {
		Ok(ms) => Retry(ms)
		Err(GiveUp) => Done
	}
}
