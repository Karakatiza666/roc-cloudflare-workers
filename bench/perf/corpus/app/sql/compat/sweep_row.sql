SELECT upto_log_index, time FROM sweeps WHERE nightly = CAST(?1 AS INTEGER) AND target = 0
