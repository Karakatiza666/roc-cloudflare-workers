#!/usr/bin/env bash
# Download the C allocators into vendor/ (gitignored): dlmalloc (wasi-libc), emmalloc (emscripten), mimalloc 2.2.4.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p vendor
curl -sSfL -o vendor/dlmalloc.c https://raw.githubusercontent.com/WebAssembly/wasi-libc/main/dlmalloc/src/malloc.c
curl -sSfL -o vendor/emmalloc.c https://raw.githubusercontent.com/emscripten-core/emscripten/main/system/lib/emmalloc.c
curl -sSfL https://github.com/microsoft/mimalloc/archive/refs/tags/v2.2.4.tar.gz | tar xz -C vendor
# emmalloc asserts emscripten's max_align_t (8); wasi has 16. Keep emmalloc's 8.
sed -e 's/^#define MALLOC_ALIGNMENT alignof(max_align_t)/#define MALLOC_ALIGNMENT 8/' -e '/max_align_t must be correct/d' vendor/emmalloc.c > vendor/emmalloc_fa.c
