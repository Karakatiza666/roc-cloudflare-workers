Runs: 2. workerd (Miniflare), AMD Ryzen AI 9 HX 370 w/ Radeon 890M, resumeCheck off. Load average at the start of each run: 2.2, 2.06.

cross

| case | us per operation |
| --- | --- |
| call k=0 | 0.492 (0.471 to 0.492) |
| call k=1 | 1.382 (1.35 to 1.382) |
| call k=4 | 3.256 (3.069 to 3.256) |
| call k=16 | 10 (9.6 to 10) |
| await k=0 | 1.265 (1.261 to 1.265) |
| await k=1 | 2.345 (2.151 to 2.345) |
| await k=4 | 4.339 (3.968 to 4.339) |
| await k=16 | 11.3 (10.8 to 11.3) |
| build k=0 | 0.03 (0.028 to 0.03) |
| build k=1 | 0.196 (0.178 to 0.196) |
| build k=4 | 0.553 (0.516 to 0.553) |
| build k=16 | 1.881 (1.775 to 1.881) |

sha

| case | us per operation |
| --- | --- |
| wasm size=256 | 0.859 (0.834 to 0.859) |
| digest size=256 | 5.274 (4.97 to 5.274) |
| digest_js size=256 | 5.407 (5.336 to 5.407) |
| copy_only size=256 | 2.755 (2.744 to 2.755) |
| wasm size=1024 | 2.752 (2.723 to 2.752) |
| digest size=1024 | 5.435 (5.297 to 5.435) |
| digest_js size=1024 | 6.253 (5.648 to 6.253) |
| copy_only size=1024 | 2.852 (2.852 to 2.852) |
| wasm size=2048 | 5.295 (5.273 to 5.295) |
| digest size=2048 | 5.882 (5.83 to 5.882) |
| digest_js size=2048 | 6.096 (6.031 to 6.096) |
| copy_only size=2048 | 3.066 (2.951 to 3.066) |
| wasm size=4096 | 10.6 (10.4 to 10.6) |
| digest size=4096 | 6.98 (6.909 to 6.98) |
| digest_js size=4096 | 6.953 (6.897 to 6.953) |
| copy_only size=4096 | 3.13 (3.064 to 3.13) |
| wasm size=8192 | 20.3 (20.3 to 20.3) |
| digest size=8192 | 9.104 (8.758 to 9.104) |
| digest_js size=8192 | 8.59 (8.482 to 8.59) |
| copy_only size=8192 | 3.557 (3.526 to 3.557) |
| wasm size=16384 | 40.5 (40.4 to 40.5) |
| digest size=16384 | 12.6 (12.6 to 12.6) |
| digest_js size=16384 | 11.8 (11.6 to 11.8) |
| copy_only size=16384 | 4 (3.965 to 4) |
| wasm size=65536 | 163.8 (161.1 to 163.8) |
| digest size=65536 | 35 (34.9 to 35) |
| digest_js size=65536 | 31.5 (31.4 to 31.5) |
| copy_only size=65536 | 7.088 (6.604 to 7.088) |
| wasm size=262144 | 649.1 (644.1 to 649.1) |
| digest size=262144 | 127.2 (126.7 to 127.2) |
| digest_js size=262144 | 110.6 (110.1 to 110.6) |
| copy_only size=262144 | 18.1 (17.8 to 18.1) |
| wasm size=1048576 | 2620.3 (2591.6 to 2620.3) |
| digest size=1048576 | 536.4 (502.5 to 536.4) |
| digest_js size=1048576 | 426 (425.2 to 426) |
| copy_only size=1048576 | 76.1 (72.7 to 76.1) |
