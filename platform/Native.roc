## The typed side of the Native ops (API.md 8, PLAN.md 8e): zstd, BLAKE3 and SHA-256 in the host.
## The ops do not wait, so each function is `f!` with no `Io` twin (MC3 is for a wait).
## A handle is a number in a table of the host. It belongs to the task that made it, and it is
## closed at the end of that task. A record backing keeps the number hidden (MC13, MODULES.md 15).
import Host

Native :: [].{

	## Decode zstd frames. The output is at most `max_bytes` (MC11): more is `OutputLimit` and no bytes.
	## A window of any size is fine, because the output is the buffer. Use a `ZstdStream` for a big archive.
	zstd_decode! : List(U8), U64 => Try(List(U8), [OutputLimit, WindowTooLarge, BadFrame, Truncated, Unsupported])
	zstd_decode! = |frames, max_bytes| {
		match call!(1, u32_le(clamp(max_bytes)).concat(frames)) {
			Ok(out) => Ok(out)
			Err("output_limit") => Err(OutputLimit)
			Err("window_too_large") => Err(WindowTooLarge)
			Err("bad_frame") => Err(BadFrame)
			Err("truncated") => Err(Truncated)
			Err("unsupported") => Err(Unsupported)
			Err(code) => crash "Native.zstd_decode!: unexpected code ${code}"
		}
	}

	## A zstd decoder that takes the archive in chunks. The window limit is 8 MiB (the hard limit too).
	ZstdStream :: { handle : U32 }.{

		## A stream with the default window limit (8 MiB) and the default limit of one push (16 MiB).
		open! : () => Try(Native.ZstdStream, [TooManyHandles, NoTask])
		open! = || {
			match call!(2, []) {
				Ok(out) => Ok(Native.ZstdStream.{ handle: handle_of(out) })
				Err("too_many_handles") => Err(TooManyHandles)
				Err("no_task") => Err(NoTask)
				Err(code) => crash "Native.ZstdStream.open!: unexpected code ${code}"
			}
		}

		## The same with limits. A limit over 8 MiB for the window is `BadArgument`. Zero is the default.
		open_with! : { window_limit_bytes ?: U64, push_limit_bytes ?: U64 } => Try(Native.ZstdStream, [BadArgument, TooManyHandles, NoTask])
		open_with! = |opts| {
			window = opts.?window_limit_bytes ?? 0
			push = opts.?push_limit_bytes ?? 0
			match call!(2, u32_le(clamp(window)).concat(u32_le(clamp(push)))) {
				Ok(out) => Ok(Native.ZstdStream.{ handle: handle_of(out) })
				Err("bad_argument") => Err(BadArgument)
				Err("too_many_handles") => Err(TooManyHandles)
				Err("no_task") => Err(NoTask)
				Err(code) => crash "Native.ZstdStream.open_with!: unexpected code ${code}"
			}
		}

		## The output of the whole blocks in the chunk (it can be empty). After an error the stream stays
		## dead: each push gives the same error, and `close!` frees it.
		push! : Native.ZstdStream, List(U8) => Try(List(U8), [OutputLimit, WindowTooLarge, BadFrame, Truncated, Unsupported, BadHandle, WrongTask])
		push! = |stream, chunk| {
			Native.ZstdStream.{ handle } = stream
			match call!(3, u32_le(handle).concat(chunk)) {
				Ok(out) => Ok(out)
				Err("output_limit") => Err(OutputLimit)
				Err("window_too_large") => Err(WindowTooLarge)
				Err("bad_frame") => Err(BadFrame)
				Err("truncated") => Err(Truncated)
				Err("unsupported") => Err(Unsupported)
				Err("bad_handle") => Err(BadHandle)
				Err("wrong_task") => Err(WrongTask)
				Err(code) => crash "Native.ZstdStream.push!: unexpected code ${code}"
			}
		}

		## End the input and free the stream, with an error or not. `Truncated`: the input stopped inside a frame.
		close! : Native.ZstdStream => Try({}, [OutputLimit, WindowTooLarge, BadFrame, Truncated, Unsupported, BadHandle, WrongTask])
		close! = |stream| {
			Native.ZstdStream.{ handle } = stream
			match call!(4, u32_le(handle)) {
				Ok(_) => Ok({})
				Err("output_limit") => Err(OutputLimit)
				Err("window_too_large") => Err(WindowTooLarge)
				Err("bad_frame") => Err(BadFrame)
				Err("truncated") => Err(Truncated)
				Err("unsupported") => Err(Unsupported)
				Err("bad_handle") => Err(BadHandle)
				Err("wrong_task") => Err(WrongTask)
				Err(code) => crash "Native.ZstdStream.close!: unexpected code ${code}"
			}
		}
	}

	## BLAKE3 with state. `final!` frees the state, so a second `final!` or `update!` is `BadHandle`.
	Blake3 :: { handle : U32 }.{
		new! : () => Try(Native.Blake3, [TooManyHandles, NoTask])
		new! = || {
			match call!(5, []) {
				Ok(out) => Ok(Native.Blake3.{ handle: handle_of(out) })
				Err("too_many_handles") => Err(TooManyHandles)
				Err("no_task") => Err(NoTask)
				Err(code) => crash "Native.Blake3.new!: unexpected code ${code}"
			}
		}

		update! : Native.Blake3, List(U8) => Try({}, [BadHandle, WrongTask])
		update! = |state, chunk| {
			Native.Blake3.{ handle } = state
			match call!(6, u32_le(handle).concat(chunk)) {
				Ok(_) => Ok({})
				Err("bad_handle") => Err(BadHandle)
				Err("wrong_task") => Err(WrongTask)
				Err(code) => crash "Native.Blake3.update!: unexpected code ${code}"
			}
		}

		## The 32 bytes of the digest.
		final! : Native.Blake3 => Try(List(U8), [BadHandle, WrongTask])
		final! = |state| {
			Native.Blake3.{ handle } = state
			match call!(7, u32_le(handle)) {
				Ok(digest) => Ok(digest)
				Err("bad_handle") => Err(BadHandle)
				Err("wrong_task") => Err(WrongTask)
				Err(code) => crash "Native.Blake3.final!: unexpected code ${code}"
			}
		}
	}

	## SHA-256 with state. The same rules as `Blake3`.
	Sha256 :: { handle : U32 }.{
		new! : () => Try(Native.Sha256, [TooManyHandles, NoTask])
		new! = || {
			match call!(8, []) {
				Ok(out) => Ok(Native.Sha256.{ handle: handle_of(out) })
				Err("too_many_handles") => Err(TooManyHandles)
				Err("no_task") => Err(NoTask)
				Err(code) => crash "Native.Sha256.new!: unexpected code ${code}"
			}
		}

		update! : Native.Sha256, List(U8) => Try({}, [BadHandle, WrongTask])
		update! = |state, chunk| {
			Native.Sha256.{ handle } = state
			match call!(9, u32_le(handle).concat(chunk)) {
				Ok(_) => Ok({})
				Err("bad_handle") => Err(BadHandle)
				Err("wrong_task") => Err(WrongTask)
				Err(code) => crash "Native.Sha256.update!: unexpected code ${code}"
			}
		}

		## The 32 bytes of the digest.
		final! : Native.Sha256 => Try(List(U8), [BadHandle, WrongTask])
		final! = |state| {
			Native.Sha256.{ handle } = state
			match call!(10, u32_le(handle)) {
				Ok(digest) => Ok(digest)
				Err("bad_handle") => Err(BadHandle)
				Err("wrong_task") => Err(WrongTask)
				Err(code) => crash "Native.Sha256.final!: unexpected code ${code}"
			}
		}
	}
}

## One op: status 0 is the bytes, status 1 is the code (API.md 8, a short ASCII text).
call! : U32, List(U8) => Try(List(U8), Str)
call! = |op, bytes| {
	r = Host.native!(op, bytes)
	if (r.status == 0) Ok(r.bytes) else Err(Str.from_utf8_lossy(r.bytes))
}

## The u32 fields of the ops are little-endian.
u32_le : U32 -> List(U8)
u32_le = |n| [n.to_u8_wrap(), n.shr_wrap(8).to_u8_wrap(), n.shr_wrap(16).to_u8_wrap(), n.shr_wrap(24).to_u8_wrap()]

## A limit above the u32 range is the largest u32 (the host takes a u32).
clamp : U64 -> U32
clamp = |n| n.to_u32_try() ?? U32.highest

## The handle in the 4 bytes that an op gives.
handle_of : List(U8) -> U32
handle_of = |out| U32.from_le_bytes(out, 0) ?? crash "Native: a handle is not 4 bytes"
