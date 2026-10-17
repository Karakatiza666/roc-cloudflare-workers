Runs: 3. node v26.7.0, AMD Ryzen AI 9 HX 370 w/ Radeon 890M, resumeCheck always. Load average at the start of each run: 3.07, 2.85, 2.65.

cross

| case | us per operation |
| --- | --- |
| call k=0 | 0.363 (0.356 to 0.368) |
| call k=1 | 1.199 (1.197 to 1.259) |
| call k=4 | 2.803 (2.781 to 2.836) |
| call k=16 | 8.978 (8.943 to 9.091) |
| await k=0 | 1.805 (1.791 to 1.841) |
| await k=1 | 2.567 (2.546 to 2.604) |
| await k=4 | 4.253 (4.205 to 4.269) |
| await k=16 | 10.5 (10.4 to 10.9) |
| build k=0 | 0.025 (0.025 to 0.026) |
| build k=1 | 0.168 (0.164 to 0.169) |
| build k=4 | 0.484 (0.481 to 0.494) |
| build k=16 | 1.707 (1.702 to 1.711) |

d1

| case | us per operation |
| --- | --- |
| js_only rows=20 fake | 4.324 (4.129 to 4.352) |
| pack_only rows=20 fake | 14.6 (14.5 to 14.9) |
| all rows=20 fake | 25.9 (25.9 to 26.2) |
| all_arrays rows=20 fake | 14.7 (14.7 to 15.1) |
| raw_js_only rows=20 fake | 4.591 (4.571 to 4.615) |
| raw_only rows=20 fake | 16.6 (16.6 to 16.8) |
| obj_tree rows=20 fake | 21.8 (21.8 to 22.2) |
| tree_typed rows=20 fake | 17.1 (17 to 17.2) |
| rows rows=20 fake | 17.8 (17.5 to 17.9) |
| js_only rows=200 fake | 4.357 (4.344 to 4.402) |
| pack_only rows=200 fake | 86.3 (83.7 to 89.6) |
| all rows=200 fake | 197.8 (192.9 to 198.2) |
| all_arrays rows=200 fake | 91.4 (88.9 to 95) |
| raw_js_only rows=200 fake | 5.308 (5.248 to 5.411) |
| raw_only rows=200 fake | 104.9 (103.8 to 107.1) |
| obj_tree rows=200 fake | 160.1 (158.6 to 166.9) |
| tree_typed rows=200 fake | 111.3 (108.1 to 111.7) |
| rows rows=200 fake | 115.1 (113.7 to 115.2) |

parse

| case | us per operation |
| --- | --- |
| records rows=20 | 11 (10.8 to 11) |
| tuples rows=20 | 3.725 (3.678 to 3.747) |
| variant_field rows=20 | 48.6 (46.7 to 48.6) |
| variant_first rows=20 | 46.8 (46.1 to 47.4) |
| fold_only rows=20 | 0.051 (0.05 to 0.051) |
| records rows=200 | 107.9 (106.6 to 109) |
| tuples rows=200 | 36.1 (35.8 to 36.4) |
| variant_field rows=200 | 482.4 (472.3 to 486) |
| variant_first rows=200 | 466 (464.2 to 468.3) |
| fold_only rows=200 | 0.473 (0.47 to 0.477) |

sha

| case | us per operation |
| --- | --- |
| wasm size=256 | 0.72 (0.714 to 0.734) |
| digest size=256 | 13 (11.2 to 14.2) |
| digest_js size=256 | 10.1 (10.1 to 10.2) |
| copy_only size=256 | 3.255 (3.217 to 3.326) |
| wasm size=1024 | 2.34 (2.338 to 2.522) |
| digest size=1024 | 10 (9.9 to 10.1) |
| digest_js size=1024 | 10.7 (10.2 to 11) |
| copy_only size=1024 | 3.457 (3.44 to 3.508) |
| wasm size=2048 | 4.471 (4.463 to 4.474) |
| digest size=2048 | 9.59 (9.565 to 10.683) |
| digest_js size=2048 | 9.974 (9.914 to 10.09) |
| copy_only size=2048 | 3.542 (3.529 to 3.542) |
| wasm size=4096 | 8.753 (8.75 to 8.759) |
| digest size=4096 | 12.2 (11.6 to 12.6) |
| digest_js size=4096 | 11.5 (11.5 to 11.9) |
| copy_only size=4096 | 3.854 (3.819 to 3.989) |
| wasm size=8192 | 17.3 (17.2 to 17.4) |
| digest size=8192 | 14 (13.9 to 14.6) |
| digest_js size=8192 | 13.7 (13.2 to 15.4) |
| copy_only size=8192 | 4.414 (4.3 to 4.551) |
| wasm size=16384 | 34.3 (34.3 to 34.6) |
| digest size=16384 | 18.9 (18.7 to 21.6) |
| digest_js size=16384 | 17.3 (17.2 to 17.5) |
| copy_only size=16384 | 6.049 (6.032 to 6.389) |
| wasm size=65536 | 137.6 (136.7 to 141.4) |
| digest size=65536 | 48.6 (48.4 to 51.2) |
| digest_js size=65536 | 40.5 (40.4 to 40.6) |
| copy_only size=65536 | 12.4 (12.4 to 13.6) |
| wasm size=262144 | 546.2 (545.7 to 547.1) |
| digest size=262144 | 160.3 (158.7 to 163.6) |
| digest_js size=262144 | 133.9 (133.6 to 135.1) |
| copy_only size=262144 | 52.1 (46.9 to 57.3) |
| wasm size=1048576 | 2181.3 (2174.7 to 2211.6) |
| digest size=1048576 | 638.3 (633.2 to 655.9) |
| digest_js size=1048576 | 542 (497.6 to 549.1) |
| copy_only size=1048576 | 224.3 (157.2 to 234.3) |

parts of one crossing (us per call)

| part | rows 20 | rows 200 |
| --- | --- | --- |
| js_encode_tree | 6.37 (6.33 to 6.45) | 48.04 (47.53 to 51.36) |
| js_encode_packed | 9.37 (9.36 to 9.8) | 77.86 (76.93 to 82.83) |
| js_encode_packed_made | 9.54 (9.44 to 9.78) | 78.23 (77.26 to 84.75) |
| zig_decode_tree | 5.47 (5.38 to 5.62) | 51.33 (50.69 to 53.16) |
| zig_decode_packed | 0.11 (0.11 to 0.11) | 0.65 (0.65 to 0.65) |
| bytes (tree, packed) | 4424, 5606 | 44045, 56387 |

| part | 1 op | 4 ops | 16 ops |
| --- | --- | --- | --- |
| js_decode | 0.204 (0.204 to 0.205) | 0.669 (0.659 to 0.685) | 2.43 (2.429 to 2.445) |
| zig_decode | 0.31 (0.306 to 0.321) | 1.089 (1.063 to 1.118) | 4.118 (4.021 to 4.189) |
| zig_decode_encode | 0.485 (0.462 to 0.49) | 1.574 (1.556 to 1.603) | 5.996 (5.937 to 6.046) |
| js_run | 0.085 (0.083 to 0.09) | 0.287 (0.287 to 0.289) | 1.033 (1.031 to 1.041) |
| js_encode_result | 0.211 (0.206 to 0.211) | 0.201 (0.199 to 0.201) | 0.202 (0.201 to 0.203) |
