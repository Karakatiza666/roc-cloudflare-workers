## The platform module `Cbor` (MODULES.md MC5, PLAN.md 8c): a wrapper of the package `roc-cbor`. This app has no `cbor`
## entry in its header, so each route proves that an app needs none. A route answers `Str.inspect` of the result.
## `checks/cbor.mjs` checks them.
import pf.Request
import pf.Response
import pf.Cbor
import Q

Person : { id : I64, name : Str, avatar : Cbor.Bytes }

## A value of any depth, for the stack check (`?n=` levels): the derived codec of a recursive type uses one frame for each level.
## In a `--opt=dev` build the frames are large (roc-lang/roc#12922): bench/stack-modes.sh uses it for the 2 MiB stack.
Nest := [Leaf(I64), Node(Nest)].{
	is_eq : _
	encoder_for : _
	parser_for : _
}

nest : U64 -> Nest
nest = |n| if n == 0 Nest.Leaf(7) else Nest.Node(nest(n - 1))

## A text id that must start with `id-`: a custom `parser_for` made with `Cbor.Format` and `Cbor.State`.
Tag := Str.{
	is_eq : Tag, Tag -> Bool
	is_eq = |Tag.(a), Tag.(b)| a == b

	parser_for : Cbor.Format -> (Cbor.State -> Try({ value : Tag, rest : Cbor.State }, [InvalidCbor(U64)]))
	parser_for = |enc| |state| {
		parsed = enc.parse_str(state)?
		if (parsed.value.starts_with("id-")) Ok({ value: Tag.(parsed.value), rest: parsed.rest }) else Err(enc.invalid_value(state))
	}
}

TagRow : { tag : Tag }

NullRec : { id : I64, note : Try(Str, [Null]) }

OptRec : { id : I64, note ?: Str }

MissRec : { id : I64, note : Try(Str, [Missing]) }

## A helper with the `where` aliases of the module.
round_trip : a -> Try(a, _) where [a.Cbor.Encodable([]), a.Cbor.Parseable([InvalidCbor(U64), ..errs])]
round_trip = |value| Cbor.parse(Cbor.encode(value))

## The path of the item of an `InvalidCbor(pos)`.
error_path : List(U8), Try(a, [InvalidCbor(U64), ..others]) -> Try(List(Cbor.Step), [NotFound])
error_path = |raw, parsed| match parsed {
	Err(InvalidCbor(pos)) => Cbor.path_at(raw, pos)
	_ => Err(NotFound)
}

CborRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| {
		match path {
			# A record with a `Cbor.Bytes` field: its bytes are a byte string (0x43), not an array.
			["bytes"] => {
				raw = Cbor.encode({ id: 7.I64, name: "x", avatar: Cbor.bytes([1, 2, 3]) })
				back : Try(Person, _)
				back = Cbor.parse(raw)
				text(Str.inspect(raw), Str.inspect(back.map_ok(|p| p.avatar.to_list())))
			}
			# `n` levels: encode, read back, compare. The answer has the size of the bytes and the result of the compare.
			["nest"] => {
				n = Q.num(req, "n")
				value = nest(n)
				raw = Cbor.encode(value)
				back : Try(Nest, _)
				back = Cbor.parse(raw)
				text("n=${n.to_str()} bytes=${raw.len().to_str()}", "same=${Str.inspect(back == Ok(value))}")
			}
			["generic"] => {
				got : Try(List(U64), _)
				got = round_trip([1, 2, 3])
				text(Str.inspect(got), "")
			}
			["custom"] => {
				ok : Try(TagRow, _)
				ok = Cbor.parse(Cbor.encode({ tag: "id-1" }))
				bad : Try(TagRow, _)
				bad = Cbor.parse(Cbor.encode({ tag: "x-1" }))
				text(Str.inspect(ok), Str.inspect(bad))
			}
			# `parse_camel` and `parse_with` read the key `userId`. `path_at` finds the field of an error.
			["options"] => {
				raw = Cbor.encode({ userId: 5.U64 })
				camel : Try({ user_id : U64 }, _)
				camel = Cbor.parse_camel(raw)
				snake : Try({ user_id : U64 }, _)
				snake = Cbor.parse(raw)
				viaopt : Try({ user_id : U64 }, _)
				viaopt = Cbor.parse_with(raw, { fields: Camel, allow: [] })
				text("${Str.inspect(camel)} ${Str.inspect(viaopt)}", Str.inspect(snake))
			}
			["path"] => {
				raw = Cbor.encode([{ name: "a", id: "x" }])
				bad : Try(List({ name : Str, id : U64 }), _)
				bad = Cbor.parse(raw)
				text(Str.inspect(bad), Str.inspect(error_path(raw, bad)))
			}
			# roc-cbor 0.2.2: `Err(Null)` in a record field writes no key (one key, the head 0xa1). Read back, the field is
			# required for `Try(a, [Null])` (`MissingRequiredField`), absent for `?:` and `Err(Missing)` for `Try(a, [Missing])`.
			# Outside a record a null reads into `Try(a, [Null])` (a list item), and a `Bool` reads 0 and 1.
			["null"] => {
				nullable : Try(Str, [Null])
				nullable = Err(Null)
				raw = Cbor.encode({ id: 7.I64, note: nullable })
				required : Try(NullRec, _)
				required = Cbor.parse(raw)
				optional : Try(OptRec, _)
				optional = Cbor.parse(raw)
				missing : Try(MissRec, _)
				missing = Cbor.parse(raw)
				items : Try(List(Try(Str, [Null])), _)
				items = round_trip([Ok("a"), Err(Null)])
				bools : Try(List(Bool), _)
				bools = Cbor.parse([0x84, 0xf4, 0xf5, 0x00, 0x01])
				# js_values (a value from JS): the null is no key, so ?: and Try(a, [Missing]) read it as absent, and a
				# Try(a, [Null]) field is MissingRequiredField.
				js_optional : Try(OptRec, _)
				js_optional = Cbor.parse_with(raw, { allow: Cbor.js_values })
				js_missing : Try(MissRec, _)
				js_missing = Cbor.parse_with(raw, { allow: Cbor.js_values })
				js_required : Try(NullRec, _)
				js_required = Cbor.parse_with(raw, { allow: Cbor.js_values })
				int_bools : Try(List(Bool), _)
				int_bools = Cbor.parse_with([0x84, 0xf4, 0xf5, 0x00, 0x01], { allow: [BoolFromInt] })
				text("${Str.inspect(raw)} ${Str.inspect(required)} ${Str.inspect(optional.map_ok(|r| r.?note))}", "${Str.inspect(missing.map_ok(|r| r.note))} ${Str.inspect(items)} ${Str.inspect(bools)} | js ${Str.inspect(js_optional.map_ok(|r| r.?note))} ${Str.inspect(js_missing.map_ok(|r| r.note))} ${Str.inspect(js_required)} ${Str.inspect(int_bools)}")
			}
			_ => Response.from_text(404, "no route")
		}
	}
}

text : Str, Str -> Response
text = |a, b| Response.from_text(200, if (b == "") a else "${a} | ${b}")
