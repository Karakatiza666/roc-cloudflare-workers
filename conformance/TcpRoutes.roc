## `Tcp` (MODULES.md 12.3, PLAN.md 8f part 3): routes that connect to the TCP echo server of `checks/tcp.mjs` on
## `127.0.0.1:<port>`. The server sends each chunk back, answers "slow" with "late" after 100 ms, and ends the
## connection after "bye".
import pf.Request
import pf.Response
import pf.Tcp
import pf.Io
import pf.Time
import Q

TcpRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| {
		port = Q.num(req, "port").to_u16_try() ?? 0
		match path {
			# `connect!`, `write!`, `read` (in a race with a timeout), `close!`.
			["echo"] => ok(
				match Tcp.connect!("127.0.0.1", port) {
					Ok(s) => {
						w = s.write!(Str.to_utf8("hello"))
						r = read_text!(s)
						s.close!()
						"write=${Str.inspect(w)} read=${Str.inspect(r)}"
					}
					Err(e) => "Err ${Str.inspect(e)}"
				},
			)
			# The twins `connect`, `write`, `read` (in `read_within!`), and `connect_with!` with `tls: Off`.
			["echo_io"] => ok(
				match Io.run!(Tcp.connect("127.0.0.1", port)) {
					Ok(s) => {
						w = Io.run!(s.write(Str.to_utf8("twin")))
						r = read_text!(s)
						s.close!()
						with_off = match Tcp.connect_with!("127.0.0.1", port, { tls: Off }) {
							Ok(s2) => {
								_ = s2.write!([0, 1, 255])
								b = read_within!(s2)
								s2.close!()
								Str.inspect(b)
							}
							Err(e) => Str.inspect(e)
						}
						"write=${Str.inspect(w)} read=${Str.inspect(r)} with=${with_off}"
					}
					Err(e) => "Err ${Str.inspect(e)}"
				},
			)
			# A port that no server has: `SocketErr`.
			["closed_port"] => ok(Str.inspect(Tcp.connect!("127.0.0.1", 1).map_ok(|_| {})))
			# The server ends the connection: `read!` gives `Closed`. A write after `close!` gives `Closed`.
			["end"] => ok(
				match Tcp.connect!("127.0.0.1", port) {
					Ok(s) => {
						# No read when the write failed: the read would wait for ever.
						r = match s.write!(Str.to_utf8("bye")) {
							Ok(_) => s.read!()
							Err(e) => Err(e)
						}
						s.close!()
						after = s.write!(Str.to_utf8("late"))
						"read=${Str.inspect(r)} write_after_close=${Str.inspect(after)}"
					}
					Err(e) => "Err ${Str.inspect(e)}"
				},
			)
			# `Io.race!` of `read` and `Time.sleep(50)`, the bytes sent at 100 ms: the sleep wins, and the next read gets them.
			["race"] => ok(
				match Tcp.connect!("127.0.0.1", port) {
					Ok(s) => {
						_ = s.write!(Str.to_utf8("slow"))
						first = Io.race!([s.read().map(|b| Got(Str.from_utf8(b) ?? "?")), Time.sleep(50).map(|_| TimedOut)])
						next = Io.race!([s.read().map(|b| Got(Str.from_utf8(b) ?? "?")), Time.sleep(1_000).map(|_| TimedOut)])
						s.close!()
						"first=${first.index.to_str()} ${Str.inspect(first.result)} next=${Str.inspect(next.result)}"
					}
					Err(e) => "Err ${Str.inspect(e)}"
				},
			)
			# OP8, the same turn: the bytes at 100 ms are in the read that a lost branch left. A race of `read` and a branch with
			# no wait (it wins): the read gets its bytes in the same turn as the end of the race, and gives them back.
			["race_ready"] => ok(
				match Tcp.connect!("127.0.0.1", port) {
					Ok(s) => {
						_ = s.write!(Str.to_utf8("slow"))
						first = Io.race!([s.read().map(|b| Got(Str.from_utf8(b) ?? "?")), Time.sleep(50).map(|_| TimedOut)])
						Time.sleep!(300)
						second = Io.race!([at_once, s.read().map(|b| Got(Str.from_utf8(b) ?? "?"))])
						next = Io.race!([s.read().map(|b| Got(Str.from_utf8(b) ?? "?")), Time.sleep(1_000).map(|_| TimedOut)])
						s.close!()
						"first=${first.index.to_str()} second=${second.index.to_str()} next=${Str.inspect(next.result)}"
					}
					Err(e) => "Err ${Str.inspect(e)}"
				},
			)
			# `tls: StartTls`, the plain steps (E47 of PLAN.md 11c: after the first read, a write and a read waited with no end on the
			# edge). Two rounds of a write and a read. No `start_tls!`: the echo server has no TLS.
			["starttls_plain"] => ok(
				match Tcp.connect_with!("127.0.0.1", port, { tls: StartTls }) {
					Ok(s) => {
						_ = s.write!(Str.to_utf8("one"))
						first = read_text!(s)
						_ = s.write!(Str.to_utf8("two"))
						second = read_text!(s)
						s.close!()
						"first=${Str.inspect(first)} second=${Str.inspect(second)}"
					}
					Err(e) => "Err ${Str.inspect(e)}"
				},
			)
			# `start_tls!` on a socket of `tls: Off` is `SocketErr` (E47: the option `secureTransport` must be 'starttls'). A race with
			# a sleep, so a route never hangs.
			["start_tls_off"] => ok(
				match Tcp.connect!("127.0.0.1", port) {
					Ok(s) => {
						r = Io.race!([Tcp.start_tls(s).map(|_| Opened), Time.sleep(2_000).map(|_| TimedOut)])
						s.close!()
						Str.inspect(r.result)
					}
					Err(e) => "Err ${Str.inspect(e)}"
				},
			)
			# EP11: the server of conformance/starttls-server.mjs (a banner, EHLO, STARTTLS), then `start_tls!`, then EHLO over TLS.
			# `start_tls` is in a race with a sleep, so a hang (the locks of the shim) is `TimedOut`, not a hang of the run.
			["starttls_tls"] => ok(
				match Tcp.connect_with!("127.0.0.1", port, { tls: StartTls }) {
					Ok(s) => {
						banner = read_text!(s)
						_ = s.write!(Str.to_utf8("EHLO a\r\n"))
						ehlo = read_text!(s)
						_ = s.write!(Str.to_utf8("STARTTLS\r\n"))
						ready = read_text!(s)
						up = Io.race!([Tcp.start_tls(s).map(|t| Upgraded(t)), Time.sleep(3_000).map(|_| TimedOut)])
						head = "banner=${Str.inspect(banner)} ehlo=${Str.inspect(ehlo)} ready=${Str.inspect(ready)}"
						match up.result {
							Ok(Upgraded(t)) => {
								_ = t.write!(Str.to_utf8("EHLO b\r\n"))
								secure = read_text!(t)
								t.close!()
								"${head} secure=${Str.inspect(secure)}"
							}
							Ok(TimedOut) => {
								s.close!()
								"${head} start_tls=TimedOut"
							}
							Err(e) => {
								s.close!()
								"${head} start_tls=${Str.inspect(e)}"
							}
						}
					}
					Err(e) => "Err ${Str.inspect(e)}"
				},
			)
			# EP11: unread bytes. A read that lost a race to a branch with no wait gave its bytes back (the same turn as in
			# `race_ready`), so they are unread. `start_tls!` is `SocketErr`, and the socket stays plain: the next read gets them.
			["start_tls_unread"] => ok(
				match Tcp.connect_with!("127.0.0.1", port, { tls: StartTls }) {
					Ok(s) => {
						_ = s.write!(Str.to_utf8("slow"))
						_ = Io.race!([s.read().map(|b| Got(Str.from_utf8(b) ?? "?")), Time.sleep(50).map(|_| TimedOut)])
						Time.sleep!(300)
						_ = Io.race!([at_once, s.read().map(|b| Got(Str.from_utf8(b) ?? "?"))])
						up = Io.race!([Tcp.start_tls(s).map(|_| Opened), Time.sleep(2_000).map(|_| TimedOut)])
						rest = read_text!(s)
						s.close!()
						"start_tls=${Str.inspect(up.result)} then_read=${Str.inspect(rest)}"
					}
					Err(e) => "Err ${Str.inspect(e)}"
				},
			)
			# EP11: a read in flight. A read that lost a race to a sleep is still pending (no bytes came). `start_tls!` is
			# `SocketErr`, and the socket stays plain: a write and a read still work.
			["start_tls_pending"] => ok(
				match Tcp.connect_with!("127.0.0.1", port, { tls: StartTls }) {
					Ok(s) => {
						first = Io.race!([s.read().map(|b| Got(Str.from_utf8(b) ?? "?")), Time.sleep(50).map(|_| TimedOut)])
						up = Io.race!([Tcp.start_tls(s).map(|_| Opened), Time.sleep(2_000).map(|_| TimedOut)])
						_ = s.write!(Str.to_utf8("ping"))
						echo = read_text!(s)
						s.close!()
						"first=${first.index.to_str()} start_tls=${Str.inspect(up.result)} then_echo=${Str.inspect(echo)}"
					}
					Err(e) => "Err ${Str.inspect(e)}"
				},
			)
			_ => Response.from_text(404, "no route")
		}
	}
}

## A branch with no wait: in `Io.race!`, it wins against a read that has its bytes.
at_once : Io([Got(Str), TimedOut, Now], [Closed, Infra([SocketErr(Io.Thrown)])])
at_once = Io.sync([Get(Root("signal"), "aborted")], |_| Ok(Now))

ok : Str -> Response
ok = |text| Response.from_text(200, text)

## `read` (the twin) in a race with a sleep of 2 s, so a route never hangs when no bytes come (a revert).
read_within! : Tcp => Try(List(U8), [Closed, Infra([SocketErr(Io.Thrown)]), TimedOut])
read_within! = |s| {
	r = Io.race!([s.read().map(|b| Got(b)), Time.sleep(2_000).map(|_| TimedOut)])
	match r.result {
		Ok(Got(b)) => Ok(b)
		Ok(TimedOut) => Err(TimedOut)
		Err(Closed) => Err(Closed)
		Err(Infra(i)) => Err(Infra(i))
	}
}

read_text! : Tcp => Try(Str, [Closed, Infra([SocketErr(Io.Thrown)]), TimedOut])
read_text! = |s| read_within!(s).map_ok(|b| Str.from_utf8(b) ?? "?")
