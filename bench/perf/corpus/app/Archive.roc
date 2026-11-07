## The archive read of a package asset (Registry R-PU38, slice 111): the effects. The decisions are in `lib/ArchiveRead.roc` (pure, W0).
## Slice 112 (ingest) calls `read!`. This slice has no route: the W2 cases (`worker/tests/cases/archive/`) run the test app `archive-test.roc`, which calls `read!`.
##
## `read!(url, hash)` flow. `hash` is the hash of the URL (Design 2; slice 112 has the URL rules). No D1 call, no write.
## 1. One `Http.open!` of `Request.get(url)` with the header `user-agent: talon-registry` (the body stays a stream; `fetch` follows the 302 of a GitHub
##    release download). No answer (`Err(Infra(_))`) is `Upstream(NoAnswer)`. A status other than 200 is `Upstream(Status(status))`: no body read.
## 2. `ArchiveRead.check_length(res.header("content-length"))` before any body read (row 2). A refusal is `Refused`, with no body read.
## 3. `Native.Blake3.new!()` and `Native.ZstdStream.open!()` (the default window limit, 8 MiB, row 3; `open_with!` is not used). An error is `Fault`.
## 4. Loop on `res.body().chunk!()`, with `state = ArchiveRead.empty()`:
##    a. `Chunk(c)`: `ArchiveRead.count(state, c.len())` first. `Err(refusal)` is `Refused(refusal)` at once: no more read, no hash (the stream can be endless).
##    b. `Native.Blake3.update!(b3, c)` for each chunk (row 4: the hash reads to the end, also after the tar end and after a refusal).
##    c. Only while `ArchiveRead.reading(state)`: `Native.ZstdStream.feed!(z, c, ArchiveRead.feed_bytes)` (64 KiB of output at most), then `feed!(z, [], ArchiveRead.feed_bytes)` while `more` is true.
##       Each `out` goes to `ArchiveRead.push`, which counts the decoded bytes (Q441) and stops the read over the limit: the loop ends when `reading` is false. A zstd error of the tags of
##       `unzip_failed` goes to `ArchiveRead.unzip_failed`. `BadHandle` and `WrongTask` are `Fault`.
##    d. `End` ends the loop. `Err(BodyErr(_))` is `Upstream(BodyRead)`.
## 5. `Native.ZstdStream.close!(z)` always (it frees the stream). While `reading`, its zstd error goes to `unzip_failed` (an empty or cut stream is `Truncated`; `close!` still has `OutputLimit`).
## 6. `Native.Blake3.final!(b3)`, then `ArchiveRead.finish(state, digest, hash)`. Its `Err` is `Refused`.
import pf.Http
import pf.Request
import pf.Response
import pf.Native
import lib.ArchiveRead
import records.Artifact

Archive :: [].{

	## The error of `read!`. `Refused`: the asset is not a candidate (the problem is `ArchiveRead.problem`). `Upstream`: the asset read failed
	## (`ArchiveRead.upstream_problem`). `Fault`: a fault of the Worker (500 `internal`).
	Error : [Refused(ArchiveRead.Refusal), Upstream([Status(U16), NoAnswer, BodyRead]), Fault(Str)]

	read! : Str, Str => Try(Artifact.Row, Archive.Error)
	read! = |url, hash| {
		res = Http.open!(Request.get(url).with_header("user-agent", "talon-registry")) ? |_| Upstream(NoAnswer)
		if res.status() != 200 {
			return Err(Upstream(Status(res.status())))
		}
		ArchiveRead.check_length(res.header("content-length")) ? Refused
		b3 = Native.Blake3.new!() ? |_| Fault("no BLAKE3 state")
		z = Native.ZstdStream.open!() ? |_| Fault("no zstd stream")
		body = res.body()
		var $state = ArchiveRead.empty()
		var $more = Bool.True
		while $more {
			match body.chunk!() {
				Ok(Chunk(c)) => {
					counted = $state.count(c.len())
					$state = match counted {
						Ok(s) => s
						Err(refusal) => {
							_ = z.close!()
							return Err(Refused(refusal))
						}
					}
					b3.update!(c) ? |_| Fault("BLAKE3 update")
					# Q441, slice 123: `feed!` gives at most `ArchiveRead.feed_bytes` bytes per call. The first call gets the chunk, each next call gets `[]` while `more` is true.
					# The loop stops when the state holds a refusal (the decoded limit, or a tar error): the stream stays open and `close!` frees it.
					var $input = c
					var $feeding = $state.reading()
					while $feeding {
						match z.feed!($input, ArchiveRead.feed_bytes) {
							Ok({ out, more }) => {
								$state = $state.push(out)
								$input = []
								$feeding = more and $state.reading()
							}
							Err(BadHandle) | Err(WrongTask) => return Err(Fault("zstd feed"))
							Err(WindowTooLarge) => {
								$state = $state.unzip_failed(WindowTooLarge)
								$feeding = Bool.False
							}
							Err(BadFrame) => {
								$state = $state.unzip_failed(BadFrame)
								$feeding = Bool.False
							}
							Err(Truncated) => {
								$state = $state.unzip_failed(Truncated)
								$feeding = Bool.False
							}
							Err(Unsupported) => {
								$state = $state.unzip_failed(Unsupported)
								$feeding = Bool.False
							}
						}
					}
				}

				Ok(End) => {
					$more = Bool.False
				}

				Err(BodyErr(_)) => {
					_ = z.close!()
					return Err(Upstream(BodyRead))
				}
			}
		}
		closed = z.close!()
		if $state.reading() {
			$state = match closed {
				Ok({}) => $state
				Err(BadHandle) | Err(WrongTask) => return Err(Fault("zstd close"))
				Err(OutputLimit) => $state.unzip_failed(OutputLimit)
				Err(WindowTooLarge) => $state.unzip_failed(WindowTooLarge)
				Err(BadFrame) => $state.unzip_failed(BadFrame)
				Err(Truncated) => $state.unzip_failed(Truncated)
				Err(Unsupported) => $state.unzip_failed(Unsupported)
			}
		}
		digest = b3.final!() ? |_| Fault("BLAKE3 final")
		$state.finish(digest, hash).map_err(|r| Refused(r))
	}
}
