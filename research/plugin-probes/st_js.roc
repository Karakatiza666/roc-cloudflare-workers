app [event!] { pf: platform "https://github.com/Karakatiza666/roc-cloudflare-workers/releases/download/0.1.0-dev/4vFZE8Vb1ANUpnYtLYLaJWRyJ99b8k7ewXVsZQvVmqbc.tar.zst" }

import pf.Worker
import pf.Request
import pf.Response
import pf.Io
import pf.Js
import pf.Ctx

# Browser Rendering binding has no module: env.BROWSER.fetch(url) gives a Response, then .status.
status_of : Str -> Io(I64, [BrowserErr(Io.Thrown), BadData(Str)])
status_of = |url| Io.new(
	[
		Get(Root("env"), "BROWSER"),
		Call(Slot(0), "fetch", [Lit(Text(url))]),
		Get(Slot(1), "status"),
	],
	|result| match result {
		Ok(Int(n)) => Ok(n)
		Ok(other) => Err(BadData(Str.inspect(other)))
		Err(thrown) => Err(BrowserErr(thrown))
	},
)

now_iso : Io(Str, [JsErr(Io.Thrown), BadData(Str)])
now_iso = Io.sync(
	[New(Root("global"), "Date", []), Call(Slot(0), "toISOString", [])],
	|result| match result {
		Ok(Text(s)) => Ok(s)
		Ok(other) => Err(BadData(Str.inspect(other)))
		Err(t) => Err(JsErr(t))
	},
)

slugify : Str -> Io(Str, [OpsErr(Io.Thrown), BadData(Str)])
slugify = |s| Io.new(
	[Call(Root("ops"), "slugify", [Lit(Text(s))])],
	|result| match result {
		Ok(Text(out)) => Ok(out)
		Ok(other) => Err(BadData(Str.inspect(other)))
		Err(t) => Err(OpsErr(t))
	},
)

fetch! : Request => Try(Response, _)
fetch! = |_req| {
	n = Io.run!(status_of("https://example.com"))?
	t = Io.run!(now_iso)?
	slug = slugify("Hello World").run!()?
	_ref = Io.start!(status_of("https://example.com/ping"))
	Ctx.wait_until!(status_of("https://example.com/ping2"))
	Ok(Response.from_text(200, "${n.to_str()} ${t} ${slug}"))
}

worker = Worker.{ fetch! }

event! = |e| worker.event!(e)
