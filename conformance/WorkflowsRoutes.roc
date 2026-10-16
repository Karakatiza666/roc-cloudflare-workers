## `Workflows`, the client (MODULES.md 13). `?binding=` is the binding: `FLOW` ends at once and gives `{ payload, id }`,
## `WAIT` waits for the event `go` and gives `{ started, got }` (the classes are in `conformance/bindings.js`),
## `STUB_WORKFLOW` is a JS stub whose instance `vanishes` is gone at its second `get`. `?pname=` and `?n=` are the
## parameters, `?id=` the id. The twin of a route is `<name>_io`.
import pf.Request
import pf.Response
import pf.Workflows
import pf.Io
import Q

Params : { name : Str, n : U64 }
Done : { payload : Params, id : Str }
Waited : { started : Params, got : { x : U64 } }

WorkflowsRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| {
		w : Workflows(Params)
		w = Workflows.json(Q.text(req, "binding"))
		params = { name: Q.text(req, "pname"), n: Q.num(req, "n") }
		id = Q.text(req, "id")
		match path {
			["create"] => made(w.create!(params))
			["create_io"] => made(Io.run!(w.create(params)))
			["create_with"] => made(w.create_with!(params, { id: id }))
			["create_with_io"] => made(Io.run!(w.create_with(params, { id: id })))
			# No `id` field: the same as `create!`.
			["create_with_none"] => made(w.create_with!(params, {}))
			["get"] => made(w.get!(id))
			["get_io"] => made(Io.run!(w.get(id)))
			["status"] => status!(w, id, Bool.False)
			["status_io"] => status!(w, id, Bool.True)
			["pause"] => act!(w, id, "pause", Bool.False, Q.num(req, "n"))
			["pause_io"] => act!(w, id, "pause", Bool.True, Q.num(req, "n"))
			["resume"] => act!(w, id, "resume", Bool.False, Q.num(req, "n"))
			["resume_io"] => act!(w, id, "resume", Bool.True, Q.num(req, "n"))
			["terminate"] => act!(w, id, "terminate", Bool.False, Q.num(req, "n"))
			["terminate_io"] => act!(w, id, "terminate", Bool.True, Q.num(req, "n"))
			["send_event"] => act!(w, id, "send_event", Bool.False, Q.num(req, "n"))
			["send_event_io"] => act!(w, id, "send_event", Bool.True, Q.num(req, "n"))
			_ => Response.from_text(404, "no route")
		}
	}
}

ok : Str -> Response
ok = |text| Response.from_text(200, text)

made : Try(Workflows.Instance, [WorkflowsErr({ name : Str, message : Str }), AlreadyExists, NotFound]) -> Response
made = |r| ok(
	match r {
		Ok(i) => "Ok id=${i.id()}"
		Err(WorkflowsErr(t)) => "WorkflowsErr ${t.name}: ${t.message}"
		Err(AlreadyExists) => "AlreadyExists"
		Err(NotFound) => "NotFound"
	},
)

## The status of an instance: the state, the error, the raw output, and the output as the type of the binding.
status! : Workflows(Params), Str, Bool => Response
status! = |w, id, twin| {
	i = match w.get!(id) {
		Ok(x) => x
		Err(e) => return ok("get: ${Str.inspect(e)}")
	}
	got = if twin Io.run!(i.status()) else i.status!()
	match got {
		Ok(s) => {
			ok("state=${Str.inspect(s.state)} error=${Str.inspect(s.error)} json=${Str.inspect(s.output_json)} ${show_output(s)}")
		}
		Err(e) => ok("status: ${Str.inspect(e)}")
	}
}

show_output : Workflows.Status -> Str
show_output = |s| {
	done : Try(Done, _)
	done = s.output()
	waited : Try(Waited, _)
	waited = s.output()
	match (done, waited) {
		(Ok(d), _) => "done payload=${d.payload.name}/${d.payload.n.to_str()} id=${d.id}"
		(_, Ok(w)) => "waited started=${w.started.name}/${w.started.n.to_str()} got=${w.got.x.to_str()}"
		(Err(NotSet), _) => "no output"
		(Err(e), _) => "typed: ${Str.inspect(e)}"
	}
}

## One of the functions of an instance, on the instance of `get!`.
act! : Workflows(Params), Str, Str, Bool, U64 => Response
act! = |w, id, which, twin, x| {
	i = match w.get!(id) {
		Ok(v) => v
		Err(e) => return ok("get: ${Str.inspect(e)}")
	}
	r = match which {
		"pause" => if twin Io.run!(i.pause()) else i.pause!()
		"resume" => if twin Io.run!(i.resume()) else i.resume!()
		"terminate" => if twin Io.run!(i.terminate()) else i.terminate!()
		_ => if twin Io.run!(i.send_event("go", { x: x })) else i.send_event!("go", { x: x })
	}
	ok(
		match r {
			Ok({}) => "Ok"
			Err(NotFound) => "NotFound"
			Err(WorkflowsErr(t)) => "WorkflowsErr ${t.name}: ${t.message}"
		},
	)
}
