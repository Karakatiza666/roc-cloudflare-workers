## A Vectorize index (MODULES.md 13): `env[name].query`, `upsert`, `insert`, `getByIds`, `deleteByIds` (the index API v2),
## one wait each. The metadata of a vector is JSON at rest, so the constant has the format `Json` and the type of the
## metadata (MC5, MC6): `index : Vectorize(Meta)`, `index = Vectorize.json("INDEX")`.
## A result is a `Js` tree (`pf.limit`, to `Body.default_max` bytes, MC11) that the module reads in Roc: a `where` clause
## cannot name a record with a type variable inside (MODULES.md 15). The metadata of each vector goes to JSON text, then
## to the type. A vector goes out as one JSON text that JS reads with `JSON.parse`, because a record with optional fields
## has no JSON encoder that leaves a field out.
import Io
import Js
import Body

Vectorize(meta) := { name : Str, write : meta -> Try(Str, Str), read : Str -> Try(meta, Str) }.{

	## A constant (WR1): the name of the binding and the codecs of the metadata.
	json : Str -> Vectorize(meta) where [meta.Json.Encodable(enc), meta.Json.Parseable([InvalidJson(Str), ..errs])]
	json = |name| Vectorize.{ name, write: |m| Json.to_str_try(m).map_err(|e| Str.inspect(e)), read: |text| Json.parse(text).map_err(|e| Str.inspect(e)) }

	## The binding for the manifest (`Worker.new({ bindings: [...] })`, MODULES.md 3): the kind `vectorize`.
	declare : Vectorize(meta) -> { name : Str, kind : Str, props : List((Str, Str)) }
	declare = |b| { name: b.name, kind: "vectorize", props: [] }

	## A vector to write: `namespace` and `metadata` are optional.
	Vector(m) : { id : Str, values : List(F64), namespace ?: Str, metadata ?: m }

	## A match of `query`: `values` is empty unless `return_values` is set, `metadata` is `Missing` unless `return_metadata`
	## is `Indexed` or `All`.
	Match(m) : { id : Str, score : F64, values : List(F64), namespace : Try(Str, [Missing]), metadata : Try(m, [Missing]) }

	## A vector of `get!`.
	Stored(m) : { id : Str, values : List(F64), namespace : Try(Str, [Missing]), metadata : Try(m, [Missing]) }

	## `topK` (Workers default: 5), `namespace`, `returnValues`, `returnMetadata` (`None`, `Indexed`: the indexed
	## fields only, `All`) and `filter` (the metadata filter of Vectorize, a `Js` object of the app). `max_bytes`: the limit of the
	## result (default `Body.default_max`, MC11): it is not sent to Vectorize.
	QueryOptions : { top_k ?: U64, namespace ?: Str, return_values ?: Bool, return_metadata ?: [None, Indexed, All], filter ?: Js, max_bytes ?: U64 }

	## What `upsert`, `insert` and `deleteByIds` give: the id of the asynchronous mutation.
	Mutation : { mutation_id : Str }

	query : Vectorize(meta), List(F64) -> Io({ matches : List(Vectorize.Match(meta)), count : U64 }, [VectorizeErr(Io.Thrown), BadData(Str), TooLarge])
	query = |index, values| query_io(index, values, [], Body.default_max)

	query! : Vectorize(meta), List(F64) => Try({ matches : List(Vectorize.Match(meta)), count : U64 }, [VectorizeErr(Io.Thrown), BadData(Str), TooLarge])
	query! = |index, values| Io.run!(query(index, values))

	query_with : Vectorize(meta), List(F64), Vectorize.QueryOptions -> Io({ matches : List(Vectorize.Match(meta)), count : U64 }, [VectorizeErr(Io.Thrown), BadData(Str), TooLarge])
	query_with = |index, values, opts| query_io(index, values, query_js(opts), opts.?max_bytes ?? Body.default_max)

	query_with! : Vectorize(meta), List(F64), Vectorize.QueryOptions => Try({ matches : List(Vectorize.Match(meta)), count : U64 }, [VectorizeErr(Io.Thrown), BadData(Str), TooLarge])
	query_with! = |index, values, opts| Io.run!(query_with(index, values, opts))

	upsert : Vectorize(meta), List(Vectorize.Vector(meta)) -> Io(Vectorize.Mutation, [VectorizeErr(Io.Thrown), BadData(Str)])
	upsert = |index, vectors| write_io(index, "upsert", vectors)

	upsert! : Vectorize(meta), List(Vectorize.Vector(meta)) => Try(Vectorize.Mutation, [VectorizeErr(Io.Thrown), BadData(Str)])
	upsert! = |index, vectors| Io.run!(upsert(index, vectors))

	## `insert`: a vector with an id that exists is ignored (Vectorize docs), `upsert` replaces it.
	insert : Vectorize(meta), List(Vectorize.Vector(meta)) -> Io(Vectorize.Mutation, [VectorizeErr(Io.Thrown), BadData(Str)])
	insert = |index, vectors| write_io(index, "insert", vectors)

	insert! : Vectorize(meta), List(Vectorize.Vector(meta)) => Try(Vectorize.Mutation, [VectorizeErr(Io.Thrown), BadData(Str)])
	insert! = |index, vectors| Io.run!(insert(index, vectors))

	## `getByIds`: the vectors that exist, in no set order.
	get : Vectorize(meta), List(Str) -> Io(List(Vectorize.Stored(meta)), [VectorizeErr(Io.Thrown), BadData(Str), TooLarge])
	get = |index, ids| {
		read = index.read
		Io.new(
			[
				Get(Root("env"), index.name),
				Call(Slot(0), "getByIds", [Lit(Arr(ids.map(|id| Text(id))))]),
				Call(Root("pf"), "limit", [Slot(1), Lit(Int(limit(Body.default_max)))]),
			],
			|r| match r {
				Ok(Arr(items)) => stored_list(read, items).map_err(|why| BadData(why))
				Ok(other) => Err(BadData("getByIds gave ${shape(other)}"))
				Err(t) => Err(read_error(t))
			},
		)
	}

	get! : Vectorize(meta), List(Str) => Try(List(Vectorize.Stored(meta)), [VectorizeErr(Io.Thrown), BadData(Str), TooLarge])
	get! = |index, ids| Io.run!(get(index, ids))

	delete : Vectorize(meta), List(Str) -> Io(Vectorize.Mutation, [VectorizeErr(Io.Thrown), BadData(Str)])
	delete = |index, ids| Io.new(
		[Get(Root("env"), index.name), Call(Slot(0), "deleteByIds", [Lit(Arr(ids.map(|id| Text(id))))])],
		mutation_read,
	)

	delete! : Vectorize(meta), List(Str) => Try(Vectorize.Mutation, [VectorizeErr(Io.Thrown), BadData(Str)])
	delete! = |index, ids| Io.run!(delete(index, ids))
}

