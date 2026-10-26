app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.0.1-local/GnYy1F5XF9RLTy8MJiT5Bsr5W1AfKXitGUXPAbbKK4As.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.D1
import pf.Sql
import pf.Id64

db = D1.binding("DB")

User : { id : I64, name : Str, avatar : List(U8) }

list_users! : () => Try(List(User), _)
list_users! = || {
	users : List(User)
	users = db.all!("SELECT id, name, avatar FROM users", Sql.none)?
	Ok(users)
}

Event : { id : Id64, kind : Str }

events! : () => Try(List(Event), _)
events! = || {
	events : List(Event)
	events = db.all!("SELECT CAST(id AS TEXT) AS id, kind FROM events", Sql.none)?
	Ok(events)
}

add_user! : Str, Try(List(U8), [NoAvatar]) => Try(I64, _)
add_user! = |name, avatar| {
	info = db.run!("INSERT INTO users (name, avatar) VALUES (?, ?)", (name, Sql.or_null(avatar.map_ok(Sql.blob))))?
	info.last_row_id.map_err(|Rounded| Infra(BadData("rowid above 2^53")))
}

create! : Str => Try(Response, _)
create! = |name| match add_user!(name, Err(NoAvatar)) {
	Ok(id) => Ok(Response.from_text(201, id.to_str()))
	Err(Infra(Constraint({ kind: Unique, message }))) => Ok(Response.from_text(409, message))
	Err(Infra(Constraint({ kind: Trigger, message }))) => Ok(Response.from_text(422, message))
	Err(e) => Err(e)
}

transfer! : I64, I64, I64 => Try(I64, _)
transfer! = |from, to, amount| {
	results = db.batch!(
		[
			Sql.stmt("UPDATE acct SET n = n - ? WHERE id = ?", (amount, from)),
			Sql.stmt("UPDATE acct SET n = n + ? WHERE id = ?", (amount, to)),
			Sql.stmt("SELECT n FROM acct WHERE id = ?", [to]),
		],
	)?
	match results {
		[_, _, last] => {
			balance : { n : I64 }
			balance = last.first()?
			Ok(balance.n)
		}
		_ => Err(Infra(BadData("the batch gave no result")))
	}
}

names! : () => Try(List((I64, Str)), _)
names! = || {
	pairs : List((I64, Str))
	pairs = db.all_tuples!("SELECT id, name FROM users", Sql.none)?
	Ok(pairs)
}

session_read! : Request => Try(Response, _)
session_read! = |req| {
	session = match req.header("x-d1-bookmark") {
		Ok(mark) => db.with_session!(After(mark))?
		Err(NotFound) => db.with_session!(Any)?
	}
	user : User
	user = session.first!("SELECT id, name, avatar FROM users LIMIT 1", Sql.none)?
	mark = session.bookmark!() ?? ""
	Ok(Response.from_json(200, { id: user.id, name: user.name }).with_header("x-d1-bookmark", mark))
}

columns! : Str => Try(Response, _)
columns! = |table| {
	raw = db.rows!("SELECT * FROM ${table} LIMIT 1", Sql.none)?
	Ok(Response.from_text(200, Str.join_with(raw.columns, ",")))
}

fetch! : Request => Try(Response, _)
fetch! = |req| match (req.method(), req.segments()) {
	(GET, ["users"]) => {
		users = list_users!()?
		Ok(Response.from_json(200, users.map(|u| { id: u.id, name: u.name })))
	}
	(POST, ["users", name]) => create!(name)
	(POST, ["transfer"]) => {
		n = transfer!(1, 2, 10)?
		Ok(Response.from_text(200, n.to_str()))
	}
	(GET, ["names"]) => {
		pairs = names!()?
		Ok(Response.from_text(200, pairs.len().to_str()))
	}
	(GET, ["events"]) => {
		es = events!()?
		Ok(Response.from_json(200, es.map(|e| { id: e.id.to_web(), kind: e.kind })))
	}
	(GET, ["session"]) => session_read!(req)
	(GET, ["columns", table]) => columns!(table)
	_ => Ok(Response.from_status(404))
}

worker = Worker.new({ fetch!: fetch!, bindings: [db.declare()] })

event! = |e| worker.event!(e)
