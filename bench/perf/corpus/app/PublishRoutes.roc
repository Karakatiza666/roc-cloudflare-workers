## The handler of the publish `POST /v1/releases` with `Authorization: Bearer <GitHub OIDC token>` (Registry 4: R-AP8, R-AP26, R-AP41, R-AP46, R-AP48, R-AP71; 7: R-PU1, R-PU2, R-PU5,
## R-PU14 to R-PU16, R-PU19; 7.1: R-TP3, R-TP5, R-TP6, R-TP9, R-TP12, R-TP13, R-TP17; 6: R-MX5; slice 114, `docs/slices/114-publish.md`). The decisions are in `lib/Publish.roc`,
## `lib/Ingest.roc` and `lib/Identity.roc` (pure, W0). This module only orders the effects. The tests are W2: `worker/tests/cases/publish/`.
## `main.roc` calls `post!` only for a request with an `Authorization` header (R-AP26: no header is an ingest, `IngestRoutes.post!`). `Err(Refuse(problem))` is a problem answer,
## `Err(Fault(text))` is 500 `internal` (R-AP48, never a `crash`).
##
## Flow (the order of the slice file section 3.1; the first check that fails gives the answer):
## 1. `req.bytes_with!({ max_bytes: 262144 })` (R-AP46). `Err(TooLarge)`: 413 `too-large`, `field` `body`, as `IngestRoutes`. Another `Err`: the bytes `[]`.
##    `Publish.parse_body`: `Bad(problem)` is `Refuse`; `TooLarge(problem, extra)` is `Ok` of the 413 answer with `Problem.to_json_with`. Then `Ingest.parse_url` on `url`.
##    No D1 call, no JWKS read, no GitHub read before this step is done.
## 2. `Auth.publish!(req, { owner_repo: "<owner>/<repo>" of the URL as sent, tag })`: `Err(problem)` is `Refuse` (401, 403, 502, 500). Then `Publish.claims_ids`: `Err(problem)` is `Refuse` (403).
## 3. One session `db.with_session!(Primary)` for all the D1 calls of the request. D1 call 1, one `batch!`: the label row (as `IngestRoutes.label_sql`, with `has_ingest` for `via` 0)
##    and the `repos` row of the name (`IngestRoutes.repo_sql`). No owner count and no IP limit (R-PU34 is for an ingest).
## 4. `Identity.decide` with the ids of `Publish.claims_ids` as `seen` (R-TP3 row 5, R-TP9): `Err(Changed)` is the answer 403 `repository-changed` with `issues_url` (`Identity.changed_json`,
##    the setting `ISSUES_URL`), no D1 call, no more reads, no `talon-bookmark` (Q267). It comes before the label outcome (a 409 never hides a 403).
## 5. `Publish.after_read`. `Conflict(problem)`: `Refuse` (409). `Answer(release)`: 200 (step 8). `Write(log_index)`: D1 call 2, one batch: the identity statements, the `oidc` provenance row
##    (`Publish.provenance_sql`), the facts (`Publish.facts_sql`, only if the body has facts), and last the label read. 200. No GitHub read. `Index`: step 6.
## 6. GitHub `GET Ingest.release_url(target)`: 404 is `Publish.no_release(tag)`; another status or no answer is 502 (as `IngestRoutes`). `Ingest.parse_release`, then `Publish.candidate`.
##    `Archive.read!(target.url, target.hash)` (as the ingest), then `GET Ingest.roc_version_url(target)` (200 text, 404 `Err(None)`, else 502). There is no `GET /repos/{owner}/{repo}` and
##    no visibility read: the visibility is the claim (R-PU31 "Publish"; checked in `Oidc.check_publish`).
## 7. `Ingest.plan` with `repo` = `{ id: <claim repository_id>, owner_id: <claim repository_owner_id>, public: Bool.True }`. D1 call 2, one batch: the statements of `IngestRoutes.writes_of`
##    with the provenance `via` 0 (`oidc`) and the claims text in place of the ingest row, the identity statements (their events carry the claims text), the facts, and last the label read.
##    `Constraint` errors as the ingest (`Ingest.batch_failure`): `LabelConflict` 409 (`Ingest.label_conflict(target, Err(None))`), `IdCollision` D1 call 3 and 409.
## 8. The answer: as the ingest (`IngestRoutes.answer!`): `Ingest.status_of(<changes of the release statement>)` (200 for steps 5 `Answer` and `Write`), `content-type: application/json`,
##    `cache-control: no-store`, `Ingest.answer_body`, `talon-bookmark`, and `location` for a 201. After a 200 of `Write` and a 201: the cache drop of R-AP69 (`IngestRoutes.dropping`).
import pf.Request
import pf.Response
import pf.Sql
import pf.Time
import lib.Compat
import lib.Ingest
import lib.Problem
import lib.Publish
import lib.Reads
import Auth
import IngestRoutes

