# Platform performance bench

Runs: 5 (a2eef2a4 to 9f878196). Source rows: `bench/perf/results/rows.jsonl`. Charts of the local rows use one point for each commit. The edge chart has the edge rows of the post-merge job (CPU time of the real runtime). The instruction charts are workerd instructions for each request with the idle rate subtracted.

### Instructions per request, small (M)

- Line 1: small, steady

```mermaid
xychart-beta
    title "Instructions per request, small (M)"
    x-axis ["a2eef2a", "2ed8a2f", "a9005cf", "5c4600a", "9f87819"]
    y-axis "M instructions" 3.4146 --> 3.774
    line [3.5943, 3.5943, 3.5943, 3.5943, 3.5943]
```

### Cold extra of the first request, small (M)

- Line 1: first request minus steady

```mermaid
xychart-beta
    title "Cold extra of the first request, small (M)"
    x-axis ["a2eef2a", "2ed8a2f", "a9005cf", "5c4600a", "9f87819"]
    y-axis "M instructions" 154.95 --> 171.26
    line [163.1, 163.1, 163.1, 163.1, 163.1]
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
    x-axis ["a2eef2a", "2ed8a2f", "a9005cf", "5c4600a", "9f87819"]
    y-axis "M instructions" 2.9302 --> 20.643
    line [4.4062, 4.4062, 4.4062, 4.4062, 4.4062]
    line [4.6469, 4.6469, 4.6469, 4.6469, 4.6469]
    line [19.167, 19.167, 19.167, 19.167, 19.167]
    line [5.6463, 5.6463, 5.6463, 5.6463, 5.6463]
    line [14.894, 14.894, 14.894, 14.894, 14.894]
```

### Crossings per request (JS/wasm calls, exact)

- Line 1: small
- Line 2: closure
- Line 3: mixed-ro

```mermaid
xychart-beta
    title "Crossings per request (JS/wasm calls, exact)"
    x-axis ["a2eef2a", "2ed8a2f", "a9005cf", "5c4600a", "9f87819"]
    y-axis "calls" 1.05 --> 6.45
    line [0, 0, 1.5, 1.5, 1.5]
    line [0, 0, 6, 6, 6]
    line [0, 0, 3.925, 3.925, 3.925]
```

### Allocations per request

- Line 1: small
- Line 2: closure
- Line 3: mixed-ro

```mermaid
xychart-beta
    title "Allocations per request"
    x-axis ["a2eef2a", "2ed8a2f", "a9005cf", "5c4600a", "9f87819"]
    y-axis "allocs" 11.854 --> 1723.6
    line [154.5, 154.5, 154.5, 154.5, 154.5]
    line [1572.5, 1572.5, 1572.5, 1572.5, 1581]
    line [1398.9, 1398.9, 1398.9, 1398.9, 1372.4]
```

### Size of app.wasm and its largest function (KB)

- Line 1: app.wasm
- Line 2: largest function

```mermaid
xychart-beta
    title "Size of app.wasm and its largest function (KB)"
    x-axis ["a2eef2a", "2ed8a2f", "a9005cf", "5c4600a", "9f87819"]
    y-axis "KB" 0 --> 5443.2
    line [3491.5, 3491.5, 3491.5, 3493.1, 4961.5]
    line [144.61, 144.61, 144.61, 144.61, 159.72]
```

### Peak wasm memory (MB)

- Line 1: small
- Line 2: closure
- Line 3: mixed-ro

```mermaid
xychart-beta
    title "Peak wasm memory (MB)"
    x-axis ["a2eef2a", "2ed8a2f", "a9005cf", "5c4600a", "9f87819"]
    y-axis "MB" 1.975 --> 3.025
    line [2.0625, 2.0625, 2.0625, 2.125, 2.125]
    line [2.8125, 2.8125, 2.8125, 2.875, 2.875]
    line [2.75, 2.75, 2.75, 2.9375, 2.9375]
```

### Latest run (9f878196, 2026-11-11T10:49:34Z, nightly nightly-2026-11-06-34f137a)

| Scenario | M ins (perf) or Ir (vg) per request | Cold extra, M ins | Allocs per request | Peak memory, MB |
| --- | --- | --- | --- | --- |
| small |  |  | 154.5 | 2.1 |
| search |  |  | 203.6 | 2.1 |
| releases |  |  | 206.2 | 2.6 |
| closure |  |  | 1581.0 | 2.9 |
| compat |  |  | 365.7 | 2.1 |
| mixed-ro |  |  | 1372.4 | 2.9 |

app.wasm 4961 KB, largest function 160 KB.
