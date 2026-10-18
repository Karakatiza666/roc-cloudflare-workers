## Email (MODULES.md 13): the `send_email` binding (`send!`, `send_raw!`), and the functions of an incoming mail, the
## payload of the event `Email` (API.md 10.1). An incoming mail is plain data (MC13): the functions of `Mail` reach the
## message of the task through the root `event`, so a `Mail` holds no ref. Each error is `EmailErr(Thrown)`.
import Io
import Js
import Body
import http.Header

Email :: { name : Str }.{

	## A constant made from the name of the binding in the Wrangler config (MC1).
	binding : Str -> Email
	binding = |name| Email.{ name }

	## The binding for the manifest (`Worker.new({ bindings: [...] })`, MODULES.md 3): the kind `email`.
	declare : Email -> { name : Str, kind : Str, props : List((Str, Str)) }
	declare = |b| { name: b.name, kind: "email", props: [] }

	## The structured send of the docs: `env[name].send({ from, to, subject, text, html, cc, bcc, replyTo })`.
	## Gives the `messageId` that Workers made. One wait.
	send : Email, { from : Str, to : List(Str), subject : Str, text ?: Str, html ?: Str, cc ?: List(Str), bcc ?: List(Str), reply_to ?: Str } -> Io({ message_id : Str }, [EmailErr(Io.Thrown)])
	send = |email, msg| {
		required = [("from", Text(msg.from)), ("to", texts(msg.to)), ("subject", Text(msg.subject))]
		optional = [
			msg.?text.map_ok(|s| ("text", Text(s))),
			msg.?html.map_ok(|s| ("html", Text(s))),
			msg.?cc.map_ok(|l| ("cc", texts(l))),
			msg.?bcc.map_ok(|l| ("bcc", texts(l))),
			msg.?reply_to.map_ok(|s| ("replyTo", Text(s))),
		].keep_oks(|r| r)
		Io.new(
			[Get(Root("env"), email.name), Call(Slot(0), "send", [Lit(Obj(required.concat(optional)))])],
			sent,
		)
	}

	send! : Email, { from : Str, to : List(Str), subject : Str, text ?: Str, html ?: Str, cc ?: List(Str), bcc ?: List(Str), reply_to ?: Str } => Try({ message_id : Str }, [EmailErr(Io.Thrown)])
	send! = |email, msg| Io.run!(email.send(msg))

	## `send(new EmailMessage(from, to, raw))`: `raw` is a MIME message as text. The `EmailMessage` class is made by
	## `pf.emailMessage` (`cloudflare:email`).
	send_raw : Email, { from : Str, to : Str, raw : Str } -> Io({ message_id : Str }, [EmailErr(Io.Thrown)])
	send_raw = |email, msg| Io.new(
		[
			Get(Root("env"), email.name),
			Call(Root("pf"), "emailMessage", [Lit(Text(msg.from)), Lit(Text(msg.to)), Lit(Text(msg.raw))]),
			Call(Slot(0), "send", [Slot(1)]),
		],
		sent,
	)

	send_raw! : Email, { from : Str, to : Str, raw : Str } => Try({ message_id : Str }, [EmailErr(Io.Thrown)])
	send_raw! = |email, msg| Io.run!(email.send_raw(msg))

	## An incoming mail. `raw` is a stream (`Body.Stream`), read once (RS3). `raw_size_bytes` is `rawSize` (MC10).
	## `can_be_forwarded`: `canBeForwarded` of the message, true when the runtime does not give it.
	Mail := { from : Str, to : Str, headers : List(Header), raw : Body, raw_size_bytes : U64, can_be_forwarded : Bool }.{

		## The first header with this name (the case does not matter), or `Missing`.
		header : Email.Mail, Str -> Try(Str, [Missing])
		header = |mail, name| {
			match mail.headers.find_first(|h| h.name.caseless_ascii_equals(name)) {
				Ok(h) => Ok(h.value)
				Err(_) => Err(Missing)
			}
		}

		## `message.forward(to)`: to a verified destination address. One wait.
		forward : Email.Mail, Str -> Io({}, [EmailErr(Io.Thrown)])
		forward = |_mail, to| Io.new([Call(Root("event"), "forward", [Lit(Text(to))])], unit)

		forward! : Email.Mail, Str => Try({}, [EmailErr(Io.Thrown)])
		forward! = |mail, to| Io.run!(mail.forward(to))

		## `message.forward(to, headers)`. Workers keeps only the headers that start with `X-`.
		forward_with : Email.Mail, Str, { headers ?: List(Header) } -> Io({}, [EmailErr(Io.Thrown)])
		forward_with = |_mail, to, opts| {
			headers = opts.?headers ?? []
			Io.new(
				[
					New(Root("global"), "Headers", [Lit(Arr(headers.map(|h| Arr([Text(h.name), Text(h.value)]))))]),
					Call(Root("event"), "forward", [Lit(Text(to)), Slot(0)]),
				],
				unit,
			)
		}

		forward_with! : Email.Mail, Str, { headers ?: List(Header) } => Try({}, [EmailErr(Io.Thrown)])
		forward_with! = |mail, to, opts| Io.run!(mail.forward_with(to, opts))

		## `message.reply(new EmailMessage(to, from, raw))`: `raw` is the MIME message of the reply, as text. It goes from
		## the address that got the mail to the sender.
		reply : Email.Mail, Str -> Io({}, [EmailErr(Io.Thrown)])
		reply = |mail, raw| Io.new(
			[
				Call(Root("pf"), "emailMessage", [Lit(Text(mail.to)), Lit(Text(mail.from)), Lit(Text(raw))]),
				Call(Root("event"), "reply", [Slot(0)]),
			],
			unit,
		)

		reply! : Email.Mail, Str => Try({}, [EmailErr(Io.Thrown)])
		reply! = |mail, raw| Io.run!(mail.reply(raw))

		## `message.setReject(reason)`: the mail is rejected with this text. Workers gives no result, and the local
		## runtime answers through a stub, so the call waits (`await!`). A throw is dropped: there is no `Try`.
		set_reject : Email.Mail, Str -> Io({}, e)
		set_reject = |_mail, reason| Io.new([Call(Root("event"), "setReject", [Lit(Text(reason))])], |_| Ok({}))

		set_reject! : Email.Mail, Str => {}
		set_reject! = |mail, reason| {
			_ = Io.run!(mail.set_reject(reason))
			{}
		}
	}
}