## `query(vector, options)`. `opts`: the fields of the options object.
query_io : Vectorize(meta), List(F64), List((Str, Js)), U64 -> Io({ matches : List(Vectorize.Match(meta)), count : U64 }, [VectorizeErr(Io.Thrown), BadData(Str), TooLarge])
query_io = |index, values, opts, max| {
	read = index.read
	Io.new(
		[
			Get(Root("env"), index.name),
			Call(Slot(0), "query", [Lit(Arr(values.map(|f| Num(f)))), Lit(Obj(opts))]),
			Call(Root("pf"), "limit", [Slot(1), Lit(Int(limit(max)))]),
		],
		|r| match r {
			Ok(js) => matches_of(read, js).map_err(|why| BadData(why))
			Err(t) => Err(read_error(t))
		},
	)
}

## `upsert` or `insert` of the vectors, which are one JSON text (JS: `JSON.parse`).
write_io : Vectorize(meta), Str, List(Vectorize.Vector(meta)) -> Io(Vectorize.Mutation, [VectorizeErr(Io.Thrown), BadData(Str)])
write_io = |index, method, vectors| {
	write = index.write
	match vectors_json(write, vectors) {
		Ok(text) => Io.new(
			[
				Get(Root("global"), "JSON"),
				Call(Slot(0), "parse", [Lit(Text(text))]),
				Get(Root("env"), index.name),
				Call(Slot(2), method, [Slot(1)]),
			],
			mutation_read,
		)
		# A metadata that does not encode (a `NaN` in an `F64`): no program, so nothing is sent.
		Err(m) => Io.sync([], |_| Err(BadData("the metadata does not encode: ${m}")))
	}
}

mutation_read : Try(Js, Io.Thrown) -> Try(Vectorize.Mutation, [VectorizeErr(Io.Thrown), BadData(Str)])
mutation_read = |r| match r {
	Ok(Obj(fs)) => match field(fs, "mutationId") {
		Text(id) => Ok({ mutation_id: id })
		other => Err(BadData("the result has no mutationId: ${shape(other)}"))
	}
	Ok(other) => Err(BadData("the result is ${shape(other)}"))
	Err(t) => Err(VectorizeErr(t))
}

