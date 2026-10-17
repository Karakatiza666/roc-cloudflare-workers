Runs: 3. workerd (Miniflare), AMD Ryzen AI 9 HX 370 w/ Radeon 890M, resumeCheck always. Load average at the start of each run: 1.79, 2, 1.79.

d1

| case | us per operation |
| --- | --- |
| js_only rows=20 fake | 4.261 (4.249 to 4.322) |
| pack_only rows=20 fake | 16.1 (16.1 to 16.4) |
| all rows=20 fake | 30.2 (30.1 to 30.8) |
| all_tuples rows=20 fake | 16.4 (16.3 to 16.6) |
| all_arrays rows=20 fake | 16.2 (16.2 to 16.6) |
| raw_js_only rows=20 fake | 4.685 (4.677 to 4.723) |
| raw_only rows=20 fake | 18.1 (18 to 19) |
| obj_tree rows=20 fake | 25.5 (25.3 to 26) |
| tree_typed rows=20 fake | 18.5 (18.3 to 18.7) |
| rows rows=20 fake | 19.3 (19.3 to 19.8) |
| js_only rows=200 fake | 4.371 (4.341 to 4.402) |
| pack_only rows=200 fake | 101.9 (101.5 to 102.2) |
| all rows=200 fake | 231.7 (231.5 to 240.4) |
| all_tuples rows=200 fake | 102.3 (100.8 to 106.5) |
| all_arrays rows=200 fake | 101.4 (100.6 to 105.8) |
| raw_js_only rows=200 fake | 5.084 (5.048 to 5.097) |
| raw_only rows=200 fake | 116.3 (114.4 to 118.9) |
| obj_tree rows=200 fake | 193.5 (190.9 to 194.6) |
| tree_typed rows=200 fake | 120.1 (118.9 to 122.8) |
| rows rows=200 fake | 125.7 (124.8 to 129.2) |

sha

| case | us per operation |
| --- | --- |
| wasm size=256 | 0.864 (0.841 to 0.88) |
| digest size=256 | 5.735 (5.608 to 5.846) |
| digest_js size=256 | 6.096 (5.978 to 6.116) |
| copy_only size=256 | 3.401 (3.392 to 3.417) |
| pick size=256 | 0.838 (0.838 to 0.876) |
| wasm size=1024 | 2.765 (2.715 to 2.775) |
| digest size=1024 | 6.065 (6.029 to 6.555) |
| digest_js size=1024 | 6.335 (6.315 to 6.713) |
| copy_only size=1024 | 3.617 (3.605 to 3.619) |
| pick size=1024 | 2.788 (2.731 to 2.795) |
| wasm size=2048 | 5.338 (5.262 to 5.384) |
| digest size=2048 | 6.69 (6.667 to 6.695) |
| digest_js size=2048 | 6.832 (6.681 to 6.858) |
| copy_only size=2048 | 3.745 (3.69 to 3.748) |
| pick size=2048 | 5.281 (5.273 to 5.481) |
| wasm size=4096 | 10.3 (10.3 to 10.4) |
| digest size=4096 | 7.851 (7.705 to 7.873) |
| digest_js size=4096 | 7.664 (7.597 to 7.802) |
| copy_only size=4096 | 4.022 (3.996 to 4.071) |
| pick size=4096 | 7.578 (7.535 to 7.595) |
| wasm size=8192 | 20.4 (20.4 to 20.6) |
| digest size=8192 | 9.966 (9.964 to 10.024) |
| digest_js size=8192 | 9.359 (9.334 to 9.494) |
| copy_only size=8192 | 4.648 (4.621 to 4.829) |
| pick size=8192 | 9.867 (9.822 to 9.975) |
| wasm size=16384 | 40.7 (40.6 to 40.9) |
| digest size=16384 | 14.3 (14.3 to 14.5) |
| digest_js size=16384 | 13 (12.9 to 13.1) |
| copy_only size=16384 | 5.747 (5.677 to 5.909) |
| pick size=16384 | 14.3 (14.1 to 14.3) |
| wasm size=65536 | 162.4 (161.3 to 163.3) |
| digest size=65536 | 39.8 (39.7 to 40.5) |
| digest_js size=65536 | 34.3 (34.2 to 34.8) |
| copy_only size=65536 | 11.4 (11.3 to 11.4) |
| pick size=65536 | 39.6 (39.4 to 39.9) |
| wasm size=262144 | 648.1 (647.5 to 649.9) |
| digest size=262144 | 142.2 (142.2 to 142.3) |
| digest_js size=262144 | 119.7 (119.3 to 120) |
| copy_only size=262144 | 34.5 (34.2 to 34.6) |
| pick size=262144 | 142.1 (141.1 to 142.4) |
| wasm size=1048576 | 2586.7 (2585.9 to 2603.6) |
| digest size=1048576 | 557.4 (557.4 to 566.4) |
| digest_js size=1048576 | 461.1 (460.8 to 462.5) |
| copy_only size=1048576 | 136.8 (135.6 to 139.7) |
| pick size=1048576 | 558.9 (557 to 566.3) |
