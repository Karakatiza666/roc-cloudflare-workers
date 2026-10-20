## WebSockets (MODULES.md 12.1, 12.2, PLAN.md 8f part 3). The class `Room` (the hibernation API) and the Worker routes:
## `/websocket/room/<name>?user=<u>` gives an upgrade request to the object `<name>` (426 with no `Upgrade`),
## `/websocket/room_admin/<name>?op=<op>` sends one plain request to it, `/websocket/echo` is a Worker that answers each
## message (`accept!`, `respond!`, `receive!`), and the client routes connect to the echo server of `checks/websocket.mjs`.
import pf.Request
import pf.Response
import pf.Object
import pf.WebSocket
import pf.Io
import pf.Time
import pf.Log
import Q

## The attachment of a socket of `Room`: kept while the object sleeps.
User : { name : Str }

user_slot : Object.Attachment(User)
user_slot = Object.attachment("user")

## A richer attachment, and a slot of another type over the same socket attachment (MODULES.md 12.1).
Prefs : { name : Str, n : U64, tags : List(Str), on : Bool, score : I64 }

prefs_slot : Object.Attachment(Prefs)
prefs_slot = Object.attachment("prefs")

count_slot : Object.Attachment(U64)
count_slot = Object.attachment("count")

## The constructor runs of the object (`init!`), and the messages that reached `web_socket_message!`.
starts : Object.Cell(U64)
starts = Object.cell("starts")

events : Object.Cell(U64)
events = Object.cell("events")

