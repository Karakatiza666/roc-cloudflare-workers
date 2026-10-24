app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Sql

db = D1.binding("DB")

User : { id : I64, name : Str, big : I64 }

fetch! : Request => Try(Response, _)
fetch! = |req| match (req.method, req.segments()) {
	(GET, ["users"]) => {
		users : List(User)
		users = db.all!("select id, name, big from users", [])?
		Ok(Response.from_json(200, users))
	}
	(POST, ["users", name]) => {
		res = db.run!("insert into users (name) values (?)", [Text(name)])
		match res {
			Ok(info) => {
				id = info.last_row_id ?? 0
				Ok(Response.from_text(201, id.to_str()))
			}
			Err(Constraint({ kind: Unique, message })) => Ok(Response.from_text(409, message))
			Err(e) => Err(e)
		}
	}
	(POST, ["move"]) => {
		results = db.batch!([
			Sql.stmt("update acct set n = n - 1 where id = ?", [Int(1)]),
			Sql.stmt("update acct set n = n + 1 where id = ?", [Int(2)]),
			Sql.stmt("select n from acct where id = ?", [Int(2)]),
		])?
		row : { n : I64 }
		row = match results.last() {
			Ok(r) => r.first()?
			Err(_) => { n: 0 }
		}
		Ok(Response.from_text(200, row.n.to_str()))
	}
	(GET, ["session"]) => {
		after = req.header("x-bookmark")
		s = match after {
			Ok(b) => db.with_session!(After(b))?
			Err(_) => db.with_session!(Any)?
		}
		u : User
		u = s.first!("select id, name, big from users limit 1", [])?
		mark = s.bookmark!() ?? ""
		Ok(Response.from_json(200, u).with_header("x-bookmark", mark))
	}
	(GET, ["pairs"]) => {
		pairs : List((I64, Str))
		pairs = db.all_tuples!("select id, name from users", [])?
		Ok(Response.from_text(200, pairs.len().to_str()))
	}
	(GET, ["raw"]) => {
		r = db.rows!("select * from users", [])?
		Ok(Response.from_text(200, Str.join_with(r.columns, ",")))
	}
	_ => Ok(Response.from_status(404))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
