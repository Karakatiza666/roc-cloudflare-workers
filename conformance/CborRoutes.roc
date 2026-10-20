## The platform module `Cbor` (MODULES.md MC5, PLAN.md 8c): a wrapper of the package `roc-cbor`. This app has no `cbor`
## entry in its header, so each route proves that an app needs none. A route answers `Str.inspect` of the result.
## `checks/cbor.mjs` checks them.
import pf.Request
import pf.Response
import pf.Cbor

Person : { id : I64, name : Str, avatar : Cbor.Bytes }

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
	route! = |_req, path| {
		match path {
			# A record with a `Cbor.Bytes` field: its bytes are a byte string (0x43), not an array.
			["bytes"] => {
				raw = Cbor.encode({ id: 7.I64, name: "x", avatar: Cbor.bytes([1, 2, 3]) })
				back : Try(Person, _)
				back = Cbor.parse(raw)
				text(Str.inspect(raw), Str.inspect(back.map_ok(|p| p.avatar.to_list())))
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
				viaopt = Cbor.parse_with(raw, { fields: Camel, int_from_text: Bool.False })
				text("${Str.inspect(camel)} ${Str.inspect(viaopt)}", Str.inspect(snake))
			}
			["path"] => {
				raw = Cbor.encode([{ name: "a", id: "x" }])
				bad : Try(List({ name : Str, id : U64 }), _)
				bad = Cbor.parse(raw)
				text(Str.inspect(bad), Str.inspect(error_path(raw, bad)))
			}
			_ => Response.from_text(404, "no route")
		}
	}
}

text : Str, Str -> Response
text = |a, b| Response.from_text(200, if (b == "") a else "${a} | ${b}")