read_error : Io.Thrown -> [VectorizeErr(Io.Thrown), TooLarge]
read_error = |t| if (t.name == "TooLarge") TooLarge else VectorizeErr(t)

## The options object of `query`: only the fields that the app gives (not `max_bytes`).
query_js : Vectorize.QueryOptions -> List((Str, Js))
query_js = |o| {
	a = match o.?top_k {
		Ok(n) => [("topK", Int(limit(n)))]
		Err(_) => []
	}
	b = match o.?namespace {
		Ok(s) => a.append(("namespace", Text(s)))
		Err(_) => a
	}
	c = match o.?return_values {
		Ok(v) => b.append(("returnValues", Bool(v)))
		Err(_) => b
	}
	d = match o.?return_metadata {
		Ok(None) => c.append(("returnMetadata", Text("none")))
		Ok(Indexed) => c.append(("returnMetadata", Text("indexed")))
		Ok(All) => c.append(("returnMetadata", Text("all")))
		Err(_) => c
	}
	match o.?filter {
		Ok(f) => d.append(("filter", f))
		Err(_) => d
	}
}

## The JSON text of a list of vectors: `[{"id":..,"values":[..],"namespace":..,"metadata":..}]`.
vectors_json : (meta -> Try(Str, Str)), List(Vectorize.Vector(meta)) -> Try(Str, Str)
vectors_json = |write, vectors| {
	items = vectors.map_try(
		|v| {
			ns = match v.?namespace {
				Ok(s) => ",\"namespace\":${Json.to_str(s)}"
				Err(_) => ""
			}
			md = match v.?metadata {
				Ok(m) => ",\"metadata\":${write(m)?}"
				Err(_) => ""
			}
			Ok("{\"id\":${Json.to_str(v.id)},\"values\":[${Str.join_with(v.values.map(f64_json), ",")}]${ns}${md}}")
		},
	)?
	Ok("[${Str.join_with(items, ",")}]")
}

matches_of : (Str -> Try(meta, Str)), Js -> Try({ matches : List(Vectorize.Match(meta)), count : U64 }, Str)
matches_of = |read, js| match js {
	Obj(fs) => match field(fs, "matches") {
		Arr(items) => {
			matches = items.map_try(|item| match_of(read, item))?
			count = match field(fs, "count") {
				Int(n) => n.to_u64_try() ?? matches.len()
				_ => matches.len()
			}
			Ok({ matches, count })
		}
		other => Err("the result has no matches: ${shape(other)}")
	}
	other => Err("the result is ${shape(other)}")
}

match_of : (Str -> Try(meta, Str)), Js -> Try(Vectorize.Match(meta), Str)
match_of = |read, js| match js {
	Obj(fs) => {
		id = text_field(fs, "id")?
		score = match number(field(fs, "score")) {
			Ok(f) => f
			Err(_) => return Err("match ${id}: the score is not a number")
		}
		values = values_of(field(fs, "values"))?
		metadata = metadata_of(read, id, field(fs, "metadata"))?
		Ok({ id, score, values, namespace: opt_text(field(fs, "namespace")), metadata })
	}
	other => Err("a match is ${shape(other)}")
}

stored_list : (Str -> Try(meta, Str)), List(Js) -> Try(List(Vectorize.Stored(meta)), Str)
stored_list = |read, items| items.map_try(
	|item| match item {
		Obj(fs) => {
			id = text_field(fs, "id")?
			values = values_of(field(fs, "values"))?
			metadata = metadata_of(read, id, field(fs, "metadata"))?
			Ok({ id, values, namespace: opt_text(field(fs, "namespace")), metadata })
		}
		other => Err("a vector is ${shape(other)}")
	},
)

metadata_of : (Str -> Try(meta, Str)), Str, Js -> Try(Try(meta, [Missing]), Str)
metadata_of = |read, id, js| match js {
	Undefined | Null => Ok(Err(Missing))
	other => match read(js_json(other)) {
		Ok(m) => Ok(Ok(m))
		Err(why) => Err("vector ${id}: the metadata does not fit the type: ${why}")
	}
}

values_of : Js -> Try(List(F64), Str)
values_of = |js| match js {
	Undefined | Null => Ok([])
	Arr(items) => items.map_try(|i| number(i).map_err(|_| "a value is not a number"))
	other => Err("the values are ${shape(other)}")
}

