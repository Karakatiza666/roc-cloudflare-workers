## The routes of the edge run (PLAN.md 11c, 5d): the CPU limit, the 128 MB limit, the facts of API.md 10.2, and the cron
## test of API.md AQ12 (`scheduled!`). `edge/run-edge.mjs` calls them on the deployed Worker.
import pf.Request
import pf.Response
import pf.Body
import pf.Ctx
import pf.Time
import pf.Log
import pf.D1
import pf.Worker
import pf.Tcp
import Q

db = D1.binding("DB")

EdgeRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| match path {
		# 5d: `n` rounds, each allocates a list of 64 items (so the signal check of `roc_alloc` runs) and sums it.
		["spin"] => {
			n = Q.num(req, "n")
			var $sum = 0.U64
			var $i = 0.U64
			while $i < n {
				items = List.repeat($i, 64)
				$sum = $sum.plus_wrap(items.fold(0.U64, |a, b| a.plus_wrap(b)))
				$i = $i + 1
			}
			Response.from_text(200, "spun n=${n.to_str()} sum=${$sum.to_str()}")
		}
		# The 128 MB check: a list of `mb` MiB, held over a wait of `hold` ms.
		["grow"] => {
			size = Q.num(req, "mb") * 1_048_576
			big = List.repeat(7.U8, size)
			Time.sleep!(Q.num(req, "hold"))
			last = big.get(size - 1) ?? 0
			Response.from_text(200, "grew mb=${Q.num(req, "mb").to_str()} len=${big.len().to_str()} last=${last.to_str()}")
		}
		# API.md 10.2: `respond!` with a whole body, then `s` waits of 1 s, a log line after each.
		["after"] => {
			tag = Q.text(req, "tag")
			_ = Ctx.respond!(Response.from_text(200, "early ${tag}"))
			var $i = 1.U64
			while $i <= Q.num(req, "s") {
				Time.sleep!(1000)
				Log.info!("edge after", { tag, i: $i })
				$i = $i + 1
			}
			Log.info!("edge after done", { tag })
			Response.from_text(200, "not sent")
		}
		# API.md 10.2: a `Body.writer!` stream of `s` lines, one each second, then `close!`.
		["writer"] => {
			tag = Q.text(req, "tag")
			s = Q.num(req, "s")
			match Body.writer!({}) {
				Err(e) => Response.from_text(500, "writer ${Str.inspect(e)}")
				Ok({ body, writer }) => {
					_ = Ctx.respond!(Response.from_body(200, "text/plain", body))
					var $i = 1.U64
					var $ok = Bool.True
					while $ok and $i <= s {
						match writer.write_text!("tick ${$i.to_str()}\n") {
							Ok({}) => {
								Log.info!("edge writer", { tag, i: $i })
								Time.sleep!(1000)
								$i = $i + 1
							}
							Err(e) => {
								Log.warn!("edge writer failed", { tag, i: $i, error: Str.inspect(e) })
								$ok = Bool.False
							}
						}
					}
					writer.close!()
					Log.info!("edge writer done", { tag, ok: $ok })
					Response.from_text(200, "not sent")
				}
			}
		}
		# SO4: `connect_with!` with `tls: On` to a public host, an HTTP HEAD, the first line of the answer.
		["tls"] => {
			host = Q.text(req, "host")
			port = Q.num(req, "port").to_u16_try() ?? 443
			match Tcp.connect_with!(host, port, { tls: On }) {
				Err(e) => Response.from_text(200, "connect ${Str.inspect(e)}")
				Ok(s) => {
					w = s.write!(Str.to_utf8("HEAD / HTTP/1.1\r\nHost: ${host}\r\nConnection: close\r\n\r\n"))
					r = s.read!()
					s.close!()
					Response.from_text(200, "write=${Str.inspect(w)} read=${first_line(r)}")
				}
			}
		}
		# SO4: `tls: StartTls` to an SMTP server (port 587): the banner, EHLO, STARTTLS, `start_tls!`, EHLO again.
		["starttls"] => {
			host = Q.text(req, "host")
			port = Q.num(req, "port").to_u16_try() ?? 587
			mode = if Q.text(req, "plain") == "1" Off else StartTls
			Log.info!("edge starttls connect", { host })
			match Tcp.connect_with!(host, port, { tls: mode }) {
				Err(e) => Response.from_text(200, "connect ${Str.inspect(e)}")
				Ok(s) => {
					Log.info!("edge starttls connected", { host })
					banner = first_line(s.read!())
					Log.info!("edge starttls banner", { host, banner })
					_ = s.write!(Str.to_utf8("EHLO rocplat.test\r\n"))
					ehlo = first_line(s.read!())
					_ = s.write!(Str.to_utf8("STARTTLS\r\n"))
					ready = first_line(s.read!())
					match Tcp.start_tls!(s) {
						Err(e) => Response.from_text(200, "banner=${banner} ehlo=${ehlo} ready=${ready} start_tls=${Str.inspect(e)}")
						Ok(t) => {
							_ = t.write!(Str.to_utf8("EHLO rocplat.test\r\n"))
							after = first_line(t.read!())
							_ = t.write!(Str.to_utf8("QUIT\r\n"))
							t.close!()
							Response.from_text(200, "banner=${banner} ehlo=${ehlo} ready=${ready} tls_ehlo=${after}")
						}
					}
				}
			}
		}
		# 8f part 3: a socket wait of minutes before `respond!` (no shim deadline): the greeting of an IMAP server, then a
		# second `read!` that waits until the server ends the connection or the edge ends the request.
		["tcpwait"] => {
			host = Q.text(req, "host")
			match Tcp.connect_with!(host, 993, { tls: On }) {
				Err(e) => Response.from_text(200, "connect ${Str.inspect(e)}")
				Ok(s) => {
					greeting = first_line(s.read!())
					t0 = Time.now_ms!({})
					Log.info!("edge tcpwait start", { host })
					second = first_line(s.read!())
					waited = Time.now_ms!({}) - t0
					Log.info!("edge tcpwait end", { host, waited, second })
					s.close!()
					Response.from_text(200, "greeting=${greeting} second=${second} waited_ms=${waited.to_str()}")
				}
			}
		}
		_ => Response.from_text(404, "no route")
	}

	## AQ12: one row for each run (the cron, `time_ms`, the run time), then `Err`. The cron `1-59/2` calls `no_retry!`
	## first. The cron `*/5` gives `Ok` (the control of the revert row of 11c).
	scheduled! : Worker.Scheduled => Try({}, [CronFailed(Str), D1Err(Str)])
	scheduled! = |s| {
		cron = s.cron
		time_ms = s.time_ms
		now = Time.now_ms!({})
		row = db.run!("INSERT INTO cron_runs (cron, time_ms, run_ms) VALUES (?, ?, ?)", (cron, time_ms.to_i64_wrap(), now.to_i64_wrap()))
		match row {
			Err(e) => Err(D1Err(Str.inspect(e)))
			Ok(_) =>
				if cron == "*/5 * * * *" {
					Ok({})
				} else {
					if cron == "1-59/2 * * * *" {
						Worker.Scheduled.no_retry!(s)
					}
					Err(CronFailed(cron))
				}
		}
	}
}

## The first line of a read, or the error.
first_line : Try(List(U8), _) -> Str
first_line = |r| match r {
	Ok(bytes) => {
		text = Str.from_utf8(bytes) ?? "(not UTF-8)"
		match text.split_first("\r\n") {
			Ok({ before, after: _ }) => before
			Err(_) => text
		}
	}
	Err(e) => Str.inspect(e)
}
