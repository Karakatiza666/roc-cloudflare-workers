## A stable merge sort. `List.sort_with` of the compiler makes 50 to 250 KB of wasm code for each call site (cloudflare-workers/research/bigfn2/README.md).
## This sort is a few KB for each call site. The lists of the Worker are short (500 rows at most), so speed does not matter.
Sorted :: [].{

	## The same contract as `List.sort_with`: `Same` keeps the input order.
	sort_with : List(a), (a, a -> [Before, Same, After]) -> List(a)
	sort_with = |items, cmp| {
		n = items.len()
		if n < 2 {
			items
		} else {
			mid = n // 2
			merge(sort_with(items.take_first(mid), cmp), sort_with(items.drop_first(mid), cmp), cmp)
		}
	}

	## Join two sorted lists. A tie takes the item of the left list first.
	merge : List(a), List(a), (a, a -> [Before, Same, After]) -> List(a)
	merge = |xs, ys, cmp| {
		var $i = 0
		var $j = 0
		var $out = List.with_capacity(xs.len() + ys.len())
		while Bool.True {
			match (xs.get($i), ys.get($j)) {
				(Ok(x), Ok(y)) => match cmp(y, x) {
					Before => {
						$out = $out.append(y)
						$j = $j + 1
					}
					_ => {
						$out = $out.append(x)
						$i = $i + 1
					}
				}
				_ => break
			}
		}
		$out.concat(xs.drop_first($i)).concat(ys.drop_first($j))
	}
}
