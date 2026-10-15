## The value of the bridge (API.md 5). The prototype uses only `Js.Ref`: its fake JS side gives CBOR, not `Js` trees.
Js := [
	Undefined,
	Null,
	Bool(Bool),
	Num(F64),
	Int(I64),
	Text(Str),
	Bytes(List(U8)),
	Arr(List(Js)),
	Obj(List((Str, Js))),
	Ref(Js.Ref),
	Error(Str, Str),
	Packed(List(U8)),
].{
	## The id of a JS object in the ref table of the task (API.md 9). `==` compares ids (RS1).
	## The backing is a record: over a bare `U32` (API.md 5), a ref gets the codecs of `U32`, so a ref
	## in typed data would encode as a number (`ref_cbor.roc`, the same bug as `Secret :: Str`).
	Ref :: { id : U32 }.{
		is_eq : _

		## Fake only: in the platform, the host makes refs.
		fake : U32 -> Js.Ref
		fake = |n| Js.Ref.{ id: n }

		## Fake only: the id, for the output of the check and the ops of the fake.
		to_str : Js.Ref -> Str
		to_str = |r| r.id.to_str()
	}
}
