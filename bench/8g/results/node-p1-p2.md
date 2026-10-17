Runs: 3. node v26.7.0, AMD Ryzen AI 9 HX 370 w/ Radeon 890M, resumeCheck always. Load average at the start of each run: 1.31, 1.84, 2.07.

d1

| case | us per operation |
| --- | --- |
| js_only rows=20 fake | 4.191 (4.004 to 4.309) |
| pack_only rows=20 fake | 14.6 (14.5 to 15.7) |
| all rows=20 fake | 26.3 (26 to 26.3) |
| all_tuples rows=20 fake | 14.7 (14.5 to 15.3) |
| all_arrays rows=20 fake | 14.8 (14.4 to 15.8) |
| raw_js_only rows=20 fake | 4.475 (4.335 to 4.559) |
| raw_only rows=20 fake | 16.2 (16.1 to 16.5) |
| obj_tree rows=20 fake | 22.3 (22.3 to 22.9) |
| tree_typed rows=20 fake | 16.8 (16.5 to 16.9) |
| rows rows=20 fake | 17.4 (17.2 to 17.8) |
| js_only rows=200 fake | 4.303 (4.188 to 4.412) |
| pack_only rows=200 fake | 85.3 (85 to 88.6) |
| all rows=200 fake | 196 (194.4 to 198.4) |
| all_tuples rows=200 fake | 91.4 (88.7 to 91.7) |
| all_arrays rows=200 fake | 89.3 (88.8 to 94.6) |
| raw_js_only rows=200 fake | 5.348 (5.259 to 5.592) |
| raw_only rows=200 fake | 103.9 (102.9 to 104.3) |
| obj_tree rows=200 fake | 165.8 (165.6 to 170.5) |
| tree_typed rows=200 fake | 107.4 (105.2 to 107.5) |
| rows rows=200 fake | 111.7 (110.6 to 112.4) |

sha

| case | us per operation |
| --- | --- |
| wasm size=256 | 0.713 (0.707 to 0.734) |
| digest size=256 | 10.1 (9.8 to 11.2) |
| digest_js size=256 | 10.2 (9.7 to 10.3) |
| copy_only size=256 | 3.376 (3.342 to 3.587) |
| pick size=256 | 0.722 (0.71 to 0.728) |
| wasm size=1024 | 2.384 (2.333 to 2.411) |
| digest size=1024 | 10.2 (10 to 10.8) |
| digest_js size=1024 | 10.213 (9.957 to 13.613) |
| copy_only size=1024 | 3.591 (3.543 to 3.787) |
| pick size=1024 | 2.349 (2.333 to 2.388) |
| wasm size=2048 | 4.5 (4.454 to 4.626) |
| digest size=2048 | 9.944 (9.852 to 10.326) |
| digest_js size=2048 | 9.93 (9.816 to 12.328) |
| copy_only size=2048 | 3.601 (3.545 to 3.645) |
| pick size=2048 | 4.49 (4.478 to 4.581) |
| wasm size=4096 | 8.805 (8.755 to 8.916) |
| digest size=4096 | 11.2 (11 to 12.2) |
| digest_js size=4096 | 11.9 (11 to 13.4) |
| copy_only size=4096 | 3.876 (3.87 to 3.997) |
| pick size=4096 | 11.5 (11.1 to 14.2) |
| wasm size=8192 | 17.5 (17.3 to 17.7) |
| digest size=8192 | 14.2 (13.8 to 17.6) |
| digest_js size=8192 | 13.5 (13.4 to 15.7) |
| copy_only size=8192 | 4.521 (4.382 to 4.686) |
| pick size=8192 | 13.8 (13.7 to 17.8) |
| wasm size=16384 | 34.5 (34.3 to 34.8) |
| digest size=16384 | 19.3 (18.9 to 20.7) |
| digest_js size=16384 | 17.5 (17.3 to 17.5) |
| copy_only size=16384 | 6.038 (6.037 to 6.298) |
| pick size=16384 | 18.5 (18.2 to 22.7) |
| wasm size=65536 | 137.7 (137.2 to 138.3) |
| digest size=65536 | 48.9 (48.2 to 59.5) |
| digest_js size=65536 | 40.3 (40 to 45.1) |
| copy_only size=65536 | 12.6 (12.3 to 13.4) |
| pick size=65536 | 51.4 (47.4 to 58.3) |
| wasm size=262144 | 549.3 (546.1 to 558.6) |
| digest size=262144 | 165.9 (158.4 to 172) |
| digest_js size=262144 | 135.8 (134.2 to 137.8) |
| copy_only size=262144 | 47.5 (47.1 to 56.1) |
| pick size=262144 | 174.2 (158 to 177.3) |
| wasm size=1048576 | 2206.3 (2193.5 to 2228.6) |
| digest size=1048576 | 676.7 (643.3 to 699.2) |
| digest_js size=1048576 | 511.8 (504.2 to 538.5) |
| copy_only size=1048576 | 219.1 (195.2 to 228.1) |
| pick size=1048576 | 734.3 (676.8 to 794.2) |
