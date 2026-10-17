# Draft: a lookup of a `FieldName` by bytes in `FieldNames` (roc-lang/roc)

Status: DRAFT. Not filed (PLAN.md 8g, proposal P4). Check the text on the newest nightly before it is filed.

Title: `Encoding.FieldName.FieldNames`: find a field by the bytes of its name (no `Str`, no walk of an `Iter`)

## Summary

A format that reads a record from bytes (CBOR, MessagePack, a binary protocol) gets the key as bytes. The derived record
parser has two ways to take a key from the format:

| Way | What the format does | Cost |
|---|---|---|
| `TryField({ name : Str, rest })` | Makes a `Str` from the key bytes. The derived code compares the `Str` with the name of each field. | One `Str` per key (an allocation and a UTF-8 check), then a compare per field |
| `Field({ field : FieldName(_shape), rest })` | Gives the `FieldName` of the field. No `Str`, no compare in the derived code. | The format must find the `FieldName` itself. The only API is to walk `FieldNames.for_size(len)` or `iter` and compare `FieldName.name(f)` with the bytes. |

`Field` should be the fast way, but with the API of the nightlies it is 4.3 to 5.6 times slower than `TryField`, so a format
cannot use it. A lookup by bytes in `FieldNames` would let the format skip both the `Str` and the walk.

## Numbers

wasm32 (`--opt=speed`), nightly `2026-10-12-2664a27`, `roc-cbor` 0.1.0 (`Karakatiza666/roc-cbor`, the `Cbor.parse_with` parser).
200 rows of 8 columns (5 `Str`, 3 `U64`), the same CBOR bytes in all cases. One parse, in microseconds, median of 9 rounds
(Node 26 and workerd 2026-10-12, one machine):

| Case | Node | workerd |
|---|---|---|
| Record `{ grp, version, hash, url, published_at, log_index, yanked, provenance }`, `TryField` (the package as released) | 107.9 | 130.2 |
| Tuple of 8 items (no key at all) | 36.1 | 36.3 |
| Time of record matching (record less tuple) | 71.8 (67 %) | 93.9 (72 %) |
| Record, `Field` with `for_size` and an exact compare of the key bytes | 482 | 725 |
| Record, `Field` with `for_size` and a compare of the length and the first byte only (not correct: a bound) | 466 | 726 |

So 67 to 72 % of a typed record parse is the key matching. The `Field` form is slower with an exact compare and also with
a compare that does almost nothing (466 against 482 us), so the compare is not what costs: the walk of the `Iter`
(`for_size`, then one `FieldName.name` call per field) costs more than the `Str` and the compare that it replaces. This
measure does not show where in the walk the time goes. It shows that the walk is the whole difference.

The same API is in the nightlies `2026-10-09`, `10-12`, `10-14` and `10-15` (the text of `Builtin.roc` in each `roc` binary).

## What the code looks like

The format (`parse_record_field` of the codec protocol) with the API of today, from `bench/8g-cbor-field/Cbor.roc` of the
Talon platform repository:

```roc
parse_record_field = |_, names, state| {
	h = head(state)?                       # CBOR text head: length of the key
	key = state.bytes.sublist({ start: h.next, len: h.arg })
	rest = at(state, h.next + h.arg)
	match find_field(names, h.arg, key) {
		Ok(f) => Ok(Field({ field: f, rest }))
		Err(_) => Ok(TryField({ name: Str.from_utf8(key) ? |_| InvalidCbor(state.pos), rest }))
	}
}

find_field : Encoding.FieldName.FieldNames(_shape), U64, List(U8) -> Try(Encoding.FieldName(_shape), [NoField])
find_field = |names, len, key| {
	for f in names.for_size(len) {
		if same_bytes(f.name(), key) {
			return Ok(f)
		}
	}
	Err(NoField)
}
```

It passes the 78 `expect`s of the package and gives the same records. It is only slower.

## Proposal

One function in `Encoding.FieldName.FieldNames`, so the format gives bytes and gets the field:

```roc
## The field whose name has exactly these UTF-8 bytes (after `rename_fields`).
find : FieldNames(_shape), List(U8) -> Try(FieldName(_shape), [NotFound])
```

Why this shape:

| Point | Reason |
|---|---|
| Bytes in, not `Str` | The format has bytes. A `Str` is the cost that the format wants to skip. |
| The compiler builds the table | It knows all names at compile time and the length range (`shortest_name`, `longest_name` exist already). It can emit a switch on the length and then on the bytes, or a perfect hash. A format cannot do it better, and a user-land walk cannot match it. |
| `NotFound` is not an error | The format then gives `TryField` (an unknown key is skipped by the derived code) or `Continue`, as today. |
| A slice | A `List(U8)` is what the formats hold. A variant with an offset and a length (`find_in`) would avoid the `sublist` of the key. A detail to settle in the discussion. |

The builtin HTTP header format (`parse_record_field_from_headers` in `Builtin.roc`) also makes a `Str` for each header name
and gives `TryFieldCaseless`, so a lookup by bytes (with a caseless form) could serve it too.

## Repro

The measure needs a wasm host, so it is a harness in the Talon repository (`cloudflare-workers/`, the platform with a
Zig host). Files, from the root of that repository:

| File | What |
|---|---|
| `bench/8g-cbor-field/Cbor.roc` | `roc-cbor` 0.1.0 with `Field` and `for_size` (exact compare). `roc test bench/8g-cbor-field/Cbor.roc`: 78 of 78 `expect`s pass |
| `bench/8g-cbor-first/Cbor.roc` | The same with the compare of the length and the first byte only |
| `bench/8g/app.roc` | The measure app: routes `/parse/records`, `/parse/tuples`, `/parse/variant_field`, `/parse/variant_first` |
| `bench/8g/run-node.mjs` | `SECTIONS=parse node bench/8g/run-node.mjs` (after `ZIG=<zig 0.17> bench/8g/build.sh default`) prints the table above |

A repro that needs no host: a program that calls `Cbor.parse_with` on 200 rows of 8 fields, built twice (the package as
released, and the package of `bench/8g-cbor-field/`), with a timer around a loop of parses. On native (Linux x86_64,
`--opt=speed`) the package as released took 137 us for records and 66 us for tuples (`research/api-probe/cbor/bench.roc`).
The `Field` form was measured only in wasm.

## Not asked

| Item | Why not |
|---|---|
| A change to the derived parser | `Field` already skips the compare. Only the lookup is missing. |
| A host decoder into app types | Separate problem: the host is built before any app exists. |
