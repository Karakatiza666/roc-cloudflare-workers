## The Hyperdrive binding (MODULES.md 13): the properties of `env[name]`. `config!` reads them in one `call!`, no wait.
## `connect!` is the `connect()` of the binding: a `Tcp` socket to the database (MODULES.md 12.3), for a database client.
import Io
import Js
import Secret
import Tcp

Hyperdrive :: { name : Str }.{
	binding : Str -> Hyperdrive
	binding = |name| Hyperdrive.{ name }

	## The binding for the manifest (`Worker.new({ bindings: [...] })`, MODULES.md 3): the kind `hyperdrive`.
	declare : Hyperdrive -> { name : Str, kind : Str, props : List((Str, Str)) }
	declare = |b| { name: b.name, kind: "hyperdrive", props: [] }

	## What Workers gives for a database: the connection string and its parts. The two secrets do not show in a log line.
	Config : { connection_string : Secret, host : Str, port : U16, user : Str, password : Secret, database : Str }

	## A binding that is not in the config gives `undefined` fields (OP7): a crash with the name of the binding.
	config! : Hyperdrive => Hyperdrive.Config
	config! = |h| match Io.call!(
		[
			Get(Root("env"), h.name),
			Fields(Slot(0), ["connectionString", "host", "port", "user", "password", "database"]),
		],
	) {
		Ok(js) => match config_of(js) {
			Ok(c) => c
			Err(why) => crash "Hyperdrive.config!: ${h.name}: ${why}"
		}
		Err(t) => crash "Hyperdrive.config!: ${h.name}: ${t.name}: ${t.message}"
	}

	## `env[name].connect()`, then a wait for `opened` (`pf.tcpOpen`): one wait. The socket goes to the database of the
	## binding through Hyperdrive. A throw (no binding, the origin does not answer) is `SocketErr`.
	connect : Hyperdrive -> Io(Tcp, [SocketErr(Io.Thrown)])
	connect = |h| Io.new(
		[Get(Root("env"), h.name), Call(Slot(0), "connect", []), Call(Root("pf"), "tcpOpen", [Slot(1)])],
		|r| match r {
			Ok(Ref(s)) => Ok(Tcp.{ ref: s })
			Ok(other) => crash "Hyperdrive.connect: the socket is ${Str.inspect(other)}"
			Err(t) => Err(SocketErr(t))
		},
	)

	connect! : Hyperdrive => Try(Tcp, [SocketErr(Io.Thrown)])
	connect! = |h| Io.run!(connect(h))
}

config_of : Js -> Try(Hyperdrive.Config, Str)
config_of = |js| match js {
	Obj(fs) => match (field(fs, "connectionString"), field(fs, "host"), field(fs, "port"), field(fs, "user"), field(fs, "password"), field(fs, "database")) {
		(Text(cs), Text(host), Int(port), Text(user), Text(password), Text(database)) => match port.to_u16_try() {
			Ok(p) => Ok({ connection_string: Secret.from_str(cs), host, port: p, user, password: Secret.from_str(password), database })
			Err(_) => Err("the port is out of range")
		}
		_ => Err("the binding is not in env, or it is not a Hyperdrive binding")
	}
	_ => Err("the program gave a value that is not an object")
}

field : List((Str, Js)), Str -> Js
field = |fields, name| match fields.find_first(|(k, _)| k == name) {
	Ok((_, v)) => v
	Err(_) => Undefined
}

fields_ok : List((Str, Js))
fields_ok = [("connectionString", Text("postgres://u:p@h:5432/d")), ("host", Text("h")), ("port", Int(5432)), ("user", Text("u")), ("password", Text("p")), ("database", Text("d"))]

expect match config_of(Obj(fields_ok)) {
	Ok(c) => c.host == "h" and c.port == 5432 and c.user == "u" and c.database == "d" and c.password.reveal() == "p" and c.connection_string.reveal() == "postgres://u:p@h:5432/d"
	Err(_) => Bool.False
}
expect config_of(Obj([("connectionString", Undefined)])).is_err()
expect config_of(Obj(fields_ok.map(|(k, v)| if k == "port" (k, Int(70_000)) else (k, v)))).is_err()
