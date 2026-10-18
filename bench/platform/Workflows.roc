## The Workflows binding, the client side (MODULES.md 13): `env[name].create(...)`, `get(id)` and the methods of an
## instance. The workflow class (`run`, `step.do`) needs callbacks: phase C (AQ1). The parameters and the event payloads
## are data that is JSON at rest, so the constant has the format `Json` (MC5, MC6): `Workflows.json("PUBLISH")`. JS gets
## them from `JSON.parse` (a plain object).
## An `Instance` is plain data, the binding name and the id (MC13): it has no ref, so an app can keep it across requests.
## Each of its functions is one program: `env[name].get(id)`, then the method (so it works in any task).
import Io
import Js

Workflows(a) := { name : Str, write : a -> Try(Str, Str) }.{
	## A constant (WR1): the name of the binding in the Wrangler config, and the codec of the parameters.
	## A value that JSON cannot show (a `NaN` in an `F64`) is `BadData` of the call.
	json : Str -> Workflows(a) where [a.Json.Encodable(enc)]
	json = |name| Workflows.{ name, write: |v| Json.to_str_try(v).map_err(|e| Str.inspect(e)) }

	## `create({ params })`: a new instance with a new id. Gives the `Instance` (its id is `instance.id`).
	create : Workflows(a), a -> Io(Workflows.Instance, [WorkflowsErr(Io.Thrown), AlreadyExists, BadData(Str)])
	create = |w, params| create_io(w, params, Err(NoId))

	create! : Workflows(a), a => Try(Workflows.Instance, [WorkflowsErr(Io.Thrown), AlreadyExists, BadData(Str)])
	create! = |w, params| Io.run!(create(w, params))

	## `id`: the id of the new instance (1 to 100 characters). An id that is in use is `AlreadyExists`.
	create_with : Workflows(a), a, { id ?: Str } -> Io(Workflows.Instance, [WorkflowsErr(Io.Thrown), AlreadyExists, BadData(Str)])
	create_with = |w, params, opts| create_io(w, params, opts.?id.map_err(|_| NoId))

	create_with! : Workflows(a), a, { id ?: Str } => Try(Workflows.Instance, [WorkflowsErr(Io.Thrown), AlreadyExists, BadData(Str)])
	create_with! = |w, params, opts| Io.run!(create_with(w, params, opts))

	## `get(id)`: the `Instance` of an id, or `NotFound`.
	get : Workflows(a), Str -> Io(Workflows.Instance, [WorkflowsErr(Io.Thrown), NotFound])
	get = |w, id| Io.new(
		[Get(Root("env"), w.name), Call(Slot(0), "get", [Lit(Text(id))]), Get(Slot(1), "id")],
		|r| match r {
			Ok(Text(got)) => Ok(Workflows.Instance.{ name: w.name, id: got })
			Ok(other) => crash "Workflows.get: the id is ${Str.inspect(other)}"
			Err(t) => Err(error_of(t))
		},
	)

	get! : Workflows(a), Str => Try(Workflows.Instance, [WorkflowsErr(Io.Thrown), NotFound])
	get! = |w, id| Io.run!(get(w, id))

	## One instance. `NotFound`: no instance has this id (any more).
	Instance :: { name : Str, id : Str }.{
		id : Workflows.Instance -> Str
		id = |i| i.id

		status : Workflows.Instance -> Io(Workflows.Status, [WorkflowsErr(Io.Thrown), NotFound])
		status = |i| Io.new(
			instance_ops(i).concat(
				[
					Call(Slot(1), "status", []),
					Get(Slot(2), "status"),
					Get(Slot(2), "error"),
					Get(Slot(2), "output"),
					Get(Root("global"), "JSON"),
					Call(Slot(6), "stringify", [Slot(5)]),
					Record([("status", Slot(3)), ("error", Slot(4)), ("output", Slot(7))]),
				],
			),
			|r| match r {
				Ok(js) => Ok(status_of(js))
				Err(t) => Err(error_of(t))
			},
		)

		status! : Workflows.Instance => Try(Workflows.Status, [WorkflowsErr(Io.Thrown), NotFound])
		status! = |i| Io.run!(status(i))

		pause : Workflows.Instance -> Io({}, [WorkflowsErr(Io.Thrown), NotFound])
		pause = |i| plain(i, "pause")

		pause! : Workflows.Instance => Try({}, [WorkflowsErr(Io.Thrown), NotFound])
		pause! = |i| Io.run!(pause(i))

		resume : Workflows.Instance -> Io({}, [WorkflowsErr(Io.Thrown), NotFound])
		resume = |i| plain(i, "resume")

		resume! : Workflows.Instance => Try({}, [WorkflowsErr(Io.Thrown), NotFound])
		resume! = |i| Io.run!(resume(i))

		terminate : Workflows.Instance -> Io({}, [WorkflowsErr(Io.Thrown), NotFound])
		terminate = |i| plain(i, "terminate")

		terminate! : Workflows.Instance => Try({}, [WorkflowsErr(Io.Thrown), NotFound])
		terminate! = |i| Io.run!(terminate(i))

		## `sendEvent({ type, payload })`: the payload is JSON (the format of the event). The waiting `step.waitForEvent`
		## of the workflow takes it.
		send_event : Workflows.Instance, Str, p -> Io({}, [WorkflowsErr(Io.Thrown), NotFound, BadData(Str)]) where [p.Json.Encodable(enc)]
		send_event = |i, type, payload| match Json.to_str_try(payload) {
			Ok(text) => Io.new(
				[Get(Root("global"), "JSON"), Call(Slot(0), "parse", [Lit(Text(text))])].concat(
					[
						Get(Root("env"), i.name),
						Call(Slot(2), "get", [Lit(Text(i.id))]),
						Record([("type", Lit(Text(type))), ("payload", Slot(1))]),
						Call(Slot(3), "sendEvent", [Slot(4)]),
					],
				),
				|r| match r {
					Ok(_) => Ok({})
					Err(t) => Err(error_of(t))
				},
			)
			Err(e) => Io.sync([], |_| Err(BadData("the payload does not encode: ${Str.inspect(e)}")))
		}

		send_event! : Workflows.Instance, Str, p => Try({}, [WorkflowsErr(Io.Thrown), NotFound, BadData(Str)]) where [p.Json.Encodable(enc)]
		send_event! = |i, type, payload| Io.run!(send_event(i, type, payload))
	}

	## What `status()` gives: the state, the error of a failed instance, and the output of a complete one as JSON text.
	Status := { state : Workflows.State, error : Try(Io.Thrown, [NotSet]), output_json : Try(Str, [NotSet]) }.{

		## The output as the type of the call: `NotSet` while the instance has none.
		output : Workflows.Status -> Try(out, [NotSet, BadData(Str)]) where [out.Json.Parseable([InvalidJson(Str), ..errs])]
		output = |s| match s.output_json {
			Ok(text) => Json.parse(text).map_err(|e| BadData(Str.inspect(e)))
			Err(NotSet) => Err(NotSet)
		}
	}

	## The `status` of an instance (the Workflows docs). A text that Workflows adds later is `Unknown`.
	State : [Queued, Running, Paused, Errored, Terminated, Complete, Waiting, WaitingForPause, Unknown]
}

