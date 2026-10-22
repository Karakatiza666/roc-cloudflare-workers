# Minimal repro: Dec.times_saturated crashes with "Decimal division overflow!" when the second argument is below 1.
# Run: roc test t.roc
expect Dec.times_saturated(1.0, 0.5) == 0.5
