Runs: 3. workerd (Miniflare), AMD Ryzen AI 9 HX 370 w/ Radeon 890M, resumeCheck always. Load average at the start of each run: 2.17, 2.34, 2.27.

cross

| case | us per operation |
| --- | --- |
| call k=0 | 0.498 (0.481 to 0.511) |
| call k=1 | 1.354 (1.346 to 1.377) |
| call k=4 | 3.111 (3.109 to 3.155) |
| call k=16 | 9.657 (9.656 to 9.878) |
| await k=0 | 2.002 (1.893 to 2.137) |
| await k=1 | 2.996 (2.726 to 3.076) |
| await k=4 | 4.88 (4.536 to 5.101) |
| await k=16 | 12.2 (11.2 to 13.2) |
| build k=0 | 0.028 (0.027 to 0.028) |
| build k=1 | 0.18 (0.179 to 0.18) |
| build k=4 | 0.516 (0.513 to 0.533) |
| build k=16 | 1.801 (1.779 to 1.809) |

d1

| case | us per operation |
| --- | --- |
| js_only rows=20 fake | 4.435 (4.353 to 4.462) |
| pack_only rows=20 fake | 16.5 (16.3 to 16.7) |
| all rows=20 fake | 30.6 (30.5 to 30.6) |
| all_arrays rows=20 fake | 16.2 (16.1 to 16.8) |
| raw_js_only rows=20 fake | 4.812 (4.805 to 4.831) |
| raw_only rows=20 fake | 18.2 (18.1 to 18.7) |
| obj_tree rows=20 fake | 24.9 (24.5 to 24.9) |
| tree_typed rows=20 fake | 19 (18.7 to 19.2) |
| rows rows=20 fake | 19.7 (19.5 to 20.1) |
| js_only rows=200 fake | 4.457 (4.436 to 4.463) |
| pack_only rows=200 fake | 101.9 (98.4 to 103.3) |
| all rows=200 fake | 236 (232.5 to 236.3) |
| all_arrays rows=200 fake | 102.6 (102.6 to 102.7) |
| raw_js_only rows=200 fake | 5.227 (5.212 to 5.395) |
| raw_only rows=200 fake | 116.9 (116.6 to 123) |
| obj_tree rows=200 fake | 184 (180.9 to 187.3) |
| tree_typed rows=200 fake | 121.2 (120.4 to 127.1) |
| rows rows=200 fake | 127 (126.7 to 133.8) |

d1real

| case | us per operation |
| --- | --- |
| js_only rows=20 | 2114.7 (2079.2 to 2115.5) |
| pack_only rows=20 | 2155.1 (2100.1 to 2192.6) |
| all rows=20 | 2212.6 (2136.2 to 2215.8) |
| all_arrays rows=20 | 2160.6 (2132.7 to 2198.5) |
| raw_js_only rows=20 | 2123.1 (2098.6 to 2172.1) |
| raw_only rows=20 | 2166.3 (2161.3 to 2185.1) |
| obj_tree rows=20 | 2144.8 (2132.8 to 2174.9) |
| tree_typed rows=20 | 2151.7 (2103.9 to 2226.8) |
| rows rows=20 | 2144.9 (2095.7 to 2309) |
| js_only rows=200 | 2868.3 (2759.8 to 3024.1) |
| pack_only rows=200 | 3838.5 (2615.6 to 3880.7) |
| all rows=200 | 2680.7 (2674.2 to 2745.9) |
| all_arrays rows=200 | 2664.3 (2553.2 to 2757.7) |
| raw_js_only rows=200 | 2520.2 (2499.5 to 2623.6) |
| raw_only rows=200 | 2477.7 (2440 to 2729.8) |
| obj_tree rows=200 | 2583.4 (2417.1 to 2586.4) |
| tree_typed rows=200 | 2321 (2303 to 2402.2) |
| rows rows=200 | 2430.1 (2339.2 to 2439.5) |

parse

| case | us per operation |
| --- | --- |
| records rows=20 | 13.4 (13.3 to 13.6) |
| tuples rows=20 | 3.76 (3.73 to 3.837) |
| variant_field rows=20 | 72.7 (72.2 to 76.2) |
| variant_first rows=20 | 72.2 (70.9 to 75.8) |
| fold_only rows=20 | 0.058 (0.058 to 0.058) |
| records rows=200 | 130.2 (129.3 to 132.3) |
| tuples rows=200 | 36.3 (36.3 to 36.5) |
| variant_field rows=200 | 725.2 (713.3 to 733) |
| variant_first rows=200 | 726.1 (694.8 to 748.3) |
| fold_only rows=200 | 0.545 (0.539 to 0.546) |

