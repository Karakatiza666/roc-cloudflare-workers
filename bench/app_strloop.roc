app [handle!] { pf: platform "../platform/main.roc" }

## Bug B5: a string that grows in a loop. Request: "<steps>". Body: ",0,1,...,<steps - 1>".
handle! : Str => Str
handle! = |req| {
	steps = U64.from_str(req) ?? 0
	var $s = ""
	var $i = 0.U64
	while $i < steps {
		$s = "${$s},${$i.to_str()}"
		$i = $i + 1
	}
	$s
}
