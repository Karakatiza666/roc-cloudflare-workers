Runs: 2. node v26.7.0, AMD Ryzen AI 9 HX 370 w/ Radeon 890M, resumeCheck off. Load average at the start of each run: 2.84, 2.17.

cross

| case | us per operation |
| --- | --- |
| call k=0 | 0.374 (0.358 to 0.374) |
| call k=1 | 1.211 (1.208 to 1.211) |
| call k=4 | 2.806 (2.784 to 2.806) |
| call k=16 | 9.275 (9.032 to 9.275) |
| await k=0 | 1.296 (1.287 to 1.296) |
| await k=1 | 2.071 (2.071 to 2.071) |
| await k=4 | 3.7 (3.662 to 3.7) |
| await k=16 | 10 (9.953 to 10) |
| build k=0 | 0.025 (0.025 to 0.025) |
| build k=1 | 0.167 (0.167 to 0.167) |
| build k=4 | 0.492 (0.486 to 0.492) |
| build k=16 | 1.683 (1.67 to 1.683) |

sha

| case | us per operation |
| --- | --- |
| wasm size=256 | 0.728 (0.707 to 0.728) |
| digest size=256 | 11.2 (11.1 to 11.2) |
| digest_js size=256 | 9.9 (9.358 to 9.9) |
| copy_only size=256 | 2.908 (2.703 to 2.908) |
| wasm size=1024 | 2.35 (2.342 to 2.35) |
| digest size=1024 | 9.481 (9.411 to 9.481) |
| digest_js size=1024 | 9.641 (9.588 to 9.641) |
| copy_only size=1024 | 3.247 (2.833 to 3.247) |
| wasm size=2048 | 4.498 (4.486 to 4.498) |
| digest size=2048 | 9.518 (9.383 to 9.518) |
| digest_js size=2048 | 9.63 (9.413 to 9.63) |
| copy_only size=2048 | 2.866 (2.8 to 2.866) |
| wasm size=4096 | 8.829 (8.796 to 8.829) |
| digest size=4096 | 13 (10.5 to 13) |
| digest_js size=4096 | 10.6 (10.5 to 10.6) |
| copy_only size=4096 | 3.307 (2.921 to 3.307) |
| wasm size=8192 | 17.3 (17.3 to 17.3) |
| digest size=8192 | 13.2 (12.6 to 13.2) |
| digest_js size=8192 | 13.6 (13 to 13.6) |
| copy_only size=8192 | 3.983 (3.539 to 3.983) |
| wasm size=16384 | 34.5 (34.5 to 34.5) |
| digest size=16384 | 17.4 (17.3 to 17.4) |
| digest_js size=16384 | 16.1 (16 to 16.1) |
| copy_only size=16384 | 5.298 (3.962 to 5.298) |
| wasm size=65536 | 137.3 (136.7 to 137.3) |
| digest size=65536 | 43.6 (42.6 to 43.6) |
| digest_js size=65536 | 38.5 (37.6 to 38.5) |
| copy_only size=65536 | 13.071 (7.647 to 13.071) |
| wasm size=262144 | 552.2 (546.9 to 552.2) |
| digest size=262144 | 152.7 (148.5 to 152.7) |
| digest_js size=262144 | 126.4 (125.5 to 126.4) |
| copy_only size=262144 | 42 (24.2 to 42) |
| wasm size=1048576 | 2189.2 (2183.6 to 2189.2) |
| digest size=1048576 | 576 (560.6 to 576) |
| digest_js size=1048576 | 498.4 (468.5 to 498.4) |
| copy_only size=1048576 | 131.1 (103.4 to 131.1) |
