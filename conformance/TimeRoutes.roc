## `Time` (MODULES.md 11). `worker.js` gives the waits of each task (`x-waits`) and its time (`x-ms`).
import pf.Request
import pf.Response
import pf.Time
import pf.Io
import Q

TimeRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| match path {
		["now"] => ok(Time.now_ms!({}).to_str())
		["sleep"] => {
			Time.sleep!(Q.num(req, "ms"))
			ok("slept")
		}
		["sleep_io"] => {
			got : Try({}, [])
			got = Io.run!(Time.sleep(Q.num(req, "ms")))
			ok(Str.inspect(got))
		}
		# A timeout is a race with a sleep (API.md 6.5): the shorter sleep wins, the other is aborted.
		["race"] => {
			r = Io.race!([Time.sleep(500).map(|_| Slow), Time.sleep(50).map(|_| Fast)])
			got : Try([Slow, Fast], [])
			got = r.result
			ok("index=${r.index.to_str()} ${Str.inspect(got)}")
		}
		_ => Response.from_text(404, "no route")
	}
}

ok : Str -> Response
ok = |text| Response.from_text(200, text)