number : Js -> Try(F64, [NotNumber])
number = |js| match js {
	Int(i) => Ok(i.to_f64())
	Num(f) => Ok(f)
	_ => Err(NotNumber)
}

text_field : List((Str, Js)), Str -> Try(Str, Str)
text_field = |fs, name| match field(fs, name) {
	Text(s) => Ok(s)
	other => Err("the field ${name} is ${shape(other)}")
}

opt_text : Js -> Try(Str, [Missing])
opt_text = |js| match js {
	Text(s) => Ok(s)
	_ => Err(Missing)
}

## A `Js` tree as JSON text, for `Json.parse` of the metadata.
js_json : Js -> Str
js_json = |js| match js {
	Null | Undefined => "null"
	Bool(b) => if (b) "true" else "false"
	Int(i) => i.to_str()
	Num(f) => if (f.is_finite()) f.to_str() else "null"
	Text(s) => Json.to_str(s)
	Arr(items) => "[${Str.join_with(items.map(js_json), ",")}]"
	Obj(fs) => "{${Str.join_with(fs.map(|(k, v)| "${Json.to_str(k)}:${js_json(v)}"), ",")}}"
	Bytes(_) | Ref(_) | Error(_, _) | Packed(_) => "null"
}

## The kind of a value, for a `BadData` text: the value can be the data of the app, so it is never shown.
shape : Js -> Str
shape = |v| match v {
	Undefined => "undefined"
	Null => "null"
	Bool(_) => "a bool"
	Num(_) | Int(_) => "a number"
	Text(_) => "text"
	Bytes(_) => "bytes"
	Arr(_) => "an array"
	Obj(_) => "an object"
	Ref(_) => "a ref"
	Error(_, _) => "an error"
	Packed(_) => "packed data"
}

## A number of a vector as JSON text. `Json.to_str` of an F64 can fail (`NaN`): a non-finite value goes as `null`, and
## Vectorize refuses the vector.
f64_json : F64 -> Str
f64_json = |f| if (f.is_finite()) f.to_str() else "null"

limit : U64 -> I64
limit = |n| n.to_i64_try() ?? I64.highest

field : List((Str, Js)), Str -> Js
field = |fields, name| match fields.find_first(|(k, _)| k == name) {
	Ok((_, v)) => v
	Err(_) => Undefined
}

Meta : { genre : Str, year : U64 }

read_meta : Str -> Try(Meta, Str)
read_meta = |text| Json.parse(text).map_err(|e| Str.inspect(e))

expect js_json(Obj([("a", Arr([Int(1), Num(1.5), Text("x\"y"), Null, Bool(Bool.True)]))])) == "{\"a\":[1,1.5,\"x\\\"y\",null,true]}"
expect query_js({}) == []
# `max_bytes` is the limit of the module: it is not an option of Vectorize.
expect query_js({ max_bytes: 5 }) == []
expect query_js({ top_k: 3, namespace: "n", return_values: Bool.True, return_metadata: All }) == [("topK", Int(3)), ("namespace", Text("n")), ("returnValues", Bool(Bool.True)), ("returnMetadata", Text("all"))]
expect query_js({ return_metadata: None, filter: Obj([("genre", Text("rock"))]) }) == [("returnMetadata", Text("none")), ("filter", Obj([("genre", Text("rock"))]))]
expect vectors_json(|m| Ok("{\"genre\":${Json.to_str(m.genre)}}"), [{ id: "a", values: [0.5, 1.0], metadata: { genre: "x" } }, { id: "b", values: [], namespace: "ns" }]) == Ok("[{\"id\":\"a\",\"values\":[0.5,1],\"metadata\":{\"genre\":\"x\"}},{\"id\":\"b\",\"values\":[],\"namespace\":\"ns\"}]")

expect match matches_of(read_meta, Obj([("count", Int(1)), ("matches", Arr([Obj([("id", Text("a")), ("score", Num(0.75)), ("metadata", Obj([("genre", Text("x")), ("year", Int(1999))]))]), Obj([("id", Text("b")), ("score", Int(1))])]))])) {
	Ok(r) => r.count == 1 and r.matches.len() == 2 and r.matches.first().map_ok(|m| m.id == "a" and m.score == 0.75 and m.metadata == Ok({ genre: "x", year: 1999 })) == Ok(Bool.True)
	Err(_) => Bool.False
}
expect matches_of(read_meta, Obj([("matches", Arr([Obj([("id", Text("a")), ("score", Num(0.75)), ("metadata", Obj([("genre", Int(1))]))])]))])).is_err()