WebSocketRoutes :: [].{

	room_class : Object.Class
	room_class = Object.class("Room", { init!: room_init!, fetch!: room_fetch!, web_socket_message!: room_message!, web_socket_close!: room_close!, web_socket_error!: room_error! })

	classes : List(Object.Class)
	classes = [room_class]

	rooms : Object.Namespace
	rooms = Object.namespace("ROOMS", { class: room_class })

	route! : Request, List(Str) => Response
	route! = |req, path| match path {
		# MODULES.md 12.1, "The Worker": the upgrade request to the object, and its 101 response with no change.
		["room", name] =>
			if WebSocket.is_upgrade(req) {
				match rooms.named(name).fetch!(req) {
					Ok(res) => res
					Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
				}
			} else {
				Response.from_status(426)
			}
		# A plain request to the object, `op` in the query. `tags`: an upgrade request with 11 tags.
		["room_admin", name] => {
			op = Q.text(req, "op")
			base = Request.get("http://o/?op=${op}")
			to_object = if (op == "tags") base.with_header("Upgrade", "websocket") else base
			match rooms.named(name).fetch!(to_object) {
				Ok(res) => Response.from_text(200, res.text!() ?? "status ${res.status().to_str()}")
				Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
			}
		}
		# MODULES.md 12.2: a Worker that answers each message for the life of the socket.
		["echo"] => echo!(req)
		# `accept!` of a request with no `Upgrade`.
		["plain"] => Response.from_text(200, Str.inspect(WebSocket.accept!(req).map_ok(|_| {})))
		# A client: `connect!`, `send!`, `receive!`, `close!`.
		["client"] => {
			got = match WebSocket.connect!(Q.text(req, "url")) {
				Ok(ws) => {
					sent = ws.send!(Text("hi"))
					reply = ws.receive!()
					ws.close!(1000, "done")
					"sent=${Str.inspect(sent)} got=${Str.inspect(reply)}"
				}
				Err(e) => "Err ${Str.inspect(e)}"
			}
			Response.from_text(200, got)
		}
		# The twins `connect`, `receive`, and `connect_with!` with a protocol and a header, `send_json!`, `Message.json`.
		["client_io"] => {
			got = match Io.run!(WebSocket.connect(Q.text(req, "url"))) {
				Ok(ws) => {
					_ = ws.send!(Text("twin"))
					reply = Io.run!(ws.receive())
					ws.close!(1000, "done")
					"got=${Str.inspect(reply)}"
				}
				Err(e) => "Err ${Str.inspect(e)}"
			}
			Response.from_text(200, got)
		}
		["client_with"] => {
			got = match WebSocket.connect_with!(Q.text(req, "url"), { protocols: ["chat", "v2"], headers: [{ name: "x-test", value: "yes" }] }) {
				Ok(ws) => {
					_ = ws.send!(Text("info"))
					info = ws.receive!()
					_ = ws.send_json!({ n: 5.U64 })
					json = ws.receive!()
					_ = ws.send!(Text("give json"))
					parsed : Try({ n : U64 }, _)
					parsed = match ws.receive!() {
						Ok(msg) => msg.json()
						Err(e) => Err(BadData(Str.inspect(e)))
					}
					_ = ws.send!(Bytes([0, 1, 255]))
					bytes = ws.receive!()
					ws.close!(1000, "done")
					"info=${Str.inspect(info)} json=${Str.inspect(json)} parsed=${Str.inspect(parsed)} bytes=${Str.inspect(bytes)}"
				}
				Err(e) => "Err ${Str.inspect(e)}"
			}
			Response.from_text(200, got)
		}
		# `Io.race!` of `receive` and `Time.sleep(50)`, the message sent at 100 ms: the sleep wins, and the next `receive!`
		# gets the message (OP8). The next read has a timeout of 1 s.
		["race"] => {
			got = match WebSocket.connect!(Q.text(req, "url")) {
				Ok(ws) => {
					_ = ws.send!(Text("delay 100 m"))
					first = Io.race!([ws.receive().map(|m| Got(m)), Time.sleep(50).map(|_| TimedOut)])
					next = Io.race!([ws.receive().map(|m| Got(m)), Time.sleep(1_000).map(|_| TimedOut)])
					ws.close!(1000, "done")
					"first=${first.index.to_str()} ${Str.inspect(first.result)} next=${Str.inspect(next.result)}"
				}
				Err(e) => "Err ${Str.inspect(e)}"
			}
			Response.from_text(200, got)
		}
		# `Io.timeout`: the same as "race" with `receive().timeout(ms).run!()`.
		["timeout"] => {
			got = match WebSocket.connect!(Q.text(req, "url")) {
				Ok(ws) => {
					_ = ws.send!(Text("delay 100 m"))
					first = ws.receive().timeout(50).run!()
					next = ws.receive().timeout(1_000).run!()
					ws.close!(1000, "done")
					"first=${Str.inspect(first)} next=${Str.inspect(next)}"
				}
				Err(e) => "Err ${Str.inspect(e)}"
			}
			Response.from_text(200, got)
		}
		# `Io.timeout` that does not fire: the message comes at once, the sleep of 5 s is aborted (the task is short).
		["timeout_ok"] => {
			got = match WebSocket.connect!(Q.text(req, "url")) {
				Ok(ws) => {
					_ = ws.send!(Text("m"))
					first = ws.receive().timeout(5_000).run!()
					ws.close!(1000, "done")
					"first=${Str.inspect(first)}"
				}
				Err(e) => "Err ${Str.inspect(e)}"
			}
			Response.from_text(200, got)
		}
		# `send_json!` of a `NaN`: `BadData`, and no frame goes out (the next reply is for the text after it).
		["send_json_nan"] => {
			got = match WebSocket.connect!(Q.text(req, "url")) {
				Ok(ws) => {
					bad = ws.send_json!({ r: 0.0.F64 / 0.0.F64 })
					good = ws.send_json!({ r: 0.5.F64 })
					first = ws.receive!()
					_ = ws.send!(Text("after"))
					second = ws.receive!()
					ws.close!(1000, "done")
					"bad=${Str.inspect(bad)} good=${Str.inspect(good)} first=${Str.inspect(first)} second=${Str.inspect(second)}"
				}
				Err(e) => "Err ${Str.inspect(e)}"
			}
			Response.from_text(200, got)
		}
		# OP8, the same turn: the message at 100 ms is in the queue. A race of a branch with no wait (it wins) and `receive`:
		# `receive` takes the message in the same turn as the end of the race, and gives it back.
		["race_ready"] => {
			got = match WebSocket.connect!(Q.text(req, "url")) {
				Ok(ws) => {
					_ = ws.send!(Text("delay 100 m"))
					first = Io.race!([ws.receive().map(|m| Got(m)), Time.sleep(50).map(|_| TimedOut)])
					Time.sleep!(300)
					second = Io.race!([Io.sync([Get(Root("signal"), "aborted")], |_| Ok(Now)), ws.receive().map(|m| Got(m))])
					next = Io.race!([ws.receive().map(|m| Got(m)), Time.sleep(1_000).map(|_| TimedOut)])
					ws.close!(1000, "done")
					"first=${first.index.to_str()} second=${second.index.to_str()} next=${Str.inspect(next.result)}"
				}
				Err(e) => "Err ${Str.inspect(e)}"
			}
			Response.from_text(200, got)
		}
		# A wait on a socket has no deadline (API.md 10.2): the answer comes after 2 s, the deadline of a wait is 1 s in the
		# Miniflare of the check (`taskDeadlineMs`).
		["slow"] => {
			got = match WebSocket.connect!(Q.text(req, "url")) {
				Ok(ws) => {
					_ = ws.send!(Text("delay 2000 s"))
					reply = ws.receive!()
					ws.close!(1000, "done")
					Str.inspect(reply)
				}
				Err(e) => "Err ${Str.inspect(e)}"
			}
			Response.from_text(200, got)
		}
		_ => Response.from_text(404, "no route")
	}
}