## `create({ id?, params })`. Slots: 0 `JSON`, 1 the parameters, 2 the binding, 3 the options, 4 the instance, 5 its id.
create_io : Workflows(a), a, Try(Str, [NoId]) -> Io(Workflows.Instance, [WorkflowsErr(Io.Thrown), AlreadyExists, BadData(Str)])
create_io = |w, params, id| {
	write = w.write
	opts = match id {
		Ok(s) => [("id", Lit(Text(s))), ("params", Slot(1))]
		Err(NoId) => [("params", Slot(1))]
	}
	match write(params) {
		Ok(text) => Io.new(
			[
				Get(Root("global"), "JSON"),
				Call(Slot(0), "parse", [Lit(Text(text))]),
				Get(Root("env"), w.name),
				Record(opts),
				Call(Slot(2), "create", [Slot(3)]),
				Get(Slot(4), "id"),
			],
			|r| match r {
				Ok(Text(got)) => Ok(Workflows.Instance.{ name: w.name, id: got })
				Ok(other) => crash "Workflows.create: the id is ${Str.inspect(other)}"
				Err(t) => Err(create_error(t))
			},
		)
		# A value that does not encode: no program, so nothing is sent.
		Err(m) => Io.sync([], |_| Err(BadData("the params do not encode: ${m}")))
	}
}

