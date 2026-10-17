## The Assets binding (MODULES.md 13): `env[name].fetch(request)`, one wait. The body of the response stays a stream in
## JS (a `Stream` body, MC13), so a response of a large file goes to the client with no copy into wasm (API.md 10a): the
## usual use is `Assets.fetch!(req)` as the response. `res.bytes!()` and `text!()` read it to a limit (MC11).
## The request goes as `fetch(url, init)` with `Remote.fetch`, the program that `Service.fetch!` and `Object` use too (OO3).
import Io
import Request
import Response
import Remote

Assets :: { name : Str }.{
	binding : Str -> Assets
	binding = |name| Assets.{ name }

	## Each status is `Ok` (a 404 is an answer of the assets): only a throw is `AssetsErr`.
	fetch : Assets, Request -> Io(Response, [AssetsErr(Io.Thrown)])
	fetch = |a, req| Remote.fetch([Get(Root("env"), a.name)], 0, req, |t| AssetsErr(t))

	fetch! : Assets, Request => Try(Response, [AssetsErr(Io.Thrown)])
	fetch! = |a, req| Io.run!(fetch(a, req))
}