## MODULES.md 12.2: `accept!`, its response with `after`: `receive!` until the close. "close" closes the socket from the Worker.
echo! : Request => Response
echo! = |req| match WebSocket.accept!(req) {
	Ok({ socket, response }) => {
		work! = || {
			closed = serve!(socket)
			Log.info!("echo closed", closed)
			Ok({})
		}
		response.after(work!)
	}
	Err(NotUpgrade) => Response.from_status(426)
}

## One message, one answer, until the close. "close": the Worker closes the socket.
serve! : WebSocket => WebSocket.Closed
serve! = |socket| match socket.receive!() {
	Ok(Text("close")) => {
		socket.close!(1000, "bye")
		serve!(socket)
	}
	# "sleep <ms>": a wait that is not on the socket, then "slept" (the deadline of the task after `respond!`).
	Ok(Text(t)) if t.starts_with("sleep ") => {
		Time.sleep!(U64.from_str(t.drop_prefix("sleep ")) ?? 0)
		_ = socket.send!(Text("slept"))
		serve!(socket)
	}
	Ok(Text(t)) => {
		_ = socket.send!(Text("echo ${t}"))
		serve!(socket)
	}
	Ok(Bytes(b)) => {
		_ = socket.send!(Bytes(b))
		serve!(socket)
	}
	Err(Closed(c)) => c
}

room_init! : Object.Self => Try({}, [StorageErr(Io.Thrown)])
room_init! = |self| starts.set!(self, (starts.get!(self) ?? 0) + 1)

