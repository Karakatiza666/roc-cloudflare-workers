## `Dec` and the other value rules of roc-cbor 0.2.0 (MODULES.md 1 "Formats of typed data", "The Dec in JS"; 5.1). Route
## `/dec/<name>`; `checks/dec.mjs` checks them. `?v=` picks a `Dec` from `dec_of`. The D1 tables are made by `checks/dec.mjs`.
import pf.Request
import pf.Response
import pf.Cbor
import pf.D1
import pf.Sql
import pf.Io
import pf.Rpc
import pf.Service
import pf.Queue
import pf.Memo
import pf.Log
import pf.WebCrypto
import RpcMethods
import Q

db = D1.binding("DB")

self_service = Service.binding("SELF", RpcMethods.default_iface)

## The queues: `DECJ` (json, a JS consumer), `DECV` (v8, the Roc consumer `consume!`), `DECVJS` (v8, a JS consumer).
Msg : { label : Str, n : U64, d : Dec, whole : Dec, big : Dec, list : List(Dec) }

decj : Queue(Msg)
decj = Queue.json("DECJ")

decv : Queue(Msg)
decv = Queue.v8("DECV")

decv_js : Queue(Msg)
decv_js = Queue.v8("DECVJS")

## Rows of the typed reads.
TypedReal : { t : Str, r : F64 }

Blob : { b : Cbor.Bytes }

BlobList : { b : List(U8) }

NeedsX : { x : I64 }

DecRow : { x : Dec }

## The value that is sent, stored and sent back.
Pair : { a : Dec, b : Dec }

echo_dec : Rpc(RpcMethods.Default, Pair, Pair, Rpc.NoErr)
echo_dec = Rpc.method("echo_dec")

## The value of the Memo has an id that `load!` makes new each time: a second `get!` with the same id was read from the pin
## (a pinned value that does not parse loads again, so the equal Decs alone would not show a failed parse).
Kept : { a : Dec, b : Dec, id : Str }

pair_memo : Memo(Kept, [LoadErr])
pair_memo = Memo.new("conformance-dec", { max_age_ms: 600_000, load!: load_pair! })

load_pair! : () => Try(Kept, [LoadErr])
load_pair! = || Ok({ a: exact_pair.a, b: exact_pair.b, id: WebCrypto.random_uuid!() })

exact_pair : Pair
exact_pair = { a: 0.1, b: Dec.lowest }

