# Check: Sorted.sort_with gives the same list as List.sort_with, and keeps the order of equal keys.
import Sorted

by_key : (U64, U64), (U64, U64) -> [Before, Same, After]
by_key = |a, b| a.0.order_relative_to(b.0)

# a mixed list (many equal keys) of 200 items from a small linear generator
make : U64 -> List((U64, U64))
make = |n| {
	var $x = 12345
	var $out = []
	for i in 0.U64..<n {
		$x = ($x * 1103515245 + 12345) % 2147483648
		$out = $out.append(($x % 7, i))
	}
	$out
}

expect Sorted.sort_with([], by_key) == []
expect Sorted.sort_with([(1, 0)], by_key) == [(1, 0)]
expect Sorted.sort_with([(2, 0), (1, 1), (2, 2), (1, 3)], by_key) == [(1, 1), (1, 3), (2, 0), (2, 2)]
expect Sorted.sort_with(make(200), by_key) == make(200).sort_with(by_key)
expect Sorted.sort_with(make(501), by_key) == make(501).sort_with(by_key)
expect Sorted.sort_with(make(2), by_key) == make(2).sort_with(by_key)

main! = |_args| Ok({})