## `op=join` (the default): `accept_with!` with the tags `room` and the user, and the user as the attachment.
room_fetch! : Object.Self, Request => Try(Response, [StorageErr(Io.Thrown)])
room_fetch! = |self, req| match Q.text(req, "op") {
	"auto" => answer(Str.inspect(self.set_auto_response!({ request: "ping", response: "pong" })))
	"noauto" => {
		self.clear_auto_response!()
		answer("cleared")
	}
	"plain" => answer(Str.inspect(self.accept!(req).map_ok(|_| {})))
	"tags" => answer(Str.inspect(self.accept_with!(req, { tags: ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k"] }).map_ok(|_| {})))
	_ => {
		user = Q.text(req, "user")
		match self.accept_with!(req, { tags: ["room", user] }) {
			Ok({ socket, response }) => {
				attached = if (Q.text(req, "noattach") == "1") Ok({}) else user_slot.set!(socket, { name: user })
				if (attached.is_ok()) Ok(response) else answer("attach! gave ${Str.inspect(attached)}")
			}
			Err(e) => answer(Str.inspect(e))
		}
	}
}

answer : Str -> Try(Response, e)
answer = |t| Ok(Response.from_text(200, t))

## "info": the state that the socket sees. "json": `send_json!`. Bytes: the bytes back, reversed. Each other text goes
## to each other socket of the room (not to the sender: `peer != socket`).
room_message! : Object.Self, Object.Socket, WebSocket.Message => Try({}, [StorageErr(Io.Thrown)])
room_message! = |self, socket, msg| {
	n = (events.get!(self) ?? 0) + 1
	events.set!(self, n)?
	user : Try(User, _)
	user = user_slot.get!(socket)
	name = match user {
		Ok(u) => u.name
		Err(e) => Str.inspect(e)
	}
	match msg {
		Text("info") => {
			peers = self.sockets!().len()
			tagged = self.sockets_with!({ tag: name }).len()
			text = "user=${name} starts=${(starts.get!(self) ?? 0).to_str()} events=${n.to_str()} tags=${Str.join_with(socket.tags!(), ",")} auto=${Str.inspect(socket.auto_response_ms!().is_ok())} peers=${peers.to_str()} tagged=${tagged.to_str()}"
			_ = socket.send!(Text(text))
			{}
		}
		Text("bcast") => {
			sent = self.broadcast_with!({}, Text("all from ${name}"))
			_ = socket.send!(Text("sent=${sent.to_str()}"))
			{}
		}
		# Closes the sockets with the tag `victim` and broadcasts at once: a closed socket is still in `sockets!` until the
		# client answers the close, and its `send!` is `Err(Closed)`, so it is not in the count.
		Text("bcast_closed") => {
			for victim in self.sockets_with!({ tag: "victim" }) {
				victim.close!(1000, "victim")
			}
			sent = self.broadcast_with!({}, Text("closed from ${name}"))
			_ = socket.send!(Text("sent=${sent.to_str()}"))
			{}
		}
		# N11: `broadcast!` gives `{}`, `broadcast_json!` sends JSON text, a NaN is `BadData` and nothing is sent.
		Text("bcast_plain") => {
			done = self.broadcast!(Text("plain from ${name}"))
			_ = socket.send!(Text("done=${Str.inspect(done)}"))
			{}
		}
		Text("bcast_json") => {
			done = self.broadcast_json!({ from: name })
			_ = socket.send!(Text("done=${Str.inspect(done)}"))
			{}
		}
		Text("bcast_json_tag") => {
			sent = self.broadcast_json_with!({ tag: name }, { from: name })
			_ = socket.send!(Text("sent=${Str.inspect(sent)}"))
			{}
		}
		Text("bcast_json_nan") => {
			one = self.broadcast_json!({ r: 0.0.F64 / 0.0.F64 })
			two = self.broadcast_json_with!({ tag: name }, { r: 0.0.F64 / 0.0.F64 })
			_ = socket.send!(Text("one=${Str.inspect(one)} two=${Str.inspect(two)}"))
			{}
		}
		Text("bcast_tag") => {
			sent = self.broadcast_with!({ tag: name }, Text("tag from ${name}"))
			_ = socket.send!(Text("sent=${sent.to_str()}"))
			{}
		}
		# The typed attachment: before any `set!`, a read as another type, and a round trip of a record.
		Text("att_before") => {
			_ = socket.send!(Text(Str.inspect(prefs_slot.get!(socket))))
			{}
		}
		Text("att_wrong") => {
			as_count : Try(U64, _)
			as_count = count_slot.get!(socket)
			_ = socket.send!(Text(Str.inspect(as_count)))
			{}
		}
		Text("att_round") => {
			want : Prefs
			want = { name: "ann", n: 1_152_921_504_606_846_976, tags: ["a", "b"], on: Bool.True, score: -7 }
			set = prefs_slot.set!(socket, want)
			got : Try(Prefs, _)
			got = prefs_slot.get!(socket)
			_ = socket.send!(Text("set=${Str.inspect(set)} same=${Str.inspect(got == Ok(want))}"))
			{}
		}
		Text("json") => {
			_ = socket.send_json!({ user: name, n })
			{}
		}
		Text("json_nan") => {
			bad = socket.send_json!({ r: 0.0.F64 / 0.0.F64 })
			_ = socket.send!(Text("bad=${Str.inspect(bad)}"))
			{}
		}
		Text(t) =>
			for peer in self.sockets!() {
				if peer != socket {
					_ = peer.send!(Text("${name}: ${t}"))
					{}
				}
			}
		Bytes(b) => {
			_ = socket.send!(Bytes(b.rev()))
			{}
		}
	}
	Ok({})
}

room_close! : Object.Self, Object.Socket, WebSocket.Closed => Try({}, [StorageErr(Io.Thrown)])
room_close! = |_self, socket, closed| {
	Log.info!("room close", closed)
	socket.close!(closed.code, closed.reason)
	Ok({})
}

room_error! : Object.Self, Object.Socket, Io.Thrown => Try({}, [StorageErr(Io.Thrown)])
room_error! = |_self, _socket, thrown| {
	Log.warn!("room error", thrown)
	Ok({})
}
