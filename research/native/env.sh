# Source this: Zig 0.17 and a cache inside research/native (nothing in the repo caches).
R=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
export ZIG=${ZIG:-/home/george/.local/zig/zig-x86_64-linux-0.17.0/zig}
export ZIG_GLOBAL_CACHE_DIR=$R/research/native/.cache/global
export ZIG_LOCAL_CACHE_DIR=$R/research/native/.cache/local
mkdir -p "$ZIG_GLOBAL_CACHE_DIR" "$ZIG_LOCAL_CACHE_DIR"
