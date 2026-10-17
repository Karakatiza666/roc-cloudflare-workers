Node, 5 reps in rotating order (median, min to max), us. node bench/8g/run-variants.mjs

| variant | decode 200 rows (us) | decode 20 rows (us) | D1.rows! 200 (us) | D1.all! 200 (us) |
| --- | --- | --- | --- | --- |
| default | 46.69 (46.51 to 46.79) | 5.01 (4.93 to 5.07) | 108.37 (107.17 to 111.61) | 196.21 (194.21 to 197.04) |
| tl_off | 45.45 (44.98 to 45.82) | 4.89 (4.85 to 4.91) | 106.27 (104.06 to 107.24) | 194.2 (192.78 to 196.95) |
| ot_off | 45.3 (45.13 to 45.86) | 4.87 (4.84 to 4.92) | 105.61 (104.9 to 106.23) | 194.2 (192.93 to 195.95) |
| fast | 37.86 (37.42 to 37.93) | 4.12 (4.1 to 4.13) | 99.56 (99.21 to 100.71) | 195.49 (193.77 to 195.88) |
| fast_tl_off | 36.97 (36.86 to 37.15) | 4.05 (4.02 to 4.05) | 98.3 (97.01 to 99.77) | 196.29 (193.04 to 196.61) |

workerd (Miniflare), 2 reps, `SECTIONS=d1,parts` for each variant (steps of 2 us in the decode: the clock moves by 1 ms):

| variant | decode 200 rows (rep 1, rep 2) | D1.rows! 200 fake (rep 1, rep 2) | D1.all! 200 fake (rep 1, rep 2) |
| --- | --- | --- | --- |
| default | 54.7, 54.7 | 126.7, 125.8 | 239, 250.8 |
| tl_off | 52.7, 54.7 | 138.1, 124.4 | 258.9, 259.1 |
| fast | 44.9, 46.9 | 117.4, 116.7 | 233.9, 234 |
| fast_tl_off | 44.9, 46.9 | 116.8, 116.5 | 241.1, 241 |
