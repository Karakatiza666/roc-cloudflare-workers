## The pure part of the publish route `POST /v1/releases` with `Authorization: Bearer <GitHub OIDC token>` (Registry 4: R-AP8, R-AP26, R-AP71; 7: R-PU1, R-PU2, R-PU5, R-PU16;
## 7.1: R-TP3, R-TP5, R-TP6, R-TP17; 6: R-MX5; 5: R-RE3, R-RE9, R-RE15; slice 114, `docs/slices/114-publish.md`). No effect, no platform import.
## The effects (the body read, the token check, the D1 session and its calls, the GitHub reads, the archive read, the clock) are in `worker/PublishRoutes.roc` and `worker/Auth.roc`.
## The rows of the publish that an ingest also writes (names, artifact, deps, leaf, release, `repos`, `repo_checks`, the identity events) use the code of `lib/Ingest.roc`,
## `lib/Identity.roc` and `worker/IngestRoutes.roc`. This module has only what a publish adds: the body with the facts, the ids and the recorded claims of the token, the
## decision after the pre-read, the author facts and the problems.
## The tests are `worker/tests/unit/PublishTest.roc` (W0) and `worker/tests/cases/publish/` (W2).
## The texts of the `detail` of a problem and the form of the recorded claims are proposals (TW24): the slice file section 5.
import records.Code
import records.Id
import records.Release
import records.Compat as Wire
import Compat
import ClosureQuery
import Identity
import Ingest
import Oidc
import Problem
import Reads

