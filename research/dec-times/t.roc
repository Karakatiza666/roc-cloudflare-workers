# Probe (2026-10-22, nightly-2026-10-19-601b54c): `Dec.times_saturated` crashes ("Decimal division overflow!") even
# for 1000 * 0.5, so the auction ledger cannot use it. `Dec` has no `times_try`. `ledger.roc` `convert` checks an F64 estimate first.
expect (1000.U64.to_dec().times_saturated(0.5)) == 500 # fails: the crash
expect (1000.U64.to_dec().times(0.5)) == 500
