# Platform performance bench

Runs: 1 (a2eef2a4 to a2eef2a4). Source rows: `bench/perf/results/rows.jsonl`. Charts of the local rows use one point for each commit. The edge chart has the edge rows of the post-merge job (CPU time of the real runtime). The instruction charts are workerd instructions for each request with the idle rate subtracted.

### Instructions per request, small (M)

- Line 1: small, steady

```mermaid
xychart-beta
    title "Instructions per request, small (M)"
    x-axis ["a2eef2a"]
    y-axis "M instructions" 3.4146 --> 3.774
    line [3.5943]
```

### Cold extra of the first request, small (M)

- Line 1: first request minus steady

```mermaid
xychart-beta
    title "Cold extra of the first request, small (M)"
    x-axis ["a2eef2a"]
    y-axis "M instructions" 154.95 --> 171.26
    line [163.1]
```

### Instructions per request, other scenarios (M)

- Line 1: search
- Line 2: releases
- Line 3: closure
- Line 4: compat
- Line 5: mixed-ro

```mermaid
xychart-beta
    title "Instructions per request, other scenarios (M)"
    x-axis ["a2eef2a"]
    y-axis "M instructions" 2.9302 --> 20.643
    line [4.4062]
    line [4.6469]
    line [19.167]
    line [5.6463]
    line [14.894]
```

### Allocations per request

- Line 1: small
- Line 2: closure
- Line 3: mixed-ro

```mermaid
xychart-beta
    title "Allocations per request"
    x-axis ["a2eef2a"]
    y-axis "allocs" 12.702 --> 1714.3
    line [154.5]
    line [1572.5]
    line [1398.9]
```

### Size of app.wasm and its largest function (KB)

- Line 1: app.wasm
- Line 2: largest function

```mermaid
xychart-beta
    title "Size of app.wasm and its largest function (KB)"
    x-axis ["a2eef2a"]
    y-axis "KB" 0 --> 3826.1
    line [3491.5]
    line [144.61]
```

### Peak wasm memory (MB)

- Line 1: small
- Line 2: closure
- Line 3: mixed-ro

```mermaid
xychart-beta
    title "Peak wasm memory (MB)"
    x-axis ["a2eef2a"]
    y-axis "MB" 1.9875 --> 2.8875
    line [2.0625]
    line [2.8125]
    line [2.75]
```

### Latest run (a2eef2a4, 2026-11-07T14:43:26Z, nightly nightly-2026-11-06-34f137a)

| Scenario | M ins per request | Cold extra, M ins | Allocs per request | Peak memory, MB |
| --- | --- | --- | --- | --- |
| small | 3.594 | 163.10 | 154.5 | 2.1 |
| search | 4.406 |  | 203.6 | 2.1 |
| releases | 4.647 |  | 206.1 | 2.6 |
| closure | 19.167 |  | 1572.5 | 2.8 |
| compat | 5.646 |  | 364.5 | 2.1 |
| mixed-ro | 14.894 |  | 1398.9 | 2.8 |

app.wasm 3491 KB, largest function 145 KB.
