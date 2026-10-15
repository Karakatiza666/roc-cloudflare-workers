import Io

## Time (MODULES.md 11). A sleep is a wait, so a timeout is a race with a sleep (D4).
Time :: [].{
	now_ms! : {} => U64
	now_ms! = |{}| 1_700_000_000_000

	## `Io({}, [])` (MODULES.md 11) does not compile in a race: a closed `[]` does not join the errors of the other branches.
	sleep : U64 -> Io({}, e)
	sleep = |ms| Io.new(["time.sleep", ms.to_str()], |_| Ok({}))

	sleep! : U64 => {}
	sleep! = |ms| {
		_ = Io.run!(sleep(ms))
		{}
	}
}
