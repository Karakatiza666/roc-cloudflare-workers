| scenario | variant | c | requests | 5xx | final mem MB | max mem MB | max livePeak KB | livePeak at max mem KB | max mem / max livePeak | growth 2nd third KB | growth last third KB | still growing | requests to 90 % of max |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| closure+releases | base | c10 | 40000 | 0 | 3.06 | 3.06 | 599 | 599 | 5.24 | 0 | 0 | no | 115 |
| closure+releases | base | c32 | 40000 | 0 | 4.25 | 4.25 | 1347 | 1347 | 3.23 | 0 | 0 | no | 2 |
| closure+releases | fa_dl | c10 | 40000 | 0 | 1.94 | 1.94 | 617 | 617 | 3.21 | 0 | 0 | no | 116 |
| closure+releases | fa_dl | c32 | 40000 | 0 | 2.81 | 2.81 | 1335 | 1335 | 2.16 | 192 | 0 | no | 3 |
| closure+releases | fa_zig | c10 | 40000 | 0 | 4.31 | 4.31 | 597 | 442 | 7.40 | 0 | 0 | no | 132 |
| closure+releases | fa_zig | c32 | 40000 | 0 | 5.50 | 5.50 | 1249 | 1062 | 4.51 | 64 | 0 | no | 107 |
| mixed | base | c10 | 60000 | 0 | 3.38 | 3.38 | 871 | 809 | 3.97 | 0 | 0 | no | 42 |
| mixed | base | c32 | 60000 | 0 | 4.44 | 4.44 | 1486 | 1304 | 3.06 | 0 | 0 | no | 54 |
| mixed | fa_dl | c10 | 60000 | 0 | 2.19 | 2.19 | 848 | 667 | 2.64 | 64 | 0 | no | 51 |
| mixed | fa_dl | c32 | 60000 | 0 | 2.88 | 2.88 | 1343 | 1298 | 2.19 | 0 | 0 | no | 557 |
| mixed | fa_zig | c10 | 60000 | 0 | 4.31 | 4.31 | 847 | 600 | 5.21 | 64 | 0 | no | 198 |
| mixed | fa_zig | c32 | 60000 | 0 | 5.56 | 5.56 | 1604 | 1477 | 3.55 | 64 | 128 | yes | 841 |