DecRoutes :: [].{

	## The RPC method of the default export (`rpc` of `Worker`).
	rpc : List(Rpc.Serves(RpcMethods.Default, {}))
	rpc = [echo_dec.on_worker(echo_handler!)]

	route! : Request, List(Str) => Response
	route! = |req, path| {
		v = dec_of(Q.text(req, "v"))
		match path {
			# The bytes that Roc writes for the `Dec` (a list of numbers, `Str.inspect`).
			["encode"] => Response.from_text(200, Str.inspect(Cbor.encode(v)))
			# MODULES.md 5.1: a `Dec` parameter. `frac`: a fraction binds a Number (typeof real); `lit1`: the list literal `[1]` binds 1.
			["d1_param", "frac"] => d1_param!(Q.text(req, "v"), "INSERT INTO dec_t (k, r) VALUES (?, ?)", (Q.text(req, "v"), v))
			["d1_param", "lit1"] => d1_param!("lit1", "INSERT INTO dec_t (k, r) VALUES ('lit1', ?)", [1])
			["d1_param", "twin"] => {
				_ = Io.run!(db.run("INSERT INTO dec_t (k, r) VALUES (?, ?)", ("twin-${Q.text(req, "v")}", v)))
				read_param!("twin-${Q.text(req, "v")}")
			}
			# A `Dec` field read from a D1 float, an integer and a text-free value.
			["d1_read"] => {
				r : Try(List(DecRow), _)
				r = db.all!("SELECT 2.5 AS x UNION ALL SELECT 3 AS x UNION ALL SELECT 0.1 AS x", Sql.none)
				Response.from_text(
					200,
					match r {
						Ok(rows) => "Ok ${Str.join_with(rows.map(|row| row.x.to_str()), " ")}"
						Err(e) => "Err ${Str.inspect(e)}"
					},
				)
			}
			# A BLOB (JS gives an array of numbers) reads into `Cbor.Bytes` and into `List(U8)`.
			["d1_blob"] => {
				a : Try(List(Blob), _)
				a = db.all!("SELECT x'0102ff' AS b", Sql.none)
				b : Try(List(BlobList), _)
				b = db.all!("SELECT x'0102ff' AS b", Sql.none)
				c : Try(List(Blob), _)
				c = db.all!("SELECT x'' AS b", Sql.none)
				Response.from_text(200, "bytes=${Str.inspect(a.map_ok(|rows| rows.map(|r| r.b.to_list())))} list=${Str.inspect(b.map_ok(|rows| rows.map(|r| r.b)))} empty=${Str.inspect(c.map_ok(|rows| rows.map(|r| r.b.to_list())))}")
			}
			# A missing column of a typed row is `BadData("column x: missing")`.
			["d1_missing"] => {
				a : Try(List(NeedsX), _)
				a = db.all!("SELECT 1 AS y", Sql.none)
				b : Try(NeedsX, _)
				b = db.first!("SELECT 1 AS y", Sql.none)
				Response.from_text(200, "all=${Str.inspect(a)} first=${Str.inspect(b)}")
			}
			# The options of `Cbor.parse_with` are optional: `{}`, and `{ int_from_text: Bool.True }`.
			["options"] => {
				raw = Cbor.encode({ user_id: "12" })
				none : Try({ user_id : U64 }, _)
				none = Cbor.parse_with(raw, {})
				text_ok : Try({ user_id : U64 }, _)
				text_ok = Cbor.parse_with(raw, { int_from_text: Bool.True })
				plain : Try({ user_id : U64 }, _)
				plain = Cbor.parse(raw)
				Response.from_text(200, "{}=${Str.inspect(none)} int_from_text=${Str.inspect(text_ok)} parse=${Str.inspect(plain)}")
			}
			# A `Dec` crosses an RPC call (JS decode, structured clone, encode) and comes back equal.
			["rpc"] => match self_service.call!(echo_dec, { a: v, b: Dec.lowest }) {
				Ok(back) => Response.from_text(200, "Ok same=${Str.inspect(back == { a: v, b: Dec.lowest })} a=${back.a.to_str()} b=${back.b.to_str()}")
				Err(e) => Response.from_text(200, "Err ${Str.inspect(e)}")
			}
			# A `Dec` in a Memo: the first `get!` loads, the second reads the cache.
			["memo"] => {
				pair_memo.clear!()
				first = pair_memo.get!()
				second = pair_memo.get!()
				same_id = match (first, second) {
					(Ok(x), Ok(y)) => x.id == y.id
					_ => Bool.False
				}
				Response.from_text(200, "same_id=${Str.inspect(same_id)} a=${Str.inspect(second.map_ok(|p| p.a.to_str()))} b=${Str.inspect(second.map_ok(|p| p.b.to_str()))}")
			}
			["queue", "json"] => queued(decj.send!(msg(req)))
			["queue", "json_batch"] => queued(decj.send_batch!([msg(req), { ..msg(req), n: 2 }]))
			["queue", "v8"] => queued(decv.send!(msg(req)))
			["queue", "v8_js"] => queued(decv_js.send!(msg(req)))
			_ => Response.from_text(404, "no route")
		}
	}

	## The `queue!` of the app for the queue `DECV`: it logs the `Dec` fields as text.
	consume! : Queue.Batch => Try({}, [Boom])
	consume! = |batch| {
		_ = decv.each!(batch, |_msg, m| Ok(Log.info!("dec", { label: m.label, d: m.d.to_str(), whole: m.whole.to_str(), big: m.big.to_str(), list: Str.join_with(m.list.map(|x| x.to_str()), ","), n: m.n.to_str() })))
		Ok({})
	}
}

msg : Request -> Msg
msg = |req| { label: Q.text(req, "label"), n: 1, d: 0.1, whole: 5, big: Dec.highest, list: [1.5, 2, -0.25] }

queued : Try({}, e) -> Response
queued = |r| Response.from_text(
	200,
	match r {
		Ok(_) => "Ok"
		Err(e) => "Err ${Str.inspect(e)}"
	},
)

echo_handler! : Pair => Try(Pair, Rpc.NoErr)
echo_handler! = |p| Ok(p)

## The `Dec` that `?v=` names.
dec_of : Str -> Dec
dec_of = |name| match name {
	"frac" => 3.14159
	"neg" => -2.75
	# A mantissa of 2^53 or more and below 2^64 (a CBOR integer of 8 bytes).
	"mid" => 123456789012.345678
	"negmid" => -123456789012.345678
	# A mantissa of 2^64 or more (a bignum, tag 2 and tag 3).
	"big" => Dec.highest
	"bigneg" => Dec.lowest
	# A mantissa of exactly 2^53 (and -2^53): the edge of the Number range of the reader.
	"p53" => 9.007199254740992
	"np53" => -9.007199254740992
	"int" => 42
	"tiny" => 0.000000000000000001
	_ => 0.1
}

## Binds the parameters, then reads the `typeof` and the value of the row `k` back.
d1_param! : Str, Str, params => Response where [params.Cbor.Writable]
d1_param! = |k, sql, params| {
	_ = db.run!(sql, params)
	read_param!(k)
}

read_param! : Str => Response
read_param! = |k| {
	r : Try(List(TypedReal), _)
	r = db.all!("SELECT typeof(r) AS t, r FROM dec_t WHERE k = ?", [k])
	Response.from_text(200, "${Str.inspect(r)}")
}
