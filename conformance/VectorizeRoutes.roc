## `Vectorize` (MODULES.md 13). The index is the JS stub `STUB_VECTORIZE` of `conformance/bindings.js` (Vectorize has no
## local form): an in-memory index that records each call, and `/__stub_calls` gives the record. The metadata type is
## `Meta`. The twin of a route is `<name>_io`.
import pf.Request
import pf.Response
import pf.Vectorize
import pf.Io
import Q

Meta : { genre : Str, year : U64 }
Wrong : { genre : U64 }

index : Vectorize(Meta)
index = Vectorize.json("STUB_VECTORIZE")

Scored : { score : F64 }

scored : Vectorize(Scored)
scored = Vectorize.json("STUB_VECTORIZE")

wrong : Vectorize(Wrong)
wrong = Vectorize.json("STUB_VECTORIZE")

vectors : List(Vectorize.Vector(Meta))
vectors = [
	{ id: "a", values: [0.5, 1.5], metadata: { genre: "rock", year: 1999 } },
	{ id: "b", values: [1.0, 2.0], namespace: "n1" },
	{ id: "c", values: [3.0], namespace: "n1", metadata: { genre: "jazz", year: 1960 } },
]

VectorizeRoutes :: [].{
	route! : Request, List(Str) => Response
	route! = |req, path| {
		q = [0.1, 0.2]
		match path {
			["upsert"] => mutation(index.upsert!(vectors))
			["upsert_io"] => mutation(Io.run!(index.upsert(vectors)))
			# A metadata with an `F64` field is sent as JSON; a `NaN` is `BadData` and no call is made.
			["upsert_f64"] => mutation(scored.upsert!([{ id: "f", values: [1.0], metadata: { score: 0.25 } }]))
			["upsert_nan"] => mutation(scored.upsert!([{ id: "n", values: [1.0], metadata: { score: 0.0 / 0.0 } }]))
			["insert_nan"] => mutation(Io.run!(scored.insert([{ id: "n", values: [1.0], metadata: { score: 0.0 / 0.0 } }])))
			["insert"] => mutation(index.insert!(vectors))
			["insert_io"] => mutation(Io.run!(index.insert(vectors)))
			# `insert` of an id that exists changes nothing (the stub; Workers: the vector is ignored).
			["insert_changed"] => mutation(index.insert!([{ id: "a", values: [9.0], metadata: { genre: "new", year: 1 } }]))
			["query"] => matches(index.query!(q))
			["query_io"] => matches(Io.run!(index.query(q)))
			# All the options.
			["query_with"] => matches(index.query_with!(q, { top_k: Q.num(req, "k"), namespace: Q.text(req, "ns"), return_values: Bool.True, return_metadata: All, filter: Obj([("genre", Text(Q.text(req, "genre")))]) }))
			["query_with_io"] => matches(Io.run!(index.query_with(q, { top_k: Q.num(req, "k"), namespace: Q.text(req, "ns"), return_values: Bool.True, return_metadata: All, filter: Obj([("genre", Text(Q.text(req, "genre")))]) })))
			# No option: nothing goes to JS.
			["query_with_none"] => matches(index.query_with!(q, {}))
			["query_with_indexed"] => matches(index.query_with!(q, { return_metadata: Indexed }))
			["query_with_nometa"] => matches(index.query_with!(q, { return_metadata: None, return_values: Bool.False }))
			["get"] => stored(index.get!(["a", "b", "zz"]))
			["get_io"] => stored(Io.run!(index.get(["a", "b", "zz"])))
			["delete"] => mutation(index.delete!(["a", "zz"]))
			["delete_io"] => mutation(Io.run!(index.delete(["a", "zz"])))
			# A metadata that does not fit the type of the index.
			["query_wrong"] => ok(
				match wrong.query_with!(q, { return_metadata: All }) {
					Ok(_) => "Ok"
					Err(BadData(text)) => "BadData ${text}"
					Err(e) => Str.inspect(e)
				},
			)
			# A result of 1.2 MB (the namespace `big` of the stub, or the id `big`): `TooLarge`. Vectorize has no `max_bytes` form: only the default limit (MC11).
			["query_big"] => matches(index.query_with!(q, { namespace: "big", return_metadata: All }))
			# The same with `max_bytes` of 2 MB: the match comes, and the size of its metadata shows.
			["query_big_max"] => match index.query_with!(q, { namespace: "big", return_metadata: All, max_bytes: 2_000_000 }) {
				Ok(res) => ok("count=${res.count.to_str()} genre_len=${res.matches.map(|m| m.metadata.map_ok(|x| x.genre.count_utf8_bytes()) ?? 0).sum().to_str()}")
				Err(e) => ok(Str.inspect(e))
			}
			["get_big"] => stored(index.get!(["big"]))
			# A binding that is not in the config: the `Call` on undefined throws (OP7).
			["missing"] => {
				absent : Vectorize(Meta)
				absent = Vectorize.json("NO_SUCH_INDEX")
				matches(absent.query!(q))
			}
			_ => Response.from_text(404, "no route")
		}
	}
}

ok : Str -> Response
ok = |text| Response.from_text(200, text)

mutation : Try(Vectorize.Mutation, [VectorizeErr({ name : Str, message : Str }), BadData(Str)]) -> Response
mutation = |r| ok(
	match r {
		Ok(m) => "Ok ${m.mutation_id}"
		Err(VectorizeErr(t)) => "VectorizeErr ${t.name}: ${t.message}"
		Err(BadData(text)) => "BadData ${text}"
	},
)

matches : Try({ matches : List(Vectorize.Match(Meta)), count : U64 }, [VectorizeErr({ name : Str, message : Str }), BadData(Str), TooLarge]) -> Response
matches = |r| ok(
	match r {
		Ok(res) => "count=${res.count.to_str()} ${Str.join_with(res.matches.map(match_text), " ")}"
		Err(VectorizeErr(t)) => "VectorizeErr ${t.name}: ${t.message}"
		Err(BadData(text)) => "BadData ${text}"
		Err(TooLarge) => "TooLarge"
	},
)

match_text : Vectorize.Match(Meta) -> Str
match_text = |m| "[${m.id} score=${m.score.to_str()} values=${values(m.values)} ns=${m.namespace ?? "-"} meta=${meta(m.metadata)}]"

stored : Try(List(Vectorize.Stored(Meta)), [VectorizeErr({ name : Str, message : Str }), BadData(Str), TooLarge]) -> Response
stored = |r| ok(
	match r {
		Ok(vs) => "count=${vs.len().to_str()} ${Str.join_with(vs.map(|v| "[${v.id} values=${values(v.values)} ns=${v.namespace ?? "-"} meta=${meta(v.metadata)}]"), " ")}"
		Err(VectorizeErr(t)) => "VectorizeErr ${t.name}: ${t.message}"
		Err(BadData(text)) => "BadData ${text}"
		Err(TooLarge) => "TooLarge"
	},
)

values : List(F64) -> Str
values = |vs| Str.join_with(vs.map(|f| f.to_str()), ",")

meta : Try(Meta, [Missing]) -> Str
meta = |m| match m {
	Ok(x) => "${x.genre}/${x.year.to_str()}"
	Err(Missing) => "-"
}