sha

| case | us per operation |
| --- | --- |
| wasm size=256 | 0.847 (0.828 to 0.892) |
| digest size=256 | 5.589 (5.578 to 5.707) |
| digest_js size=256 | 6.044 (5.998 to 6.068) |
| copy_only size=256 | 3.394 (3.352 to 3.397) |
| wasm size=1024 | 2.722 (2.718 to 2.793) |
| digest size=1024 | 6.109 (6.09 to 6.131) |
| digest_js size=1024 | 6.48 (6.414 to 6.534) |
| copy_only size=1024 | 3.648 (3.566 to 3.658) |
| wasm size=2048 | 5.348 (5.232 to 5.451) |
| digest size=2048 | 6.695 (6.695 to 6.775) |
| digest_js size=2048 | 6.905 (6.848 to 7.166) |
| copy_only size=2048 | 3.797 (3.768 to 4.888) |
| wasm size=4096 | 10.3 (10.3 to 10.5) |
| digest size=4096 | 7.897 (7.689 to 7.979) |
| digest_js size=4096 | 7.679 (7.624 to 7.762) |
| copy_only size=4096 | 4.013 (4.011 to 4.036) |
| wasm size=8192 | 20.5 (20.5 to 20.9) |
| digest size=8192 | 10.1 (10.1 to 10.2) |
| digest_js size=8192 | 9.423 (9.414 to 9.459) |
| copy_only size=8192 | 4.634 (4.589 to 4.655) |
| wasm size=16384 | 40.8 (40.7 to 40.8) |
| digest size=16384 | 14.5 (14.2 to 14.5) |
| digest_js size=16384 | 12.9 (12.9 to 13) |
| copy_only size=16384 | 5.737 (5.627 to 5.761) |
| wasm size=65536 | 161.3 (160.7 to 162.7) |
| digest size=65536 | 39.8 (39.4 to 40.3) |
| digest_js size=65536 | 34.3 (34.1 to 34.6) |
| copy_only size=65536 | 11.5 (11.3 to 11.6) |
| wasm size=262144 | 645.3 (645.1 to 653.4) |
| digest size=262144 | 142.4 (141.9 to 142.8) |
| digest_js size=262144 | 121 (119.2 to 121.5) |
| copy_only size=262144 | 34.3 (33.2 to 34.6) |
| wasm size=1048576 | 2607.1 (2594.1 to 2610.6) |
| digest size=1048576 | 559.6 (557.3 to 561.7) |
| digest_js size=1048576 | 460.7 (460.2 to 468.5) |
| copy_only size=1048576 | 137.3 (137.3 to 137.6) |

parts of one crossing (us per call)

| part | rows 20 | rows 200 |
| --- | --- | --- |
| js_encode_tree | 7.57 (7.57 to 8.06) | 60.55 (60.55 to 62.5) |
| js_encode_packed | 11.23 (11.23 to 11.72) | 97.66 (93.75 to 97.66) |
| js_encode_packed_made | 11.23 (11.23 to 11.72) | 97.66 (93.75 to 97.66) |
| zig_decode_tree | 5.86 (5.62 to 6.1) | 54.69 (52.73 to 62.5) |
| zig_decode_packed | 0.12 (0.11 to 0.12) | 0.67 (0.67 to 0.67) |
| bytes (tree, packed) | 4424, 5606 | 44045, 56387 |

| part | 1 op | 4 ops | 16 ops |
| --- | --- | --- | --- |
| js_decode | 0.206 (0.198 to 0.214) | 0.641 (0.61 to 0.702) | 2.319 (2.319 to 2.563) |
| zig_decode | 0.305 (0.305 to 0.305) | 1.129 (1.129 to 1.16) | 4.272 (4.15 to 4.395) |
| zig_decode_encode | 0.473 (0.473 to 0.519) | 1.709 (1.648 to 1.77) | 6.348 (6.348 to 6.592) |
| js_run | 0.099 (0.095 to 0.107) | 0.336 (0.336 to 0.336) | 1.19 (1.19 to 1.221) |
| js_encode_result | 0.252 (0.244 to 0.252) | 0.252 (0.252 to 0.259) | 0.252 (0.252 to 0.259) |
