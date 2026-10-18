## `Http` (MODULES.md 4, PLAN.md 8c, 8d). `?url=` is the URL to fetch (the local server of `run.mjs`, or a URL that fails).
## Each route answers the status and the body of the response, or the error as `<Tag> <name>: <message>`.
import pf.Request
import pf.Response
import pf.Http
import pf.Io
import pf.Time
import Q

HttpRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| {
		url = Q.text(req, "url")
		match path {
			["send"] => show!(Http.send!(Request.get(url)))
			["send_io"] => show!(Io.run!(Http.send(Request.get(url))))
			["send_with"] => show!(Http.send_with!(Request.get(url), { max_bytes: Q.num(req, "max") }))
			["send_with_io"] => show!(Io.run!(Http.send_with(Request.get(url), { max_bytes: Q.num(req, "max") })))
			["timeout"] => show!(Http.send_with!(Request.get(url), { timeout_ms: Q.num(req, "ms") }))
			["post"] => {
				out = Request.post(url, Bytes("a body".to_utf8())).with_header("x-test", "yes")
				show!(Http.send!(out))
			}
			# `Request.post_json` is a `Try`: a `NaN` is `BadData` and nothing is sent.
			["post_json"] => match Request.post_json(url, { name: Q.text(req, "v"), r: if Q.text(req, "v") == "nan" 0.0.F64 / 0.0.F64 else 0.5.F64 }) {
				Ok(out) => show!(Http.send!(out))
				Err(BadData(m)) => Response.from_text(200, "BadData ${m}")
			}
			["open"] => show_open!(Http.open!(Request.get(url)))
			["open_io"] => show_open!(Io.run!(Http.open(Request.get(url))))
			# `Http.cloudflare_error` of the response of `send!` (a body of bytes), or of `open!` (a stream, `open=1`).
			["cf_error"] => {
				got = if Q.text(req, "open") == "1" Http.open!(Request.get(url)).map_err(|_| Failed) else Http.send!(Request.get(url)).map_err(|_| Failed)
				match got {
					Ok(res) => Response.from_text(200, Str.inspect(Http.cloudflare_error(res)))
					Err(Failed) => Response.from_text(200, "request failed")
				}
			}
			# A body of text, built here: `Text` is the other body that `cloudflare_error` reads.
			["cf_error_text"] => Response.from_text(200, Str.inspect(Http.cloudflare_error(Response.from_status(Q.num(req, "status").to_u16_try() ?? 0).with_body(Text(Q.text(req, "body"))))))
			["get"] => show!(Http.get!(url))
			["get_io"] => show!(Io.run!(Http.get(url)))
			# The errors of `Http` join the errors of another module in one crossing (API.md 6.5).
			["both"] => match Io.both!(Http.get(url), Time.sleep(10)) {
				Ok((res, {})) => show!(Ok(res))
				Err(e) => show!(Err(e))
			}
			_ => Response.from_text(404, "no route")
		}
	}
}

## `send!` read the body in its crossing: `text!` here has no wait.
show! : Try(Response, [Network(Io.Thrown), HttpErr(Io.Thrown), TooLarge]) => Response
show! = |r| match r {
	Ok(res) => match res.text!() {
		Ok(text) => Response.from_text(200, "${res.status().to_str()} ${text}")
		Err(e) => Response.from_text(200, "body ${Str.inspect(e)}")
	}
	Err(e) => Response.from_text(200, error(e))
}

## `open!` keeps a stream: `text!` is one more wait.
show_open! : Try(Response, [Network(Io.Thrown), HttpErr(Io.Thrown)]) => Response
show_open! = |r| match r {
	Ok(res) => {
		kind = match res.body() {
			Stream(_) => "stream"
			_ => "not a stream"
		}
		match res.text!() {
			Ok(text) => Response.from_text(200, "${res.status().to_str()} ${kind} ${text}")
			Err(e) => Response.from_text(200, "body ${Str.inspect(e)}")
		}
	}
	Err(Network(t)) => Response.from_text(200, error(Network(t)))
	Err(HttpErr(t)) => Response.from_text(200, error(HttpErr(t)))
}

error : [Network(Io.Thrown), HttpErr(Io.Thrown), TooLarge] -> Str
error = |e| match e {
	Network(t) => "Network ${t.name}: ${t.message}"
	HttpErr(t) => "HttpErr ${t.name}: ${t.message}"
	TooLarge => "TooLarge"
}
