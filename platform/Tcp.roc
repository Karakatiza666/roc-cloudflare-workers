## TCP sockets (MODULES.md 12.3): `connect` of `cloudflare:sockets`. A socket holds a ref, so it is good for one task
## (MC13). The helpers `tcpConnect`, `tcpOpen`, `tcpRead`, `tcpWrite`, `tcpStartTls` and `tcpClose` of `js/helpers.js`
## keep the reader and the writer of each socket. A database client (Postgres through `Hyperdrive.connect!`) is a package
## over `Tcp`.
import Io
import Js
import Body

## `:=`, not `::`: `Hyperdrive.connect!` makes a `Tcp` from the socket of its binding (PLAN.md 8f, part 3).
Tcp := { ref : Js.Ref }.{
	is_eq : _

	## The TLS of `connect_with!`: `Off` (the default), `On`, or `StartTls` (plain first, then `start_tls!`).
	Tls : [Off, On, StartTls]

	## `connect({ hostname, port })`, then a wait for `opened`: one wait. A host that does not answer is `SocketErr`.
	connect : Str, U16 -> Io(Tcp, [SocketErr(Io.Thrown)])
	connect = |host, port| connect_with(host, port, {})

	connect! : Str, U16 => Try(Tcp, [SocketErr(Io.Thrown)])
	connect! = |host, port| Io.run!(connect(host, port))

	connect_with : Str, U16, { tls ?: Tcp.Tls } -> Io(Tcp, [SocketErr(Io.Thrown)])
	connect_with = |host, port, opts| {
		tls = match opts.?tls {
			Ok(On) => "on"
			Ok(StartTls) => "starttls"
			Ok(Off) | Err(_) => "off"
		}
		Io.new([Call(Root("pf"), "tcpConnect", [Lit(Text(host)), Lit(Int(port.to_i64())), Lit(Text(tls))])], socket_of)
	}

	connect_with! : Str, U16, { tls ?: Tcp.Tls } => Try(Tcp, [SocketErr(Io.Thrown)])
	connect_with! = |host, port, opts| Io.run!(connect_with(host, port, opts))

	## The next bytes that the peer sent, at most `Body.default_max` (MC11: the rest comes next). One wait, with no
	## deadline (API.md 10.2). `Closed` at the end of the stream. In `Io.race!`, a branch that lost takes no bytes (OP8).
	read : Tcp -> Io(List(U8), [Closed, SocketErr(Io.Thrown)])
	read = |tcp| Io.new(
		[Keep(Root("signal")), Call(Root("pf"), "tcpRead", [Lit(Ref(tcp.ref)), Lit(Int(Body.default_max.to_i64_try() ?? I64.highest)), Slot(0)])],
		|r| match r {
			Ok(Bytes(b)) => Ok(b)
			Ok(Undefined) | Ok(Null) => Err(Closed)
			Ok(other) => crash "Tcp.read: pf.tcpRead gave ${Str.inspect(other)}"
			Err(t) => Err(SocketErr(t))
		},
	)

	read! : Tcp => Try(List(U8), [Closed, SocketErr(Io.Thrown)])
	read! = |tcp| Io.run!(read(tcp))

	## `writer.write(bytes)`: one wait. A socket that is closed is `Closed`.
	write : Tcp, List(U8) -> Io({}, [Closed, SocketErr(Io.Thrown)])
	write = |tcp, bytes| Io.new(
		[Call(Root("pf"), "tcpWrite", [Lit(Ref(tcp.ref)), Lit(Bytes(bytes))])],
		|r| match r {
			Ok(Text("closed")) => Err(Closed)
			Ok(_) => Ok({})
			Err(t) => Err(SocketErr(t))
		},
	)

	write! : Tcp, List(U8) => Try({}, [Closed, SocketErr(Io.Thrown)])
	write! = |tcp, bytes| Io.run!(write(tcp, bytes))

	## `socket.startTls()` of a socket of `connect_with!` with `tls: StartTls`, then a wait for `opened`. The old socket
	## is not usable after it.
	start_tls : Tcp -> Io(Tcp, [SocketErr(Io.Thrown)])
	start_tls = |tcp| Io.new([Call(Root("pf"), "tcpStartTls", [Lit(Ref(tcp.ref))])], socket_of)

	start_tls! : Tcp => Try(Tcp, [SocketErr(Io.Thrown)])
	start_tls! = |tcp| Io.run!(start_tls(tcp))

	## `socket.close()`, one `call!` with no wait. A throw is dropped.
	close! : Tcp => {}
	close! = |tcp| {
		_ = Io.call!([Call(Root("pf"), "tcpClose", [Lit(Ref(tcp.ref))])])
		{}
	}

}

## The socket of a program that ends with `pf.tcpConnect` or `pf.tcpStartTls`.
socket_of : Try(Js, Io.Thrown) -> Try(Tcp, [SocketErr(Io.Thrown)])
socket_of = |r| match r {
	Ok(Ref(s)) => Ok(Tcp.{ ref: s })
	Ok(other) => crash "Tcp: the socket is ${Str.inspect(other)}"
	Err(t) => Err(SocketErr(t))
}