Publish :: [].{

	## R-AP71 and R-AP46: the most facts in a publish body (first guess). More: 413 `too-large`, `field` `compat`, `limit` 500.
	fact_limit : U64
	fact_limit = 500

	## One fact of the body after the checks of `parse_body` (R-AP71). `nightly` is the id of the tag (`Id.nightly_id`, R-IK4), `result` the code of the text.
	## The `target` of every fact is `any` (code 0, checked), and the `hash` is the hash of the asset, so neither is a member here.
	Fact : { nightly : I64, result : Code.Result, error_digest : Try(Str, [None]) }

	## A body that passed `parse_body`: the asset URL as sent, and the facts in the order of the body (`compat` missing or `null` is `[]`).
	Post : { url : Str, facts : List(Publish.Fact) }

	## R-AP26, R-AP48 row 6, R-AP51, R-AP71, R-MX5, R-AP46. The checks before the token (the order of the slice file section 3.1 rows 3 to 6). The first that fails gives the problem:
	## 1. The body is not valid: not UTF-8, empty, or `Wire.decode_publish` (`records.Compat`, slice 104f) gives `BadJson(why)`: 400 `bad-request`, `detail`
	##    `the publish request body is not valid: <why>`. `why` is the text of `BadJson`. A `hash` or `source` member of a fact (any value, `null` too, also an escaped key) is in this
	##    step: `why` is `member hash or source is not allowed in a fact`. `compat` missing or `null` is no facts.
	## 2. More than `fact_limit` facts: `TooLarge(problem, { field: "compat", limit: 500 })`, 413 `too-large`, `detail`
	##    `the compat member of the publish request has more than 500 facts`.
	## 3. The values, fact by fact in the order of the body; in a fact `nightly`, then `target`, then `result` (Design Q291): a `nightly` that has no nightly id (`Id.nightly_id`):
	##    400, `detail` `the nightly <nightly> of a fact is not a nightly tag`; a `target` other than `any`: 400, `the target <target> of a fact is not any`; a `result` that is not
	##    `pass`, `fail`, `hang` or `crash` (`Code.result_from_str`): 400, `the result <result> of a fact is not pass, fail, hang or crash`.
	## The URL rules (R-PU34 row 4) are not here: the route calls `Ingest.parse_url` on `url` after this function.
	parse_body : List(U8) -> Try(Publish.Post, ClosureQuery.Reject)
	parse_body = |bytes| {
		text = Str.from_utf8(bytes).map_err(|_| bad_body("it is not UTF-8"))?
		wire = Wire.decode_publish(text).map_err(|BadJson(why)| bad_body(why))?
		wire_facts = wire.compat ?? []
		if wire_facts.len() > fact_limit {
			return Err(TooLarge(Problem.new(TooLarge, "the compat member of the publish request has more than ${fact_limit.to_str()} facts"), { field: "compat", limit: fact_limit }))
		}
		facts = wire_facts.map_try(fact_of)?
		Ok({ url: wire.url, facts })
	}

	bad_body : Str -> ClosureQuery.Reject
	bad_body = |why| Bad(Problem.new(BadRequest, "the publish request body is not valid: ${why}"))

	bad_value : Str -> ClosureQuery.Reject
	bad_value = |detail| Bad(Problem.new(BadRequest, detail))

	## The values of one fact (Design Q291): `nightly`, then `target`, then `result`.
	fact_of : Wire.Fact -> Try(Publish.Fact, ClosureQuery.Reject)
	fact_of = |f| {
		nightly = Id.nightly_id(f.nightly).map_err(|_| bad_value("the nightly ${f.nightly} of a fact is not a nightly tag"))?
		if f.target != "any" {
			return Err(bad_value("the target ${f.target} of a fact is not any"))
		}
		result = Code.result_from_str(f.result).map_err(|_| bad_value("the result ${f.result} of a fact is not pass, fail, hang or crash"))?
		Ok({ nightly, result, error_digest: f.error_digest })
	}

	## R-TP3 row 5 and R-TP9: the ids that the token claims. `repository_id` first, then `repository_owner_id`. A claim that is missing: 403 `forbidden`,
	## `detail` `token claim <name> is missing`. A claim that is not decimal digits (`U64.from_str`): 403 `forbidden`, `detail` `token claim <name> is "<value>", expected a number`.
	## The result is the `seen` of `Identity.decide`.
	claims_ids : Oidc.Claims -> Try(Identity.Ids, Problem)
	claims_ids = |claims| {
		repository_id = id_claim("repository_id", claims.repository_id)?
		owner_id = id_claim("repository_owner_id", claims.repository_owner_id)?
		Ok({ repository_id, owner_id })
	}

	id_claim : Str, Try(Str, [Missing]) -> Try(U64, Problem)
	id_claim = |name, claim| match claim {
		Err(Missing) => Err(Problem.new(Forbidden, "token claim ${name} is missing"))
		Ok(text) => U64.from_str(text).map_err(|_| Problem.new(Forbidden, "token claim ${name} is \"${text}\", expected a number"))
	}

	## R-TP6, R-TP13, R-RE9: the text of the column `claims` of the `oidc` provenance row, and of each `repo_events` row that the token caused. One JSON object with the 8 members
	## `workflow_ref`, `workflow_sha`, `job_workflow_ref`, `event_name`, `run_id`, `run_attempt`, `actor_id`, `runner_environment`, in this order, each a JSON text (`Json.to_str`);
	## a claim that is missing is `null`. No white space. The Worker does not check these claims.
	claims_json : Oidc.Claims -> Str
	claims_json = |claims| {
		members = [
			("workflow_ref", claims.workflow_ref),
			("workflow_sha", claims.workflow_sha),
			("job_workflow_ref", claims.job_workflow_ref),
			("event_name", claims.event_name),
			("run_id", claims.run_id),
			("run_attempt", claims.run_attempt),
			("actor_id", claims.actor_id),
			("runner_environment", claims.runner_environment),
		]
		items = members.map(
			|(name, claim)| {
				value = match claim {
					Ok(text) => Json.to_str(text)
					Err(Missing) => "null"
				}
				"\"${name}\":${value}"
			},
		)
		"{${Str.join_with(items, ",")}}"
	}

	## What to do after D1 call 1 and the identity check (R-PU14, R-PU16, R-PU19, R-AP41). `rows` are the label rows of the pre-read; in a `LabelRow`, `has_ingest` means a `provenance`
	## row with `via` 0 (`oidc`) for a publish (the field name is the one of the ingest). `facts` is true when the body has a fact. `events` is true when the identity decision of
	## R-TP9 has an event (a `bind`, a `transfer`, a `recreate`, a `found`). The first rule that fits:
	## 1. No row: `Index` (the whole flow: release, asset, `.roc-version`, one write batch).
	## 2. The row has another hash: `Conflict(Ingest.label_conflict(target, Ok(<the hash of the row>)))` (409).
	## 3. The row has this hash, an `oidc` row, no fact and no event: `Answer(release)` (200, no write, 1 D1 call).
	## 4. The row has this hash and something to write: `Write(log_index)` (the batch with the identity statements, the `oidc` row, the facts, the label read; 200; no GitHub read).
	## A row that `Reads.release_of_row` refuses is `Err(BadRow(text))`, as `Ingest.after_read`.
	after_read : Ingest.Target, List(Ingest.LabelRow), { facts : Bool, events : Bool } -> Try([Conflict(Problem), Answer(Release.Row), Write(U64), Index], [BadRow(Str)])
	after_read = |target, rows, have| match rows {
		[] => Ok(Index)
		[row, ..] => {
			release = Reads.release_of_row(row.release)?
			if release.hash != target.hash {
				Ok(Conflict(Ingest.label_conflict(target, Ok(release.hash))))
			} else if row.has_ingest and !have.facts and !have.events {
				Ok(Answer(release))
			} else {
				Ok(Write(release.log_index))
			}
		}
	}

	## R-PU6, R-PU16: `Ingest.candidate`, with another text for a draft (the author can fix it): a draft is 422 `not-a-candidate` with `draft(tag)`. The other faults and the
	## result (`published_at` in ms) are those of `Ingest.candidate`.
	candidate : Ingest.Target, Ingest.GithubRelease -> Try(U64, Problem)
	candidate = |target, release| if (release.draft) Err(draft(target.tag)) else Ingest.candidate(target, release)

	## R-PU16: 422 `not-a-candidate`. A draft is not a candidate; the release workflow publishes the GitHub release before `tln publish`.
	draft : Str -> Problem
	draft = |tag| Problem.new(NotACandidate, "the release ${tag} is a draft: publish the GitHub release before tln publish")

	## R-AP8, R-PU16: the release read by tag gives 404. A draft that the Worker cannot read is also a 404, so the text names it.
	no_release : Str -> Problem
	no_release = |tag| Problem.new(NotACandidate, "the repository has no published release with the tag ${tag}: a draft is not published, so publish the GitHub release before tln publish")

	## R-PU5, R-RE3, R-RE13: the `compat` rows of the facts, for `Compat.rows_json` and `facts_sql`. `artifact` is the id of the hash of the asset (`Reads.artifact_id`). `target` is 0
	## (`any`), `result` is `Code.result_code`. The order is the order of the facts.
	fact_rows : List(Publish.Fact), I64 -> List(Compat.PlanRow)
	fact_rows = |facts, artifact| facts.map(|f| { artifact, nightly: f.nightly, target: 0, result: Code.result_code(f.result), error_digest: f.error_digest })

	## R-PU5, R-RE3, R-RE13, R-MX5, Design Q86: the statement that writes the author facts. ?1 is `Compat.rows_json(fact_rows(..))`, ?2 the time in ms (R-RE26, the clock of the request),
	## ?3 the form id, ?4 the version column, ?5 the `version_text` of the label (`Ingest.Target.column`). One `compat` row for each item of ?1 with `source` 1 (`author`) and
	## `log_index` the `log_index` of the release of that label (a subquery on `releases`, so the statement must run after the release statement of the same batch).
	## It ends with `ON CONFLICT DO NOTHING`, never `INSERT OR IGNORE`: the first write of a key wins, and a key that is twice in the list or that an earlier publish wrote
	## changes nothing (R-RE13 row 1, R-AP71).
	facts_sql : () -> Str
	facts_sql = || "INSERT INTO compat (artifact, nightly, target, source, result, error_digest, time, log_index) SELECT json_extract(j.value, '$.artifact'), json_extract(j.value, '$.nightly'), json_extract(j.value, '$.target'), 1, json_extract(j.value, '$.result'), json_extract(j.value, '$.error_digest'), ?2, r.log_index FROM json_each(?1) j, releases r WHERE r.form = ?3 AND r.version = ?4 AND r.version_text = ?5 ON CONFLICT DO NOTHING"

	## R-PU15, R-RE9: the statement that adds the `oidc` provenance row of the label. ?1 the form id, ?2 the version column, ?3 the `version_text`, ?4 the claims text (`claims_json`),
	## ?5 the time in ms. `INSERT INTO provenance (release, via, claims, time) SELECT r.log_index, 0, ?4, ?5 FROM releases r WHERE <label> AND NOT EXISTS (via 0)`.
	provenance_sql : () -> Str
	provenance_sql = || "INSERT INTO provenance (release, via, claims, time) SELECT r.log_index, 0, ?4, ?5 FROM releases r WHERE r.form = ?1 AND r.version = ?2 AND r.version_text = ?3 AND NOT EXISTS (SELECT 1 FROM provenance p WHERE p.release = r.log_index AND p.via = 0)"
}
