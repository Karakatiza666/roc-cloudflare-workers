import Io
import Memo

## A fake crossing: it gives back the ops joined, or a throw for "boom".
cross! = |ops| {
	echo!("crossing: ${Str.join_with(ops, ",")}\n")
	if ops.contains("boom") Err({ name: "TypeError", message: "boom" }) else Ok(Str.join_with(ops, "+"))
}

rows : Str -> Io(U64, [D1Err(Str)])
rows = |sql| Io.new(["prepare", sql], |r| match r {
	Ok(s) => Ok(s.count_utf8_bytes())
	Err(t) => Err(D1Err(t.message))
})

page : Str -> Io(Str, [HttpErr(Str)])
page = |url| Io.new(["fetch", url], |r| r.map_err(|t| HttpErr(t.name)))

key_codec = { to_js: |k| k, from_js: |s| if s == "" Err(BadJs("empty")) else Ok(s) }

load_jwks! = |{}| {
	echo!("load_jwks! runs\n")
	Ok("key-1")
}

jwks = Memo.new("github-jwks", { max_age_ms: 3_600_000, load!: load_jwks!, codec: key_codec })

main! = |_args| {
	both = Io.both_via!(rows("select 1"), page("/jwks"), cross!)
	fail = Io.both_via!(rows("select 1"), page("boom"), cross!)
	len = Io.run_via!(Io.map(page("/x"), |s| s.count_utf8_bytes()), cross!)
	key = jwks.get!()
	echo!("${Str.inspect(both)} | ${Str.inspect(fail)} | ${Str.inspect(len)} | ${Str.inspect(key)}\n")
	Ok({})
}
