## `Email` (MODULES.md 13, PLAN.md 8f). `handle!` is the `email!` of the app: it reads the address that got the mail (`to`) and
## does what that address says. `checks/email.mjs` sends a mail to `/cdn-cgi/local/email` (Miniflare) and reads the answer
## (`forwards`, `replies`, `rejectReason`) and the log lines. The producer routes send with the binding `EMAIL`.
import pf.Request
import pf.Response
import pf.Email
import pf.Io
import pf.Log
import pf.Body
import http.Header
import Q

email = Email.binding("EMAIL")

EmailRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| {
		match path {
			["send"] => sent(email.send!({ from: "sender@example.com", to: ["dest@example.com"], subject: Q.text(req, "subject"), text: "hello text", reply_to: "reply@example.com" }))
			["send_io"] => sent(Io.run!(email.send({ from: "sender@example.com", to: ["dest@example.com"], subject: Q.text(req, "subject"), html: "<p>hi</p>", cc: ["cc@example.com"] })))
			["send_raw"] => sent(email.send_raw!({ from: "sender@example.com", to: "dest@example.com", raw: raw_mail(Q.text(req, "subject")) }))
			["send_raw_io"] => sent(Io.run!(email.send_raw({ from: "sender@example.com", to: "dest@example.com", raw: raw_mail(Q.text(req, "subject")) })))
			_ => Response.from_text(404, "no route")
		}
	}

	## The `email!` of the app.
	handle! : Email.Mail => Try({}, _)
	handle! = |mail| match mail.to() {
		"fwd@example.com" => mail.forward!("dest@example.com")
		"fwd-io@example.com" => Io.run!(mail.forward("dest@example.com"))
		"fwd-x@example.com" => mail.forward_with!("dest@example.com", { headers: [Header.{ name: "X-Test", value: "yes" }] })
		"fwd-x-io@example.com" => Io.run!(mail.forward_with("dest@example.com", { headers: [Header.{ name: "X-Test", value: "io" }] }))
		# `header` is case-blind, and a header that is not there is `Missing`.
		"fwd-subject@example.com" => {
			subject = mail.header("SUBJECT") ?? "none"
			missing = match mail.header("x-none") {
				Ok(_) => "has"
				Err(Missing) => "missing"
			}
			mail.forward_with!("dest@example.com", { headers: [Header.{ name: "X-Subject", value: subject }, Header.{ name: "X-None", value: missing }] })
		}
		"reject@example.com" => {
			mail.set_reject!("no thanks")
			Ok({})
		}
		"reject-io@example.com" => {
			_ = Io.run!(mail.set_reject("no thanks io"))
			Ok({})
		}
		"reply@example.com" => mail.reply!(reply_mail(mail))
		"reply-io@example.com" => Io.run!(mail.reply(reply_mail(mail)))
		"err@example.com" => Err(Boom)
		"raw@example.com" => {
			body = mail.raw().text!()?
			Log.info!("mail raw", { size: mail.raw_size_bytes(), chars: body.count_utf8_bytes(), from: mail.from(), can_forward: mail.can_be_forwarded() })
			Ok({})
		}
		_ => Ok({})
	}
}

raw_mail : Str -> Str
raw_mail = |subject| "From: sender@example.com\r\nTo: dest@example.com\r\nSubject: ${subject}\r\nMessage-ID: <raw-${subject}@example.com>\r\nDate: Thu, 15 Oct 2026 10:00:00 +0000\r\nContent-Type: text/plain\r\n\r\nraw body\r\n"

## A reply to the mail of the test: its `Message-ID` is in `In-Reply-To`.
reply_mail : Email.Mail -> Str
reply_mail = |mail| {
	id = mail.header("message-id") ?? "none"
	"From: ${mail.to()}\r\nTo: ${mail.from()}\r\nSubject: Re: reply\r\nMessage-ID: <reply-1@example.com>\r\nIn-Reply-To: ${id}\r\nReferences: ${id}\r\nDate: Thu, 15 Oct 2026 10:00:05 +0000\r\nContent-Type: text/plain\r\n\r\nthe reply\r\n"
}

sent : Try({ message_id : Str }, e) -> Response
sent = |r| Response.from_text(
	200,
	match r {
		Ok(x) => if (x.message_id.is_empty()) "Ok no id" else "Ok id"
		Err(e) => "Err ${Str.inspect(e)}"
	},
)
