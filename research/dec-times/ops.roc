# Other Dec checked and saturated ops. Run: roc test ops.roc. Each expect is one op with small values, then at the edge.
expect Dec.plus_saturated(1.5, 2.0) == 3.5
expect Dec.plus_saturated(Dec.highest, 1.0) == Dec.highest
expect Dec.minus_saturated(3.5, 2.0) == 1.5
expect Dec.minus_saturated(Dec.lowest, 1.0) == Dec.lowest
expect Dec.plus_try(1.5, 2.0) == Ok(3.5)
expect Dec.plus_try(Dec.highest, 1.0) == Err(Overflow)
expect Dec.minus_try(3.5, 2.0) == Ok(1.5)
expect Dec.minus_try(Dec.lowest, 1.0) == Err(Overflow)
expect Dec.times_saturated(2.0, 3.0) == 6.0
expect Dec.times_saturated(1.0, 0.5) == 0.5 # BUG: crashes, second argument below 1
expect Dec.times_saturated(Dec.highest, 0.5) == 85070591730234615865.843651857942052863 # BUG: crashes
expect Dec.times_saturated(Dec.highest, 2.0) == Dec.highest
expect Dec.times_saturated(Dec.lowest, 2.0) == Dec.lowest
expect Dec.times(2.0, 3.0) == 6.0
expect Dec.round_try(2.5) == Ok(3.0)
expect Dec.round_try(Dec.highest) == Err(Overflow)
expect Dec.round_try(Dec.lowest) == Err(Overflow)
expect Dec.floor_try(2.5) == Ok(2.0)
expect Dec.ceiling_try(2.5) == Ok(3.0)
expect Dec.round_to_try(2.57, { step: 0.1, ties: AwayFromZero }) == Ok(2.6)
expect Dec.round_to_u64_try(2.5) == Ok(3)
expect Dec.round_to_u64_try(-1.0) == Err(OutOfRange)
expect Dec.round_to_u64_try(Dec.highest) == Err(OutOfRange)
expect Dec.to_u64_try(2.0) == Ok(2)
expect Dec.to_u64_try(Dec.highest) == Err(OutOfRange)
expect Dec.sqrt_try(4.0) == Ok(2.0)
expect Dec.sqrt_try(-4.0) == Err(SqrtOfNegative)
expect Dec.div_by(6.0, 3.0) == 2.0
expect Dec.pow(2.0, 3.0) == 8.0