texts : List(Str) -> Js
texts = |l| Arr(l.map(|s| Text(s)))

unit : Try(Js, Io.Thrown) -> Try({}, [EmailErr(Io.Thrown)])
unit = |r| match r {
	Ok(_) => Ok({})
	Err(t) => Err(EmailErr(t))
}

## `{ messageId }` of `send`. A runtime that gives no result has an empty id.
sent : Try(Js, Io.Thrown) -> Try({ message_id : Str }, [EmailErr(Io.Thrown)])
sent = |r| match r {
	Ok(Obj(fields)) => match fields.find_first(|(k, _)| k == "messageId") {
		Ok((_, Text(id))) => Ok({ message_id: id })
		_ => Ok({ message_id: "" })
	}
	Ok(_) => Ok({ message_id: "" })
	Err(t) => Err(EmailErr(t))
}

mail : Email.Mail
mail = Email.Mail.{
	from: "a@example.com",
	to: "b@example.com",
	headers: [Header.{ name: "Subject", value: "hi" }, Header.{ name: "X-Test", value: "1" }],
	raw: Empty,
	raw_size_bytes: 0,
	can_be_forwarded: Bool.True,
}

expect mail.header("subject") == Ok("hi")
expect mail.header("X-TEST") == Ok("1")
expect mail.header("x-none") == Err(Missing)
expect sent(Ok(Obj([("messageId", Text("m1"))]))) == Ok({ message_id: "m1" })
expect sent(Ok(Undefined)) == Ok({ message_id: "" })