PublishRoutes :: [].{

	post! : Request => Try(Response, IngestRoutes.Error)
	post! = |req| {
		bytes = match req.bytes_with!({ max_bytes: IngestRoutes.body_limit }) {
			Ok(b) => b
			Err(TooLarge) => return Ok(too_large)
			Err(BodyErr(_)) => []
		}
		body = match Publish.parse_body(bytes) {
			Ok(parsed) => parsed
			Err(Bad(problem)) => return Err(Refuse(problem))
			Err(TooLarge(problem, extra)) => return Ok(Response.from_bytes(413, "application/problem+json", Problem.to_json_with(problem, extra).to_utf8()))
		}
		target = Ingest.parse_url(body.url).map_err(|p| Refuse(p))?
		claims = Auth.publish!(req, { owner_repo: "${target.owner}/${target.repo}", tag: target.tag }).map_err(|p| Refuse(p))?
		ids = Publish.claims_ids(claims).map_err(|p| Refuse(p))?
		claims_text = Publish.claims_json(claims)
		session = IngestRoutes.db.with_session!(Primary).map_err(IngestRoutes.fault)?
		repo_id = Reads.repo_id(target.owner, target.repo)
		label_stmt = Sql.stmt(IngestRoutes.label_sql_of(0), IngestRoutes.label_params(target))
		first = session.batch!([label_stmt, Sql.stmt(IngestRoutes.repo_sql, [repo_id])]).map_err(IngestRoutes.fault)?
		rows = IngestRoutes.label_rows(first.first().map_err(|_| Fault("the pre-read gave no result"))?.all())?
		old = IngestRoutes.old_row(first, 1, repo_id)?
		now = Time.now_ms!()
		github_repo = { repo: { id: ids.repository_id, owner_id: ids.owner_id, public: Bool.True }, full_name: claims.repository ?? target.name }
		done = match IngestRoutes.identity!(target, repo_id, github_repo, old, now, Ok(claims_text))? {
			Stop(response) => return Ok(response)
			Go(found) => found
		}
		artifact = Reads.artifact_id(target.hash).map_err(|_| Fault("the hash of the asset URL has no artifact id"))?
		form = Reads.form_id(target.form)
		facts = if body.facts.is_empty() {
			[]
		} else {
			[Sql.stmt(Publish.facts_sql(), (Compat.rows_json(Publish.fact_rows(body.facts, artifact)), now, form, target.column.version, target.column.version_text))]
		}
		have = { facts: !body.facts.is_empty(), events: done.has_events }
		match Publish.after_read(target, rows, have).map_err(IngestRoutes.bad_row)? {
			Conflict(problem) => Err(Refuse(problem))
			Answer(release) => IngestRoutes.answer!(session, 200, release)
			Write(_) => {
				provenance = Sql.stmt(Publish.provenance_sql(), (form, target.column.version, target.column.version_text, claims_text, now))
				stmts = [provenance].concat(done.stmts).concat(facts).append(label_stmt)
				results = session.batch!(stmts).map_err(IngestRoutes.fault)?
				IngestRoutes.dropping(IngestRoutes.answer!(session, 200, IngestRoutes.last_release(results)?), req, target, 200)
			}
			Index => {
				flow = {
					repo: github_repo.repo,
					identity: done.stmts,
					now,
					via: 0,
					claims: Ok(claims_text),
					extra: facts,
					candidate: Publish.candidate,
					no_release: Publish.no_release,
				}
				IngestRoutes.dropping(IngestRoutes.index!(session, target, flow), req, target, 201)
			}
		}
	}

	## R-AP46: the 413 of a body that is larger than the limit.
	too_large : Response
	too_large = {
		problem = Problem.new(TooLarge, "the body of the publish request is larger than its limit of ${IngestRoutes.body_limit.to_str()}")
		Response.from_bytes(413, "application/problem+json", Problem.to_json_with(problem, { field: "body", limit: IngestRoutes.body_limit }).to_utf8())
	}
}