## The start of an instance program: slot 0 the binding, slot 1 the instance (`get` throws for an id that is not there).
instance_ops : Workflows.Instance -> List(Js.Op)
instance_ops = |i| [Get(Root("env"), i.name), Call(Slot(0), "get", [Lit(Text(i.id))])]

## A method with no argument and no result.
plain : Workflows.Instance, Str -> Io({}, [WorkflowsErr(Io.Thrown), NotFound])
plain = |i, method| Io.new(
	instance_ops(i).append(Call(Slot(1), method, [])),
	|r| match r {
		Ok(_) => Ok({})
		Err(t) => Err(error_of(t))
	},
)

## MC9: the codes of the Workflows binding are in the message of the throw (`instance.not_found`,
## `instance.already_exists`). Each other throw is `WorkflowsErr`.
error_of : Io.Thrown -> [WorkflowsErr(Io.Thrown), NotFound]
error_of = |t| if t.message.contains("instance.not_found") NotFound else WorkflowsErr(t)

create_error : Io.Thrown -> [WorkflowsErr(Io.Thrown), AlreadyExists]
create_error = |t| if t.message.contains("instance.already_exists") AlreadyExists else WorkflowsErr(t)

status_of : Js -> Workflows.Status
status_of = |js| match js {
	Obj(fs) => {
		error = match field(fs, "error") {
			Obj(e) => Ok({ name: text_of(field(e, "name")), message: text_of(field(e, "message")) })
			Text(s) => Ok({ name: "Error", message: s })
			_ => Err(NotSet)
		}
		output_json = match field(fs, "output") {
			Text(s) => Ok(s)
			_ => Err(NotSet)
		}
		Workflows.Status.{ state: state_of(field(fs, "status")), error, output_json }
	}
	other => crash "Workflows.status: the program gave ${Str.inspect(other)}"
}

state_of : Js -> Workflows.State
state_of = |v| match v {
	Text("queued") => Queued
	Text("running") => Running
	Text("paused") => Paused
	Text("errored") => Errored
	Text("terminated") => Terminated
	Text("complete") => Complete
	Text("waiting") => Waiting
	Text("waitingForPause") => WaitingForPause
	_ => Unknown
}

text_of : Js -> Str
text_of = |v| match v {
	Text(s) => s
	_ => ""
}

field : List((Str, Js)), Str -> Js
field = |fields, name| match fields.find_first(|(k, _)| k == name) {
	Ok((_, v)) => v
	Err(_) => Undefined
}

expect error_of({ name: "Error", message: "instance.not_found" }) == NotFound
expect create_error({ name: "Error", message: "(instance.already_exists) Workflow instance with id \"dup\" already exists" }) == AlreadyExists
expect error_of({ name: "Error", message: "boom" }) == WorkflowsErr({ name: "Error", message: "boom" })
expect state_of(Text("waitingForPause")) == WaitingForPause
expect state_of(Text("a state of the future")) == Unknown
expect status_of(Obj([("status", Text("complete")), ("error", Undefined), ("output", Text("{\"a\":1}"))])).state == Complete
